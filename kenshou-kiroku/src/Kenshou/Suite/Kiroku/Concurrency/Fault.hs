module Kenshou.Suite.Kiroku.Concurrency.Fault (scenarios) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Concurrent.STM (atomically)
import Control.Exception (SomeException, try)
import Data.Aeson (object, withObject, (.:), (.=))
import Data.Aeson.Types (parseMaybe)
import Data.Int (Int64)
import Data.List (sort)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time.Clock (diffUTCTime, getCurrentTime)
import Data.Vector qualified as Vector
import Kenshou.Check.Process (ProgressSnapshot (..), awaitReady, progress, roleProcess, sendCommand, spawn, withSupervisor)
import Kenshou.Check.Scenario (withCheck)
import Kenshou.Core.Context (Environment (..), RunContext (..), SummarySection (..), putSummary)
import Kenshou.Core.Dimension
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Env.Postgres (PostgresEnv (..), ServerControl (..), StopMode (..))
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Role (ControlMessage (..))
import Kenshou.Core.Scenario
import Kenshou.Suite.Kiroku.Correctness.Append (recordCells)
import Kenshou.Suite.Kiroku.Fixture.Oracle qualified as Oracle
import Kenshou.Suite.Kiroku.Fixture.Store (withKirokuStore)
import Kenshou.Suite.Kiroku.Fixture.Workload (eventIdFor)
import Kenshou.Suite.Kiroku.Knobs (storeKnobs)
import Kiroku.Store hiding (id, withKirokuStore)
import System.Timeout (timeout)

scenarios :: [Scenario]
scenarios = [postgresRestart]

postgresRestart :: Scenario
postgresRestart =
  Scenario
    { id = either (error . show) id (parseScenarioId "kiroku/subscription/concurrency/postgres-restart"),
      revision = 1,
      summary = "Restarts an ephemeral PostgreSQL server during appends and subscription delivery.",
      tier = TierStandard,
      placement = PlaceLocal,
      knobs = storeKnobs,
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
      run = runRestart
    }

