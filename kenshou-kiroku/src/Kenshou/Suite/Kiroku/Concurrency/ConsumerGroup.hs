module Kenshou.Suite.Kiroku.Concurrency.ConsumerGroup (scenarios) where

import Control.Concurrent (threadDelay)
import Control.Monad (forM_)
import Data.Aeson (object, withObject, (.:), (.=))
import Data.Aeson.Types (parseMaybe)
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Int (Int64)
import Data.List (sort)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Vector qualified as Vector
import Kenshou.Core.Context (RunContext (..), SummarySection (..), putSummary)
import Kenshou.Core.Dimension
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Knob (Allowed (..), KnobSpec (..), KnobType (..), KnobValue (..), knobBool, mkKnobName)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Role (ControlMessage (..), WorkerMessage (..))
import Kenshou.Core.Role.Spawn (WorkerHandle (..), withWorker)
import Kenshou.Core.Scenario
import Kenshou.Suite.Kiroku.Correctness.Append (recordCells)
import Kenshou.Suite.Kiroku.Fixture.Oracle qualified as Oracle
import Kenshou.Suite.Kiroku.Fixture.Store (withKirokuStore)
import Kenshou.Suite.Kiroku.Knobs (storeKnobs)
import Kenshou.Suite.Kiroku.Roles (subscriberRoleName)
import Kiroku.Store hiding (id, withKirokuStore)
import System.Timeout (timeout)

scenarios :: [Scenario]
scenarios = [duplicateMemberClaim]

duplicateMemberClaim :: Scenario
duplicateMemberClaim =
  Scenario
    { id = either (error . show) id (parseScenarioId "kiroku/consumer-group/concurrency/duplicate-member-claim"),
      revision = 1,
      summary = "Measures simultaneous ownership of one consumer-group member and checks complete delivery.",
      tier = TierStandard,
      placement = PlaceEither,
      knobs = storeKnobs <> [KnobSpec (name "kiroku.consumer-group.guard") "Enable the consumer-group startup guard" KnobBool (VBool False) AnyValue [VBool False, VBool True]],
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
      run = runDuplicateMember
    }
  where
    name = either (error . show) id . mkKnobName

runDuplicateMember :: RunContext -> IO ScenarioReport
runDuplicateMember context = withKirokuStore context \store -> do
  let guardEnabled = knobBool context.knobs (either (error . show) id (mkKnobName "kiroku.consumer-group.guard"))
      args member = object ["name" .= ("duplicate-member" :: Text), "member" .= (member :: Int), "size" .= (2 :: Int), "guard" .= guardEnabled]
      snapshot worker = do
        _ <- worker.send (CtlCustom "snapshot" (object []))
        response <- worker.receive 10000
        pure case response of
          Just (WrkCustom "snapshot" payload) -> parseMaybe (withObject "snapshot" (.: "positions")) payload :: Maybe [Int64]
          _ -> Nothing
      collect workers = do
        values <- traverse snapshot workers
        let combined = Set.unions [Set.fromList positions | Just positions <- values]
        if Set.size combined >= 200 then pure values else threadDelay 10000 >> collect workers
      seedEvent = EventData Nothing (EventType "DuplicateMember") (object []) Nothing Nothing Nothing
      sampleCheckpoints = do
        rows <- Oracle.checkpoints store.pool
        pure (Map.fromList [(member, position) | (checkpointName, member, position) <- rows, checkpointName == "duplicate-member"])
  withWorker context subscriberRoleName "claim-member-0-first" (args 0) \first -> do
    readyFirst <- first.receive 10000
    first.send CtlStart
    withWorker context subscriberRoleName "claim-member-1" (args 1) \other -> do
      readyOther <- other.receive 10000
      other.send CtlStart
      threadDelay 2000000
      withWorker context subscriberRoleName "claim-member-0-second" (args 0) \second -> do
        readySecond <- second.receive 10000
        second.send CtlStart
        samples <- newIORef []
        sampleCheckpoints >>= modifyIORef' samples . (:)
        forM_ [0 .. 99 :: Int] \index -> do
          result <- runStoreIO store (appendToStream (StreamName ("claim-" <> Text.pack (show index))) NoStream [seedEvent, seedEvent])
          case result of
            Right _ -> pure ()
            Left err -> fail ("duplicate-member seed append failed: " <> show err)
          if index `mod` 10 == 9 then sampleCheckpoints >>= modifyIORef' samples . (:) else pure ()
        observed <- timeout 30000000 (collect [first, second, other])
        checkpoints <- Oracle.checkpoints store.pool
        checkpointSamples <- reverse <$> readIORef samples
        durable <- runStoreIO store (readAllForward (GlobalPosition 0) 201)
        let positions = case observed of Just [Just a, Just b, Just c] -> Just (a, b, c); _ -> Nothing
            allObserved = case positions of Just (a, b, c) -> a <> b <> c; _ -> []
            union = Set.fromList allObserved
            expected = Set.fromList [1 .. 200 :: Int64]
            ordered values = values == sort values
            overlap = case positions of Just (a, b, _) -> Set.size (Set.intersection (Set.fromList a) (Set.fromList b)); _ -> 0
            finalRows = either (const []) Vector.toList durable
            durablePositions = Set.fromList [position | row <- finalRows, let GlobalPosition position = row.globalPosition]
            checkpointRows = [(member, position) | (checkpointName, member, position) <- checkpoints, checkpointName == "duplicate-member"]
            checkpointHistory member = [Map.findWithDefault 0 member sample | sample <- checkpointSamples]
            monotonic values = values == sort values
            cells =
              [ ("members-ready", all (== Just WrkReady) [readyFirst, readyOther, readySecond]),
                ("all-positions-delivered", union == expected && durablePositions == expected),
                ("member-local-order", case positions of Just (a, b, c) -> all ordered [a, b, c]; _ -> False),
                ("checkpoint-rows-present", Map.keysSet (Map.fromList checkpointRows) == Set.fromList [0, 1]),
                ("checkpoints-monotonic", length checkpointSamples >= 11 && all (monotonic . checkpointHistory) [0, 1]),
                ("checkpoint-within-durable-head", all (\(_, position) -> position >= 0 && position <= 200) checkpointRows)
              ]
        putSummary context Measurements "duplicate-member-claim" (object ["guard" .= guardEnabled, "overlapPositions" .= overlap, "deliveries" .= length allObserved, "distinctPositions" .= Set.size union, "checkpoints" .= checkpointRows, "checkpointSamples" .= checkpointSamples])
        recordCells context "duplicate-member-claim" [] cells
