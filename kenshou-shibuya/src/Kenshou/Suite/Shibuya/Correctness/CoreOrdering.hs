module Kenshou.Suite.Shibuya.Correctness.CoreOrdering (scenarios) where

import Control.Monad (forM)
import Data.ByteString.Char8 qualified as ByteString
import Data.List (nub)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Effectful (runEff)
import Kenshou.Core.Dimension (noDimensions)
import Kenshou.Core.Env (noEnvironment)
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Scenario (Placement (..), Scenario (..), Tier (..), failedWith, passed)
import Kenshou.Suite.Shibuya.Fixture.Handlers (HandlerEvent (..), HandlerScript (..), HandlerStats (..), defaultHandlerScript, handlerEvents, handlerStats, newHandlerProbe, scriptedHandler)
import Kenshou.Suite.Shibuya.Fixture.SyntheticAdapter (BrokerEvent (..), BrokerStats (..), brokerEvents, brokerStats, closeInput, defaultSyntheticConfig, newSyntheticBroker, publish, syntheticAdapter)
import Shibuya.App (QueueProcessor (..), defaultAppConfig, mkProcessor, runApp, stopApp, waitApp)
import Shibuya.Core.Ack (AckDecision (..))
import Shibuya.Core.Metrics (ProcessorId (..))
import Shibuya.Core.Types (MessageId)
import Shibuya.Policy (Concurrency (..), OrderingPolicy (..))
import Shibuya.Telemetry.Effect (runTracingNoop)
import System.Timeout (timeout)

scenarios :: [Scenario]
scenarios =
  [ Scenario
      { id = either (error . Text.unpack) id (parseScenarioId "shibuya/core-ordering/correctness/policy-matrix"),
        revision = 1,
        summary = "Checks source and per-partition order across every valid ordering and concurrency pair.",
        tier = TierSmoke,
        placement = PlaceEither,
        knobs = [],
        dimensions = noDimensions,
        phases = zeroPhases,
        requires = noEnvironment,
        knownDefect = Nothing,
        run = \_ -> do
          failures <- concat <$> mapM runArm validPolicies
          pure $ if null failures then passed else failedWith failures (Text.intercalate "; " failures)
      }
  ]

validPolicies :: [(OrderingPolicy, Concurrency)]
validPolicies =
  [ (StrictInOrder, Serial),
    (PartitionedInOrder, Serial),
    (PartitionedInOrder, Ahead 4),
    (PartitionedInOrder, Async 4),
    (Unordered, Serial),
    (Unordered, Ahead 4),
    (Unordered, Async 4)
  ]

runArm :: (OrderingPolicy, Concurrency) -> IO [Text]
runArm (ordering, concurrency) = do
  broker <- newSyntheticBroker defaultSyntheticConfig
  published <- forM [1 .. 64 :: Int] $ \number -> do
    let key = Just ("partition-" <> Text.pack (show (number `mod` 16)))
    identifier <- publish broker key (ByteString.pack (show number))
    pure (identifier, key)
  closeInput broker
  let keys = Map.fromList published
      delayFor _ _ = 5000
  probe <- newHandlerProbe defaultHandlerScript {delayFor}
  completed <- timeout 5000000 $ runEff $ runTracingNoop $ do
    let processor = (mkProcessor (syntheticAdapter broker) (scriptedHandler probe)) {ordering, concurrency}
    result <- runApp defaultAppConfig [(ProcessorId "policy-matrix", processor)]
    case result of
      Left err -> error (show err)
      Right handle -> waitApp handle >> stopApp handle
  stats <- brokerStats broker
  handlerState <- handlerStats probe
  handlerFacts <- handlerEvents probe
  brokerFacts <- brokerEvents broker
  let label = Text.pack (show ordering <> "/" <> show concurrency)
      starts = [identifier | HandlerStarted identifier _ _ _ <- handlerFacts]
      finalizations = [identifier | Finalized identifier _ AckOk <- brokerFacts]
      expected = map fst published
      partitionKeys = nub [key | (_, Just key) <- published]
      perKey actual = all (\key -> filter ((== Just (Just key)) . (`Map.lookup` keys)) actual == filter ((== Just (Just key)) . (`Map.lookup` keys)) expected) partitionKeys
      noKeyOverlaps = all (\key -> peakForKey key keys handlerFacts <= 1) partitionKeys
      bound = case concurrency of Serial -> 1; Ahead count -> count; Async count -> count
      expectedParallelism = if bound == 1 then 1 else 2
  pure $
    [label <> ": application timed out" | completed == Nothing]
      <> [label <> ": publication was not conserved" | stats.finalizedOk /= 64 || stats.leasedUnfinalized /= 0]
      <> [label <> ": handler concurrency exceeded policy bound" | handlerState.highWater > bound]
      <> [label <> ": concurrent policy did not overlap handlers" | handlerState.highWater < expectedParallelism]
      <> [label <> ": strict ordering changed handler start order" | ordering == StrictInOrder && starts /= expected]
      <> [label <> ": strict ordering changed finalization order" | ordering == StrictInOrder && finalizations /= expected]
      <> [label <> ": partition order changed" | ordering == PartitionedInOrder && (not (perKey starts) || not (perKey finalizations))]
      <> [label <> ": handlers for a partition overlapped" | ordering == PartitionedInOrder && not noKeyOverlaps]

peakForKey :: Text -> Map MessageId (Maybe Text) -> [HandlerEvent] -> Int
peakForKey key keys = snd . foldl step (0, 0)
  where
    belongs identifier = Map.lookup identifier keys == Just (Just key)
    step (active, peak) event = case event of
      HandlerStarted identifier _ _ _ | belongs identifier -> let next = active + 1 in (next, max peak next)
      HandlerEnded identifier _ _ _ _ | belongs identifier -> (active - 1, peak)
      _ -> (active, peak)
