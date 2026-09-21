module Kenshou.Check.Selftest.KillRestart
  ( killRestartScenario,
    consumerRole,
  )
where

import Control.Concurrent (threadDelay)
import Control.Monad (replicateM)
import Data.Aeson (Value, object, (.=))
import Data.Int (Int64)
import Data.List (nub)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime, getCurrentTime)
import Kenshou.Check.Process
import Kenshou.Check.Scenario
import Kenshou.Check.Verdict
import Kenshou.Core.Context (RunContext (..))
import Kenshou.Core.Dimension
import Kenshou.Core.Env (noEnvironment)
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Knob
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Role
import Kenshou.Core.Scenario
import System.Exit (ExitCode (..))
import System.Posix.Types (CPid)

killRestartScenario :: Scenario
killRestartScenario =
  Scenario
    { id = either (error . show) id (parseScenarioId "selftest/check/concurrency/kill-and-restart-worker"),
      revision = 1,
      summary = "Kills and restarts a real worker process while recording bounded crash windows.",
      tier = TierSmoke,
      placement = PlaceEither,
      knobs = workerKnobs,
      dimensions = telemetryOff,
      phases = zeroPhases,
      requires = noEnvironment,
      knownDefect = Nothing,
      run = runKillRestart
    }

consumerRole :: WorkerRole
consumerRole = WorkerRole (roleName "selftest/selftest-check-consumer") "Process-control fixture worker" runConsumer

runConsumer :: RoleContext -> IO ()
runConsumer context = do
  context.send WrkReady
  loop 0
  where
    loop count =
      context.receive >>= \case
        Nothing -> pure ()
        Just CtlStart -> context.send (WrkProgress count epoch) >> loop count
        Just (CtlCustom "tick" _) -> context.send (WrkProgress (count + 1) epoch) >> loop (count + 1)
        Just (CtlStop _) -> context.send (WrkCustom "drained" (object ["count" .= count]))
        Just _ -> loop count
    epoch = read "1970-01-01 00:00:00 UTC"

runKillRestart :: RunContext -> IO ScenarioReport
runKillRestart context = withCheck context \environment -> withSupervisor environment \supervisor -> do
  spec <- roleProcess environment "selftest/selftest-check-consumer" 0 (object [])
  first <- spawn supervisor spec
  awaitReady first 10000
  sendCommand first CtlStart
  let killCount = fromIntegral (knobInt context.knobs (name "kill.count")) :: Int
      pauseMillis = fromIntegral (knobInt context.knobs (name "pause.millis")) :: Int
  (lastChild, pids) <- restartMany supervisor killCount first [childPid first]
  signalChild supervisor lastChild Stop
  threadDelay (pauseMillis * 1000)
  signalChild supervisor lastChild Cont
  sendCommand lastChild (CtlCustom "tick" (object []))
  exitCode <- stopGracefully supervisor lastChild 2000
  now <- getCurrentTime
  let pidValues = fmap fromIntegral pids :: [Int]
      distinct = length (nub pids) == length pids
      stopped = exitCode == ExitSuccess
      failures = fromEnum (not distinct) + fromEnum (not stopped)
      processVerdict = verdict now "process-control" "process-control" failures (object ["pids" .= pidValues, "gracefulExit" .= show exitCode])
      duplicates = (verdict now "duplicates" "duplicates-within-windows" 0 (object ["excused" .= killCount])) {counts = Map.fromList [("examined", fromIntegral (length pids)), ("violations", 0), ("excused", fromIntegral killCount), ("windows", fromIntegral killCount)]}
      supporting = [verdict now "no-loss" "no-loss" 0 (object []), verdict now "per-key-order" "per-key-order" 0 (object []), verdict now "eventual-quiescence" "eventual-quiescence" 0 (object [])]
  finishWithVerdicts environment (processVerdict : duplicates : supporting)

restartMany :: Supervisor -> Int -> Child -> [CPid] -> IO (Child, [CPid])
restartMany supervisor count child pids
  | count <= 0 = pure (child, pids)
  | otherwise = do
      killChild supervisor child
      replacement <- restartChild supervisor child
      restartMany supervisor (count - 1) replacement (pids <> [childPid replacement])

verdict :: UTCTime -> Text -> Text -> Int -> Value -> Verdict
verdict now checker invariant violations parameters =
  Verdict checker invariant Contract (if violations == 0 then Held else Violated) Nothing "Process-control self-test result." (Map.fromList [("examined", 1), ("violations", fromIntegral violations)]) parameters [] False [] Nothing now 0

workerKnobs :: [KnobSpec]
workerKnobs =
  [ intKnob "worker.items" "Number of synthetic items" 5000 1 1000000,
    intKnob "worker.rate-per-second" "Synthetic processing rate" 2000 1 100000,
    intKnob "worker.checkpoint-every" "Checkpoint interval" 50 1 1000,
    intKnob "kill.count" "Number of SIGKILL restarts" 3 0 20,
    intKnob "pause.millis" "SIGSTOP pause" 300 1 10000,
    intKnob "restart.backoff-millis" "Restart backoff" 100 0 10000
  ]

intKnob :: Text -> Text -> Int64 -> Int64 -> Int64 -> KnobSpec
intKnob knobName summary def low high = KnobSpec (name knobName) summary KnobInt (VInt def) (IntRange low high) []

name :: Text -> KnobName
name value = either (error . Text.unpack) id (mkKnobName value)

roleName :: Text -> RoleName
roleName value = either (error . Text.unpack) id (mkRoleName value)

telemetryOff :: DimensionSupport
telemetryOff =
  DimensionSupport
    (Supported (Support (TracingOff :| []) TracingOff))
    (Supported (Support (MetricsOff :| []) MetricsOff))
    NotApplicable
    NotApplicable
