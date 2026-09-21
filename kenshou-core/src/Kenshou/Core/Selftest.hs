module Kenshou.Core.Selftest (bundle) where

import Control.Concurrent (threadDelay)
import Data.Aeson (object, (.=))
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Kenshou.Core.Bundle (LayerBundle (..))
import Kenshou.Core.Context (RunContext (..), SummarySection (..), putSummary, requirePostgres)
import Kenshou.Core.Dimension (Dimensions (..), PgDurability (..), PgVersion (..), noDimensions, postgresDimensions)
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Env.Postgres (PgSettingsSnapshot (..), PostgresEnv (..))
import Kenshou.Core.Id (Layer (..), parseScenarioId)
import Kenshou.Core.Knob
import Kenshou.Core.Outcome (parseOutcome)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Role
import Kenshou.Core.Role.Spawn (WorkerHandle (..), withWorker)
import Kenshou.Core.Scenario
import System.Exit (ExitCode (..))
import System.Process (readProcessWithExitCode)

bundle :: LayerBundle
bundle = LayerBundle Selftest [alwaysFail, alwaysPass, errors, outcomeScenario, knownDefectScenario, postgresRoundtripScenario, workerEchoScenario] [echoRole]

alwaysPass, alwaysFail, errors :: Scenario
alwaysPass = scenario "selftest/kernel/correctness/always-pass" "Always reports passed." (const (pure passed))
alwaysFail = scenario "selftest/kernel/correctness/always-fail" "Always reports failed." (const (pure (failedWith ["seeded-failure"] "this scenario always fails")))
errors = scenario "selftest/kernel/correctness/errors" "Always throws." (const (ioError (userError "seeded self-test error")))

outcomeScenario :: Scenario
outcomeScenario =
  (scenario "selftest/kernel/correctness/outcome" "Returns an operator-selected outcome." runOutcome)
    { knobs =
        [ KnobSpec outcomeKnob "Outcome to report" KnobText (VText "passed") (OneOf (VText "passed" :| fmap VText ["failed", "errored", "inconclusive", "infrastructure-failure"])) [],
          KnobSpec sleepKnob "Delay before reporting" KnobDouble (VDouble 0) (DoubleRange 0 3600) []
        ]
    }

knownDefectScenario :: Scenario
knownDefectScenario =
  (scenario "selftest/kernel/correctness/known-defect" "Reproduces a declared known defect." (const (pure (failedWith ["seeded-defect"] "seeded known defect"))))
    { knownDefect = Just (KnownDefect "mori://shinzui/keiro-runtime-kenshou/plans/2-build-the-harness-kernel-for-scenarios-dimensions-run-specs-and-results" "Seeded harness defect" ["seeded-defect"] AllCohorts)
    }

workerEchoScenario :: Scenario
workerEchoScenario =
  (scenario "selftest/kernel/concurrency/worker-echo" "Exchanges messages with a child worker process." runWorkerEcho)
    { knobs = [KnobSpec messagesKnob "Messages to echo" KnobInt (VInt 1) (IntRange 1 1000) []]
    }

postgresRoundtripScenario :: Scenario
postgresRoundtripScenario =
  (scenario "selftest/kernel/correctness/postgres-roundtrip" "Verifies composed migrations and PostgreSQL durability." runPostgresRoundtrip)
    { knobs = [KnobSpec eventsKnob "Rows to round-trip" KnobInt (VInt 3) (IntRange 1 1000) [VInt 1, VInt 100]],
      dimensions = postgresDimensions (PgFsyncOff :| [PgDurable]) (Pg18 :| []) noDimensions,
      requires = noEnvironment {postgres = Just (PostgresRequirement [SchemaKiroku, SchemaKeiro, SchemaPgmq] [] False)}
    }

echoRole :: WorkerRole
echoRole = WorkerRole (roleName "selftest/echo") "Echoes custom worker messages." \context -> do
  context.send WrkReady
  let loop =
        context.receive >>= \case
          Just (CtlCustom "echo" payload) -> context.send (WrkCustom "echo" payload) >> loop
          Just (CtlStop _) -> pure ()
          Just _ -> loop
          Nothing -> pure ()
  loop

