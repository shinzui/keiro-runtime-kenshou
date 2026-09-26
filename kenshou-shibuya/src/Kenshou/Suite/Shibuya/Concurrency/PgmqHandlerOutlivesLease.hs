module Kenshou.Suite.Shibuya.Concurrency.PgmqHandlerOutlivesLease (scenario) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.STM (atomically)
import Control.Exception (SomeException, displayException, try)
import Data.Aeson (Value (..), object, (.=))
import Data.Int (Int64)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time.Clock (UTCTime, diffUTCTime)
import Kenshou.Check.Process (ProgressSnapshot (..), awaitMark, awaitReady, progress, roleProcess, sendCommand, spawn, stopGracefully, withSupervisor)
import Kenshou.Check.Scenario (withCheck)
import Kenshou.Core.Context (RunContext (..), SummarySection (..), putSummary, requirePostgres)
import Kenshou.Core.Dimension (PgDurability (..), PgVersion (..), noDimensions, postgresDimensions)
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Env.Postgres (PostgresEnv (..))
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Role (ControlMessage (..))
import Kenshou.Core.Scenario (Placement (..), Scenario (..), ScenarioReport, Tier (..), failedWith, passed)
import Kenshou.Suite.Shibuya.Fixture.Pgmq (PgmqFixture (..), effectIntervals, ensureEffectsTable, queueLeaseRows, queueRows, runPgmqStack, withPgmqConnectionPool, withPgmqFixture)
import Pgmq.Effectful (MessageBody (..), SendMessage (..), sendMessage)
import Pgmq.Effectful qualified as Pgmq
import Shibuya.Adapter.Pgmq (queueNameToText)
import System.Exit (ExitCode (..))
import System.Timeout (timeout)

scenario :: Scenario
scenario =
  Scenario
    { id = either (error . Text.unpack) id (parseScenarioId "shibuya/pgmq-adapter/concurrency/handler-outlives-visibility-timeout"),
      revision = 1,
      summary = "Two consumer processes demonstrate overlapping effects after lease expiry and prevent them with explicit lease renewal.",
      tier = TierSmoke,
      placement = PlaceEither,
      knobs = [],
      dimensions = postgresDimensions (PgDurable :| []) (Pg18 :| [Pg17]) noDimensions,
      phases = zeroPhases,
      requires = noEnvironment {postgres = Just (PostgresRequirement [SchemaPgmq] [] False)},
      knownDefect = Nothing,
      run = runOverlap
    }

data ArmEvidence = ArmEvidence
  { sentId :: !Text,
    firstIntervals :: ![(Text, UTCTime, UTCTime)],
    secondIntervals :: ![(Text, UTCTime, UTCTime)],
    secondStarted :: !Bool,
    remainingRows :: !Int64,
    firstExit :: !ExitCode,
    secondExit :: !ExitCode
  }

runOverlap :: RunContext -> IO ScenarioReport
runOverlap context = do
  result <- try @SomeException $ timeout 55000000 $ do
    unextended <- runArm context "lease_off" False
    extended <- runArm context "lease_on" True
    pure (unextended, extended)
  case result of
    Left err -> pure (failedWith ["lease-overlap-exception"] (Text.pack (displayException err)))
    Right Nothing -> pure (failedWith ["lease-overlap-timeout"] "The two-process lease probe exceeded 55 seconds")
    Right (Just (unextended, extended)) -> do
      let failures =
            ["unextended-no-overlap" | not (overlaps unextended)]
              <> ["unextended-second-not-started" | not unextended.secondStarted]
              <> ["extended-second-started" | extended.secondStarted]
              <> ["extended-effect-count" | length extended.firstIntervals /= 1 || not (null extended.secondIntervals)]
              <> ["unextended-effect-count" | null unextended.firstIntervals || null unextended.secondIntervals]
              <> ["unextended-queue-not-drained" | unextended.remainingRows /= 0]
              <> ["extended-queue-not-drained" | extended.remainingRows /= 0]
              <> ["worker-exit" | any (/= ExitSuccess) [unextended.firstExit, unextended.secondExit, extended.firstExit, extended.secondExit]]
      putSummary context Verdicts "pgmq-handler-outlives-visibility-timeout" $
        object
          [ "visibilitySeconds" .= (2 :: Int),
            "handlerSeconds" .= (5 :: Int),
            "unextended" .= armValue unextended,
            "extended" .= armValue extended
          ]
      pure $ if null failures then passed else failedWith failures (Text.intercalate "; " failures)

