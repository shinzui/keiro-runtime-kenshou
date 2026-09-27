module Kenshou.Evidence.Record
  ( RecordInput (..),
    RecordOptions (..),
    RecordOutcome (..),
    RecordError (..),
    buildRunRecord,
    recordRun,
    recordRunWith,
    recordComparison,
  )
where

import Control.Monad (forM, unless, when)
import Data.Aeson (FromJSON (..), Result (..), ToJSON (..), Value (..), fromJSON, object, withObject, (.:), (.:?), (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (Parser)
import Data.List (nub, sortOn)
import Data.Map.Strict qualified as Map
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime, defaultTimeLocale, formatTime, getCurrentTime)
import Kenshou.Core.Cohort (CohortIdentity (..), CohortName (..), PackageSource (..), PlanHash (..), ResolvedComponent (..), ResolvedPackage (..))
import Kenshou.Core.Id (Kind (..), Layer (..), RunId, ScenarioId (..), renderRunId, renderScenarioId)
import Kenshou.Core.Outcome (Outcome (..), renderOutcome)
import Kenshou.Core.RunSpec (EnvironmentSpec (..), RunSpec (..), SpecPlacement (..))
import Kenshou.Evidence.Bundle (BundleWriteError, BundleWriteResult (..), writeComparisonRecord, writeRunRecord)
import Kenshou.Evidence.Frontmatter (ComparisonEvidence (..), EvidenceRecord (..), recordFromDocument)
import Kenshou.Evidence.Publish (PublishError, PublishOptions (..), UploadMode, publishComparisonData, publishRunData)
import Kenshou.Evidence.Source (ComparisonSource (..), ComparisonView (..), RunResultView (..), RunSource (..), SourceError, loadComparisonSource, loadRunSource)
import Kenshou.Evidence.Store (ObjectStore)
import Kenshou.Evidence.Types (ComponentRef (..), DataKind (..), DataLink (..), Purpose (..), Sha256, SubjectKind (..), mkRevision, mkSha256)
import Kenshou.Evidence.Types qualified as EvidenceTypes
import Okf.Bundle (conceptDocument, conceptSourcePath, walkBundle)
import Okf.ConceptId (parseConceptId, renderConceptLink)

data RecordInput = RecordInput
  { purpose :: !Purpose,
    generatedAt :: !UTCTime,
    allowDirty :: !Bool,
    subjectOverride :: !(Maybe (Text, SubjectKind)),
    produced :: ![Text],
    previousRun :: !(Maybe Text)
  }
  deriving stock (Eq, Show)

data RecordError
  = RecordError !Text
  | SourceFailure !SourceError
  | PublishFailure !PublishError
  | BundleFailure !BundleWriteError
  deriving stock (Eq, Show)

data RecordOptions = RecordOptions
  { bundleRoot :: !FilePath,
    dataBaseUri :: !Text,
    purpose :: !Purpose,
    uploadMode :: !UploadMode,
    deepVerify :: !Bool,
    allowDirty :: !Bool,
    linkLogs :: !Bool,
    subjectOverride :: !(Maybe (Text, SubjectKind)),
    produced :: ![Text]
  }
  deriving stock (Eq, Show)

data RecordOutcome = Recorded !FilePath | AlreadyRecorded !FilePath
  deriving stock (Eq, Show)

recordRun :: ObjectStore -> RecordOptions -> FilePath -> IO (Either RecordError RecordOutcome)
recordRun store options directory = do
  now <- getCurrentTime
  recordRunWith writeRunRecord now store options directory

recordRunWith :: (FilePath -> EvidenceRecord -> IO (Either BundleWriteError BundleWriteResult)) -> UTCTime -> ObjectStore -> RecordOptions -> FilePath -> IO (Either RecordError RecordOutcome)
recordRunWith writer now store options directory = do
  loaded <- loadRunSource directory
  case loaded of
    Left err -> pure (Left (SourceFailure err))
    Right source -> case preflight source of
      Left err -> pure (Left err)
      Right () -> do
        let publishing = PublishOptions options.dataBaseUri options.uploadMode options.deepVerify options.linkLogs
        published <- publishRunData store publishing directory source
        case published of
          Left err -> pure (Left (PublishFailure err))
          Right links -> do
            let input = RecordInput options.purpose now options.allowDirty options.subjectOverride options.produced Nothing
            case buildRunRecord input source links of
              Left err -> pure (Left err)
              Right record -> do
                written <- writer options.bundleRoot record
                pure case written of
                  Left err -> Left (BundleFailure err)
                  Right (RecordCreated path) -> Right (Recorded path)
                  Right (RecordPresent path) -> Right (AlreadyRecorded path)
  where
    preflight source = do
      kenshou <- jsonField "kenshou" source.result.resultFingerprint
      revision <- jsonField "revision" kenshou
      _ <- either (Left . RecordError) Right (mkRevision revision)
      dirty <- jsonField "dirty" kenshou
      when (dirty && not options.allowDirty) (Left (RecordError "dirty harness requires --allow-dirty"))

recordComparison :: ObjectStore -> RecordOptions -> FilePath -> IO (Either RecordError RecordOutcome)
recordComparison store options path = do
  loaded <- loadComparisonSource path
  case loaded of
    Left err -> pure (Left (SourceFailure err))
    Right source -> do
      arms <- loadRecordedArms options.bundleRoot (source.view.baselineRuns <> source.view.candidateRuns)
      case arms of
        Left err -> pure (Left err)
        Right records -> case comparisonFields options source records of
          Left err -> pure (Left err)
          Right build -> do
            let publishing = PublishOptions options.dataBaseUri options.uploadMode options.deepVerify options.linkLogs
            published <- publishComparisonData store publishing path source
            case published of
              Left err -> pure (Left (PublishFailure err))
              Right link -> do
                now <- getCurrentTime
                let record = build now link
                written <- writeComparisonRecord options.bundleRoot record
                pure case written of
                  Left err -> Left (BundleFailure err)
                  Right (RecordCreated relative) -> Right (Recorded relative)
                  Right (RecordPresent relative) -> Right (AlreadyRecorded relative)

loadRecordedArms :: FilePath -> [RunId] -> IO (Either RecordError [(FilePath, EvidenceRecord)])
loadRecordedArms root identifiers = do
  found <- walkBundle root
  pure do
    concepts <- either (Left . RecordError . Text.pack . show) Right found
    let records = [(conceptSourcePath concept, record) | concept <- concepts, Right record <- [recordFromDocument (conceptDocument concept)]]
    let byId = Map.fromListWith (<>) [(record.runId, [(path, record)]) | (path, record) <- records]
    forM identifiers $ \identifier -> case Map.lookup (renderRunId identifier) byId of
      Just [entry] -> Right entry
      Just _ -> Left (RecordError ("recorded arm has duplicate concepts: " <> renderRunId identifier))
      Nothing -> Left (RecordError ("comparison arm is not recorded: " <> renderRunId identifier))

comparisonFields :: RecordOptions -> ComparisonSource -> [(FilePath, EvidenceRecord)] -> Either RecordError (UTCTime -> DataLink -> ComparisonEvidence)
comparisonFields options source arms = do
  unless (null options.produced) (Left (RecordError "--produced applies only to run records"))
  let view = source.view
      pairCount = view.pairCount
      (baselines, candidates) = splitAt pairCount arms
      allRecords = map snd arms
  unless (length baselines == pairCount && length candidates == pairCount) (Left (RecordError "comparison arm count differs from source"))
  scenario <- case nub (map (.scenario) allRecords) of
    [single] -> Right single
    _ -> Left (RecordError "comparison arms must have one scenario")
  axis <- case view.variedFactors of
    [single] -> Right single
    _ -> Left (RecordError "comparison evidence requires one varied factor")
  (factor, factorName) <- factorForAxis axis
  baselineValue <- armValue axis baselines
  candidateValue <- armValue axis candidates
  when (baselineValue == candidateValue) (Left (RecordError "comparison factor values must differ"))
  revisionText <- maybe (Left (RecordError "comparison harness revision is unavailable")) Right view.harnessRevision
  harnessRevision <- either (Left . RecordError) Right (mkRevision revisionText)
  harnessDirty <- maybe (Left (RecordError "comparison harness dirty state is unavailable")) Right view.harnessDirty
  when (harnessDirty && not options.allowDirty) (Left (RecordError "dirty harness requires --allow-dirty"))
  first <- case candidates of
    (_, candidate) : _ -> Right candidate
    [] -> Left (RecordError "comparison has no candidate arm")
  let subject = maybe first.subject fst options.subjectOverride
      subjectKind = maybe first.subjectKind snd options.subjectOverride
  unless ("mori://" `Text.isPrefixOf` subject) (Left (RecordError "subject must be a canonical Mori URI"))
  let outcome = case view.verdict of
        "pass" -> Passed
        "regression" -> Failed
        "inconclusive" -> Inconclusive
        _ -> InfrastructureFailure
      comparison =
        object
          ( [ "verdict" .= view.verdict,
              "factor" .= factor,
              "baselineValue" .= baselineValue,
              "candidateValue" .= candidateValue,
              "design" .= view.design,
              "baselineRuns" .= map (('/' :) . fst) baselines,
              "candidateRuns" .= map (('/' :) . fst) candidates
            ]
              <> maybe [] (\name -> ["factorName" .= name]) factorName
          )
      build now link =
        ComparisonEvidence
          { title = renderScenarioId scenario <> " comparison " <> view.verdict,
            description = "Recorded comparison of " <> Text.pack (show pairCount) <> " paired runs with digest-pinned data.",
            generatedAt = utcText now,
            runId = renderRunId view.comparisonId,
            purpose = if harnessDirty then Investigation else options.purpose,
            scenario,
            tier = first.tier,
            placement = first.placement,
            outcome,
            startedAt = utcText view.startedAt,
            finishedAt = utcText view.finishedAt,
            subject,
            subjectKind,
            harnessRevision,
            harnessDirty,
            computations = ["VC-3"],
            dataLinks = [link],
            comparison,
            body = "The paired comparison produced the recorded verdict under [VC-3](/computations/paired-comparison.md). Its raw document is linked by digest in the frontmatter.\n"
          }
  pure build

factorForAxis :: Text -> Either RecordError (Text, Maybe Text)
factorForAxis axis
  | axis == "cohort" = Right ("cohort", Nothing)
  | Just name <- Text.stripPrefix "dim:" axis, not (Text.null name) = Right ("dimension", Just name)
  | Just name <- Text.stripPrefix "knob:" axis, not (Text.null name) = Right ("knob", Just name)
  | otherwise = Left (RecordError ("unsupported comparison factor: " <> axis))

armValue :: Text -> [(FilePath, EvidenceRecord)] -> Either RecordError Value
armValue axis records = case nub (mapMaybe value (map snd records)) of
  [single] | length records == length (mapMaybe value (map snd records)) -> Right single
  _ -> Left (RecordError ("comparison arm has missing or inconsistent " <> axis <> " values"))
  where
    value record
      | axis == "cohort" = Just (String record.cohort)
      | Just name <- Text.stripPrefix "dim:" axis = String <$> lookup name record.dimensions
      | Just name <- Text.stripPrefix "knob:" axis = lookup name record.knobs
      | otherwise = Nothing

data FingerprintFields = FingerprintFields
  { os :: !Text,
    arch :: !Text,
    cpuModel :: !(Maybe Text),
    cores :: !Integer,
    memoryBytes :: !(Maybe Integer),
    ghc :: !Text,
    postgres :: !Text,
    harnessRevision :: !(Maybe Text),
    harnessDirty :: !(Maybe Bool)
  }

instance FromJSON FingerprintFields where
  parseJSON = withObject "fingerprint" \value -> do
    host <- value .: "host"
    runtime <- value .: "runtime"
    kenshou <- value .: "kenshou"
    pg <- value .:? "postgres" :: Parser (Maybe Value)
    postgres <- case pg of
      Just (Object fields) -> fields .: "serverVersion"
      _ -> pure "none"
    FingerprintFields
      <$> host .: "os"
      <*> host .: "arch"
      <*> host .:? "cpuModel"
      <*> host .: "logicalCores"
      <*> host .:? "memoryBytes"
      <*> runtime .: "ghc"
      <*> pure postgres
      <*> kenshou .:? "revision"
      <*> kenshou .:? "dirty"

buildRunRecord :: RecordInput -> RunSource -> [DataLink] -> Either RecordError EvidenceRecord
buildRunRecord input source dataLinks = do
  let linkedKinds = map (.kind) dataLinks
  unless (all (`elem` linkedKinds) [ManifestData, RunSpecData, RunResultData]) (Left (RecordError "run data must link its manifest, spec and result"))
  unless ("mori://" `Text.isPrefixOf` maybe (defaultSubject source.result.resultScenario.layer) fst input.subjectOverride) (Left (RecordError "subject must be a canonical Mori URI"))
  unless (all (Text.isPrefixOf "mori://") input.produced) (Left (RecordError "produced artifacts must use canonical Mori URIs"))
  fingerprint <- decoded "fingerprint" source.result.resultFingerprint :: Either RecordError FingerprintFields
  revisionText <- maybe (Left (RecordError "harness revision is unavailable")) Right fingerprint.harnessRevision
  harnessRevision <- either (Left . RecordError) Right (mkRevision revisionText)
  harnessDirty <- maybe (Left (RecordError "harness dirty state is unavailable")) Right fingerprint.harnessDirty
  when (harnessDirty && not input.allowDirty) (Left (RecordError "dirty harness requires --allow-dirty"))
  cpuModel <- maybe (Left (RecordError "CPU model is unavailable")) Right fingerprint.cpuModel
  memoryBytes <- maybe (Left (RecordError "physical memory size is unavailable")) Right fingerprint.memoryBytes
  when (fingerprint.cores < 0 || memoryBytes < 0) (Left (RecordError "invalid environment size"))
  let effectivePurpose = if harnessDirty then Investigation else input.purpose
      scenario = source.result.resultScenario
      cohortIdentity = source.result.resultCohort
      cohort = unCohortName cohortIdentity.identityCohort
      subject = maybe (defaultSubject scenario.layer) fst input.subjectOverride
      subjectKind = maybe SubjectProject snd input.subjectOverride
      environment = object ["os" .= fingerprint.os, "arch" .= fingerprint.arch, "cpuModel" .= cpuModel, "cores" .= fingerprint.cores, "memoryBytes" .= memoryBytes, "ghc" .= fingerprint.ghc, "postgres" .= fingerprint.postgres]
      title = renderScenarioId scenario <> " " <> renderOutcome source.result.resultOutcome <> " on " <> cohort
      description = "Recorded " <> renderScenarioId scenario <> " run against cohort " <> cohort <> " with digest-pinned data."
      computations = "VC-1" : ["VC-2" | scenario.kind `elem` [Benchmark, Soak]]
  solverPlanHash <- kernelDigest (unPlanHash cohortIdentity.identityPlanHash)
  compatibilityKey <- do
    comparisonKey <- jsonField "comparisonKey" source.result.resultCompatibility
    kernelDigest comparisonKey
  components <- concat <$> traverse componentRefs cohortIdentity.identityComponents
  knownDefects <- case source.result.resultKnownDefect of
    Nothing -> Right []
    Just value@(Object fields) -> case KeyMap.lookup "defects" fields of
      Nothing -> (: []) <$> jsonField "reference" value
      Just raw -> do
        defects <- decoded "defects" raw :: Either RecordError [Value]
        traverse (jsonField "reference") defects
    Just value -> (: []) <$> jsonField "reference" value
  knobs <- case toJSON source.spec of
    Object fields -> case KeyMap.lookup "knobs" fields of
      Just (Object entries) -> Right $ sortOn fst [(Key.toText key, value) | (key, value) <- KeyMap.toList entries]
      _ -> Left (RecordError "run spec has no resolved knobs")
    _ -> Left (RecordError "run spec is not an object")
  firstComputation <- either (Left . RecordError . Text.pack . show) Right (parseConceptId "computations/run-outcome")
  pure
    EvidenceRecord
      { title,
        description,
        generatedAt = utcText input.generatedAt,
        runId = renderRunId source.result.resultRunId,
        purpose = effectivePurpose,
        scenario,
        tier = source.result.resultTier,
        placement = case source.spec.environment.placement of RunLocal -> "local"; RunOnCell -> "cell",
        outcome = source.result.resultOutcome,
        startedAt = utcText source.result.resultStartedAt,
        finishedAt = utcText source.result.resultEndedAt,
        subject,
        subjectKind,
        harnessRevision,
        harnessDirty,
        computations,
        dataLinks,
        cohort,
        solverPlanHash,
        components,
        environment,
        seed = source.result.resultSeed,
        compatibilityKey,
        knobs,
        dimensions = source.spec.dimensions,
        knownDefects,
        produced = input.produced,
        previousRun = input.previousRun,
        body = "This run produced the recorded outcome under " <> renderConceptLink firstComputation "VC-1" <> ". Its raw data is linked by digest in the frontmatter.\n"
      }

componentRefs :: ResolvedComponent -> Either RecordError [ComponentRef]
componentRefs component = forM component.resolvedComponentPackages $ \package -> do
  (source, revision) <- case package.resolvedPackageSource of
    FromHackage _ -> Right (EvidenceTypes.FromHackage, Nothing)
    FromGit _ rawRevision _ -> do
      parsed <- either (Left . RecordError) Right (mkRevision rawRevision)
      Right (EvidenceTypes.FromGit, Just parsed)
    FromBoot -> Left (RecordError ("boot package is not a runtime component: " <> package.resolvedPackageName))
    FromLocalPath _ -> Left (RecordError ("local-path package cannot be recorded as a released runtime component: " <> package.resolvedPackageName))
  unless ("mori://" `Text.isPrefixOf` component.resolvedComponentMoriUri) (Left (RecordError "component has no canonical Mori project URI"))
  pure ComponentRef {project = component.resolvedComponentMoriUri, package = package.resolvedPackageName, version = package.resolvedPackageVersion, source, revision}

kernelDigest :: Text -> Either RecordError Sha256
kernelDigest value = do
  raw <- maybe (Left (RecordError "kernel digest is missing its sha256: prefix")) Right (Text.stripPrefix "sha256:" value)
  either (Left . RecordError) Right (mkSha256 raw)

jsonField :: (FromJSON value) => Text -> Value -> Either RecordError value
jsonField name value = case value of
  Object fields -> case KeyMap.lookup (Key.fromText name) fields of
    Nothing -> Left (RecordError ("missing JSON field " <> name))
    Just raw -> decoded name raw
  _ -> Left (RecordError "expected a JSON object")

decoded :: (FromJSON value) => Text -> Value -> Either RecordError value
decoded label value = case fromJSON value of
  Error message -> Left (RecordError (label <> ": " <> Text.pack message))
  Success parsed -> Right parsed

utcText :: UTCTime -> Text
utcText = Text.pack . formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%S%QZ"

defaultSubject :: Layer -> Text
defaultSubject Selftest = "mori://shinzui/keiro-runtime-kenshou"
defaultSubject Pgmq = "mori://shinzui/pgmq-hs"
defaultSubject Kiroku = "mori://shinzui/kiroku"
defaultSubject Shibuya = "mori://shinzui/shibuya"
defaultSubject Kafka = "mori://shinzui/kafka-effectful"
defaultSubject Keiro = "mori://shinzui/keiro"
defaultSubject Runtime = "mori://shinzui/keiro-runtime-kenshou"
