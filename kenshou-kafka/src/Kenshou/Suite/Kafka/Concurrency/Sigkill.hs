module Kenshou.Suite.Kafka.Concurrency.Sigkill (scenarios) where

import Control.Concurrent.Async (async, wait)
import Control.Concurrent.STM (atomically, check)
import Data.Aeson (FromJSON (..), object, withObject, (.:), (.=))
import Data.Aeson qualified as Aeson
import Data.Int (Int64)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime, addUTCTime, getCurrentTime)
import Kafka.Consumer.Types (ConsumerGroupId (..))
import Kafka.Types (BrokerAddress (..), PartitionId (..), TopicName (..))
import Kenshou.Check.Process (Child, ProgressSnapshot (..), Supervisor, awaitReady, killChild, progress, readChildMessages, restartChild, roleProcess, sendCommand, spawn, stopGracefully, withSupervisor)
import Kenshou.Check.Scenario (withCheck)
import Kenshou.Core.Context (RunContext (..), SummarySection (..), putSummary)
import Kenshou.Core.Dimension (allTelemetryArms, noDimensions)
import Kenshou.Core.Env (noEnvironment)
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Knob (KnobName, knobInt, mkKnobName)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Role (ControlMessage (..), WorkerMessage (..))
import Kenshou.Core.Scenario (Placement (..), Scenario (..), ScenarioReport, Tier (..), failedWith, passed)
import Kenshou.Env.Kafka
import Kenshou.Suite.Kafka.Fixture (firstBrokers, intKnob, produceValues)
import System.Timeout (timeout)

scenarios :: [Scenario]
scenarios =
  [ Scenario
      { id = either (error . Text.unpack) id (parseScenarioId "kafka/adapter/concurrency/sigkill-redelivery-window"),
        revision = 1,
        summary = "Kills and restarts an adapter consumer, checking complete redelivery and commit boundaries.",
        tier = TierStandard,
        placement = PlaceEither,
        knobs =
          [ intKnob "kafka.messages" "Acknowledged records" 20000 200 100000,
            intKnob "kafka.kills" "Consumer SIGKILL cycles" 3 1 8,
            intKnob "kafka.prop.auto.commit.interval.ms" "Auto-commit interval in milliseconds" 1000 100 10000
          ],
        dimensions = allTelemetryArms noDimensions,
        phases = zeroPhases,
        requires = noEnvironment,
        knownDefect = Nothing,
        run = runSigkill
      }
  ]

data OkFact = OkFact {value :: Int, partition :: Int, offset :: Int, at :: UTCTime} deriving stock (Eq, Show)

instance FromJSON OkFact where
  parseJSON = withObject "Kafka ok fact" \v -> OkFact <$> v .: "value" <*> v .: "partition" <*> v .: "offset" <*> v .: "at"

