module Kenshou.Evidence.Frontmatter
  ( EvidenceRecord (..),
    ComparisonEvidence (..),
    AttestationEvidence (..),
    AttestationCheck (..),
    FieldError (..),
    recordToDocument,
    comparisonToDocument,
    attestationToDocument,
    recordFromDocument,
    comparisonFromDocument,
  )
where

import Data.Aeson (FromJSON (..), Result (..), ToJSON (..), Value (..), fromJSON, object, withObject, withText, (.:), (.:?), (.=))
import Data.Aeson.Types (Parser)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Word (Word64)
import Kenshou.Core.Id (ScenarioId (..), renderKind, renderLayer, renderScenarioId, unSegment)
import Kenshou.Core.Outcome (Outcome, renderOutcome)
import Kenshou.Evidence.Types (ComponentRef (..), ComponentSource (..), DataKind (..), DataLink (..), Purpose (..), Revision (..), Sha256 (..), SubjectKind (..), mkRevision, mkSha256)
import Okf.Actor (Actor (ProcessActor, ProducerActor), parseActor)
import Okf.Document (Generated (..), OKFDocument (..), OkfCommon (..), frontmatterLookup, okfCommon, readGenerated, setField, setGenerated)

newtype FieldError = FieldError Text deriving stock (Eq, Show)

data EvidenceRecord = EvidenceRecord
  { title :: !Text,
    description :: !Text,
    generatedAt :: !Text,
    runId :: !Text,
    purpose :: !Purpose,
    scenario :: !ScenarioId,
    tier :: !Text,
    placement :: !Text,
    outcome :: !Outcome,
    startedAt :: !Text,
    finishedAt :: !Text,
    subject :: !Text,
    subjectKind :: !SubjectKind,
    harnessRevision :: !Revision,
    harnessDirty :: !Bool,
    computations :: ![Text],
    dataLinks :: ![DataLink],
    cohort :: !Text,
    solverPlanHash :: !Sha256,
    components :: ![ComponentRef],
    environment :: !Value,
    seed :: !Word64,
    compatibilityKey :: !Sha256,
    knobs :: ![(Text, Value)],
    dimensions :: ![(Text, Text)],
    knownDefects :: ![Text],
    produced :: ![Text],
    previousRun :: !(Maybe Text),
    body :: !Text
  }
  deriving stock (Eq, Show)

data ComparisonEvidence = ComparisonEvidence
  { title :: !Text,
    description :: !Text,
    generatedAt :: !Text,
    runId :: !Text,
    purpose :: !Purpose,
    scenario :: !ScenarioId,
    tier :: !Text,
    placement :: !Text,
    outcome :: !Outcome,
    startedAt :: !Text,
    finishedAt :: !Text,
    subject :: !Text,
    subjectKind :: !SubjectKind,
    harnessRevision :: !Revision,
    harnessDirty :: !Bool,
    computations :: ![Text],
    dataLinks :: ![DataLink],
    comparison :: !Value,
    body :: !Text
  }
  deriving stock (Eq, Show)

data AttestationCheck = AttestationCheck
  { name :: !Text,
    result :: !Text,
    detail :: !(Maybe Text)
  }
  deriving stock (Eq, Show)

instance ToJSON AttestationCheck where
  toJSON check = object (["name" .= check.name, "result" .= check.result] <> maybe [] (\detail -> ["detail" .= detail]) check.detail)

data AttestationEvidence = AttestationEvidence
  { title :: !Text,
    description :: !Text,
    generatedAt :: !Text,
    attestationId :: !Text,
    run :: !Text,
    attesterRevision :: !Revision,
    attestedAt :: !Text,
    verdict :: !Text,
    checks :: ![AttestationCheck],
    dataDigests :: ![Sha256],
    exception :: !(Maybe Value),
    body :: !Text
  }
  deriving stock (Eq, Show)

