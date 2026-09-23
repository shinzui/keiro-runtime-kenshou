module Kenshou.Suite.Kiroku.Concurrency.ConsumerGroup (scenarios) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.STM (atomically)
import Control.Monad (forM, forM_)
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
import Kenshou.Check.Process (ProgressSnapshot (..), awaitReady, killChild, progress, restartChild, roleProcess, sendCommand, spawn, withSupervisor)
import Kenshou.Check.Scenario (withCheck)
import Kenshou.Core.Context (RunContext (..), SummarySection (..), putSummary)
import Kenshou.Core.Dimension
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Knob (Allowed (..), KnobSpec (..), KnobType (..), KnobValue (..), knobBool, knobInt, mkKnobName)
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
scenarios = [duplicateMemberClaim, multiProcessMembers]

multiProcessMembers :: Scenario
multiProcessMembers =
  duplicateMemberClaim
    { id = either (error . show) id (parseScenarioId "kiroku/consumer-group/concurrency/multi-process-members"),
      summary = "Kills and restarts process members while checking partition coverage and checkpoint progress.",
      knobs = storeKnobs <> [intKnob "kiroku.consumer-group.size" 4 2 8, intKnob "crash.kills" 8 1 32],
      run = runMultiProcessMembers
    }
  where
    intKnob key value lower upper = KnobSpec (either (error . show) id (mkKnobName key)) key KnobInt (VInt value) (IntRange lower upper) []

runMultiProcessMembers :: RunContext -> IO ScenarioReport
runMultiProcessMembers context = withKirokuStore context \store -> withCheck context \check -> withSupervisor check \supervisor -> do
  let knob key = fromIntegral (knobInt context.knobs (either (error . show) id (mkKnobName key))) :: Int
      size = knob "kiroku.consumer-group.size"
      kills = knob "crash.kills"
      args member = object ["name" .= ("multi-process-members" :: Text), "member" .= member, "size" .= size, "guard" .= False, "emitDeliveries" .= True]
      event = EventData Nothing (EventType "MemberCrash") (object []) Nothing Nothing Nothing
      stream index = StreamName ("member-" <> Text.pack (show index))
      checkpointSample = do
        rows <- Oracle.checkpoints store.pool
        pure (Map.fromList [(member, position) | (checkpointName, member, position) <- rows, checkpointName == "multi-process-members"])
      deliveries child = do
        state <- atomically (progress child)
        let records = [record | (key, payload) <- Map.toList state.marks, "delivery-" `Text.isPrefixOf` key, Just record <- [parseMaybe (withObject "delivery" (\value -> (,) <$> value .: "sequence" <*> value .: "position")) payload :: Maybe (Int, Int64)]]
        pure [position | (_, position) <- sort records]
      collect active archived = do
        current <- forM (Map.toList active) \(member, child) -> (member,) <$> deliveries child
        let observations = archived <> current
            covered = Set.unions [Set.fromList positions | (_, positions) <- observations]
        if Set.size covered >= 200 + 100 * kills then pure observations else threadDelay 10000 >> collect active archived
  forM_ [0 .. 99 :: Int] \index -> do
    result <- runStoreIO store (appendToStream (stream index) NoStream [event, event])
    case result of Right _ -> pure (); Left err -> fail ("member seed failed: " <> show err)
  originalChildren <- forM [0 .. size - 1] \member -> do
    spec <- roleProcess check "kiroku/subscriber" member (args member)
    child <- spawn supervisor spec
    awaitReady child 10000
    sendCommand child CtlStart
    pure (member, child)
  initial <- checkpointSample
  let runRounds active archived samples crashMembers index
        | index >= kills = pure (active, archived, reverse samples, reverse crashMembers)
        | otherwise = do
            forM_ [0 .. 99 :: Int] \streamIndex -> do
              result <- runStoreIO store (appendToStream (stream streamIndex) AnyVersion [event])
              case result of Right _ -> pure (); Left err -> fail ("member append failed: " <> show err)
            let member = (index * 3) `mod` size
                child = active Map.! member
            killChild supervisor child
            threadDelay 10000
            delivered <- deliveries child
            replacement <- restartChild supervisor child
            awaitReady replacement 10000
            sendCommand replacement CtlStart
            sample <- checkpointSample
            runRounds (Map.insert member replacement active) (archived <> [(member, delivered)]) (sample : samples) (member : crashMembers) (index + 1)
  (active, archived, samples, crashMembers) <- runRounds (Map.fromList originalChildren) [] [initial] [] 0
  final <- timeout 30000000 (collect active archived)
  finalSample <- checkpointSample
  slots <- Oracle.partitionSlots store.pool (fromIntegral size)
  durable <- runStoreIO store (readAllForward (GlobalPosition 0) (fromIntegral (201 + 100 * kills)))
  let observations = maybe archived id final
      finalRows = either (const []) Vector.toList durable
      expected = 200 + 100 * kills
      positions = Set.fromList [position | row <- finalRows, let GlobalPosition position = row.globalPosition]
      covered = Set.unions [Set.fromList values | (_, values) <- observations]
      streamByPosition = Map.fromList [(position, case row.originalStreamId of StreamId streamId -> streamId) | row <- finalRows, let GlobalPosition position = row.globalPosition]
      assigned = and [Map.lookup (streamByPosition Map.! position) slots == Just (fromIntegral member) | (member, values) <- observations, position <- values, Map.member position streamByPosition]
      ordered values = values == sort values
      checkpointHistory member = [Map.findWithDefault 0 (fromIntegral member) sample | sample <- samples <> [finalSample]]
      memberPositions member = concat [values | (which, values) <- observations, which == member]
      duplicateBound member = let values = memberPositions member in length values - Set.size (Set.fromList values) <= 100 * length (filter (== member) crashMembers)
      cells =
        [ ("all-positions-covered", final /= Nothing && positions == Set.fromList [1 .. fromIntegral expected] && covered == positions),
          ("partition-slot-agreement", Map.size slots == 100 && assigned),
          ("incarnation-local-order", all (ordered . snd) observations),
          ("checkpoints-monotonic", all (ordered . checkpointHistory) [0 .. size - 1]),
          ("duplicate-budget-per-member", all duplicateBound [0 .. size - 1])
        ]
  putSummary context Measurements "multi-process-members" (object ["members" .= size, "kills" .= kills, "crashMembers" .= crashMembers, "durableEvents" .= length finalRows, "coveredPositions" .= Set.size covered, "deliveries" .= sum (fmap (length . snd) observations), "checkpointSamples" .= (samples <> [finalSample])])
  recordCells context "multi-process-members" ["duplicate-budget-per-member"] cells

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
