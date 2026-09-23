module Kenshou.Suite.Kiroku.Concurrency.Append (scenarios) where

import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, readMVar, takeMVar)
import Control.Exception (SomeException, try)
import Control.Monad (forM, forM_, (<=<))
import Data.Aeson (Value, object, withObject, (.:), (.=))
import Data.Aeson.Types (Parser, parseMaybe)
import Data.List (find, permutations)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Maybe (isJust)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time.Clock (addUTCTime, getCurrentTime)
import Data.UUID qualified as UUID
import Data.Vector qualified as Vector
import Data.Word (Word64)
import GHC.Clock (getMonotonicTimeNSec)
import Kenshou.Core.Context (RunContext (..), SummarySection (..), putSummary)
import Kenshou.Core.Dimension
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Knob (Allowed (..), KnobSpec (..), KnobType (..), KnobValue (..), knobInt, mkKnobName)
import Kenshou.Core.Phase (PhasePlan (..))
import Kenshou.Core.Role (ControlMessage (..), WorkerMessage (..))
import Kenshou.Core.Role.Spawn (WorkerHandle (..), withWorker)
import Kenshou.Core.Scenario
import Kenshou.Suite.Kiroku.Correctness.Append (recordCells)
import Kenshou.Suite.Kiroku.Fixture.Model qualified as Model
import Kenshou.Suite.Kiroku.Fixture.Oracle qualified as Oracle
import Kenshou.Suite.Kiroku.Fixture.Store (withKirokuStore)
import Kenshou.Suite.Kiroku.Fixture.Workload (eventIdFor)
import Kenshou.Suite.Kiroku.Knobs (storeKnobs)
import Kenshou.Suite.Kiroku.Roles (appenderRoleName)
import Kiroku.Store hiding (id, withKirokuStore)

scenarios :: [Scenario]
scenarios = [expectedVersionRace, idempotentDuplicates, modelBasedOcc]

modelBasedOcc :: Scenario
modelBasedOcc =
  expectedVersionRace
    { id = either (error . show) id (parseScenarioId "kiroku/append/concurrency/model-based-occ"),
      summary = "Checks concurrent append, read, and lifecycle calls against a pure stream model.",
      knobs = storeKnobs <> [intKnob "model.cases" 200 1 1000, intKnob "model.branches" 3 2 3],
      phases = PhasePlan 0 0 0,
      run = runModelCases
    }

data Observed = Observed
  { command :: Model.Cmd,
    outcome :: Maybe Model.Outcome,
    started :: Word64,
    ended :: Word64
  }

runModelCases :: RunContext -> IO ScenarioReport
runModelCases context = withKirokuStore context \store -> do
  let knob key = fromIntegral (knobInt context.knobs (either (error . show) id (mkKnobName key))) :: Int
      cases = knob "model.cases"
      branches = knob "model.branches"
  results <- forM [0 .. cases - 1] \caseIndex -> do
    let name = "model-" <> Text.pack (show caseIndex)
        uuid ordinal = let EventId value = eventIdFor context.seed caseIndex ordinal in value
        first = uuid 1
        commands = take branches $ case caseIndex `mod` 4 of
          0 -> [Model.CmdAppend name (ExactVersion (StreamVersion 1)) [uuid 2], Model.CmdAppend name (ExactVersion (StreamVersion 1)) [uuid 3], Model.CmdAppend name (ExactVersion (StreamVersion 1)) [uuid 4]]
          1 -> [Model.CmdSoftDelete name, Model.CmdAppend name (ExactVersion (StreamVersion 1)) [uuid 2], Model.CmdReadForward name 0 5]
          2 -> [Model.CmdUndelete name, Model.CmdAppend name StreamExists [uuid 2], Model.CmdGetStream name]
          _ -> [Model.CmdReadForward name 0 5, Model.CmdAppend name AnyVersion [uuid 2], Model.CmdGetStream name]
        initial = Model.Model Map.empty
        (modelAfterSeed, expectedSeed) = Model.stepModel initial (Model.CmdAppend name NoStream [first])
    seeded <- executeModelCommand store (Model.CmdAppend name NoStream [first])
    gate <- newEmptyMVar
    slots <- forM commands \command -> do
      slot <- newEmptyMVar
      _ <- forkIO do
        readMVar gate
        started <- getMonotonicTimeNSec
        attempted <- try @SomeException (executeModelCommand store command)
        ended <- getMonotonicTimeNSec
        putMVar slot (Observed command (either (const Nothing) id attempted) started ended)
      pure slot
    putMVar gate ()
    observations <- traverse takeMVar slots
    let allowed ordering =
          all (\(leftIndex, left) -> all (\(rightIndex, right) -> left.ended >= right.started || leftIndex < rightIndex) (zip [0 :: Int ..] ordering)) (zip [0 :: Int ..] ordering)
        explains ordering = snd (foldl step (modelAfterSeed, True) ordering)
          where
            step (model, valid) observation =
              let (next, predicted) = Model.stepModel model observation.command
               in (next, valid && observation.outcome == Just predicted)
        linearizable = any (\ordering -> allowed ordering && explains ordering) (permutations observations)
    pure (seeded == Just expectedSeed, linearizable, observations)
  let failedCases = [index | (index, (seeded, valid, _)) <- zip [0 :: Int ..] results, not (seeded && valid)]
      firstFailure = do
        index <- find (`elem` failedCases) [0 .. cases - 1]
        let (_, _, rows) = results !! index
        pure (object ["case" .= index, "commands" .= fmap (show . (.command)) rows, "observed" .= fmap (show . (.outcome)) rows])
      observedConflicts = length [() | (_, _, rows) <- results, row <- rows, row.outcome == Just (Model.Rejected Model.WrongVersion)]
      cells =
        [ ("all-prefixes-created", all (\(seeded, _, _) -> seeded) results),
          ("all-cases-linearizable", null failedCases),
          ("version-conflicts-observed", observedConflicts > 0)
        ]
  putSummary context Measurements "model-based-occ" (object ["seed" .= context.seed, "cases" .= cases, "branches" .= branches, "failedCases" .= take 20 failedCases, "firstFailure" .= firstFailure, "versionConflicts" .= observedConflicts])
  recordCells context "model-based-occ" [] cells

