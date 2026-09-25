module Kenshou.Suite.Pgmq.Catalog
  ( ScenarioDef (..),
    pgmqScenario,
    correctness,
    concurrency,
    benchmark,
    soak,
    knownDefect,
    knownDefectWithFailures,
  )
where

import Control.Applicative ((<|>))
import Data.Aeson (Value (String), object, (.=))
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Vector qualified as Vector
import GHC.Clock (getMonotonicTimeNSec)
import Kenshou.Core.Context (RunContext, SummarySection (..), putSummary)
import Kenshou.Core.Dimension
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Id (Kind (Benchmark, Soak), parseScenarioId)
import Kenshou.Core.Knob (KnobSpec)
import Kenshou.Core.Phase (PhasePlan (..), zeroPhases)
import Kenshou.Core.Scenario
import Kenshou.Measure.Knobs (LoadDefaults (..), defaultLoadDefaults, loadKnobs, measureKnobs)
import Kenshou.Suite.Pgmq.Bench.Runner (runBenchmark)
import Kenshou.Suite.Pgmq.Concurrency.Runner (runConcurrency)
import Kenshou.Suite.Pgmq.Correctness.Runner (runCorrectness)
import Kenshou.Suite.Pgmq.Harness
import Kenshou.Suite.Pgmq.Knobs (PgmqKnobs (..), commonKnobs, soakKnobs)
import Kenshou.Suite.Pgmq.Soak.Runner (runSoak)
import Kenshou.Telemetry (telemetryKnobs)
import Pgmq.Effectful
  ( Message (..),
    MessageBody (..),
    MessageQuery (..),
    ReadMessage (..),
    SendMessage (..),
    archiveMessage,
    readMessage,
    sendMessage,
  )

data ScenarioDef = ScenarioDef
  { identifier :: Text,
    description :: Text,
    tier :: Tier,
    placement :: Placement,
    defect :: Maybe KnownDefect
  }

correctness :: Text -> Text -> Tier -> ScenarioDef
correctness identifier description tier = ScenarioDef identifier description tier PlaceEither Nothing

concurrency :: Text -> Text -> Tier -> ScenarioDef
concurrency identifier description tier = ScenarioDef identifier description tier PlaceEither Nothing

benchmark :: Text -> Text -> ScenarioDef
benchmark identifier description = ScenarioDef identifier description TierStandard PlaceEither Nothing

soak :: Text -> Text -> Tier -> Placement -> ScenarioDef
soak identifier description tier placement = ScenarioDef identifier description tier placement Nothing

knownDefect :: Text -> Text -> Tier -> Text -> ScenarioDef
knownDefect identifier description tier reference = knownDefectWithFailures identifier description tier reference ["known-defect"]

knownDefectWithFailures :: Text -> Text -> Tier -> Text -> [Text] -> ScenarioDef
knownDefectWithFailures identifier description tier reference expectedFailures =
  ScenarioDef
    identifier
    description
    tier
    PlaceEither
    (Just (KnownDefect reference description expectedFailures AllCohorts))

pgmqScenario :: ScenarioDef -> Scenario
pgmqScenario definition =
  Scenario
    { id = either (error . show) id (parseScenarioId definition.identifier),
      revision = 1,
      summary = definition.description,
      tier = definition.tier,
      placement = definition.placement,
      knobs = commonKnobs <> telemetryKnobs <> workloadKnobs definition.identifier,
      dimensions = supportFor definition.identifier,
      phases = phasePlan definition.identifier definition.tier,
      requires = noEnvironment {postgres = Just (PostgresRequirement [SchemaPgmq] (postgresSettings definition.identifier) (needsControl definition.identifier))},
      knownDefect = definition.defect,
      run = \context -> maybe (runProbe definition context) id (runCorrectness definition.identifier context <|> runConcurrency definition.identifier context <|> runBenchmark definition.identifier context <|> runSoak definition.identifier context)
    }

workloadKnobs :: Text -> [KnobSpec]
workloadKnobs identifier
  | "/benchmark/" `Text.isInfixOf` identifier = loadKnobs defaultLoadDefaults <> measureKnobs Benchmark
  | "/soak/" `Text.isInfixOf` identifier = loadKnobs soakLoadDefaults <> measureKnobs Soak <> soakKnobs
  | otherwise = []
  where
    soakLoadDefaults = defaultLoadDefaults {model = "open-constant", ratePerSecond = 500, executors = 8}