attestationToDocument :: AttestationEvidence -> OKFDocument
attestationToDocument record =
  OKFDocument
    { frontmatter = foldl (\front (name, value) -> setField name value front) generated fields,
      body = record.body
    }
  where
    generated =
      setGenerated
        Generated {generatedBy = ProcessActor "kenshou-attester/0.1.0.0", generatedAt = Just record.generatedAt}
        (okfCommon OkfCommon {commonType = "Attestation", commonTitle = Just record.title, commonDescription = Just record.description, commonTimestamp = Nothing})
    fields =
      [ ("attestationId", String record.attestationId),
        ("run", String record.run),
        ("attester", String "process:kenshou-attester/0.1.0.0"),
        ("attesterRevision", toJSON record.attesterRevision),
        ("attestedAt", String record.attestedAt),
        ("verdict", String record.verdict),
        ("checks", toJSON record.checks),
        ("dataDigests", toJSON record.dataDigests)
      ]
        <> maybe [] (\value -> [("exception", value)]) record.exception

comparisonToDocument :: ComparisonEvidence -> OKFDocument
comparisonToDocument record =
  OKFDocument
    { frontmatter = foldl (\front (name, value) -> setField name value front) generated fields,
      body = record.body
    }
  where
    generated =
      setGenerated
        Generated {generatedBy = ProducerActor "kenshou-record" "0.1.0.0", generatedAt = Just record.generatedAt}
        (okfCommon OkfCommon {commonType = "Verification Run", commonTitle = Just record.title, commonDescription = Just record.description, commonTimestamp = Nothing})
    scenarioId = record.scenario
    fields =
      [ ("runId", toJSON record.runId),
        ("recordKind", String "comparison"),
        ("purpose", String (purposeText record.purpose)),
        ("scenario", String (renderScenarioId scenarioId)),
        ("layer", String (renderLayer scenarioId.layer)),
        ("component", String (unSegment scenarioId.component)),
        ("kind", String (renderKind scenarioId.kind)),
        ("tier", String record.tier),
        ("placement", String record.placement),
        ("outcome", String (renderOutcome record.outcome)),
        ("startedAt", String record.startedAt),
        ("finishedAt", String record.finishedAt),
        ("subject", String record.subject),
        ("subjectKind", String (subjectKindText record.subjectKind)),
        ("harnessRevision", toJSON record.harnessRevision),
        ("harnessDirty", Bool record.harnessDirty),
        ("computations", toJSON record.computations),
        ("data", toJSON record.dataLinks),
        ("comparison", record.comparison)
      ]

recordToDocument :: EvidenceRecord -> OKFDocument
recordToDocument record =
  OKFDocument
    { frontmatter = foldl (\front (name, value) -> setField name value front) generated fields,
      body = record.body
    }
  where
    generated =
      setGenerated
        Generated {generatedBy = ProducerActor "kenshou-record" "0.1.0.0", generatedAt = Just record.generatedAt}
        (okfCommon OkfCommon {commonType = "Verification Run", commonTitle = Just record.title, commonDescription = Just record.description, commonTimestamp = Nothing})
    scenarioId = record.scenario
    fields =
      [ ("runId", toJSON record.runId),
        ("recordKind", String "run"),
        ("purpose", String (purposeText record.purpose)),
        ("scenario", String (renderScenarioId scenarioId)),
        ("layer", String (renderLayer scenarioId.layer)),
        ("component", String (unSegment scenarioId.component)),
        ("kind", String (renderKind scenarioId.kind)),
        ("tier", String record.tier),
        ("placement", String record.placement),
        ("outcome", String (renderOutcome record.outcome)),
        ("startedAt", String record.startedAt),
        ("finishedAt", String record.finishedAt),
        ("subject", String record.subject),
        ("subjectKind", String (subjectKindText record.subjectKind)),
        ("harnessRevision", toJSON record.harnessRevision),
        ("harnessDirty", Bool record.harnessDirty),
        ("computations", toJSON record.computations),
        ("data", toJSON record.dataLinks),
        ("cohort", String record.cohort),
        ("solverPlanHash", toJSON record.solverPlanHash),
        ("components", toJSON record.components),
        ("environment", record.environment),
        ("seed", toJSON record.seed),
        ("compatibilityKey", toJSON record.compatibilityKey)
      ]
        <> optionalList "knobs" [object ["name" .= name, "value" .= value] | (name, value) <- record.knobs]
        <> optionalList "dimensions" [object ["name" .= name, "value" .= value] | (name, value) <- record.dimensions]
        <> optionalList "knownDefects" record.knownDefects
        <> optionalList "produced" record.produced
        <> maybe [] (\path -> [("previousRun", String path)]) record.previousRun

    optionalList name values = [(name, toJSON values) | not (null values)]

