module Kenshou.Suite.Kiroku.Correctness.DeadLetter (scenarios) where

import Control.Concurrent (threadDelay)
import Data.Aeson (object)
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Int (Int32, Int64)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Vector qualified as Vector
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Statement qualified as Statement
import Hasql.Transaction qualified as Tx
import Kenshou.Core.Context (RunContext (..))
import Kenshou.Core.Dimension
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Knob (Allowed (..), KnobSpec (..), KnobType (..), KnobValue (..), knobInt, mkKnobName)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Scenario
import Kenshou.Suite.Kiroku.Correctness.Append (recordCells)
import Kenshou.Suite.Kiroku.Fixture.Oracle qualified as Oracle
import Kenshou.Suite.Kiroku.Fixture.Store (withKirokuStore)
import Kenshou.Suite.Kiroku.Knobs (storeKnobs)
import Kiroku.Store hiding (id, withKirokuStore)
import System.Timeout (timeout)

scenarios :: [Scenario]
scenarios = [retryAndDeadLetter]

retryAndDeadLetter :: Scenario
retryAndDeadLetter =
  Scenario
    { id = either (error . show) id (parseScenarioId "kiroku/dead-letter/correctness/retry-and-dead-letter"),
      revision = 1,
      summary = "Checks bounded retries, explicit dead letters and checkpoint progress.",
      tier = TierSmoke,
      placement = PlaceEither,
      knobs = storeKnobs <> [KnobSpec (either (error . show) id (mkKnobName "kiroku.subscription.retry-max-attempts")) "Maximum retry deliveries" KnobInt (VInt 3) (IntRange 1 10) [VInt 1, VInt 3]],
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
      run = runDeadLetters
    }

runDeadLetters :: RunContext -> IO ScenarioReport
runDeadLetters context = withKirokuStore context \store -> do
  let stream = StreamName "dead-letter-events"
      name = SubscriptionName "dead-letter-subscription"
      maxAttempts = fromIntegral (knobInt context.knobs (either (error . show) id (mkKnobName "kiroku.subscription.retry-max-attempts")))
      event = EventData Nothing (EventType "DeadLetter") (object []) Nothing Nothing Nothing
      handler ref row = do
        modifyIORef' ref (row.globalPosition :)
        pure $ case row.globalPosition of
          GlobalPosition 10 -> Retry (RetryDelay 0.01)
          GlobalPosition 20 -> DeadLetter (DeadLetterPoison "seeded-poison")
          _ -> Continue
      awaitHead = timeout 10000000 loop
      loop = do
        inventory <- runStoreIO store subscriptionCheckpointInventory
        case inventory of
          Right snapshot
            | [row.checkpointPosition | row <- Vector.toList snapshot.checkpoints, row.subscriptionName == name] == [GlobalPosition 100] -> pure True
          _ -> threadDelay 10000 >> loop
  appended <- runStoreIO store (appendToStream stream NoStream (replicate 100 event))
  deliveredRef <- newIORef []
  caughtUp <- withSubscription store ((defaultSubscriptionConfig name AllStreams (handler deliveredRef)) {retryPolicy = RetryPolicy maxAttempts}) \_ -> awaitHead
  delivered <- reverse <$> readIORef deliveredRef
  letters <- runStoreIO store (runTransaction (Tx.statement () deadLettersStatement))
  oracleLetters <- Oracle.deadLetters store.pool "dead-letter-subscription"
  inventory <- runStoreIO store subscriptionCheckpointInventory
  let expectedDeliveries = [GlobalPosition value | value <- [1 .. 100], value /= 10, value /= 20]
      ordinary = filter (`notElem` [GlobalPosition 10, GlobalPosition 20]) delivered
      cells =
        [ ("append-100-events", case appended of Right result -> result.globalPosition == GlobalPosition 100; _ -> False),
          ("checkpoint-reaches-head", caughtUp == Just True),
          ("ordinary-events-delivered-once", ordinary == expectedDeliveries),
          ("retry-delivery-count", length (filter (== GlobalPosition 10) delivered) == maxAttempts),
          ("explicit-poison-delivered-once", length (filter (== GlobalPosition 20) delivered) == 1),
          ("dead-letter-rows-exact", letters == Right [(10, fromIntegral maxAttempts, "max_attempts_exceeded"), (20, 1, "poison")]),
          ("oracle-dead-letters", fmap (\row -> (row.position, row.attempts)) oracleLetters == [(10, fromIntegral maxAttempts), (20, 1)]),
          ( "checkpoint-durable-at-head",
            case inventory of
              Right snapshot -> [row.checkpointPosition | row <- Vector.toList snapshot.checkpoints, row.subscriptionName == name] == [GlobalPosition 100]
              _ -> False
          )
        ]
  recordCells context "retry-and-dead-letter" [] cells

deadLettersStatement :: Statement.Statement () [(Int64, Int32, Text)]
deadLettersStatement =
  Statement.preparable
    "select global_position, attempt_count, reason->>'kind' from kiroku.dead_letters where subscription_name = 'dead-letter-subscription' and consumer_group_member = 0 order by global_position"
    Encoders.noParams
    (Decoders.rowList ((,,) <$> Decoders.column (Decoders.nonNullable Decoders.int8) <*> Decoders.column (Decoders.nonNullable Decoders.int4) <*> Decoders.column (Decoders.nonNullable Decoders.text)))