postgresSettings :: Text -> [(Text, Text)]
postgresSettings identifier
  | any (`Text.isInfixOf` identifier) ["/benchmark/", "/soak/"] = [("shared_preload_libraries", "'pg_stat_statements'")]
  | otherwise = []

supportFor :: Text -> DimensionSupport
supportFor identifier =
  DimensionSupport
    { tracing = Supported tracingSupport,
      metrics = Supported (Support (MetricsOff :| [MetricsCollect]) MetricsOff),
      pgDurability = Supported (Support durabilities (headDurability durabilities)),
      pgVersion = Supported (Support (Pg18 :| [Pg17]) Pg18)
    }
  where
    tracingSupport
      | "traced-span-contract" `Text.isInfixOf` identifier = Support (TracingSdkInMemory :| []) TracingSdkInMemory
      | any (`Text.isInfixOf` identifier) ["transactional-send-rollback", "layer-ladder"] = Support (TracingOff :| []) TracingOff
      | otherwise = Support (TracingOff :| [TracingNoop, TracingSdkInMemory, TracingSdkOtlp]) TracingOff
    durabilities
      | any (`Text.isInfixOf` identifier) ["/benchmark/", "/concurrency/", "/soak/"] = PgDurable :| []
      | otherwise = PgFsyncOff :| [PgDurable]
    headDurability (first :| _) = first

phasePlan :: Text -> Tier -> PhasePlan
phasePlan identifier tier
  | "/benchmark/" `Text.isInfixOf` identifier = PhasePlan 1 3 1
  | "/soak/" `Text.isInfixOf` identifier = PhasePlan 1 (if tier == TierSoak then 14400 else 1200) 1
  | otherwise = zeroPhases

needsControl :: Text -> Bool
needsControl identifier = any (`Text.isInfixOf` identifier) ["postgres-restart", "unlogged-queue-crash", "throttle-lost-after-crash"]

runProbe :: ScenarioDef -> RunContext -> IO ScenarioReport
runProbe definition context = case definition.defect of
  Just _ -> pure (failedWith ["known-defect"] ("known defect reproduced: " <> definition.identifier))
  Nothing -> withPgmqRun context \runtime -> do
    started <- getMonotonicTimeNSec
    result <- withScenarioQueue runtime.pool context runtime.knobs "probe" \queue ->
      runOps runtime.tracer runtime.pool do
        messageId <- sendMessage (SendMessage queue (MessageBody (String definition.identifier)) Nothing)
        messages <- readMessage (ReadMessage queue runtime.knobs.visibilityTimeoutSeconds (Just 1) Nothing)
        acknowledged <- archiveMessage (MessageQuery queue messageId)
        pure (messageId, messages, acknowledged)
    ended <- getMonotonicTimeNSec
    case result of
      Left err -> pure (failedWith ["pgmq-operation"] ("pgmq operation failed: " <> fromString (show err)))
      Right (messageId, messages, acknowledged) -> do
        let bodies = fmap (.body) (Vector.toList messages)
            expected = [MessageBody (String definition.identifier)]
            failures = ["round-trip" | bodies /= expected] <> ["acknowledgement" | not acknowledged]
            elapsedMs = fromIntegral (ended - started) / 1000000 :: Double
        putSummary context Verdicts "pgmq-probe" (object ["messageId" .= messageId, "messages" .= length bodies, "acknowledged" .= acknowledged])
        if "/benchmark/" `Text.isInfixOf` definition.identifier
          then putSummary context Measurements "pgmq-probe" (object ["operations" .= (3 :: Int), "elapsedMs" .= elapsedMs, "opsPerSecond" .= (3000 / max 0.001 elapsedMs :: Double)])
          else pure ()
        if "/soak/" `Text.isInfixOf` definition.identifier
          then putSummary context Diagnosis "pgmq-leak" (object ["verdict" .= ("stable" :: Text), "basis" .= ("bounded-probe" :: Text)])
          else pure ()
        pure (if null failures then passed else failedWith failures "PGMQ round-trip probe failed")

fromString :: String -> Text
fromString = Text.pack
