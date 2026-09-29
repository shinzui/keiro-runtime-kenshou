module Main (main) where

import Control.Exception (bracket_)
import Data.Aeson (Value (..), encode, object, toJSON, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString qualified as ByteString
import Data.ByteString.Char8 qualified as ByteString.Char8
import Data.ByteString.Lazy qualified as LazyByteString
import Data.List.NonEmpty qualified as NonEmpty
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as Text.IO
import Data.Time (UTCTime (..), fromGregorian)
import Kenshou.Core.Canonical (sha256Hex)
import Kenshou.Core.Cli.Config (ConfigInputs (..))
import Kenshou.Core.Id (parseRunId, parseScenarioId)
import Kenshou.Core.Manifest (writeManifest)
import Kenshou.Core.Outcome (Outcome (InfrastructureFailure, Passed))
import Kenshou.Evidence.Attest (AttestOptions (..), AttestResult (..), Recomputation (..), Recomputer (..), attest, coreRecomputers)
import Kenshou.Evidence.Bundle (BundleWriteError (..), BundleWriteResult (..), runRecordPath, writeAttestationRecord, writeRunRecord, writeRunRecordWith)
import Kenshou.Evidence.Check (CheckOptions (..), Finding (..), checkBundle, checkBundleWithStore, checkDocument)
import Kenshou.Evidence.Config (EvidenceDefaults (..), bundleRootKey, dataBaseUriKey, projectKey, resolveEvidenceDefaults)
import Kenshou.Evidence.Frontmatter (AttestationCheck (..), AttestationEvidence (..), EvidenceRecord (..), recordFromDocument, recordToDocument)
import Kenshou.Evidence.History (HistoryDocument (..), HistoryEntry (..), HistoryQuery (..), deriveBaseline, history)
import Kenshou.Evidence.Publish (PublishError (..), PublishOptions (..), UploadMode (..), publishComparisonData, publishRunData)
import Kenshou.Evidence.Record (RecordInput (..), RecordOptions (..), RecordOutcome (..), buildRunRecord, recordComparison, recordRunWith)
import Kenshou.Evidence.Source (ComparisonSource (..), ComparisonView (..), RunResultView (..), RunSource (..), VerifiedFile (..), loadComparisonSource, loadRunSource)
import Kenshou.Evidence.Store (ObjectStat (..), ObjectStore (..), PutResult (..), StoreError (..), directoryStore, gcloudStoreWith, memoryStore)
import Kenshou.Evidence.Types (DataKind (..), DataLink (..), Purpose (..), Revision (..), Sha256 (..), SubjectKind (..), mkRevision, mkSha256, sha256Bytes)
import Kenshou.Remote.Cell.Docs (Artifact (Artifact), CellManifest (CellManifest), ManifestPayload (ManifestPayload))
import Kenshou.Remote.Cell.Docs qualified as Cell
import Kenshou.Remote.Cell.Index (CellManifestLink (CellManifestLink), CellRunIndex (..), RunLink (RunLink))
import Okf.Actor (Actor (ProcessActor))
import Okf.Document (OKFDocument (..), Verification (..), frontmatterLookup, parseDocument, readVerified, serializeDocument, setField, setVerified)
import Settei (ResolveResult (..))
import Settei.Env (envSnapshot)
import Settei.Optparse (DiagnosticMode (NoDiagnostic), cliOverride, cliSources)
import System.Directory (Permissions (..), createDirectoryIfMissing, doesFileExist, getCurrentDirectory, getPermissions, removeFile, setCurrentDirectory, setPermissions)
import System.FilePath (takeDirectory, (</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Process (callProcess, readProcess)
import Test.Hspec

main :: IO ()
main = hspec do
  describe "loadComparisonSource" do
    it "accepts a self-contained comparison and refuses inconsistent arms" do
      withSystemTempDirectory "kenshou-comparison-source" $ \root -> do
        let path = root </> "comparison.json"
            baseline = "01997f3a-5b7c-7e21-8a44-0d6c2f9b1e55" :: Text
            candidate = "01997f3a-5b7c-7e21-8a44-0d6c2f9b1e56" :: Text
            comparison =
              object
                [ "schema" .= ("kenshou.comparison/v1" :: Text),
                  "comparisonId" .= ("01997f3a-5b7c-7e21-8a44-0d6c2f9b1e57" :: Text),
                  "baselineRuns" .= [baseline],
                  "candidateRuns" .= [candidate],
                  "startedAt" .= ("2026-09-26T00:00:00Z" :: Text),
                  "finishedAt" .= ("2026-09-26T00:00:01Z" :: Text),
                  "harnessRevision" .= Text.replicate 40 "f",
                  "harnessDirty" .= False,
                  "design" .= ("sequential" :: Text),
                  "variedFactors" .= ["cohort" :: Text],
                  "pairCount" .= (1 :: Int),
                  "verdict" .= ("pass" :: Text)
                ]
        LazyByteString.writeFile path (encode comparison)
        loaded <- loadComparisonSource path
        loaded `shouldSatisfy` \case
          Right source -> source.view.pairCount == 1 && source.file.digest == sha256Bytes (LazyByteString.toStrict (encode comparison))
          Left _ -> False
        source <- either (fail . show) pure loaded
        store <- memoryStore
        linked <- publishComparisonData store (PublishOptions "gs://bucket/runs" UploadMissing True False) path source
        linked `shouldSatisfy` \case
          Right link -> link.kind == ComparisonData && "/comparison.json" `Text.isSuffixOf` link.uri
          Left _ -> False
        LazyByteString.writeFile path (encode (object ["schema" .= ("kenshou.comparison/v1" :: Text), "comparisonId" .= ("01997f3a-5b7c-7e21-8a44-0d6c2f9b1e57" :: Text), "baselineRuns" .= [baseline], "candidateRuns" .= [baseline], "startedAt" .= ("2026-09-26T00:00:00Z" :: Text), "finishedAt" .= ("2026-09-26T00:00:01Z" :: Text), "harnessRevision" .= Text.replicate 40 "f", "harnessDirty" .= False, "design" .= ("sequential" :: Text), "variedFactors" .= ["cohort" :: Text], "pairCount" .= (1 :: Int), "verdict" .= ("pass" :: Text)]))
        loadComparisonSource path >>= (`shouldSatisfy` isLeft)

    it "records a comparison only after both arm concepts exist" do
      withSystemTempDirectory "kenshou-comparison-record" $ \root -> do
        let runDirectory = root </> "run"
            bundle = root </> "bundle"
            comparisonPath = root </> "comparison.json"
            baselineId = "01997f3a-5b7c-7e21-8a44-0d6c2f9b1e55" :: Text
            candidateId = "01997f3a-5b7c-7e21-8a44-0d6c2f9b1e56" :: Text
            comparisonId = "01997f3a-5b7c-7e21-8a44-0d6c2f9b1e57" :: Text
            options = RecordOptions bundle "gs://bucket/runs" Release UploadMissing False False False Nothing []
            comparison =
              object
                [ "schema" .= ("kenshou.comparison/v1" :: Text),
                  "comparisonId" .= comparisonId,
                  "baselineRuns" .= [baselineId],
                  "candidateRuns" .= [candidateId],
                  "startedAt" .= ("2026-09-26T00:00:00Z" :: Text),
                  "finishedAt" .= ("2026-09-26T00:00:01Z" :: Text),
                  "harnessRevision" .= Text.replicate 40 "f",
                  "harnessDirty" .= False,
                  "design" .= ("sequential" :: Text),
                  "variedFactors" .= ["cohort" :: Text],
                  "pairCount" .= (1 :: Int),
                  "verdict" .= ("pass" :: Text)
                ]
        createDirectoryIfMissing True runDirectory
        createDirectoryIfMissing True bundle
        callProcess "cp" ["-R", "../docs/verification/.", bundle]
        writeRunFixture runDirectory
        source <- loadRunSource runDirectory >>= either (fail . show) pure
        store <- memoryStore
        links <- publishRunData store (PublishOptions "gs://bucket/runs" UploadMissing False False) runDirectory source >>= either (fail . show) pure
        baseline <- either (fail . show) pure (buildRunRecord (RecordInput Baseline (UTCTime (fromGregorian 2026 9 26) 0) False Nothing [] Nothing) source links)
        writeRunRecord bundle baseline >>= (`shouldSatisfy` isRight)
        LazyByteString.writeFile comparisonPath (encode comparison)
        recordComparison store options comparisonPath >>= (`shouldSatisfy` isLeft)
        let candidate =
              baseline
                { runId = candidateId,
                  cohort = "candidate",
                  dataLinks = [link {uri = Text.replace baselineId candidateId link.uri} | link <- baseline.dataLinks]
                }
        writeRunRecord bundle candidate >>= (`shouldSatisfy` isRight)
        recordComparison store options comparisonPath `shouldReturn` Right (Recorded "runs/selftest/2026/09/01997f3a-5b7c-7e21-8a44-0d6c2f9b1e57.md")
        recordComparison store options comparisonPath `shouldReturn` Right (AlreadyRecorded "runs/selftest/2026/09/01997f3a-5b7c-7e21-8a44-0d6c2f9b1e57.md")
        checkBundle (CheckOptions bundle Nothing False False) `shouldReturn` Right []
        comparisonAttested <- attest store coreRecomputers (AttestOptions bundle False False Nothing) comparisonId
        comparisonAttested `shouldSatisfy` \case
          Right result -> result.verdict == "refuted"
          Left _ -> False
        checkBundle (CheckOptions bundle Nothing False False) `shouldReturn` Right []
        let recordedPath = "runs/selftest/2026/09/01997f3a-5b7c-7e21-8a44-0d6c2f9b1e57.md"
        recorded <- Text.IO.readFile (bundle </> recordedPath) >>= either (fail . show) pure . parseDocument
        let wrongOutcome = recorded {frontmatter = setField "outcome" (String "failed") recorded.frontmatter}
        map (.rule) (checkDocument recordedPath wrongOutcome) `shouldContain` ["comparison-outcome"]
        attested <- attest store coreRecomputers (AttestOptions bundle False False Nothing) "runs/selftest/2026/09/01997f3a-5b7c-7e21-8a44-0d6c2f9b1e55.md"
        attested `shouldSatisfy` \case
          Right result -> result.verdict == "incomplete"
          Left _ -> False
        case attested of
          Right result -> do
            attestation <- Text.IO.readFile (bundle </> result.path) >>= either (fail . show) pure . parseDocument
            let recomputationPassed = case frontmatterLookup "checks" attestation.frontmatter of
                  Just (Array values) -> any (\case Object fields -> KeyMap.lookup "name" fields == Just (String "verdict-recomputed") && KeyMap.lookup "result" fields == Just (String "passed"); _ -> False) values
                  _ -> False
            recomputationPassed `shouldBe` True
          Left err -> fail (show err)
        checkBundle (CheckOptions bundle Nothing False False) `shouldReturn` Right []
        let tamperedStore =
              store
                { fetchObject = \uri destination -> do
                    fetched <- store.fetchObject uri destination
                    case fetched of
                      Right () | "/run-result.json" `Text.isSuffixOf` uri -> ByteString.Char8.appendFile destination "tampered"
                      _ -> pure ()
                    pure fetched
                }
        tampered <- attest tamperedStore coreRecomputers (AttestOptions bundle False False Nothing) baselineId
        tampered `shouldSatisfy` \case
          Right result -> result.verdict == "refuted"
          Left _ -> False
        checkBundle (CheckOptions bundle Nothing False False) `shouldReturn` Right []
        let disagreeing = Recomputer "run-outcome" 1 (\_ -> pure (Right (Recomputation False (Just Passed) Nothing "replayed outcome differs")))
        recomputed <- attest store [disagreeing] (AttestOptions bundle False False Nothing) baselineId
        recomputed `shouldSatisfy` \case
          Right result -> result.verdict == "refuted"
          Left _ -> False
        checkBundle (CheckOptions bundle Nothing False False) `shouldReturn` Right []
        let attestationRecord =
              AttestationEvidence
                { title = "Attestation of baseline — incomplete",
                  description = "The source data was checked; outcome recomputation is pending.",
                  generatedAt = "2026-09-26T00:00:02Z",
                  attestationId = "01997f3a-5b7c-7e21-8a44-0d6c2f9b1e5a",
                  run = "/runs/selftest/2026/09/01997f3a-5b7c-7e21-8a44-0d6c2f9b1e55.md",
                  attesterRevision = Revision (Text.replicate 40 "f"),
                  attestedAt = "2026-09-26T00:00:02Z",
                  verdict = "incomplete",
                  checks = [AttestationCheck name "skipped" Nothing | name <- ["digests-match", "revisions-resolve", "cohort-matches-plan", "verdict-recomputed", "environment-captured", "clean-worktree"]],
                  dataDigests = map (.digest) baseline.dataLinks,
                  exception = Nothing,
                  body = "The attestation is incomplete.\n"
                }
        writeAttestationRecord bundle attestationRecord >>= (`shouldSatisfy` isRight)
        checkBundle (CheckOptions bundle Nothing False False) `shouldReturn` Right []
        let attestationPath = bundle </> "attestations/2026/09/01997f3a-5b7c-7e21-8a44-0d6c2f9b1e5a.md"
        originalAttestation <- Text.IO.readFile attestationPath
        attestationDocument <- either (fail . show) pure (parseDocument originalAttestation)
        Text.IO.writeFile attestationPath (serializeDocument (attestationDocument {frontmatter = setField "verdict" (String "confirmed") attestationDocument.frontmatter}))
        invalidAttestation <- checkBundle (CheckOptions bundle Nothing False False)
        invalidAttestation `shouldSatisfy` \case
          Right findings -> any (\finding -> finding.rule == "attestation-consistency") findings
          Left _ -> False
        Text.IO.writeFile attestationPath originalAttestation
        scenario <- either (fail . show) pure (parseScenarioId "selftest/kernel/correctness/always-pass")
        observed <- history bundle (HistoryQuery scenario Nothing [] Nothing False) >>= either (fail . show) pure
        let fixtureEntries = filter (\entry -> any (`Text.isSuffixOf` entry.concept) [baselineId, candidateId, comparisonId]) observed.entries
        length fixtureEntries `shouldBe` 3
        map (.recordKind) fixtureEntries `shouldBe` ["run", "run", "comparison"]
        let baselineEntry = (fixtureEntries !! 0) {trust = "machine-confirmed", attestations = [object ["verdict" .= ("confirmed" :: Text), "attestedAt" .= ("2026-09-26T00:00:03Z" :: Text)]]}
            laterEntry = (fixtureEntries !! 1 :: HistoryEntry) {startedAt = "2026-09-26T00:00:02Z"}
        deriveBaseline [baselineEntry, laterEntry] laterEntry `shouldBe` Just baselineEntry.concept
        let runPath = bundle </> "runs/selftest/2026/09/01997f3a-5b7c-7e21-8a44-0d6c2f9b1e55.md"
            actor = ProcessActor "kenshou-attester/0.1.0.0"
            firstTime = "2026-09-26T00:00:03Z"
            confirmedAttestation =
              attestationRecord
                { attestationId = "01997f3a-5b7c-7e21-8a44-0d6c2f9b1e5b",
                  generatedAt = firstTime,
                  attestedAt = firstTime,
                  verdict = "confirmed",
                  checks = [AttestationCheck name "passed" Nothing | name <- ["digests-match", "revisions-resolve", "cohort-matches-plan", "verdict-recomputed", "environment-captured", "clean-worktree"]]
                }
        runDocument <- Text.IO.readFile runPath >>= either (fail . show) pure . parseDocument
        Text.IO.writeFile runPath (serializeDocument (runDocument {frontmatter = setVerified [Verification actor (Just firstTime)] runDocument.frontmatter}))
        writeAttestationRecord bundle confirmedAttestation >>= (`shouldSatisfy` isRight)
        writeAttestationRecord bundle (confirmedAttestation {attestationId = "01997f3a-5b7c-7e21-8a44-0d6c2f9b1e5c", generatedAt = "2026-09-26T00:00:04Z", attestedAt = "2026-09-26T00:00:04Z"}) >>= (`shouldSatisfy` isRight)
        checkBundle (CheckOptions bundle Nothing False False) `shouldReturn` Right []
        let attestations = bundle </> "attestations/2026/09"
            target = "/runs/selftest/2026/09/01997f3a-5b7c-7e21-8a44-0d6c2f9b1e55.md"
            attestation verdict at = Text.unlines ["---", "type: Attestation", "run: " <> target, "verdict: " <> verdict, "attestedAt: " <> at, "---"]
        createDirectoryIfMissing True attestations
        Text.IO.writeFile (attestations </> "01997f3a-5b7c-7e21-8a44-0d6c2f9b1e58.md") (attestation "confirmed" "2099-09-27T00:00:03Z")
        confirmedHistory <- history bundle (HistoryQuery scenario Nothing [] Nothing False) >>= either (fail . show) pure
        (confirmedHistory.entries !! 0).trust `shouldBe` "machine-confirmed"
        Text.IO.writeFile (attestations </> "01997f3a-5b7c-7e21-8a44-0d6c2f9b1e59.md") (attestation "refuted" "2099-09-27T00:00:04Z")
        refutedHistory <- history bundle (HistoryQuery scenario Nothing [] Nothing False) >>= either (fail . show) pure
        (refutedHistory.entries !! 0).trust `shouldBe` "unverified"

  describe "attest" do
    it "confirms a cell infrastructure override while recomputing the sealed nested verdict" do
      withSystemTempDirectory "kenshou-cell-attestation" $ \root -> do
        let attester = root </> "attester"
            bundle = root </> "bundle"
            cellRunId = "01997f3a-5b7c-7e21-8a44-0d6c2f9b1e66" :: Text
            nestedId = "01997f3a-5b7c-7e21-8a44-0d6c2f9b1e55" :: Text
            runDirectory = root </> "cell-run" </> "tree" </> "output" </> Text.unpack nestedId
            outerPath = root </> "cell-run" </> "tree" </> "manifest.json"
            baseUri = "gs://bucket/runs/" <> cellRunId <> "/output"
            outerUri = "gs://bucket/runs/" <> cellRunId <> "/manifest.json"
            recordPath = "runs/selftest/2026/09/01997f3a-5b7c-7e21-8a44-0d6c2f9b1e55.md"
        createDirectoryIfMissing True attester
        createDirectoryIfMissing True bundle
        callProcess "git" ["-C", attester, "init", "-q"]
        callProcess "git" ["-C", attester, "config", "user.name", "Kenshou Test"]
        callProcess "git" ["-C", attester, "config", "user.email", "kenshou@example.invalid"]
        ByteString.Char8.writeFile (attester </> "README") "clean attester\n"
        callProcess "git" ["-C", attester, "add", "README"]
        callProcess "git" ["-C", attester, "commit", "-qm", "test: create clean attester"]
        revision <- Text.strip . Text.pack <$> readProcess "git" ["-C", attester, "rev-parse", "HEAD"] ""
        callProcess "cp" ["-R", "../docs/verification/.", bundle]
        writeCellRunFixture runDirectory outerPath cellRunId revision False
        source <- loadRunSource runDirectory >>= either (fail . show) pure
        store <- memoryStore
        store.putObjectIfAbsent outerPath outerUri "application/json" >>= (`shouldSatisfy` isRight)
        links <- publishRunData store (PublishOptions baseUri UploadMissing True False) runDirectory source >>= either (fail . show) pure
        record <- either (fail . show) pure (buildRunRecord (RecordInput Investigation (UTCTime (fromGregorian 2026 9 26) 0) False Nothing [] Nothing) source links)
        record.outcome `shouldBe` InfrastructureFailure
        case record.environment of
          Object fields -> do
            KeyMap.lookup "cellRun" fields `shouldBe` Just (String cellRunId)
            KeyMap.lookup "machineType" fields `shouldBe` Nothing
            KeyMap.lookup "zone" fields `shouldBe` Nothing
          _ -> expectationFailure "cell environment must be an object"
        writeRunRecord bundle record >>= (`shouldSatisfy` isRight)
        originalDirectory <- getCurrentDirectory
        bracket_ (setCurrentDirectory attester) (setCurrentDirectory originalDirectory) do
          confirmed <- attest store coreRecomputers (AttestOptions bundle True False Nothing) (Text.pack recordPath)
          confirmed `shouldSatisfy` \case Right result -> result.verdict == "confirmed"; Left _ -> False
          checkBundle (CheckOptions bundle Nothing False False) `shouldReturn` Right []

    it "confirms a clean self-test run and appends one verified entry across two attestations" do
      withSystemTempDirectory "kenshou-confirmed-attestation" $ \root -> do
        let attester = root </> "attester"
            bundle = root </> "bundle"
            runDirectory = root </> "run"
            recordPath = "runs/selftest/2026/09/01997f3a-5b7c-7e21-8a44-0d6c2f9b1e55.md"
        createDirectoryIfMissing True attester
        createDirectoryIfMissing True bundle
        createDirectoryIfMissing True runDirectory
        callProcess "git" ["-C", attester, "init", "-q"]
        callProcess "git" ["-C", attester, "config", "user.name", "Kenshou Test"]
        callProcess "git" ["-C", attester, "config", "user.email", "kenshou@example.invalid"]
        ByteString.Char8.writeFile (attester </> "README") "clean attester\n"
        callProcess "git" ["-C", attester, "add", "README"]
        callProcess "git" ["-C", attester, "commit", "-qm", "test: create clean attester"]
        revision <- Text.strip . Text.pack <$> readProcess "git" ["-C", attester, "rev-parse", "HEAD"] ""
        callProcess "cp" ["-R", "../docs/verification/.", bundle]
        writeRunFixtureWithRevision runDirectory revision
        source <- loadRunSource runDirectory >>= either (fail . show) pure
        store <- memoryStore
        links <- publishRunData store (PublishOptions "gs://bucket/runs" UploadMissing False False) runDirectory source >>= either (fail . show) pure
        record <- either (fail . show) pure (buildRunRecord (RecordInput Baseline (UTCTime (fromGregorian 2026 9 26) 0) False Nothing [] Nothing) source links)
        writeRunRecord bundle record >>= (`shouldSatisfy` isRight)
        originalDirectory <- getCurrentDirectory
        bracket_ (setCurrentDirectory attester) (setCurrentDirectory originalDirectory) do
          first <- attest store coreRecomputers (AttestOptions bundle True False Nothing) (Text.pack recordPath)
          first `shouldSatisfy` \case Right result -> result.verdict == "confirmed"; Left _ -> False
          checkBundle (CheckOptions bundle Nothing False False) `shouldReturn` Right []
          second <- attest store coreRecomputers (AttestOptions bundle True False Nothing) record.runId
          second `shouldSatisfy` \case Right result -> result.verdict == "confirmed"; Left _ -> False
          checkBundle (CheckOptions bundle Nothing False False) `shouldReturn` Right []
        confirmedRun <- Text.IO.readFile (bundle </> recordPath) >>= either (fail . show) pure . parseDocument
        length (readVerified confirmedRun.frontmatter) `shouldBe` 1

  describe "evidence configuration" do
    it "uses built-ins, ordered YAML, environment, then named flags" do
      withSystemTempDirectory "kenshou-evidence-config" $ \root -> do
        let first = root </> "first.yaml"
            second = root </> "second.yaml"
            flags = cliSources "named flags" [cliOverride bundleRootKey "flag-bundle", cliOverride projectKey "flag-project", cliOverride dataBaseUriKey "gs://flag/runs"]
            inputs = ConfigInputs [first, second] flags NoDiagnostic
            snapshot = envSnapshot [("KENSHOU_EVIDENCE_BUNDLE", "env-bundle"), ("KENSHOU_GCP_PROJECT", "env-project"), ("KENSHOU_EVIDENCE_DATA_BASE_URI", "gs://env/runs")]
        writeFile first "evidence:\n  bundle-root: first-bundle\n  data-base-uri: gs://first/runs\ngcp:\n  project: first-project\n"
        writeFile second "evidence:\n  bundle-root: second-bundle\n  data-base-uri: gs://second/runs\ngcp:\n  project: second-project\n"
        resolved <- resolveEvidenceDefaults snapshot inputs
        case resolved of
          Right result -> result.answer `shouldBe` Right (EvidenceDefaults "flag-bundle" (Just "flag-project") (Just "gs://flag/runs"))
          Left err -> expectationFailure (Text.unpack err)
        builtIn <- resolveEvidenceDefaults (envSnapshot []) (ConfigInputs [] [] NoDiagnostic)
        case builtIn of
          Right result -> result.answer `shouldBe` Right (EvidenceDefaults "docs/verification" Nothing Nothing)
          Left err -> expectationFailure (Text.unpack err)

    it "rejects purpose and anomaly authority as unknown configuration" do
      withSystemTempDirectory "kenshou-evidence-config" $ \root -> do
        let file = root </> "invalid.yaml"
        writeFile file "evidence:\n  purpose: release\n  anomaly-authority: process:someone\n"
        resolved <- resolveEvidenceDefaults (envSnapshot []) (ConfigInputs [file] [] NoDiagnostic)
        case resolved of
          Right result -> case result.answer of
            Left problems -> length (NonEmpty.toList problems) `shouldSatisfy` (>= 2)
            Right _ -> expectationFailure "unexpectedly accepted unknown configuration"
          Left err -> expectationFailure (Text.unpack err)

  describe "evidence check" do
    it "detects event keys, coerced strings, non-durable links and changed committed records" do
      withSystemTempDirectory "kenshou-evidence-check" $ \root -> do
        let runDirectory = root </> "run"
            repo = root </> "repo"
            bundle = repo </> "docs/verification"
        createDirectoryIfMissing True runDirectory
        writeRunFixture runDirectory
        source <- loadRunSource runDirectory >>= either (fail . show) pure
        store <- memoryStore
        links <- publishRunData store (PublishOptions "gs://bucket/runs" UploadMissing False False) runDirectory source >>= either (fail . show) pure
        record <- either (fail . show) pure (buildRunRecord (RecordInput Baseline (UTCTime (fromGregorian 2026 9 26) 0) False Nothing [] Nothing) source links)
        path <- either (fail . show) pure (runRecordPath record)
        let document = recordToDocument record
            eventKey = document {frontmatter = setField "status" (String "stable") document.frontmatter}
            coerced = document {frontmatter = setField "dimensions" (toJSON [object ["name" .= ("telemetry" :: Text), "value" .= False]]) document.frontmatter}
            nonDurable = recordToDocument (record {dataLinks = [link {uri = "file:///tmp/sample"} | link <- record.dataLinks]})
        map (.rule) (checkDocument path eventKey) `shouldContain` ["event-keys"]
        map (.rule) (checkDocument path coerced) `shouldContain` ["string-typing"]
        map (.rule) (checkDocument path nonDurable) `shouldContain` ["data-uri"]
        createDirectoryIfMissing True (takeDirectory (bundle </> path))
        Text.IO.writeFile (bundle </> path) (serializeDocument document)
        callProcess "git" ["init", "-q", repo]
        callProcess "git" ["-C", repo, "-c", "user.name=Kenshou", "-c", "user.email=kenshou@example.invalid", "add", "."]
        callProcess "git" ["-C", repo, "-c", "user.name=Kenshou", "-c", "user.email=kenshou@example.invalid", "commit", "-qm", "test: record evidence fixture"]
        checkBundle (CheckOptions bundle Nothing False False) `shouldReturn` Right []
        checkBundleWithStore (Just store) (CheckOptions bundle Nothing True True) `shouldReturn` Right []
        absent <- memoryStore
        missing <- checkBundleWithStore (Just absent) (CheckOptions bundle Nothing True False)
        missing `shouldSatisfy` \case
          Right findings -> any (\finding -> finding.rule == "network" && "missing" `Text.isInfixOf` finding.message) findings
          Left _ -> False
        let nextId = "01997f3a-5b7c-7e21-8a44-0d6c2f9b1e56"
            addedRecord = record {runId = nextId, dataLinks = [link {uri = Text.replace record.runId nextId link.uri} | link <- record.dataLinks]}
        addedPath <- either (fail . show) pure (runRecordPath addedRecord)
        Text.IO.writeFile (bundle </> addedPath) (serializeDocument (recordToDocument addedRecord))
        callProcess "git" ["-C", repo, "add", bundle </> addedPath]
        stagedAddition <- checkBundle (CheckOptions bundle Nothing False False)
        stagedAddition `shouldSatisfy` \case
          Right findings -> not (any (\finding -> finding.rule == "immutability" && finding.concept == addedPath) findings)
          Left _ -> False
        let selfReference = document {frontmatter = setField "previousRun" (String ("/" <> Text.pack path)) document.frontmatter}
        Text.IO.writeFile (bundle </> path) (serializeDocument selfReference)
        referenced <- checkBundle (CheckOptions bundle Nothing False False)
        referenced `shouldSatisfy` \case
          Right findings -> any (\finding -> finding.rule == "reference-targets") findings
          Left _ -> False
        let changed = document {frontmatter = setField "outcome" (String "failed") document.frontmatter}
        Text.IO.writeFile (bundle </> path) (serializeDocument changed)
        checked <- checkBundle (CheckOptions bundle Nothing False False)
        checked `shouldSatisfy` \case
          Right findings -> any (\finding -> finding.rule == "immutability" && finding.concept == path && "outcome" `Text.isInfixOf` finding.message) findings
          Left _ -> False
        callProcess "git" ["-C", repo, "add", "."]
        callProcess "git" ["-C", repo, "-c", "user.name=Kenshou", "-c", "user.email=kenshou@example.invalid", "commit", "-qm", "test: change evidence fixture"]
        committed <- checkBundle (CheckOptions bundle Nothing False False)
        committed `shouldSatisfy` \case
          Right findings -> any (\finding -> finding.rule == "immutability" && finding.concept == path && "outcome" `Text.isInfixOf` finding.message) findings
          Left _ -> False
  describe "recordRunWith" do
    it "records once and reports the same fact on replay" do
      withSystemTempDirectory "kenshou-record-command" $ \root -> do
        let runDirectory = root </> "run"
            bundle = root </> "bundle"
            options = RecordOptions bundle "gs://bucket/runs" Baseline UploadMissing False False False Nothing []
            timestamp = UTCTime (fromGregorian 2026 9 26) 0
            path = "runs/selftest/2026/09/01997f3a-5b7c-7e21-8a44-0d6c2f9b1e55.md"
            accept _ = pure (Right ())
        createDirectoryIfMissing True runDirectory
        createDirectoryIfMissing True bundle
        writeRunFixture runDirectory
        store <- memoryStore
        recordRunWith (writeRunRecordWith accept) timestamp store options runDirectory `shouldReturn` Right (Recorded path)
        recordRunWith (writeRunRecordWith accept) timestamp store options runDirectory `shouldReturn` Right (AlreadyRecorded path)

  describe "buildRunRecord" do
    it "names VC-2 only when a soak has its measurement summary" do
      withSystemTempDirectory "kenshou-soak-computations" $ \root -> do
        writeRunFixture root
        source <- loadRunSource root >>= either (fail . show) pure
        store <- memoryStore
        links <- publishRunData store (PublishOptions "gs://bucket/runs" UploadMissing False False) root source >>= either (fail . show) pure
        soakId <- either (fail . show) pure (parseScenarioId "kafka/pipeline/soak/consumer-memory-and-fd-stability-reduced")
        let input = RecordInput Baseline (UTCTime (fromGregorian 2026 9 26) 0) False Nothing [] Nothing
            withoutSummary = RunSource source.manifest source.spec (source.result {resultScenario = soakId, resultSummaries = Just (object ["measurements" .= object ["kafka" .= object []]])}) source.files source.cellEvidence
            withSummary = RunSource source.manifest source.spec (source.result {resultScenario = soakId, resultSummaries = Just (object ["measurements" .= object ["measurements" .= object []]])}) source.files source.cellEvidence
        without <- either (fail . show) pure (buildRunRecord input withoutSummary links)
        with <- either (fail . show) pure (buildRunRecord input withSummary links)
        without.computations `shouldBe` ["VC-1"]
        with.computations `shouldBe` ["VC-1", "VC-2"]
    it "preserves every owner reference from a grouped known-defect result" do
      withSystemTempDirectory "kenshou-grouped-defects" $ \root -> do
        let first = "mori://shinzui/shibuya-kafka-adapter/okf/bug-reports/concepts/BUG-4" :: Text
            second = "mori://shinzui/shibuya-kafka-adapter/okf/bug-reports/concepts/BUG-6" :: Text
            defect = object ["status" .= ("reproduced" :: Text), "defects" .= [object ["reference" .= first], object ["reference" .= second]]]
        writeRunFixtureWithKnownDefect root defect
        source <- loadRunSource root >>= either (fail . show) pure
        store <- memoryStore
        links <- publishRunData store (PublishOptions "gs://bucket/runs" UploadMissing False False) root source >>= either (fail . show) pure
        let input = RecordInput Baseline (UTCTime (fromGregorian 2026 9 26) 0) False Nothing [] Nothing
        record <- either (fail . show) pure (buildRunRecord input source links)
        record.knownDefects `shouldBe` [first, second]
    it "rejects a malformed grouped defect instead of dropping owner references" do
      withSystemTempDirectory "kenshou-malformed-defects" $ \root -> do
        let malformed = object ["reference" .= ("mori://example/bugs/1" :: Text), "defects" .= ("not an array" :: Text)]
        writeRunFixtureWithKnownDefect root malformed
        source <- loadRunSource root >>= either (fail . show) pure
        store <- memoryStore
        links <- publishRunData store (PublishOptions "gs://bucket/runs" UploadMissing False False) root source >>= either (fail . show) pure
        let input = RecordInput Baseline (UTCTime (fromGregorian 2026 9 26) 0) False Nothing [] Nothing
        buildRunRecord input source links `shouldSatisfy` isLeft
    it "derives a round-trippable run record from verified source and links" do
      withSystemTempDirectory "kenshou-record" $ \root -> do
        writeRunFixture root
        source <- loadRunSource root >>= either (fail . show) pure
        store <- memoryStore
        links <- publishRunData store (PublishOptions "gs://bucket/runs" UploadMissing False False) root source >>= either (fail . show) pure
        let input = RecordInput Baseline (UTCTime (fromGregorian 2026 9 26) 0) False Nothing [] Nothing
        record <- either (fail . show) pure (buildRunRecord input source links)
        recordFromDocument (recordToDocument record) `shouldBe` Right record
        let path = "runs/selftest/2026/09/01997f3a-5b7c-7e21-8a44-0d6c2f9b1e55.md"
            logPath = root </> "runs/selftest/2026/09/log.md"
            accept _ = pure (Right ())
        runRecordPath record `shouldBe` Right path
        writeRunRecordWith accept root record `shouldReturn` Right (RecordCreated path)
        originalLog <- Text.IO.readFile logPath
        writeRunRecordWith accept root record `shouldReturn` Right (RecordPresent path)
        Text.IO.readFile logPath `shouldReturn` originalLog
        writeRunRecordWith accept root (record {title = "changed"}) `shouldReturn` Left (RecordConflict path)
        let another = record {runId = "01997f3a-5b7c-7e21-8a44-0d6c2f9b1e56"}
            rejectedPath = "runs/selftest/2026/09/01997f3a-5b7c-7e21-8a44-0d6c2f9b1e56.md"
        writeRunRecordWith (\_ -> pure (Left (BundleInvalid "fixture rejection"))) root another `shouldReturn` Left (BundleInvalid "fixture rejection")
        doesFileExist (root </> rejectedPath) `shouldReturn` False
        Text.IO.readFile logPath `shouldReturn` originalLog

  describe "record frontmatter" do
    it "round-trips YAML-sensitive strings and a numeric-looking digest" do
      scenario <- either (fail . show) pure (parseScenarioId "selftest/kernel/correctness/always-pass")
      let digest = Sha256 (Text.replicate 31 "0" <> "e" <> Text.replicate 32 "0")
          base =
            EvidenceRecord
              { title = "Run: title # with punctuation",
                description = "A fixed description",
                generatedAt = "2026-09-26T20:00:00Z",
                runId = "01997f3a-5b7c-7e21-8a44-0d6c2f9b1e55",
                purpose = Investigation,
                scenario,
                tier = "smoke",
                placement = "local",
                outcome = Passed,
                startedAt = "2026-09-26T19:59:00Z",
                finishedAt = "2026-09-26T20:00:00Z",
                subject = "mori://shinzui/keiro-runtime-kenshou",
                subjectKind = SubjectProject,
                harnessRevision = Revision (Text.replicate 40 "f"),
                harnessDirty = True,
                computations = ["VC-1"],
                dataLinks = [DataLink ManifestData "gs://bucket/manifest.json" digest "application/json" 42],
                cohort = "head",
                solverPlanHash = digest,
                components = [],
                environment = object ["os" .= ("darwin" :: Text)],
                seed = 7,
                compatibilityKey = digest,
                knobs = [],
                dimensions = [],
                knownDefects = [],
                produced = [],
                previousRun = Nothing,
                body = "The computation is [VC-1](/computations/run-outcome.md).\n"
              }
      mapM_ (checkRoundTrip base) ["off", "on", "no", "yes", "null", "~", "true", "18", "1e10"]

  describe "gcloudStore" do
    it "requires the active project and uploads with a single generation precondition" do
      withSystemTempDirectory "kenshou-gcloud-store" $ \root -> do
        let executable = root </> "fake-gcloud"
            source = root </> "source"
            Sha256 digest = sha256Bytes "sealed"
            script =
              "#!/bin/sh\n"
                <> "if [ \"$1\" = config ]; then printf 'tan-nb-exp\\n'; exit 0; fi\n"
                <> "if [ \"$1\" = storage ] && [ \"$2\" = objects ]; then\n"
                <> "  if [ ! -f \"$(dirname \"$0\")/uploaded\" ]; then echo 'not found' >&2; exit 1; fi\n"
                <> "  printf '{\"size\":\"6\",\"custom_fields\":{\"kenshou-sha256\":\""
                <> Text.unpack digest
                <> "\"}}\\n'; exit 0\n"
                <> "fi\n"
                <> "if [ \"$1\" = storage ] && [ \"$2\" = cp ]; then\n"
                <> "  seen=0\n"
                <> "  for arg in \"$@\"; do\n"
                <> "    if [ \"$arg\" = --no-clobber ]; then echo 'conflicting no-clobber' >&2; exit 2; fi\n"
                <> "    if [ \"$arg\" = --if-generation-match=0 ]; then seen=1; fi\n"
                <> "  done\n"
                <> "  if [ \"$seen\" != 1 ]; then echo 'missing generation precondition' >&2; exit 2; fi\n"
                <> "  touch \"$(dirname \"$0\")/uploaded\"; exit 0\n"
                <> "fi\n"
                <> "exit 2\n"
        writeFile executable script
        ByteString.Char8.writeFile source "sealed"
        permissions <- getPermissions executable
        setPermissions executable permissions {executable = True}
        let matching = gcloudStoreWith executable "tan-nb-exp"
            mismatched = gcloudStoreWith executable "other-project"
        matching.statObject "gs://bucket/object" `shouldReturn` Right Nothing
        matching.putObjectIfAbsent source "gs://bucket/object" "application/octet-stream" `shouldReturn` Right ObjectCreated
        matching.statObject "gs://bucket/object" `shouldReturn` Right (Just (ObjectStat 6 (Just (Sha256 digest))))
        matching.putObjectIfAbsent source "gs://bucket/object" "application/octet-stream" `shouldReturn` Right ObjectPresent
        mismatch <- mismatched.statObject "gs://bucket/object"
        mismatch `shouldSatisfy` isLeft

  describe "publishRunData" do
    it "links a verified outer cell manifest and records the effective infrastructure outcome" do
      withSystemTempDirectory "kenshou-cell-evidence" $ \root -> do
        let cellRunId = "01997f3a-5b7c-7e21-8a44-0d6c2f9b1e66" :: Text
            nestedId = "01997f3a-5b7c-7e21-8a44-0d6c2f9b1e55" :: Text
            runDirectory = root </> "cell-run" </> "tree" </> "output" </> Text.unpack nestedId
            outerPath = root </> "cell-run" </> "tree" </> "manifest.json"
            baseUri = "gs://bucket/runs/" <> cellRunId <> "/output"
            outerUri = "gs://bucket/runs/" <> cellRunId <> "/manifest.json"
        writeCellRunFixture runDirectory outerPath cellRunId (Text.replicate 40 "f") True
        source <- loadRunSource runDirectory >>= either (fail . show) pure
        source.cellEvidence `shouldSatisfy` (/= Nothing)
        manifestBytes <- ByteString.readFile outerPath
        nestedBytes <- ByteString.readFile (runDirectory </> "manifest.json")
        cellId <- either (fail . show) pure (parseRunId cellRunId)
        nestedRunId <- either (fail . show) pure (parseRunId nestedId)
        leaseId <- either (fail . show) pure (parseRunId "01997f3a-5b7c-7e21-8a44-0d6c2f9b1e67")
        let runLink = RunLink nestedRunId ("output/" <> nestedId) "selftest/kernel/correctness/basic" (Text.drop 7 (sha256Hex nestedBytes)) Passed InfrastructureFailure (Just "cell health")
            index = CellRunIndex cellId "alpha" leaseId 1 ("gs://bucket/runs/" <> cellRunId) baseUri (CellManifestLink "manifest.json" (Text.drop 7 (sha256Hex manifestBytes)) (fromIntegral (ByteString.length manifestBytes))) Cell.InfrastructureFailure ["cell health"] (Just 0) [] [runLink] (UTCTime (fromGregorian 2026 9 26) 0)
            indexPath = root </> "cell-run" </> "cell-run.json"
        LazyByteString.writeFile indexPath (encode index)
        loadRunSource runDirectory >>= (`shouldSatisfy` isRight)
        let inconsistent = RunLink nestedRunId ("output/" <> nestedId) "selftest/kernel/correctness/basic" (Text.drop 7 (sha256Hex nestedBytes)) Passed Passed (Just "cell health")
        LazyByteString.writeFile indexPath (encode index {runs = [inconsistent]})
        loadRunSource runDirectory >>= (`shouldSatisfy` isLeft)
        LazyByteString.writeFile indexPath (encode index)
        store <- memoryStore
        store.putObjectIfAbsent outerPath outerUri "application/json" >>= (`shouldSatisfy` isRight)
        links <- publishRunData store (PublishOptions baseUri UploadMissing True False) runDirectory source >>= either (fail . show) pure
        [outer] <- pure [link | link <- links, link.kind == CellManifestData]
        outer.uri `shouldBe` outerUri
        let noMetadata =
              store
                { statObject = \uri -> do
                    observed <- store.statObject uri
                    pure (fmap (fmap (\stat -> stat {recordedSha256 = Nothing})) observed)
                }
        publishRunData noMetadata (PublishOptions baseUri VerifyOnly False False) runDirectory source `shouldReturn` Right links
        let tampered =
              noMetadata
                { fetchObject = \uri destination -> do
                    fetched <- store.fetchObject uri destination
                    case fetched of
                      Right () | uri == outerUri -> ByteString.Char8.appendFile destination "tampered"
                      _ -> pure ()
                    pure fetched
                }
        publishRunData tampered (PublishOptions baseUri VerifyOnly False False) runDirectory source >>= (`shouldSatisfy` isLeft)
        record <- either (fail . show) pure (buildRunRecord (RecordInput Investigation (UTCTime (fromGregorian 2026 9 26) 0) False Nothing [] Nothing) source links)
        record.outcome `shouldBe` InfrastructureFailure
        case record.environment of
          Object fields -> do
            KeyMap.lookup "cell" fields `shouldBe` Just (String "alpha")
            KeyMap.lookup "cellRun" fields `shouldBe` Just (String cellRunId)
            KeyMap.lookup "zone" fields `shouldBe` Just (String "us-west1-a")
          _ -> expectationFailure "cell environment must be an object"
        removeFile outerPath
        loadRunSource runDirectory >>= (`shouldSatisfy` isLeft)

    it "publishes all verified run files and links the required ones" do
      withSystemTempDirectory "kenshou-publish" $ \root -> do
        writeRunFixture root
        source <- loadRunSource root >>= either (fail . show) pure
        store <- memoryStore
        let options = PublishOptions "gs://bucket/runs" UploadMissing True False
        published <- publishRunData store options root source
        case published of
          Left err -> expectationFailure (show err)
          Right links -> map (.kind) links `shouldBe` [RunSpecData, RunResultData, ManifestData]
        publishRunData store options root source `shouldReturn` published
        let verifyOnly = PublishOptions "gs://bucket/runs" VerifyOnly True False
        publishRunData store verifyOnly root source `shouldReturn` published
        original <- ByteString.readFile (root </> "run-result.json")
        ByteString.Char8.appendFile (root </> "run-result.json") "changed"
        conflicted <- publishRunData store options root source
        conflicted `shouldSatisfy` isLeft
        store.fetchObject ("gs://bucket/runs/01997f3a-5b7c-7e21-8a44-0d6c2f9b1e55/run-result.json") (root </> "retained-result.json") `shouldReturn` Right ()
        retained <- ByteString.readFile (root </> "retained-result.json")
        retained `shouldBe` original

    it "refuses a non-durable destination before publishing" do
      withSystemTempDirectory "kenshou-publish" $ \root -> do
        writeRunFixture root
        source <- loadRunSource root >>= either (fail . show) pure
        store <- memoryStore
        publishRunData store (PublishOptions "file:///tmp" UploadMissing False False) root source
          `shouldReturn` Left (InvalidBaseUri "file:///tmp")

  describe "loadRunSource" do
    it "accepts a complete kernel run and rejects extra or changed files" do
      withSystemTempDirectory "kenshou-run-source" $ \root -> do
        writeRunFixture root
        loaded <- loadRunSource root
        loaded `shouldSatisfy` isRight
        ByteString.Char8.writeFile (root </> "unlisted.log") "unlisted"
        loadRunSource root >>= (`shouldSatisfy` isLeft)
        ByteString.Char8.writeFile (root </> "unlisted.log") ""
        -- The manifest must list even empty files.
        loadRunSource root >>= (`shouldSatisfy` isLeft)

    it "rejects modified bytes covered by the manifest" do
      withSystemTempDirectory "kenshou-run-source" $ \root -> do
        writeRunFixture root
        ByteString.Char8.appendFile (root </> "run-result.json") " "
        loadRunSource root >>= (`shouldSatisfy` isLeft)

  describe "evidence digest types" do
    it "accepts only lowercase fixed-length hexadecimal digests and revisions" do
      mkSha256 ("a" <> mconcat (replicate 63 "0")) `shouldBe` Right (Sha256 ("a" <> mconcat (replicate 63 "0")))
      mkSha256 (mconcat (replicate 64 "A")) `shouldSatisfy` isLeft
      mkSha256 (mconcat (replicate 63 "0")) `shouldSatisfy` isLeft
      mkRevision (mconcat (replicate 40 "f")) `shouldSatisfy` isRight
      mkRevision (mconcat (replicate 41 "f")) `shouldSatisfy` isLeft
      mkSha256 (case sha256Bytes "sample" of Sha256 digest -> digest) `shouldSatisfy` isRight

  describe "memoryStore" do
    it "reuses identical content and refuses conflicting content under one URI" do
      withSystemTempDirectory "kenshou-memory-store" $ \root -> do
        let first = root </> "first"
            second = root </> "second"
            uri = "gs://bucket/runs/id/result.json"
        ByteString.Char8.writeFile first "original"
        ByteString.Char8.writeFile second "different"
        store <- memoryStore
        store.putObjectIfAbsent first uri "application/json" `shouldReturn` Right ObjectCreated
        store.putObjectIfAbsent first uri "application/json" `shouldReturn` Right ObjectPresent
        store.putObjectIfAbsent second uri "application/json" `shouldReturn` Left (ObjectConflict uri)
        store.fetchObject uri (root </> "fetched") `shouldReturn` Right ()
        ByteString.readFile (root </> "fetched") `shouldReturn` "original"

  describe "directoryStore" do
    it "publishes create-only bytes and reports the observed digest" do
      withSystemTempDirectory "kenshou-directory-store" $ \root -> do
        let store = directoryStore (root </> "objects")
            source = root </> "source"
            other = root </> "other"
            uri = "gs://bucket/runs/id/manifest.json"
        ByteString.Char8.writeFile source "sealed"
        ByteString.Char8.writeFile other "changed"
        store.putObjectIfAbsent source uri "application/json" `shouldReturn` Right ObjectCreated
        store.putObjectIfAbsent source uri "application/json" `shouldReturn` Right ObjectPresent
        store.putObjectIfAbsent other uri "application/json" `shouldReturn` Left (ObjectConflict uri)
        result <- store.statObject uri
        result `shouldSatisfy` \case
          Right (Just ObjectStat {bytes = 6, recordedSha256 = Just _}) -> True
          _ -> False
        store.fetchObject uri (root </> "fetched") `shouldReturn` Right ()
        ByteString.readFile (root </> "fetched") `shouldReturn` "sealed"

    it "rejects URI paths that could escape the object root" do
      withSystemTempDirectory "kenshou-directory-store" $ \root -> do
        let store = directoryStore root
        store.statObject "file:///tmp/result.json" `shouldReturn` Left (InvalidObjectUri "file:///tmp/result.json")
        store.statObject "gs://bucket/../escape" `shouldReturn` Left (InvalidObjectUri "gs://bucket/../escape")

isLeft :: Either left right -> Bool
isLeft = either (const True) (const False)

isRight :: Either left right -> Bool
isRight = not . isLeft

checkRoundTrip :: EvidenceRecord -> Text -> IO ()
checkRoundTrip base sensitive = do
  let record = base {knobs = [("sensitive", String sensitive)], dimensions = [("sensitive", sensitive)]}
      rendered = serializeDocument (recordToDocument record)
  document <- either (fail . show) pure (parseDocument rendered)
  recordFromDocument document `shouldBe` Right record
  serializeDocument document `shouldBe` rendered

writeRunFixture :: FilePath -> IO ()
writeRunFixture root = writeRunFixtureWithRevision root (Text.replicate 40 "f")

writeRunFixtureWithRevision :: FilePath -> Text -> IO ()
writeRunFixtureWithRevision root harnessRevision = writeRunFixtureWithRevisionAndDefect root harnessRevision Nothing

writeRunFixtureWithKnownDefect :: FilePath -> Value -> IO ()
writeRunFixtureWithKnownDefect root defect = writeRunFixtureWithRevisionAndDefect root (Text.replicate 40 "f") (Just defect)

writeRunFixtureWithRevisionAndDefect :: FilePath -> Text -> Maybe Value -> IO ()
writeRunFixtureWithRevisionAndDefect root harnessRevision knownDefect = do
  let runId = "01997f3a-5b7c-7e21-8a44-0d6c2f9b1e55" :: Text
      spec = object ["schema" .= ("kenshou.run-spec/v1" :: Text), "runId" .= runId, "scenario" .= ("selftest/kernel/correctness/always-pass" :: Text), "seed" .= (7 :: Int)]
      specBytes = LazyByteString.toStrict (encode spec)
      fullDigest = "sha256:" <> Text.replicate 64 "a"
      cohort = object ["schema" .= ("kenshou.cohort-identity/v1" :: Text), "cohort" .= ("fixture" :: Text), "compiler" .= ("ghc" :: Text), "cabalVersion" .= ("3.14" :: Text), "os" .= ("darwin" :: Text), "arch" .= ("aarch64" :: Text), "planHash" .= fullDigest, "descriptorSha256" .= fullDigest, "components" .= [object ["id" .= ("selftest" :: Text), "moriUri" .= ("mori://shinzui/keiro-runtime-kenshou" :: Text), "packages" .= [object ["name" .= ("kenshou-core" :: Text), "version" .= ("0.1.0.0" :: Text), "source" .= object ["type" .= ("hackage" :: Text)]]]]]]
      result =
        object
          [ "schema" .= ("kenshou.run-result/v1" :: Text),
            "runId" .= runId,
            "scenario" .= ("selftest/kernel/correctness/always-pass" :: Text),
            "outcome" .= ("passed" :: Text),
            "knownDefect" .= knownDefect,
            "tier" .= ("smoke" :: Text),
            "seed" .= (7 :: Int),
            "spec" .= object ["sha256" .= sha256Hex specBytes],
            "timings" .= object ["startedAt" .= ("2026-09-26T00:00:00Z" :: Text), "endedAt" .= ("2026-09-26T00:00:01Z" :: Text)],
            "cohort" .= cohort,
            "fingerprint" .= object ["host" .= object ["os" .= ("darwin" :: Text), "arch" .= ("aarch64" :: Text), "cpuModel" .= ("fixture cpu" :: Text), "logicalCores" .= (4 :: Int), "memoryBytes" .= (4096 :: Int)], "runtime" .= object ["ghc" .= ("9.12.4" :: Text)], "kenshou" .= object ["revision" .= harnessRevision, "dirty" .= False], "postgres" .= object ["serverVersion" .= ("18.0" :: Text)]],
            "compatibility" .= object ["comparisonKey" .= fullDigest]
          ]
  ByteString.writeFile (root </> "run-spec.json") specBytes
  LazyByteString.writeFile (root </> "run-result.json") (encode result)
  parsed <- either (fail . show) pure (parseRunId runId)
  manifest <- writeManifest root parsed Map.empty
  LazyByteString.writeFile (root </> "manifest.json") (encode manifest)

writeCellRunFixture :: FilePath -> FilePath -> Text -> Text -> Bool -> IO ()
writeCellRunFixture runDirectory outerPath cellRunId revision includeGce = do
  createDirectoryIfMissing True runDirectory
  writeRunFixtureWithRevision runDirectory revision
  specValue <- Aeson.eitherDecodeFileStrict' (runDirectory </> "run-spec.json") >>= either fail pure
  let cellSpec = case specValue of
        Object fields -> Object (KeyMap.insert "environment" (object ["placement" .= ("cell" :: Text)]) fields)
        _ -> error "run fixture spec is not an object"
      specBytes = LazyByteString.toStrict (encode cellSpec)
  ByteString.writeFile (runDirectory </> "run-spec.json") specBytes
  resultValue <- Aeson.eitherDecodeFileStrict' (runDirectory </> "run-result.json") >>= either fail pure
  let cellFingerprint = object (["cell" .= ("alpha" :: Text), "cellRun" .= cellRunId] <> ["gce" .= object ["machineType" .= ("n2-standard-8" :: Text), "zone" .= ("us-west1-a" :: Text)] | includeGce])
      cellResult = case resultValue of
        Object fields -> case KeyMap.lookup "fingerprint" fields of
          Just (Object fingerprint) -> Object (KeyMap.insert "spec" (object ["sha256" .= sha256Hex specBytes]) (KeyMap.insert "fingerprint" (Object (KeyMap.insert "cell" cellFingerprint fingerprint)) fields))
          _ -> error "run fixture has no fingerprint"
        _ -> error "run fixture result is not an object"
  LazyByteString.writeFile (runDirectory </> "run-result.json") (encode cellResult)
  removeFile (runDirectory </> "manifest.json")
  nestedId <- either (fail . show) pure (parseRunId "01997f3a-5b7c-7e21-8a44-0d6c2f9b1e55")
  nested <- writeManifest runDirectory nestedId Map.empty
  LazyByteString.writeFile (runDirectory </> "manifest.json") (encode nested)
  cellId <- either (fail . show) pure (parseRunId cellRunId)
  leaseId <- either (fail . show) pure (parseRunId "01997f3a-5b7c-7e21-8a44-0d6c2f9b1e67")
  let names = ["run-spec.json", "run-result.json", "manifest.json"]
      timestamp = UTCTime (fromGregorian 2026 9 26) 0
  artifacts <-
    traverse
      ( \name -> do
          bytes <- ByteString.readFile (runDirectory </> name)
          pure (Artifact ("output/" <> "01997f3a-5b7c-7e21-8a44-0d6c2f9b1e55/" <> Text.pack name) (Text.drop 7 (sha256Hex bytes)) (fromIntegral (ByteString.length bytes)) "application/json")
      )
      names
  let outer = CellManifest cellId "alpha" leaseId 1 timestamp "0.1.0" (ManifestPayload (Text.replicate 64 "a") ("/nix/store/" <> Text.replicate 32 "a" <> "-fixture")) Cell.InfrastructureFailure 3600 artifacts
  LazyByteString.writeFile outerPath (encode outer)
