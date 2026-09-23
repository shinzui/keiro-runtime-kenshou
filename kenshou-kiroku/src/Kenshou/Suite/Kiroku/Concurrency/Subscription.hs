module Kenshou.Suite.Kiroku.Concurrency.Subscription (scenarios) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.STM (atomically)
import Control.Monad (void)
import Data.Aeson (object, withObject, (.:), (.=))
import Data.Aeson.Types (parseMaybe)
import Data.Int (Int64)
import Data.List (sort)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Kenshou.Check.Process (ProgressSnapshot (..), awaitMark, awaitReady, killChild, progress, restartChild, roleProcess, sendCommand, spawn, stopGracefully, terminateChild, withSupervisor)
import Kenshou.Check.Scenario (withCheck)
import Kenshou.Core.Context (RunContext (..), SummarySection (..), putSummary)
import Kenshou.Core.Dimension
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Knob (Allowed (..), KnobSpec (..), KnobType (..), KnobValue (..), knobInt, knobText, mkKnobName)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Role (ControlMessage (..))
import Kenshou.Core.Scenario
import Kenshou.Suite.Kiroku.Correctness.Append (recordCells)
import Kenshou.Suite.Kiroku.Fixture.Oracle qualified as Oracle
import Kenshou.Suite.Kiroku.Fixture.Store (withKirokuStore)
import Kenshou.Suite.Kiroku.Knobs (storeKnobs)
import Kiroku.Store hiding (id, withKirokuStore)
import System.Timeout (timeout)

scenarios :: [Scenario]
scenarios = [sigkillRedeliveryWindow]

sigkillRedeliveryWindow :: Scenario
sigkillRedeliveryWindow =
  Scenario
    { id = either (error . show) id (parseScenarioId "kiroku/subscription/concurrency/sigkill-redelivery-window"),
      revision = 1,
      summary = "Interrupts a live subscriber inside delivery batches and checks bounded redelivery.",
      tier = TierStandard,
      placement = PlaceEither,
      knobs = storeKnobs <> [intKnob "crash.kills" 10 1 32, intKnob "kiroku.subscription.batch-size" 100 1 1000, targetKnob, apiKnob, modeKnob],
      dimensions =
        DimensionSupport
          { tracing = Supported (Support (TracingOff :| []) TracingOff),
            metrics = Supported (Support (MetricsOff :| []) MetricsOff),
            pgDurability = Supported (Support (PgDurable :| []) PgDurable),
            pgVersion = Supported (Support (Pg18 :| [Pg17]) Pg18)
          },
      phases = zeroPhases,
      requires = noEnvironment {postgres = Just (PostgresRequirement [SchemaKiroku] [] False)},
      knownDefect = Nothing,
      run = runRedelivery
    }
  where
    name = either (error . show) id . mkKnobName
    intKnob key value lower upper = KnobSpec (name key) key KnobInt (VInt value) (IntRange lower upper) []
    targetKnob = KnobSpec (name "kiroku.subscription.target") "All streams or one category" KnobText (VText "all") (OneOf (VText "all" :| [VText "category"])) [VText "all", VText "category"]
    apiKnob = KnobSpec (name "kiroku.subscription.api") "Native handler, plain Streamly, or acknowledged Streamly" KnobText (VText "native") (OneOf (VText "native" :| [VText "plain", VText "ack"])) [VText "native", VText "plain", VText "ack"]
    modeKnob = KnobSpec (name "crash.mode") "Subscriber interruption mode" KnobText (VText "sigkill") (OneOf (VText "sigkill" :| [VText "sigterm", VText "cancel", VText "handler-exception"])) [VText "sigkill", VText "sigterm", VText "cancel", VText "handler-exception"]

