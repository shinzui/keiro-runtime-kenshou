module Kenshou.Suite.Kiroku.Correctness.ConsumerGroup (scenarios) where

import Control.Concurrent (threadDelay)
import Control.Exception (try)
import Control.Monad (forM, forM_)
import Data.Aeson (object)
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Int (Int32, Int64)
import Data.List (sort)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Data.Vector qualified as Vector
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Statement qualified as Statement
import Hasql.Transaction qualified as Tx
import Kenshou.Core.Context (RunContext (..))
import Kenshou.Core.Dimension
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Knob (Allowed (..), KnobSpec (..), KnobType (..), KnobValue (..), knobInt, knobText, mkKnobName)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Scenario
import Kenshou.Suite.Kiroku.Correctness.Append (recordCells)
import Kenshou.Suite.Kiroku.Fixture.Store (withKirokuStore)
import Kenshou.Suite.Kiroku.Knobs (storeKnobs)
import Kiroku.Store hiding (id, withKirokuStore)
import System.Timeout (timeout)

scenarios :: [Scenario]
scenarios = [partitionCoverage]

partitionCoverage :: Scenario
partitionCoverage =
  Scenario
    { id = either (error . show) id (parseScenarioId "kiroku/consumer-group/correctness/partition-coverage"),
      revision = 1,
      summary = "Checks complete, disjoint partitioned delivery and durable member checkpoints.",
      tier = TierStandard,
      placement = PlaceEither,
      knobs = storeKnobs <> [sizeKnob, targetKnob],
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
      run = runCoverage
    }
  where
    sizeKnob = KnobSpec (name "kiroku.consumer-group.size") "Consumer-group members" KnobInt (VInt 4) (OneOf (VInt 1 :| fmap VInt [2, 3, 4, 8])) (fmap VInt [1, 2, 3, 4, 8])
    targetKnob = KnobSpec (name "kiroku.subscription.target") "Subscription target" KnobText (VText "all") (OneOf (VText "all" :| [VText "category"])) [VText "all", VText "category"]
    name = either (error . show) id . mkKnobName

runCoverage :: RunContext -> IO ScenarioReport
runCoverage context = withKirokuStore context \store -> do
  let name = either (error . show) id . mkKnobName
      size = fromIntegral (knobInt context.knobs (name "kiroku.consumer-group.size")) :: Int32
      target = if knobText context.knobs (name "kiroku.subscription.target") == "category" then Category (CategoryName "cg") else AllStreams
      subscriptionName = SubscriptionName "cg-coverage"
      event = EventData Nothing (EventType "Grouped") (object []) Nothing Nothing Nothing
      streamName i = StreamName ("cg-" <> Text.pack (show i))
      config member ref =
        (defaultSubscriptionConfig subscriptionName target (\row -> modifyIORef' ref (row :) >> pure Continue))
          { consumerGroup = Just (ConsumerGroup member size)
          }
      withMembers [] action = action
      withMembers ((member, ref) : rest) action = withSubscription store (config member ref) \_ -> withMembers rest action
      awaitDelivered refs = timeout 30000000 (loop refs)
      loop refs = do
        counts <- traverse (fmap length . readIORef . snd) refs
        if sum counts >= 10000 then pure counts else threadDelay 10000 >> loop refs
  forM_ [0 .. 499 :: Int] \i -> do
    result <- runStoreIO store (appendToStream (streamName i) NoStream (replicate 20 event))
    case result of
      Right appended | appended.streamVersion == StreamVersion 20 -> pure ()
      other -> fail ("consumer-group seed append failed: " <> show other)
  refs <- forM [0 .. size - 1] \member -> (member,) <$> newIORef []
  counts <- withMembers refs (awaitDelivered refs)
  observed <- forM refs \(member, ref) -> (member,) . reverse <$> readIORef ref
  slotsResult <- runStoreIO store (runTransaction (Tx.statement size partitionSlotsStatement))
  inventory <- runStoreIO store subscriptionCheckpointInventory
  let rows = concatMap snd observed
      positions = fmap (.globalPosition) rows
      slots = either (const Map.empty) Map.fromList slotsResult
      assigned = and [Map.lookup (case row.originalStreamId of StreamId value -> value) slots == Just member | (member, memberRows) <- observed, row <- memberRows]
      perStream =
        foldl'
          (\collected row -> Map.insertWith (flip (<>)) row.originalStreamId [row.originalVersion] collected)
          Map.empty
          rows
      checkpoints = case inventory of
        Right snapshot -> [row.consumerGroupMember | row <- Vector.toList snapshot.checkpoints, row.subscriptionName == subscriptionName]
        Left _ -> []
      invalid group = try @InvalidConsumerGroup (withSubscription store ((defaultSubscriptionConfig (SubscriptionName "cg-invalid") AllStreams (\_ -> pure Continue)) {consumerGroup = Just group}) (\_ -> pure ()))
  invalidZero <- invalid (ConsumerGroup 0 0)
  invalidHigh <- invalid (ConsumerGroup size size)
  invalidNegative <- invalid (ConsumerGroup (-1) size)
  let cells =
        [ ("all-members-complete", case counts of Just values -> sum values == 10000; _ -> False),
          ("union-covers-global-events", sort positions == [GlobalPosition value | value <- [1 .. 10000]]),
          ("member-positions-increase", all (\(_, memberRows) -> let ps = fmap (.globalPosition) memberRows in ps == sort ps) observed),
          ("partition-slot-agreement", Map.size slots == 500 && assigned),
          ("per-stream-local-order", Map.size perStream == 500 && all (\versions -> versions == [StreamVersion value | value <- [1 .. 20]]) (Map.elems perStream)),
          ("checkpoint-row-per-member", sort checkpoints == [0 .. size - 1]),
          ("invalid-size-rejected", case invalidZero of Left _ -> True; _ -> False),
          ("invalid-upper-member-rejected", case invalidHigh of Left _ -> True; _ -> False),
          ("invalid-negative-member-rejected", case invalidNegative of Left _ -> True; _ -> False)
        ]
  recordCells context "partition-coverage" [] cells

partitionSlotsStatement :: Statement.Statement Int32 [(Int64, Int32)]
partitionSlotsStatement =
  Statement.preparable
    "select stream_id, (((hashtextextended(stream_id::text, 0) % $1) + $1) % $1)::int from kiroku.streams where stream_id <> 0 order by stream_id"
    (Encoders.param (Encoders.nonNullable Encoders.int4))
    (Decoders.rowList ((,) <$> Decoders.column (Decoders.nonNullable Decoders.int8) <*> Decoders.column (Decoders.nonNullable Decoders.int4)))