executeModelCommand :: KirokuStore -> Model.Cmd -> IO (Maybe Model.Outcome)
executeModelCommand store = \case
  Model.CmdAppend name expected identifiers -> do
    let events = [EventData (Just (EventId uuid)) (EventType "Model") (object []) Nothing Nothing Nothing | uuid <- identifiers]
    result <- runStoreIO store (appendToStream (StreamName name) expected events)
    pure case result of
      Right value -> Just (Model.Appended (fromIntegral (case value.streamVersion of StreamVersion version -> version)))
      Left (WrongExpectedVersion _ _ _) -> Just (Model.Rejected Model.WrongVersion)
      Left (StreamAlreadyExists _) -> Just (Model.Rejected Model.AlreadyExists)
      Left (StreamNotFound _) -> Just (Model.Rejected Model.NotFound)
      Left (DuplicateEvent _) -> Just (Model.Rejected Model.DuplicateId)
      Left _ -> Nothing
  Model.CmdGetStream name -> do
    result <- runStoreIO store (getStream (StreamName name))
    pure case result of
      Right stream -> Just (Model.StreamIs ((\value -> (fromIntegral (case value.version of StreamVersion version -> version), isJust value.deletedAt)) <$> stream))
      Left _ -> Nothing
  Model.CmdSoftDelete name -> do
    result <- runStoreIO store (softDeleteStream (StreamName name))
    pure (Model.Done . isJust <$> either (const Nothing) Just result)
  Model.CmdUndelete name -> do
    result <- runStoreIO store (undeleteStream (StreamName name))
    pure (Model.Done . isJust <$> either (const Nothing) Just result)
  Model.CmdReadForward name cursor limit -> do
    result <- runStoreIO store (readStreamForward (StreamName name) (StreamVersion (fromIntegral cursor)) (fromIntegral limit))
    pure (Model.Events . fmap (\row -> case row.eventId of EventId uuid -> uuid) . Vector.toList <$> either (const Nothing) Just result)

idempotentDuplicates :: Scenario
idempotentDuplicates =
  expectedVersionRace
    { id = either (error . show) id (parseScenarioId "kiroku/append/concurrency/idempotent-duplicates"),
      summary = "Races identical caller-ID batches across child processes under AnyVersion and ExactVersion.",
      knobs = storeKnobs <> [intKnob "kiroku.append.processes" 4 2 8, intKnob "workload.batches" 500 2 10000, intKnob "kiroku.append.batch-size" 10 1 100],
      phases = PhasePlan 0 0 0,
      run = runDuplicates
    }