recordFromDocument :: OKFDocument -> Either [FieldError] EvidenceRecord
recordFromDocument document = do
  let front = document.frontmatter
      required :: Text -> Either [FieldError] Value
      required name = maybe (Left [FieldError ("missing " <> name)]) Right (frontmatterLookup name front)
      typed :: (FromJSON value) => Text -> Either [FieldError] value
      typed name =
        required name >>= \value -> case fromJSON value of
          Error message -> Left [FieldError (name <> ": " <> Text.pack message)]
          Success decoded -> Right decoded
      optional :: (FromJSON value) => Text -> Either [FieldError] (Maybe value)
      optional name = case frontmatterLookup name front of
        Nothing -> Right Nothing
        Just value -> case fromJSON value of
          Error message -> Left [FieldError (name <> ": " <> Text.pack message)]
          Success decoded -> Right (Just decoded)
  recordType <- typed "type"
  if (recordType :: Text) /= "Verification Run" then Left [FieldError "type must be Verification Run"] else pure ()
  kind <- typed "recordKind"
  if (kind :: Text) /= "run" then Left [FieldError "recordKind must be run"] else pure ()
  title <- typed "title"
  description <- typed "description"
  generatedAt <- case readGenerated front of
    Just Generated {generatedBy, generatedAt = Just at}
      | generatedBy == parseActor "kenshou-record/0.1.0.0" -> Right at
    _ -> Left [FieldError "generated must name kenshou-record/0.1.0.0 and a time"]
  runId <- typed "runId"
  purpose <- typed "purpose"
  scenario <- typed "scenario"
  tier <- typed "tier"
  placement <- typed "placement"
  outcome <- typed "outcome"
  startedAt <- typed "startedAt"
  finishedAt <- typed "finishedAt"
  subject <- typed "subject"
  subjectKind <- typed "subjectKind"
  harnessRevision <- typed "harnessRevision"
  harnessDirty <- typed "harnessDirty"
  computations <- typed "computations"
  dataLinks <- typed "data"
  cohort <- typed "cohort"
  solverPlanHash <- typed "solverPlanHash"
  components <- typed "components"
  environment <- typed "environment"
  seed <- typed "seed"
  compatibilityKey <- typed "compatibilityKey"
  rawKnobs <- maybe [] id <$> optional "knobs"
  rawDimensions <- maybe [] id <$> optional "dimensions"
  let knobs = [(name, value) | NamedValue name value <- rawKnobs]
      dimensions = [(name, value) | NamedText name value <- rawDimensions]
  knownDefects <- maybe [] id <$> optional "knownDefects"
  produced <- maybe [] id <$> optional "produced"
  previousRun <- optional "previousRun"
  pure EvidenceRecord {title, description, generatedAt, runId, purpose, scenario, tier, placement, outcome, startedAt, finishedAt, subject, subjectKind, harnessRevision, harnessDirty, computations, dataLinks, cohort, solverPlanHash, components, environment, seed, compatibilityKey, knobs, dimensions, knownDefects, produced, previousRun, body = document.body}

comparisonFromDocument :: OKFDocument -> Either [FieldError] ComparisonEvidence
comparisonFromDocument document = do
  let front = document.frontmatter
      typed :: (FromJSON value) => Text -> Either [FieldError] value
      typed name = case frontmatterLookup name front of
        Nothing -> Left [FieldError ("missing " <> name)]
        Just value -> case fromJSON value of
          Error message -> Left [FieldError (name <> ": " <> Text.pack message)]
          Success decoded -> Right decoded
  recordType <- typed "type"
  if (recordType :: Text) /= "Verification Run" then Left [FieldError "type must be Verification Run"] else pure ()
  kind <- typed "recordKind"
  if (kind :: Text) /= "comparison" then Left [FieldError "recordKind must be comparison"] else pure ()
  generatedAt <- case readGenerated front of
    Just Generated {generatedBy, generatedAt = Just at}
      | generatedBy == parseActor "kenshou-record/0.1.0.0" -> Right at
    _ -> Left [FieldError "generated must name kenshou-record/0.1.0.0 and a time"]
  title <- typed "title"
  description <- typed "description"
  runId <- typed "runId"
  purpose <- typed "purpose"
  scenario <- typed "scenario"
  tier <- typed "tier"
  placement <- typed "placement"
  outcome <- typed "outcome"
  startedAt <- typed "startedAt"
  finishedAt <- typed "finishedAt"
  subject <- typed "subject"
  subjectKind <- typed "subjectKind"
  harnessRevision <- typed "harnessRevision"
  harnessDirty <- typed "harnessDirty"
  computations <- typed "computations"
  dataLinks <- typed "data"
  comparison <- typed "comparison"
  pure ComparisonEvidence {title, description, generatedAt, runId, purpose, scenario, tier, placement, outcome, startedAt, finishedAt, subject, subjectKind, harnessRevision, harnessDirty, computations, dataLinks, comparison, body = document.body}