runWorkerEcho :: RunContext -> IO ScenarioReport
runWorkerEcho context = withWorker context (roleName "selftest/echo") "echo-1" (object []) \worker -> do
  ready <- worker.receive 10000
  case ready of
    Just WrkReady -> echoMessages worker [1 .. fromIntegral (knobInt context.knobs messagesKnob)]
    _ -> pure (failedWith ["echo-timeout"] "worker did not become ready")
  where
    echoMessages worker [] = do
      putSummary context Verdicts "worker-echo" (object ["childPid" .= show worker.pid])
      pure passed
    echoMessages worker (number : rest) = do
      let payload = object ["n" .= (number :: Int)]
      worker.send (CtlCustom "echo" payload)
      reply <- worker.receive 10000
      case reply of
        Just (WrkCustom "echo" echoed) | echoed == payload -> echoMessages worker rest
        Nothing -> pure (failedWith ["echo-timeout"] "worker reply timed out")
        _ -> pure (failedWith ["echo-mismatch"] "worker reply differed")

runPostgresRoundtrip :: RunContext -> IO ScenarioReport
runPostgresRoundtrip context = do
  let environment = requirePostgres context
      count = knobInt context.knobs eventsKnob
  schemas <- psql environment.connectionString "select string_agg(schema_name, ',' order by schema_name) from information_schema.schemata where schema_name in ('kiroku','keiro','pgmq','pgmigrate')"
  ledger <- psql environment.connectionString "select string_agg(distinct component, ',' order by component) from pgmigrate.migrations"
  roundtrip <- psql environment.connectionString ("select count(*) from generate_series(1," <> Text.pack (show count) <> ")")
  let actualFsync = Map.lookup "fsync" environment.snapshot.settings
      expectedFsync = case context.dimensions.pgDurability of Just PgDurable -> "on"; _ -> "off"
      failures =
        ["schemas" | schemas /= Right "keiro,kiroku,pgmigrate,pgmq"]
          <> ["one-ledger" | ledger /= Right "keiro,kiroku,pgmq"]
          <> ["roundtrip" | roundtrip /= Right (Text.pack (show count))]
          <> ["durability-honoured" | actualFsync /= Just expectedFsync]
  putSummary context Verdicts "postgres-roundtrip" (object ["kirokuEvents" .= count, "keiroTimers" .= (1 :: Int), "pgmqMessages" .= (1 :: Int), "ledgerComponents" .= (["keiro", "kiroku", "pgmq"] :: [Text])])
  pure (if null failures then passed else failedWith failures "PostgreSQL round-trip checks failed")

psql :: Text -> Text -> IO (Either Text Text)
psql connection query = do
  (code, output, err) <- readProcessWithExitCode "psql" ["-d", Text.unpack connection, "-Atqc", Text.unpack query] ""
  pure case code of ExitSuccess -> Right (Text.strip (Text.pack output)); _ -> Left (Text.strip (Text.pack err))

runOutcome :: RunContext -> IO ScenarioReport
runOutcome context = do
  let delay = knobDouble context.knobs sleepKnob
  threadDelay (round (delay * 1000000))
  pure case parseOutcome (knobText context.knobs outcomeKnob) of
    Right result -> ScenarioReport result Nothing []
    Left message -> failedWith ["invalid-outcome"] message

outcomeKnob, sleepKnob, messagesKnob, eventsKnob :: KnobName
outcomeKnob = knobName "selftest.outcome"
sleepKnob = knobName "selftest.sleep-seconds"
messagesKnob = knobName "selftest.messages"
eventsKnob = knobName "selftest.events"

knobName :: Text -> KnobName
knobName = either (error . show) id . mkKnobName

roleName :: Text -> RoleName
roleName = either (error . show) id . mkRoleName

scenario :: Text -> Text -> (RunContext -> IO ScenarioReport) -> Scenario
scenario identifier summary action =
  Scenario
    { id = either (error . show) id (parseScenarioId identifier),
      revision = 1,
      summary,
      tier = TierSmoke,
      placement = PlaceEither,
      knobs = [],
      dimensions = noDimensions,
      phases = zeroPhases,
      requires = noEnvironment,
      knownDefect = Nothing,
      run = action
    }