runDuplicates :: RunContext -> IO ScenarioReport
runDuplicates context = withKirokuStore context \store -> do
  let knob key = fromIntegral (knobInt context.knobs (either (error . show) id (mkKnobName key))) :: Int
      processes = knob "kiroku.append.processes"
      batches = knob "workload.batches"
      batchSize = knob "kiroku.append.batch-size"
      total = batches * batchSize
      stream = StreamName "duplicate-batches"
      callerIds = [eventIdFor context.seed 0 (fromIntegral ordinal) | ordinal <- [1 .. total]]
      render (EventId uuid) = UUID.toText uuid
      withWorkers count accumulated action
        | count <= 0 = action (reverse accumulated)
        | otherwise = withWorker context appenderRoleName ("duplicate-" <> Text.pack (show count)) (object []) (\worker -> withWorkers (count - 1) (worker : accumulated) action)
      parseResponse (Just (WrkCustom "duplicate" payload)) = parseMaybe (withObject "duplicate reply" \value -> (,) <$> value .: "status" <*> value .: "version" :: Parser (Text, Maybe Int)) payload
      parseResponse _ = Nothing
  withWorkers processes [] \workers -> do
    ready <- traverse (\worker -> worker.receive 10000) workers
    forM_ workers (\worker -> worker.send CtlStart)
    rounds <- forM [0 .. batches - 1] \batchIndex -> do
      let ids = take batchSize (drop (batchIndex * batchSize) callerIds)
          mode = if batchIndex < batches `div` 2 then "any" else "exact" :: Text
          request = object ["stream" .= ("duplicate-batches" :: Text), "eventIds" .= fmap render ids, "mode" .= mode, "version" .= (batchIndex * batchSize)]
      forM_ workers (\worker -> worker.send (CtlCustom "duplicate" request))
      replies <- traverse (\worker -> worker.receive 30000) workers
      let parsed = traverse parseResponse replies
          successes = maybe [] (filter ((== "success") . fst)) parsed
          losers = maybe [] (filter ((/= "success") . fst)) parsed
          allowed (status, _) = status == "duplicate" || (mode == "exact" && status == "version")
      pure (length successes == 1 && successes == [("success", Just ((batchIndex + 1) * batchSize))] && length losers == processes - 1 && all allowed losers, parsed)
    info <- runStoreIO store (getStream stream)
    readRows <- runStoreIO store (readStreamForward stream (StreamVersion 0) (fromIntegral total))
    counts <- Oracle.threeCounts store.pool
    let observed = case readRows of Right rows -> Vector.toList rows; _ -> []
        observedIds = fmap (.eventId) observed
        statuses = concat [fmap fst values | (_, Just values) <- rounds]
        duplicateCount = length (filter (== "duplicate") statuses)
        anyDuplicateCount = length [() | (_, Just values) <- take (batches `div` 2) rounds, (status, _) <- values, status == "duplicate"]
        versionCount = length (filter (== "version") statuses)
        cells =
          [ ("child-processes-ready", all (== Just WrkReady) ready),
            ("one-winner-per-batch", all fst rounds),
            ("every-caller-id-once", length observed == total && observedIds == callerIds && Set.size (Set.fromList observedIds) == total),
            ("durable-final-version", case info of Right (Just value) -> value.version == StreamVersion (fromIntegral total); _ -> False),
            ("global-count-agrees", counts == (fromIntegral total, fromIntegral total, fromIntegral total)),
            ("any-version-duplicates-observed", anyDuplicateCount > 0)
          ]
    putSummary context Measurements "idempotent-duplicates" (object ["batches" .= batches, "batchSize" .= batchSize, "processes" .= processes, "duplicateErrors" .= duplicateCount, "wrongVersionErrors" .= versionCount, "committedEvents" .= length observed])
    recordCells context "idempotent-duplicates" [] cells

expectedVersionRace :: Scenario
expectedVersionRace =
  Scenario
    { id = either (error . show) id (parseScenarioId "kiroku/append/concurrency/expected-version-race"),
      revision = 1,
      summary = "Races expected-version appends from multiple child processes and audits committed versions.",
      tier = TierStandard,
      placement = PlaceEither,
      knobs = storeKnobs <> [intKnob "kiroku.append.writers" 8 2 32, intKnob "kiroku.append.processes" 2 2 4, intKnob "kiroku.append.streams" 4 1 16],
      dimensions =
        DimensionSupport
          { tracing = Supported (Support (TracingOff :| []) TracingOff),
            metrics = Supported (Support (MetricsOff :| []) MetricsOff),
            pgDurability = Supported (Support (PgDurable :| []) PgDurable),
            pgVersion = Supported (Support (Pg18 :| [Pg17]) Pg18)
          },
      phases = PhasePlan 0 60 0,
      requires = noEnvironment {postgres = Just (PostgresRequirement [SchemaKiroku] [] False)},
      knownDefect = Nothing,
      run = runRace
    }

intKnob :: Text -> Int -> Int -> Int -> KnobSpec
intKnob key def low high = KnobSpec (either (error . show) id (mkKnobName key)) key KnobInt (VInt (fromIntegral def)) (IntRange (fromIntegral low) (fromIntegral high)) []