armValue :: ArmEvidence -> Value
armValue evidence =
  object
    [ "sentId" .= evidence.sentId,
      "firstIntervals" .= evidence.firstIntervals,
      "secondIntervals" .= evidence.secondIntervals,
      "secondStarted" .= evidence.secondStarted,
      "overlap" .= overlaps evidence,
      "remainingRows" .= evidence.remainingRows,
      "firstExit" .= show evidence.firstExit,
      "secondExit" .= show evidence.secondExit
    ]

overlaps :: ArmEvidence -> Bool
overlaps evidence =
  or
    [ firstId == evidence.sentId
        && secondId == evidence.sentId
        && firstStart < secondEnd
        && secondStart < firstEnd
        && diffUTCTime firstEnd firstStart > 2
    | (firstId, firstStart, firstEnd) <- evidence.firstIntervals,
      (secondId, secondStart, secondEnd) <- evidence.secondIntervals
    ]

runArm :: RunContext -> Text -> Bool -> IO ArmEvidence
runArm context arm renew = withPgmqFixture context arm 2 $ \source ->
  withPgmqConnectionPool (requirePostgres context).connectionString 2 $ \observer -> do
    ensureEffectsTable observer
    sent <- runPgmqStack source.pool (sendMessage (SendMessage source.queue (MessageBody (String arm)) Nothing))
    identifier <- either (ioError . userError . show) (pure . Text.pack . show . Pgmq.unMessageId) sent
    let firstArm = arm <> "_first"
        secondArm = arm <> "_second"
        arguments label = object ["queue" .= queueNameToText source.queue, "arm" .= label, "visibilitySeconds" .= (2 :: Int), "extendLease" .= renew]
    (firstExit, secondExit, secondStarted) <- withCheck context $ \check -> withSupervisor check $ \supervisor -> do
      firstSpec <- roleProcess check "shibuya/pgmq-consumer" (if renew then 2 else 0) (arguments firstArm)
      secondSpec <- roleProcess check "shibuya/pgmq-consumer" (if renew then 3 else 1) (arguments secondArm)
      first <- spawn supervisor firstSpec
      second <- spawn supervisor secondSpec
      awaitReady first 5000
      awaitReady second 5000
      sendCommand first CtlStart
      awaitMark first "delivery-start" 5000
      sendCommand first (CtlCustom "quiesce" (object []))
      sendCommand second CtlStart
      awaitMark second "running" 5000
      if renew
        then do
          awaitMark first "effect-done" 9000
          -- Wait beyond the original visibility timeout after the first effect.
          threadDelay 2500000
        else do
          threadDelay 2500000
          leases <- queueLeaseRows source
          putSummary context Verdicts "pgmq-unextended-midflight" (object ["leases" .= leases])
          awaitMark second "delivery-start" 8000
          sendCommand second (CtlCustom "quiesce" (object []))
          awaitMark first "effect-done" 9000
          awaitMark second "effect-done" 9000
      awaitMark first "quiesced" 9000
      if renew then pure () else awaitMark second "quiesced" 9000
      secondSnapshot <- atomically (progress second)
      firstCode <- stopGracefully supervisor first 9000
      secondCode <- stopGracefully supervisor second 9000
      pure (firstCode, secondCode, Map.member "delivery-start" secondSnapshot.marks)
    firstIntervals <- effectIntervals observer firstArm
    secondIntervals <- effectIntervals observer secondArm
    rows <- queueRows source
    pure (ArmEvidence identifier firstIntervals secondIntervals secondStarted rows firstExit secondExit)