runRestart :: RunContext -> IO ScenarioReport
runRestart context = case context.env.postgres >>= (.control) of
  Nothing -> pure (failedWith ["no-postgres-control"] "postgres-restart requires an ephemeral local PostgreSQL server")
  Just control -> withKirokuStore context \store -> withCheck context \check -> withSupervisor check \supervisor -> do
    let batches = 100
        batchSize = 10
        eventIds index = [eventIdFor context.seed index (fromIntegral ordinal) | ordinal <- [0 .. batchSize - 1]]
        appendBatch index = do
          let stream = StreamName ("restart-" <> Text.pack (show index))
              events = [EventData (Just eventId) (EventType "Restart") (object []) Nothing Nothing Nothing | eventId <- eventIds index]
              attempt n errors
                | n >= (500 :: Int) = pure (False, reverse errors)
                | otherwise = do
                    response <- try @SomeException (runStoreIO store (appendToStream stream NoStream events))
                    case response of
                      Right (Right _) -> pure (True, reverse errors)
                      Right (Left err) -> retry n errors (Text.pack (show err))
                      Left err -> retry n errors (Text.pack (show err))
              retry n errors reason = do
                observed <- try @SomeException (runStoreIO store (readStreamForward stream (StreamVersion 0) (fromIntegral (batchSize + 1))))
                let exact = case observed of Right (Right rows) -> fmap (.eventId) (Vector.toList rows) == eventIds index; _ -> False
                if exact then pure (True, reverse (reason : errors)) else threadDelay 10000 >> attempt (n + 1) (reason : errors)
          result <- attempt 0 []
          threadDelay 5000
          pure result
        deliveries child = do
          state <- atomically (progress child)
          let records = [record | (key, payload) <- Map.toList state.marks, "delivery-" `Text.isPrefixOf` key, Just record <- [parseMaybe (withObject "delivery" (\row -> (,) <$> row .: "sequence" <*> row .: "position")) payload :: Maybe (Int, Int64)]]
          pure [position | (_, position) <- sort records]
        awaitCoverage child = do
          observed <- deliveries child
          if Set.size (Set.fromList observed) >= batches * batchSize then pure observed else threadDelay 10000 >> awaitCoverage child
        awaitNextDelivery child previous = do
          observed <- deliveries child
          if length observed > previous then pure () else threadDelay 10000 >> awaitNextDelivery child previous
    spec <- roleProcess check "kiroku/subscriber" 0 (object ["name" .= ("postgres-restart" :: Text), "guard" .= False, "emitDeliveries" .= True])
    child <- spawn supervisor spec
    awaitReady child 10000
    sendCommand child CtlStart
    initialCheckpoints <- Oracle.checkpoints store.pool
    results <- newEmptyMVar
    _ <- forkIO (traverse appendBatch [0 .. batches - 1] >>= putMVar results)
    threadDelay 150000
    control.restartServer
    afterFast <- getCurrentTime
    threadDelay 150000
    beforeImmediateCheckpoints <- Oracle.checkpoints store.pool
    beforeImmediate <- length <$> deliveries child
    control.stopServer StopImmediate
    control.startServer
    afterImmediate <- getCurrentTime
    firstDelivery <- timeout 90000000 (awaitNextDelivery child beforeImmediate)
    firstDeliveryAt <- getCurrentTime
    firstDeliveryCheckpoints <- Oracle.checkpoints store.pool
    appendResults <- takeMVar results
    delivered <- timeout 180000000 (awaitCoverage child)
    recoveredAt <- getCurrentTime
    durable <- runStoreIO store (readAllForward (GlobalPosition 0) (fromIntegral (batches * batchSize + 1)))
    checkpoints <- Oracle.checkpoints store.pool
    counts <- Oracle.threeCounts store.pool
    let expectedIds = Set.fromList [uuid | index <- [0 .. batches - 1], EventId uuid <- eventIds index]
        actualIds = case durable of Right rows -> Set.fromList [uuid | row <- Vector.toList rows, let EventId uuid = row.eventId]; Left _ -> Set.empty
        positions = maybe [] id delivered
        checkpointOf rows = maximum (0 : [position | (name, member, position) <- rows, name == "postgres-restart", member == 0])
        checkpointSamples = map checkpointOf [initialCheckpoints, beforeImmediateCheckpoints, firstDeliveryCheckpoints, checkpoints]
        finalCheckpoint = last checkpointSamples
        duplicates = length positions - Set.size (Set.fromList positions)
        errors = concatMap snd appendResults
        errorConstructors = Map.toList (Map.fromListWith (+) [(Text.takeWhile (/= ' ') err, 1 :: Int) | err <- errors])
        cells =
          [ ("append-retries-converged", all fst appendResults),
            ("acknowledged-identifiers-durable", actualIds == expectedIds),
            ("subscriber-covers-all", Set.fromList positions == Set.fromList [1 .. fromIntegral (batches * batchSize)]),
            ("subscriber-order", positions == sort positions),
            ("checkpoint-reaches-head", finalCheckpoint == fromIntegral (batches * batchSize)),
            ("checkpoint-samples-monotonic", checkpointSamples == sort checkpointSamples),
            ("duplicates-within-restart-budgets", duplicates <= 2000),
            ("durable-counts-agree", counts == (fromIntegral (batches * batchSize), fromIntegral (batches * batchSize), fromIntegral (batches * batchSize))),
            ("first-delivery-within-ninety-seconds", firstDelivery == Just () && diffUTCTime firstDeliveryAt afterImmediate <= 90)
          ]
    putSummary context Measurements "postgres-restart" (object ["batches" .= batches, "events" .= (batches * batchSize), "retryErrors" .= errors, "errorConstructors" .= errorConstructors, "delivered" .= length positions, "duplicates" .= duplicates, "checkpointSamples" .= checkpointSamples, "afterFast" .= afterFast, "afterImmediate" .= afterImmediate, "firstDeliveryAt" .= firstDeliveryAt, "recoveredAt" .= recoveredAt])
    recordCells context "postgres-restart" [] cells
