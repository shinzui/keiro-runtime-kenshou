module Kenshou.Suite.Kiroku.Correctness.Notifier (scenarios) where

import Control.Concurrent (threadDelay)
import Control.Monad (forM_)
import Data.Aeson (object, (.=))
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Int (Int64)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Time.Clock (diffUTCTime, getCurrentTime)
import Kenshou.Core.Context (RunContext, SummarySection (..), putSummary)
import Kenshou.Core.Dimension
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Scenario
import Kenshou.Suite.Kiroku.Correctness.Append (recordCells)
import Kenshou.Suite.Kiroku.Fixture.Store (withKirokuStore)
import Kenshou.Suite.Kiroku.Knobs (storeKnobs)
import Kiroku.Store hiding (id, withKirokuStore)
import System.Timeout (timeout)

scenarios :: [Scenario]
scenarios = [wakeLatency]

wakeLatency :: Scenario
wakeLatency =
  Scenario
    { id = either (error . show) id (parseScenarioId "kiroku/notifier/correctness/wake-latency"),
      revision = 1,
      summary = "Checks timely NOTIFY wake-up on all-stream, category and consumer-group live paths.",
      tier = TierSmoke,
      placement = PlaceEither,
      knobs = storeKnobs,
      dimensions =
        DimensionSupport
          { tracing = Supported (Support (TracingOff :| []) TracingOff),
            metrics = Supported (Support (MetricsOff :| []) MetricsOff),
            pgDurability = Supported (Support (PgFsyncOff :| [PgDurable]) PgFsyncOff),
            pgVersion = Supported (Support (Pg18 :| [Pg17]) Pg18)
          },
      phases = zeroPhases,
      requires = noEnvironment {postgres = Just (PostgresRequirement [SchemaKiroku] [] False)},
      knownDefect = Nothing,
      run = runWakeLatency
    }

runWakeLatency :: RunContext -> IO ScenarioReport
runWakeLatency context = withKirokuStore context \store -> do
  appendTimes <- newIORef Map.empty
  allTimes <- newIORef []
  categoryTimes <- newIORef []
  groupTimes <- newIORef []
  let stream = StreamName "wake-events"
      event = EventData Nothing (EventType "Wake") (object []) Nothing Nothing Nothing
      handler ref row = do
        now <- getCurrentTime
        modifyIORef' ref ((row.globalPosition, now) :)
        pure Continue
      allConfig = defaultSubscriptionConfig (SubscriptionName "wake-all") AllStreams (handler allTimes)
      categoryConfig = defaultSubscriptionConfig (SubscriptionName "wake-category") (Category (CategoryName "wake")) (handler categoryTimes)
      groupConfig = (defaultSubscriptionConfig (SubscriptionName "wake-group") AllStreams (handler groupTimes)) {consumerGroup = Just (ConsumerGroup 0 1)}
      awaitLive handle = timeout 10000000 loop
        where
          loop = do
            state <- handle.currentState
            case state of
              Just value | stateName value == "live" -> pure True
              _ -> threadDelay 10000 >> loop
      awaitDelivered = timeout 10000000 loop
        where
          loop = do
            counts <- traverse (fmap length . readIORef) [allTimes, categoryTimes, groupTimes]
            if counts == [200, 200, 200] then pure True else threadDelay 10000 >> loop
  withSubscription store allConfig \allHandle ->
    withSubscription store categoryConfig \categoryHandle ->
      withSubscription store groupConfig \groupHandle -> do
        live <- traverse awaitLive [allHandle, categoryHandle, groupHandle]
        forM_ [1 .. 200 :: Int64] \position -> do
          started <- getCurrentTime
          modifyIORef' appendTimes (Map.insert (GlobalPosition position) started)
          appended <- runStoreIO store (appendToStream stream (if position == 1 then NoStream else ExactVersion (StreamVersion (position - 1))) [event])
          case appended of
            Right result | result.globalPosition == GlobalPosition position -> pure ()
            other -> fail ("wake workload append failed: " <> show other)
          threadDelay 100000
        complete <- awaitDelivered
        starts <- readIORef appendTimes
        delivered <- traverse (fmap reverse . readIORef) [allTimes, categoryTimes, groupTimes]
        let expected = [GlobalPosition position | position <- [1 .. 200]]
            positions rows = fmap fst rows
            maximumDelay rows = maximum (0 : [realToFrac (diffUTCTime received (starts Map.! position)) :: Double | (position, received) <- rows, Map.member position starts])
            labels = ["all", "category", "group"] :: [Text]
            delays = fmap maximumDelay delivered
            cells =
              [ ("all-three-live-before-appends", live == [Just True, Just True, Just True]),
                ("all-three-complete", complete == Just True)
              ]
                <> [(label <> "-delivery-in-order", positions rows == expected) | (label, rows) <- zip labels delivered]
                <> [(label <> "-max-wake-under-five-seconds", length rows == 200 && maximumDelay rows < 5) | (label, rows) <- zip labels delivered]
        putSummary context Verdicts "wake-latency" (object ["maxSeconds" .= delays])
        recordCells context "wake-latency" [] cells
