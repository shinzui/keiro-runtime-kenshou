module Kenshou.Suite.Kafka.Concurrency.BarrierOverwrite (scenarios) where

import Control.Monad (forM_)
import Data.Aeson (object, (.=))
import Data.ByteString.Char8 qualified as ByteString
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.List (sort)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text qualified as Text
import Effectful (Eff, IOE, liftIO, runEff, (:>))
import Effectful.Error.Static (Error, runError)
import Kafka.Consumer.Types (ConsumerRecord (..), Offset (..), OffsetCommit (..))
import Kafka.Effectful.Consumer qualified as C
import Kafka.Types (BatchSize (..), KafkaError, Timeout (..), TopicName (..))
import Kenshou.Core.Context (RunContext (..), SummarySection (..), putSummary)
import Kenshou.Core.Dimension (allTelemetryArms, noDimensions)
import Kenshou.Core.Env (noEnvironment)
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Scenario (CohortScope (..), KnownDefect (..), PackageCondition (..), Placement (..), Scenario (..), ScenarioReport, Tier (..), failedWith, passed)
import Kenshou.Env.Kafka
import Kenshou.Suite.Kafka.Fixture (firstBrokers, produceValues)
import Shibuya.Adapter.Kafka (defaultConfig)
import Shibuya.Adapter.Kafka.Internal (KafkaAdapterState, mkAckHandle, newKafkaAdapterState)
import Shibuya.Core.Ack (AckDecision (..), RetryDelay (..))
import Shibuya.Core.AckHandle (AckHandle (..))

scenarios :: [Scenario]
scenarios =
  [ Scenario
      { id = either (error . Text.unpack) id (parseScenarioId "kafka/adapter/concurrency/barrier-overwrite-loses-record"),
        revision = 1,
        summary = "Finalizes two retries from one broker poll before repolling and checks whether the first is skipped.",
        tier = TierSmoke,
        placement = PlaceEither,
        knobs = [],
        dimensions = allTelemetryArms noDimensions,
        phases = zeroPhases,
        requires = noEnvironment,
        knownDefect =
          Just
            KnownDefect
              { reference = "mori://shinzui/shibuya-kafka-adapter/okf/bug-reports/concepts/BUG-5",
                summary = "A later retry can overwrite an earlier partition seek barrier.",
                expectedFailures = ["barrier-overwrite-no-loss"],
                appliesTo = OnlyWhen (ResolvedFromHackage "shibuya-kafka-adapter" :| [VersionBelow "shibuya-kafka-adapter" "0.9.0.2"])
              },
        run = runBarrierOverwrite
      }
  ]

runBarrierOverwrite :: RunContext -> IO ScenarioReport
runBarrierOverwrite context = do
  spec <- either (ioError . userError . Text.unpack) pure (kafkaEnvSpecFromRunSpec context)
  withKafkaEnv context spec \env -> do
    [topic] <- createTopics env [TopicSpec "barrier-overwrite" 1 mempty]
    sent <- produceValues env topic [0 .. 9]
    let group = groupName env "barrier-overwrite"
        props = C.brokersList (firstBrokers env) <> C.groupId group <> C.noAutoOffsetStore <> C.extraProp "auto.commit.interval.ms" "1000"
        subscription = C.topics [topic] <> C.offsetReset C.Earliest
    firstDeliveries <- newIORef []
    successes <- newIORef []
    state <- newKafkaAdapterState
    outcome <- runEff . runError @KafkaError $
      C.runKafkaConsumer props subscription $ do
        first <- collectBatch 20 10 []
        liftIO $ modifyIORef' firstDeliveries (<> fmap recordOffset first)
        forM_ first \record -> do
          let offset = recordOffset record
              decision = if offset `elem` [3, 4] then AckRetry (RetryDelay 0) else AckOk
          finalize state topic record decision
          if decision == AckOk then liftIO $ modifyIORef' successes (<> [offset]) else pure ()
        replay <- collectReplay state topic firstDeliveries successes 20
        C.commitAllOffsets OffsetCommit
        pure (fmap recordOffset first, replay)
    (first, replay) <- either (ioError . userError . show) pure outcome
    handled <- readIORef successes
    delivered <- readIORef firstDeliveries
    snapshot <- describeGroup env group
    _ <- deleteRunGroups env
    _ <- deleteRunTopics env
    let committed = case snapshot.offsets of item : _ -> item.committed; [] -> Nothing
        missingBelowCommit = [offset | Just end <- [committed], offset <- [0 .. fromIntegral end - 1], offset `notElem` handled]
        failures =
          ["barrier-overwrite-initial-batch" | fmap unOffset sent /= [0 .. 9] || sort first /= [0 .. 9]]
            <> ["barrier-overwrite-replay" | null replay]
            <> ["barrier-overwrite-commit-progress" | maybe True (<= 3) committed]
            <> ["barrier-overwrite-no-loss" | not (null missingBelowCommit)]
    putSummary context Verdicts "barrierOverwrite" (object ["initialBatch" .= first, "deliveries" .= delivered, "replay" .= replay, "successes" .= handled, "committed" .= committed, "missingBelowCommit" .= missingBelowCommit])
    pure $ if null failures then passed else failedWith failures ("first=" <> Text.pack (show first) <> " replay=" <> Text.pack (show replay) <> " committed=" <> Text.pack (show committed) <> " missing=" <> Text.pack (show missingBelowCommit))

collectBatch :: (C.KafkaConsumer :> es, Error KafkaError :> es, IOE :> es) => Int -> Int -> [ConsumerRecord (Maybe ByteString.ByteString) (Maybe ByteString.ByteString)] -> Eff es [ConsumerRecord (Maybe ByteString.ByteString) (Maybe ByteString.ByteString)]
collectBatch 0 _ collected = pure collected
collectBatch attempts needed collected
  | length collected >= needed = pure (take needed collected)
  | otherwise = do
      rows <- C.pollMessageBatch (Timeout 500) (BatchSize (needed - length collected))
      let records = [record | Right record <- rows]
      collectBatch (attempts - 1) needed (collected <> records)

collectReplay :: (C.KafkaConsumer :> es, Error KafkaError :> es, IOE :> es) => KafkaAdapterState -> TopicName -> IORef [Int] -> IORef [Int] -> Int -> Eff es [Int]
collectReplay _ _ _ _ 0 = pure []
collectReplay state topic deliveries successes attempts = do
  rows <- C.pollMessageBatch (Timeout 500) (BatchSize 10)
  let records = [record | Right record <- rows]
      offsets = fmap recordOffset records
  liftIO $ modifyIORef' deliveries (<> offsets)
  forM_ records \record -> do
    finalize state topic record AckOk
    liftIO $ modifyIORef' successes (<> [recordOffset record])
  if 4 `elem` offsets
    then pure offsets
    else (offsets <>) <$> collectReplay state topic deliveries successes (attempts - 1)

finalize :: (C.KafkaConsumer :> es, Error KafkaError :> es, IOE :> es) => KafkaAdapterState -> TopicName -> ConsumerRecord (Maybe ByteString.ByteString) (Maybe ByteString.ByteString) -> AckDecision -> Eff es ()
finalize state topic record decision = do
  let config = defaultConfig [topic]
      AckHandle ack = mkAckHandle state config record
  ack decision

recordOffset :: ConsumerRecord key value -> Int
recordOffset record = case record.crOffset of Offset offset -> fromIntegral offset