purposeText :: Purpose -> Text
purposeText Nightly = "nightly"
purposeText Release = "release"
purposeText Baseline = "baseline"
purposeText Investigation = "investigation"

subjectKindText :: SubjectKind -> Text
subjectKindText SubjectProject = "project"
subjectKindText SubjectPackage = "package"

dataKindText :: DataKind -> Text
dataKindText RunSpecData = "run-spec"
dataKindText RunResultData = "run-result"
dataKindText ManifestData = "manifest"
dataKindText CellManifestData = "cell-manifest"
dataKindText SamplesData = "samples"
dataKindText SeriesData = "series"
dataKindText VerdictsData = "verdicts"
dataKindText DiagnosisData = "diagnosis"
dataKindText LogsData = "logs"
dataKindText ComparisonData = "comparison"

instance ToJSON Sha256 where toJSON (Sha256 digest) = String digest

instance FromJSON Sha256 where
  parseJSON = withText "SHA-256" (either (fail . Text.unpack) pure . mkSha256)

instance ToJSON Revision where toJSON (Revision revision) = String revision

instance FromJSON Revision where
  parseJSON = withText "revision" (either (fail . Text.unpack) pure . mkRevision)

instance FromJSON Purpose where
  parseJSON = withText "purpose" \case
    "nightly" -> pure Nightly
    "release" -> pure Release
    "baseline" -> pure Baseline
    "investigation" -> pure Investigation
    _ -> fail "unknown purpose"

instance FromJSON SubjectKind where
  parseJSON = withText "subject kind" \case
    "project" -> pure SubjectProject
    "package" -> pure SubjectPackage
    _ -> fail "unknown subject kind"

instance ToJSON DataLink where
  toJSON link = object ["kind" .= dataKindText link.kind, "uri" .= link.uri, "digest" .= link.digest, "mediaType" .= link.mediaType, "bytes" .= link.bytes]

instance FromJSON DataLink where
  parseJSON = withObject "data link" \value -> do
    rawKind <- value .: "kind" :: Parser Text
    kind <- parseKind rawKind
    DataLink kind <$> value .: "uri" <*> value .: "digest" <*> value .: "mediaType" <*> value .: "bytes"
    where
      parseKind = \case
        "run-spec" -> pure RunSpecData
        "run-result" -> pure RunResultData
        "manifest" -> pure ManifestData
        "cell-manifest" -> pure CellManifestData
        "samples" -> pure SamplesData
        "series" -> pure SeriesData
        "verdicts" -> pure VerdictsData
        "diagnosis" -> pure DiagnosisData
        "logs" -> pure LogsData
        "comparison" -> pure ComparisonData
        _ -> fail "unknown data kind"

instance ToJSON ComponentRef where
  toJSON component =
    object $
      ["project" .= component.project, "package" .= component.package, "version" .= component.version, "source" .= sourceText component.source]
        <> maybe [] (\revision -> ["revision" .= revision]) component.revision
    where
      sourceText FromHackage = "hackage" :: Text
      sourceText FromGit = "git"

instance FromJSON ComponentRef where
  parseJSON = withObject "component" \value -> do
    project <- value .: "project"
    package <- value .: "package"
    version <- value .: "version"
    rawSource <- value .: "source" :: Parser Text
    source <- case rawSource of
      "hackage" -> pure FromHackage
      "git" -> pure FromGit
      _ -> fail "unknown component source"
    revision <- value .:? "revision"
    pure ComponentRef {project, package, version, source, revision}

data NamedValue = NamedValue Text Value

instance FromJSON NamedValue where
  parseJSON = withObject "name/value" \value -> NamedValue <$> value .: "name" <*> value .: "value"

data NamedText = NamedText Text Text

instance FromJSON NamedText where
  parseJSON = withObject "name/value" \value -> NamedText <$> value .: "name" <*> value .: "value"