runSigkill :: RunContext -> IO ScenarioReport
runSigkill context = do
  spec <- either (ioError . userError . Text.unpack) pure (kafkaEnvSpecFromRunSpec context)
  withKafkaEnv context spec \env -> do
    let messages = fromIntegral (knobInt context.knobs (key "kafka.messages"))
        kills = fromIntegral (knobInt context.knobs (key "kafka.kills"))
        commitMillis = fromIntegral (knobInt context.knobs (key "kafka.prop.auto.commit.interval.ms")) :: Int
        group = groupName env "sigkill"
    [topic] <- createTopics env [TopicSpec "sigkill" 4 mempty]
    (sent, generations, boundaries, finalSnapshot) <- withCheck context \checkEnv -> withSupervisor checkEnv \supervisor -> do
      let args =
            object
              [ "brokers" .= fmap unBrokerAddress (firstBrokers env),
                "topic" .= unTopicName topic,
                "group" .= unConsumerGroupId group,
                "autoCommitMillis" .= commitMillis
              ]
      childSpec <- roleProcess checkEnv "kafka/crash-consumer" 0 args
      first <- spawn supervisor childSpec
      awaitReady first 10000
      sendCommand first CtlStart
      producer <- async $ produceValues env topic [0 .. messages - 1]
      let segment = max 20 (messages `div` (kills + 1))
      (lastChild, oldFacts, oldBoundaries) <- crashLoop env group supervisor first kills segment [] []
      acknowledged <- wait producer
      finished <- awaitGroup env group 45 (\snapshot -> length snapshot.offsets == 4 && all ((== Just 0) . (.lag)) snapshot.offsets)
      _ <- stopGracefully supervisor lastChild 5000
      lastFacts <- factsFrom lastChild
      pure (acknowledged, oldFacts <> [lastFacts], oldBoundaries, finished)
    _ <- deleteRunGroups env
    _ <- deleteRunTopics env
    let allFacts = concat generations
        ids = fmap (.value) allFacts
        seenIds = Set.fromList ids
        missing = [number | number <- [0 .. messages - 1], not (Set.member number seenIds)]
        oldCommitted =
          [ (generationIndex, p, committed)
          | (generationIndex, (_, boundarySnapshot)) <- zip [1 :: Int ..] boundaries,
            item <- boundarySnapshot.offsets,
            let PartitionId p = item.partition,
            Just committed <- [item.committed]
          ]
        replayBelowCommit =
          [ (generationIndex, fact.partition, fact.offset, committed)
          | (generationIndex, p, committed) <- oldCommitted,
            fact <- generations !! generationIndex,
            fact.partition == p,
            fromIntegral fact.offset < committed
          ]
        duplicateWindows =
          [ (generationIndex, p, length duplicates, 2 * length windowFacts + 1)
          | (generationIndex, (killedAt, _)) <- zip [1 :: Int ..] boundaries,
            p <- [0 .. 3],
            let previous = generations !! (generationIndex - 1),
            let next = generations !! generationIndex,
            let previousOffsets = Set.fromList (fmap (.offset) (filter ((== p) . (.partition)) previous)),
            let duplicates = [fact | fact <- next, fact.partition == p, Set.member fact.offset previousOffsets],
            let windowStart = addUTCTime (negate (fromIntegral commitMillis / 1000)) killedAt,
            let windowFacts = [fact | fact <- previous, fact.partition == p, fact.at >= windowStart]
          ]
        duplicateOverruns = filter (\(_, _, observed, limit) -> observed > limit) duplicateWindows
        (groupReachedEnd, snapshot) = case finalSnapshot of Left value -> (False, value); Right value -> (True, value)
        completeBoundaries = length boundaries == kills && all ((== 4) . length . (.offsets) . snd) boundaries
        failures =
          ["sigkill-ack-count" | length sent /= messages]
            <> ["sigkill-no-loss" | not (null missing)]
            <> ["sigkill-commit-snapshots" | not completeBoundaries]
            <> ["sigkill-no-replay-below-commit" | not (null replayBelowCommit)]
            <> ["sigkill-duplicate-window" | not (null duplicateOverruns)]
            <> ["sigkill-zero-lag" | not groupReachedEnd]
    putSummary context Verdicts "sigkill" (object ["acknowledged" .= length sent, "handled" .= length allFacts, "missing" .= take 20 missing, "committedBeforeRestart" .= oldCommitted, "replayedBelowCommit" .= take 20 replayBelowCommit, "duplicateWindows" .= duplicateWindows, "duplicateOverruns" .= duplicateOverruns, "killCount" .= kills])
    pure $
      if null failures
        then passed
        else failedWith failures ("facts=" <> Text.pack (show (length allFacts)) <> " missing=" <> Text.pack (show (take 20 missing)) <> " replay=" <> Text.pack (show (take 20 replayBelowCommit)) <> " overruns=" <> Text.pack (show duplicateOverruns) <> " group=" <> Text.pack (show snapshot))

crashLoop :: KafkaEnv -> ConsumerGroupId -> Supervisor -> Child -> Int -> Int -> [[OkFact]] -> [(UTCTime, GroupSnapshot)] -> IO (Child, [[OkFact]], [(UTCTime, GroupSnapshot)])
crashLoop _ _ _ child 0 _ generations boundaries = pure (child, reverse generations, reverse boundaries)
crashLoop env group supervisor child remaining segment generations boundaries = do
  awaitProgress child segment 90000
  killedAt <- getCurrentTime
  killChild supervisor child
  facts <- factsFrom child
  -- Read C_p after the old process is gone and before its replacement joins.
  snapshot <- describeGroup env group
  replacement <- restartChild supervisor child
  sendCommand replacement CtlStart
  crashLoop env group supervisor replacement (remaining - 1) segment (facts : generations) ((killedAt, snapshot) : boundaries)

awaitProgress :: Child -> Int -> Int -> IO ()
awaitProgress child target timeoutMillis = do
  result <- timeout (timeoutMillis * 1000) (atomically (progress child >>= \snapshot -> check (snapshot.count >= fromIntegral @Int @Int64 target)))
  maybe (ioError (userError ("crash consumer did not handle " <> show target <> " records"))) pure result

factsFrom :: Child -> IO [OkFact]
factsFrom child = do
  messages <- readChildMessages child
  pure
    [ fact
    | WrkCustom "ok" value <- messages,
      Aeson.Success fact <- [Aeson.fromJSON value]
    ]

key :: Text -> KnobName
key = either (error . Text.unpack) id . mkKnobName