runRace :: RunContext -> IO ScenarioReport
runRace context = withKirokuStore context \store -> do
  let knob key = fromIntegral (knobInt context.knobs (either (error . show) id (mkKnobName key))) :: Int
      writers = knob "kiroku.append.writers"
      processes = knob "kiroku.append.processes"
      streams = knob "kiroku.append.streams"
      event = EventData Nothing (EventType "RaceSeed") (object []) Nothing Nothing Nothing
      streamName index = StreamName ("race-" <> Text.pack (show index))
  if writers `mod` processes /= 0
    then pure (failedWith ["invalid-worker-count"] "writer count must be divisible by process count")
    else do
      seeded <- forM [0 .. streams - 1] \index -> runStoreIO store (appendToStream (streamName index) NoStream [event])
      deadlocksBefore <- Oracle.deadlockCount store.pool
      withWorkers processes [] \workers -> do
        ready <- traverse (\worker -> worker.receive 10000) workers
        forM_ workers (\worker -> worker.send CtlStart)
        began <- getCurrentTime
        let deadline = addUTCTime (realToFrac context.phases.steadySeconds) began
            loop roundIndex versions wins losses faults = do
              now <- getCurrentTime
              if now >= deadline && roundIndex > 0
                then pure (roundIndex, versions, wins, losses, faults)
                else do
                  let index = roundIndex `mod` streams
                      version = Map.findWithDefault 1 index versions
                      request = object ["stream" .= ("race-" <> Text.pack (show index)), "version" .= version, "writers" .= (writers `div` processes)]
                  forM_ workers (\worker -> worker.send (CtlCustom "race" request))
                  replies <- traverse (\worker -> worker.receive 30000) workers
                  let parsed = traverse (parseReply <=< extractReply) replies
                      (successes, conflicts, errors) = maybe (0, 0, writers) (foldr combine (0, 0, 0)) parsed
                      nextVersion = if successes == 1 then Map.insert index (version + 1) versions else versions
                  loop (roundIndex + 1) nextVersion (wins + successes) (losses + conflicts) (faults + errors)
            extractReply (Just (WrkCustom "race" payload)) = Just payload
            extractReply _ = Nothing
            combine (a, b, c) (x, y, z) = (a + x, b + y, c + z)
        (rounds, versions, wins, losses, faults) <- loop 0 (Map.fromList [(i, 1) | i <- [0 .. streams - 1]]) 0 0 0
        audits <- forM [0 .. streams - 1] \index -> do
          let name = streamName index
              expectedVersion = Map.findWithDefault 1 index versions
          info <- runStoreIO store (getStream name)
          rows <- runStoreIO store (readStreamForward name (StreamVersion 0) (fromIntegral (expectedVersion + 1)))
          pure (info, rows, expectedVersion)
        deadlocksAfter <- Oracle.deadlockCount store.pool
        let audit (info, rows, version) =
              case (info, rows) of
                (Right (Just streamInfo), Right events) -> streamInfo.version == StreamVersion (fromIntegral version) && fmap (.streamVersion) (Vector.toList events) == fmap (StreamVersion . fromIntegral) [1 .. version]
                _ -> False
            cells =
              [ ("seeded-all-streams", all isRight seeded),
                ("child-processes-ready", all (== Just WrkReady) ready),
                ("races-produced-wins-and-conflicts", rounds > 0 && wins == rounds && losses == rounds * (writers - 1)),
                ("no-unexpected-worker-errors", faults == 0),
                ("durable-versions-exact", all audit audits && sum (fmap (\(_, _, version) -> version - 1) audits) == wins)
              ]
        putSummary context Measurements "expected-version-race" (object ["rounds" .= rounds, "writers" .= writers, "processes" .= processes, "wins" .= wins, "conflicts" .= losses, "unexpectedErrors" .= faults, "databaseDeadlocksBefore" .= deadlocksBefore, "databaseDeadlocksAfter" .= deadlocksAfter])
        recordCells context "expected-version-race" [] cells
  where
    withWorkers count accumulated action
      | count <= 0 = action (reverse accumulated)
      | otherwise = withWorker context appenderRoleName ("race-" <> Text.pack (show count)) (object []) (\worker -> withWorkers (count - 1) (worker : accumulated) action)
    isRight (Right _) = True
    isRight _ = False

parseReply :: Value -> Maybe (Int, Int, Int)
parseReply = parseMaybe (withObject "race reply" \value -> (,,) <$> value .: "successes" <*> value .: "conflicts" <*> value .: "errors" :: Parser (Int, Int, Int))
