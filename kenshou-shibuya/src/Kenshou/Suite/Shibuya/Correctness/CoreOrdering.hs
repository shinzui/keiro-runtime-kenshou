module Kenshou.Suite.Shibuya.Correctness.CoreOrdering (scenarios) where

import Control.Monad (forM)
import Data.Aeson (object, (.=))
import Data.ByteString.Char8 qualified as ByteString
import Data.List (nub, sort)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time.Clock (UTCTime, diffUTCTime, getCurrentTime)
import Effectful (runEff)
import Kenshou.Core.Context (RunContext (..), SummarySection (..), putSummary)
import Kenshou.Core.Dimension (noDimensions)
import Kenshou.Core.Env (noEnvironment)
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Knob (Allowed (..), KnobName, KnobSpec (..), KnobType (..), KnobValue (..), knobInt, mkKnobName)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Scenario (Placement (..), Scenario (..), ScenarioReport, Tier (..), failedWith, passed)
import Kenshou.Suite.Shibuya.Fixture.Handlers (HandlerEvent (..), HandlerScript (..), HandlerStats (..), defaultHandlerScript, handlerEvents, handlerStats, newHandlerProbe, scriptedHandler)
import Kenshou.Suite.Shibuya.Fixture.SyntheticAdapter (BrokerEvent (..), BrokerStats (..), SyntheticBroker, brokerEvents, brokerStats, closeInput, defaultSyntheticConfig, newSyntheticBroker, publish, syntheticAdapter)
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
      },
    hotKeyHeadOfLine
  ]

hotKeyHeadOfLine :: Scenario
hotKeyHeadOfLine =
  Scenario
    { id = either (error . Text.unpack) id (parseScenarioId "shibuya/core-ordering/concurrency/hot-key-head-of-line"),
      revision = 1,
      summary = "Cold partition keys continue while one hot key has slow handlers; reports the latency cost against a control run.",
      tier = TierSmoke,
      placement = PlaceEither,
      knobs =
        [ KnobSpec (hotKnob "hol.starvation-seconds") "Maximum cold-key publish-to-handler-start delay" KnobInt (VInt 30) (IntRange 1 3600) [],
          KnobSpec (hotKnob "hol.alert-factor") "P99 latency ratio above which upstream review is recommended" KnobInt (VInt 10) (IntRange 1 1000) []
        ],
      dimensions = noDimensions,
      phases = zeroPhases,
      requires = noEnvironment,
      knownDefect = Nothing,
      run = runHotKey
    }

runHotKey :: RunContext -> IO ScenarioReport
runHotKey context = do
  hot <- runHotArm True
  control <- runHotArm False
  let factor = hot.coldP99Seconds / max 0.000001 control.coldP99Seconds
      starvationSeconds = fromIntegral (knobInt context.knobs (hotKnob "hol.starvation-seconds"))
      alertFactor = fromIntegral (knobInt context.knobs (hotKnob "hol.alert-factor"))
      failures = hot.failures <> control.failures <> ["cold-keys-starved" | hot.coldMaxSeconds > starvationSeconds]
  putSummary context Verdicts "hot-key-head-of-line" $
    object
      [ "coldP99SecondsWithHotKey" .= hot.coldP99Seconds,
        "coldP99SecondsControl" .= control.coldP99Seconds,
        "headOfLineFactor" .= factor,
        "alertFactorExceeded" .= (factor > alertFactor),
        "coldMaxSeconds" .= hot.coldMaxSeconds
      ]
  pure $ if null failures then passed else failedWith failures (Text.intercalate "; " failures)

hotKnob :: Text -> KnobName
hotKnob raw = either (error . Text.unpack) id (mkKnobName raw)

data HotArm = HotArm
  { failures :: [Text],
    coldP99Seconds :: Double,
    coldMaxSeconds :: Double
  }

runHotArm :: Bool -> IO HotArm
runHotArm includeHot = do
  broker <- newSyntheticBroker defaultSyntheticConfig
  published <- fmap concat $ forM [1 .. 4 :: Int] $ \roundNumber -> do
    hot <- if includeHot then fmap (: []) (publishOne broker (Just "hot") ("hot-" <> show roundNumber)) else pure []
    cold <- forM [1 .. 63 :: Int] $ \number ->
      publishOne broker (Just ("cold-" <> Text.pack (show number))) ("cold-" <> show roundNumber <> "-" <> show number)
    pure (hot <> cold)
  closeInput broker
  let metadata = Map.fromList [(identifier, (key, at)) | (identifier, key, at) <- published]
      delayFor identifier _ = case Map.lookup identifier metadata of
        Just (Just "hot", _) -> 100000
        _ -> 1000
  probe <- newHandlerProbe defaultHandlerScript {delayFor}
  completed <- timeout 10000000 $ runEff $ runTracingNoop $ do
    let processor = (mkProcessor (syntheticAdapter broker) (scriptedHandler probe)) {ordering = PartitionedInOrder, concurrency = Async 4}
    result <- runApp defaultAppConfig [(ProcessorId "hot-key", processor)]
    case result of
      Left err -> error (show err)
      Right handle -> waitApp handle >> stopApp handle
  stats <- brokerStats broker
  events <- handlerEvents probe
  brokerFacts <- brokerEvents broker
  let starts = [(identifier, at) | HandlerStarted identifier _ at _ <- events]
      startIds = map fst starts
      finalizedIds = [identifier | Finalized identifier _ AckOk <- brokerFacts]
      allKeys = nub [key | (_, Just key, _) <- published]
      expected = [identifier | (identifier, _, _) <- published]
      perKeyOrder = all (\key -> filter (belongs key) startIds == filter (belongs key) expected && filter (belongs key) finalizedIds == filter (belongs key) expected) allKeys
      noOverlap = all (\key -> peakForKey key (Map.map fst metadata) events <= 1) allKeys
      belongs key identifier = case Map.lookup identifier metadata of
        Just (actual, _) -> actual == Just key
        Nothing -> False
      coldLatencies =
        [ realToFrac (diffUTCTime startedAt publishedAt) :: Double
        | (identifier, startedAt) <- starts,
          Just (Just key, publishedAt) <- [Map.lookup identifier metadata],
          key /= "hot"
        ]
      label = if includeHot then "hot" else "control"
      problems =
        [label <> ": application timed out" | completed == Nothing]
          <> [label <> ": messages not conserved" | stats.finalizedOk /= length published || stats.leasedUnfinalized /= 0]
          <> [label <> ": per-key order changed" | not perKeyOrder]
          <> [label <> ": same-key handlers overlapped" | not noOverlap]
          <> [label <> ": no cold handlers started" | null coldLatencies]
  pure $ HotArm problems (percentile99 coldLatencies) (maximum (0 : coldLatencies))

publishOne :: SyntheticBroker -> Maybe Text -> String -> IO (MessageId, Maybe Text, UTCTime)
publishOne broker key payload = do
  at <- getCurrentTime
  identifier <- publish broker key (ByteString.pack payload)
  pure (identifier, key, at)

percentile99 :: [Double] -> Double
percentile99 [] = 0
percentile99 values = ordered !! max 0 (ceiling ((0.99 :: Double) * fromIntegral (length values)) - 1)
  where
    ordered = sort values

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
