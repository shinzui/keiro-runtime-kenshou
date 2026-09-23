module Kenshou.Suite.Kiroku.Concurrency.Append (scenarios) where

import Control.Monad (forM, forM_, (<=<))
import Data.Aeson (Value, object, withObject, (.:), (.=))
import Data.Aeson.Types (Parser, parseMaybe)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time.Clock (addUTCTime, getCurrentTime)
import Data.Vector qualified as Vector
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
import Kenshou.Suite.Kiroku.Fixture.Oracle qualified as Oracle
import Kenshou.Suite.Kiroku.Fixture.Store (withKirokuStore)
import Kenshou.Suite.Kiroku.Knobs (storeKnobs)
import Kenshou.Suite.Kiroku.Roles (appenderRoleName)
import Kiroku.Store hiding (id, withKirokuStore)

scenarios :: [Scenario]
scenarios = [expectedVersionRace]

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