runRedelivery :: RunContext -> IO ScenarioReport
runRedelivery context = withKirokuStore context \store -> withCheck context \check -> withSupervisor check \supervisor -> do
  let name = either (error . show) id . mkKnobName
      kills = fromIntegral (knobInt context.knobs (name "crash.kills")) :: Int
      batchSize = fromIntegral (knobInt context.knobs (name "kiroku.subscription.batch-size")) :: Int
      target = knobText context.knobs (name "kiroku.subscription.target")
      api = knobText context.knobs (name "kiroku.subscription.api")
      crashMode = knobText context.knobs (name "crash.mode")
      eventsPerRound = 500
      subscriberArgs = object ["name" .= ("redelivery-window" :: Text), "guard" .= False, "target" .= target, "api" .= api, "batchSize" .= batchSize, "emitDeliveries" .= True, "handlerDelayMicros" .= (1000 :: Int)]
      event = EventData Nothing (EventType "CrashWindow") (object []) Nothing Nothing Nothing
      deliveryPositions child = do
        state <- atomically (progress child)
        let records = [record | (key, payload) <- Map.toList state.marks, "delivery-" `Text.isPrefixOf` key, Just record <- [parseMaybe (withObject "delivery" (\row -> (,) <$> row .: "sequence" <*> row .: "position")) payload :: Maybe (Int, Int64)]]
        pure [position | (_, position) <- sort records]
      checkpoint = do
        rows <- Oracle.checkpoints store.pool
        pure (maximum (0 : [position | (subscriptionName, member, position) <- rows, subscriptionName == "redelivery-window", member == 0]))
      awaitCount child count = do
        values <- deliveryPositions child
        if length values >= count then pure values else threadDelay 1000 >> awaitCount child count
      awaitCheckpoint position = do
        saved <- checkpoint
        if saved >= position then pure saved else threadDelay 10000 >> awaitCheckpoint position
  spec <- roleProcess check "kiroku/subscriber" 0 subscriberArgs
  first <- spawn supervisor spec
  awaitReady first 10000
  sendCommand first CtlStart
  threadDelay 100000
  initialCheckpoint <- checkpoint
  let loop child index archived samples windows
        | index >= kills = pure (child, reverse archived, reverse samples, reverse windows)
        | otherwise = do
            let start = index * eventsPerRound + 1
                end = (index + 1) * eventsPerRound
                streamName = if target == "category" then StreamName "crash-events" else StreamName "window-events"
            beforeCount <- length <$> deliveryPositions child
            if crashMode == "handler-exception"
              then sendCommand child (CtlCustom "arm-handler-exception" (object ["position" .= (fromIntegral (start + 150) :: Int64)])) >> awaitMark child "handler-armed" 10000
              else pure ()
            result <- runStoreIO store (appendToStream streamName AnyVersion (replicate eventsPerRound event))
            case result of Right _ -> pure (); Left err -> fail ("redelivery append failed: " <> show err)
            _ <- timeout 30000000 (awaitCount child (beforeCount + 150))
            if crashMode == "handler-exception" then awaitMark child "handler-exception" 30000 else pure ()
            case crashMode of
              "sigterm" -> terminateChild supervisor child
              "cancel" -> void (stopGracefully supervisor child 5000)
              "handler-exception" -> void (stopGracefully supervisor child 5000)
              _ -> killChild supervisor child
            threadDelay 10000
            oldDeliveries <- deliveryPositions child
            replacement <- restartChild supervisor child
            awaitReady replacement 10000
            sendCommand replacement CtlStart
            saved <- timeout 30000000 (awaitCheckpoint (fromIntegral end))
            loop replacement (index + 1) (oldDeliveries : archived) (maybe (-1) id saved : samples) ((start, end) : windows)
  (active, archived, samples, windows) <- loop first 0 [] [initialCheckpoint] []
  finalDeliveries <- deliveryPositions active
  finalCheckpoint <- checkpoint
  let incarnations = archived <> [finalDeliveries]
      observed = concat incarnations
      total = kills * eventsPerRound
      expected = Set.fromList [1 .. fromIntegral total]
      actual = Set.fromList observed
      counts = Map.fromListWith (+) [(position, 1 :: Int) | position <- observed]
      duplicates = [position | (position, count) <- Map.toList counts, count > 1]
      inWindow position = any (\(start, end) -> position >= fromIntegral start && position <= fromIntegral end) windows
      perWindow = [length [position | position <- duplicates, position >= fromIntegral start && position <= fromIntegral end] | (start, end) <- windows]
      budget = if target == "all" then max batchSize 1000 else batchSize
      cells =
        [ ("all-positions-delivered", actual == expected),
          ("incarnation-order", all (\values -> values == sort values) incarnations),
          ("checkpoints-monotonic", (samples <> [finalCheckpoint]) == sort (samples <> [finalCheckpoint]) && finalCheckpoint == fromIntegral total),
          ("duplicates-within-crash-windows", all inWindow duplicates),
          ("per-crash-duplicate-budget", all (<= budget) perWindow)
        ]
  putSummary context Measurements "sigkill-redelivery-window" (object ["target" .= target, "api" .= api, "crashMode" .= crashMode, "kills" .= kills, "batchSize" .= batchSize, "budget" .= budget, "distinctPositions" .= Set.size actual, "totalEvents" .= total, "duplicatePositions" .= length duplicates, "duplicatesPerWindow" .= perWindow, "checkpointSamples" .= (samples <> [finalCheckpoint])])
  recordCells context "sigkill-redelivery-window" ["per-crash-duplicate-budget"] cells
