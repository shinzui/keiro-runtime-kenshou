module Kenshou.Evidence.History
  ( HistoryQuery (..),
    HistoryError (..),
    HistoryDocument (..),
    HistoryEntry (..),
    history,
    deriveBaseline,
  )
where

import Data.Aeson (ToJSON (..), Value (..), object, (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.List (sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (Day, defaultTimeLocale, formatTime)
import Kenshou.Core.Id (ScenarioId, renderScenarioId)
import Kenshou.Core.Outcome (Outcome, renderOutcome)
import Okf.Actor (renderActor)
import Okf.Bundle (Concept, conceptDocument, conceptSourcePath, conceptType, walkBundle)
import Okf.Document (OKFDocument (..), Verification (..), frontmatterKeys, frontmatterLookup, readVerified)
import System.FilePath (dropExtension)

data HistoryQuery = HistoryQuery
  { scenario :: !ScenarioId,
    cohortComponent :: !(Maybe (Text, Maybe Text)),
    outcomes :: ![Outcome],
    since :: !(Maybe Day),
    confirmedOnly :: !Bool
  }
  deriving stock (Eq, Show)

newtype HistoryError = HistoryError Text deriving stock (Eq, Show)

data HistoryDocument = HistoryDocument
  { query :: !HistoryQuery,
    entries :: ![HistoryEntry]
  }
  deriving stock (Eq, Show)

data HistoryEntry = HistoryEntry
  { concept :: !Text,
    record :: !Value,
    trust :: !Text,
    attestations :: ![Value],
    derivedBaseline :: !(Maybe Text),
    startedAt :: !Text,
    scenario :: !Text,
    compatibilityKey :: !(Maybe Text),
    outcome :: !Text,
    recordKind :: !Text
  }
  deriving stock (Eq, Show)

instance ToJSON HistoryDocument where
  toJSON document =
    object
      [ "schema" .= ("kenshou.evidence-history/v1" :: Text),
        "bundle" .= ("mori://shinzui/keiro-runtime-kenshou/okf/verification" :: Text),
        "query" .= queryValue document.query,
        "entries" .= document.entries
      ]

instance ToJSON HistoryEntry where
  toJSON entry =
    object
      [ "concept" .= entry.concept,
        "ref" .= ("mori://shinzui/keiro-runtime-kenshou/okf/verification/concepts/" <> entry.concept),
        "record" .= entry.record,
        "trust" .= entry.trust,
        "attestations" .= entry.attestations,
        "derivedBaseline" .= entry.derivedBaseline
      ]

queryValue :: HistoryQuery -> Value
queryValue query =
  object
    ( ["scenario" .= renderScenarioId query.scenario]
        <> maybe [] (\(name, version) -> ["cohortComponent" .= maybe name (\value -> name <> "=" <> value) version]) query.cohortComponent
        <> ["outcomes" .= map renderOutcome query.outcomes | not (null query.outcomes)]
        <> maybe [] (\day -> ["since" .= Text.pack (formatTime defaultTimeLocale "%Y-%m-%d" day)]) query.since
        <> ["confirmedOnly" .= True | query.confirmedOnly]
    )

history :: FilePath -> HistoryQuery -> IO (Either HistoryError HistoryDocument)
history root query = do
  walked <- walkBundle root
  pure do
    concepts <- either (Left . HistoryError . Text.pack . show) Right walked
    let attested = attestationIndex concepts
        allEntries = sortOn (\entry -> (entry.startedAt, entry.concept)) (mapMaybe (runEntry attested) concepts)
        withBaselines = [entry {derivedBaseline = deriveBaseline allEntries entry} | entry <- allEntries]
        selected = filter (matches query) withBaselines
    Right (HistoryDocument query selected)

deriveBaseline :: [HistoryEntry] -> HistoryEntry -> Maybe Text
deriveBaseline entries current
  | current.recordKind /= "run" = Nothing
  | otherwise = case reverse (sortOn (\entry -> (entry.startedAt, entry.concept)) candidates) of
      best : _ -> Just best.concept
      [] -> Nothing
  where
    candidates =
      [ entry
      | entry <- entries,
        entry.recordKind == "run",
        entry.scenario == current.scenario,
        entry.compatibilityKey /= Nothing,
        entry.compatibilityKey == current.compatibilityKey,
        entry.startedAt < current.startedAt,
        entry.outcome == "passed",
        hasConfirmation entry.attestations
      ]

matches :: HistoryQuery -> HistoryEntry -> Bool
matches query entry =
  entry.scenario == renderScenarioId query.scenario
    && (null query.outcomes || entry.outcome `elem` map renderOutcome query.outcomes)
    && maybe True (\day -> Text.take 10 entry.startedAt >= Text.pack (formatTime defaultTimeLocale "%Y-%m-%d" day)) query.since
    && (not query.confirmedOnly || entry.trust `elem` ["machine-confirmed", "human-reviewed"])
    && maybe True (hasComponent entry.record) query.cohortComponent

hasComponent :: Value -> (Text, Maybe Text) -> Bool
hasComponent record (package, version) = case member "components" record of
  Just (Array components) -> any matchesComponent components
  _ -> False
  where
    matchesComponent component =
      member "package" component == Just (String package)
        && maybe True (\wanted -> member "version" component == Just (String wanted) || member "revision" component == Just (String wanted)) version

runEntry :: Map Text [Value] -> Concept -> Maybe HistoryEntry
runEntry index concept
  | conceptType concept /= "Verification Run" = Nothing
  | otherwise = do
      let front = (conceptDocument concept).frontmatter
          path = Text.pack (conceptSourcePath concept)
          conceptId = Text.pack (dropExtension (conceptSourcePath concept))
          attested = Map.findWithDefault [] ("/" <> path) index
      String startedAt <- frontmatterLookup "startedAt" front
      String scenario <- frontmatterLookup "scenario" front
      String outcome <- frontmatterLookup "outcome" front
      String recordKind <- frontmatterLookup "recordKind" front
      let record = Object (KeyMap.fromList [(Key.fromText name, value) | name <- frontmatterKeys front, Just value <- [frontmatterLookup name front]])
          compatibilityKey = case frontmatterLookup "compatibilityKey" front of Just (String key) -> Just key; _ -> Nothing
          humanReviewed = any (Text.isPrefixOf "human:" . renderActor . (.verificationBy)) (readVerified front)
          confirmed = hasConfirmation attested
          trust = if humanReviewed then "human-reviewed" else if confirmed then "machine-confirmed" else "unverified"
      pure HistoryEntry {concept = conceptId, record, trust, attestations = attested, derivedBaseline = Nothing, startedAt, scenario, compatibilityKey, outcome, recordKind}

hasConfirmation :: [Value] -> Bool
hasConfirmation attestations =
  any
    (\confirmedAt -> all (\attestation -> textMember "verdict" attestation /= Just "refuted" || textMember "attestedAt" attestation <= Just confirmedAt) attestations)
    [at | attestation <- attestations, textMember "verdict" attestation == Just "confirmed", Just at <- [textMember "attestedAt" attestation]]

attestationIndex :: [Concept] -> Map Text [Value]
attestationIndex concepts = Map.map (sortOn (textMember "attestedAt")) (Map.fromListWith (<>) [(reference, [summary]) | (reference, summary) <- mapMaybe attestation concepts])
  where
    attestation concept
      | conceptType concept /= "Attestation" = Nothing
      | otherwise = do
          let front = (conceptDocument concept).frontmatter
          String run <- frontmatterLookup "run" front
          String verdict <- frontmatterLookup "verdict" front
          String attestedAt <- frontmatterLookup "attestedAt" front
          let conceptId = Text.pack (dropExtension (conceptSourcePath concept))
          pure (run, object ["concept" .= conceptId, "verdict" .= verdict, "attestedAt" .= attestedAt])

member :: Text -> Value -> Maybe Value
member name (Object fields) = KeyMap.lookup (Key.fromText name) fields
member _ _ = Nothing

textMember :: Text -> Value -> Maybe Text
textMember name value = case member name value of
  Just (String result) -> Just result
  _ -> Nothing
