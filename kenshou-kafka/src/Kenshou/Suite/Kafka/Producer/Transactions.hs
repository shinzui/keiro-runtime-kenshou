module Kenshou.Suite.Kafka.Producer.Transactions (scenarios) where

import Control.Monad (forM_)
import Data.Aeson (object, (.=))
import Data.ByteString.Char8 qualified as ByteString
import Data.List (sort)
import Data.Text (Text)
import Data.Text qualified as Text
import Effectful (liftIO, runEff)
import Effectful.Error.Static (runError)
import Kafka.Effectful.Consumer qualified as C
import Kafka.Effectful.Producer qualified as P
import Kafka.Types (BrokerAddress (..), KafkaError, Timeout (..), TopicName (..))
import Kenshou.Check.Process (awaitMark, awaitReady, childPid, killChild, restartChild, roleProcess, sendCommand, spawn, stopGracefully, withSupervisor)
import Kenshou.Check.Scenario (withCheck)
import Kenshou.Core.Context (RunContext (..), SummarySection (..), putSummary)
import Kenshou.Core.Dimension (allTelemetryArms, noDimensions)
import Kenshou.Core.Env (noEnvironment)
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Role (ControlMessage (..))
import Kenshou.Core.Scenario (Placement (..), Scenario (..), ScenarioReport, Tier (..), failedWith, passed)
import Kenshou.Env.Kafka
import Kenshou.Suite.Kafka.Fixture (firstBrokers, produceValues)

scenarios :: [Scenario]
scenarios =
  [ Scenario
      { id = either (error . Text.unpack) id (parseScenarioId "kafka/producer/correctness/transactions-commit-and-abort"),
        revision = 1,
        summary = "Checks read-committed visibility and exactly-once transform across a worker SIGKILL.",
        tier = TierStandard,
        placement = PlaceEither,
        knobs = [],
        dimensions = allTelemetryArms noDimensions,
        phases = zeroPhases,
        requires = noEnvironment,
        knownDefect = Nothing,
        run = runTransactions
      }
  ]

runTransactions :: RunContext -> IO ScenarioReport
runTransactions context = do
  spec <- either (ioError . userError . Text.unpack) pure (kafkaEnvSpecFromRunSpec context)
  withKafkaEnv context spec \env -> do
    [visibility, input, output] <- createTopics env [TopicSpec "tx-visibility" 1 mempty, TopicSpec "tx-input" 1 mempty, TopicSpec "tx-output" 1 mempty]
    publishCommittedAndAborted env visibility
    visible <- readCommitted env visibility "tx-visibility-reader" 10
    _ <- produceValues env input [0 .. 49]
    (firstPid, secondPid) <- crashAndRestart context env input output
    transformed <- readCommitted env output "tx-output-reader" 50
    inputSnapshot <- describeGroup env (groupName env "tx-input-worker")
    _ <- deleteRunGroups env
    _ <- deleteRunTopics env
    let exactVisibility = sort visible == [0 .. 9] && length visible == 10
        exactTransform = sort transformed == [0 .. 49] && length transformed == 50
        consumedInput = length inputSnapshot.offsets == 1 && all ((== Just 0) . (.lag)) inputSnapshot.offsets
    putSummary context Verdicts "transactions" (object ["committedVisible" .= length visible, "transformedVisible" .= length transformed, "firstWorkerPid" .= firstPid, "replacementWorkerPid" .= secondPid, "inputLagZero" .= consumedInput])
    pure $
      if exactVisibility && exactTransform && consumedInput && firstPid /= secondPid
        then passed
        else failedWith ["transactions-commit-and-abort"] ("visible=" <> Text.pack (show visible) <> " transformed=" <> Text.pack (show transformed) <> " inputSnapshot=" <> Text.pack (show inputSnapshot) <> " pids=" <> Text.pack (show (firstPid, secondPid)))

publishCommittedAndAborted :: KafkaEnv -> TopicName -> IO ()
publishCommittedAndAborted env topic = do
  let props =
        P.brokersList (firstBrokers env)
          <> P.extraProp "transactional.id" (env.prefix <> "-visibility")
          <> P.extraProp "enable.idempotence" "true"
          <> P.extraProp "acks" "all"
  outcome <- runEff . runError @KafkaError $
    P.runKafkaProducer props $ do
      P.initTransactions (Timeout 10000)
      P.beginTransaction
      forM_ [0 :: Int .. 9] (P.produceMessage . record)
      committed <- P.commitTransaction (Timeout 10000)
      case committed of
        Nothing -> pure ()
        Just problem -> liftIO $ ioError (userError ("transaction commit failed: " <> show (P.getKafkaError problem)))
      P.beginTransaction
      forM_ [100 :: Int .. 109] (P.produceMessage . record)
      P.abortTransaction (Timeout 10000)
  either (ioError . userError . show) pure outcome
  where
    record number =
      P.ProducerRecord
        { P.prTopic = topic,
          P.prPartition = P.UnassignedPartition,
          P.prKey = Nothing,
          P.prValue = Just (ByteString.pack (show number)),
          P.prHeaders = mempty
        }

crashAndRestart :: RunContext -> KafkaEnv -> TopicName -> TopicName -> IO (Int, Int)
crashAndRestart context env (TopicName input) (TopicName output) = withCheck context \check -> withSupervisor check \supervisor -> do
  let args =
        object
          [ "brokers" .= fmap unBrokerAddress (firstBrokers env),
            "inputTopic" .= input,
            "outputTopic" .= output,
            "group" .= unGroup (groupName env "tx-input-worker"),
            "transactionId" .= (env.prefix <> "-transform"),
            "messages" .= (50 :: Int)
          ]
  spec <- roleProcess check "kafka/transaction-worker" 0 args
  first <- spawn supervisor spec
  awaitReady first 10000
  sendCommand first CtlStart
  awaitMark first "prepared" 45000
  killChild supervisor first
  second <- restartChild supervisor first
  sendCommand second CtlStart
  awaitMark second "prepared" 45000
  sendCommand second (CtlCustom "commit" (object []))
  awaitMark second "committed" 30000
  _ <- stopGracefully supervisor second 2000
  pure (fromIntegral (childPid first), fromIntegral (childPid second))
  where
    unGroup (C.ConsumerGroupId value) = value

readCommitted :: KafkaEnv -> TopicName -> Text -> Int -> IO [Int]
readCommitted env topic suffix count = do
  let props =
        C.brokersList (firstBrokers env)
          <> C.groupId (groupName env suffix)
          <> C.noAutoCommit
          <> C.noAutoOffsetStore
          <> C.extraProp "isolation.level" "read_committed"
      subscription = C.topics [topic] <> C.offsetReset C.Earliest
  outcome <- runEff . runError @KafkaError $ C.runKafkaConsumer props subscription $ do
    records <- collect 0 []
    extra <- C.pollMessage (Timeout 3000)
    pure (records, extra)
  case outcome of
    Left problem -> ioError (userError (show problem))
    Right (records, extra) ->
      if extra /= Nothing
        then ioError (userError "read_committed saw an unexpected extra record")
        else pure [number | record <- records, Just bytes <- [C.crValue record], Just number <- [readInt bytes]]
  where
    collect (emptyPolls :: Int) records
      | length records >= count = pure (reverse records)
      | emptyPolls >= 10 = pure (reverse records)
      | otherwise = do
          candidate <- C.pollMessage (Timeout 1000)
          case candidate of
            Nothing -> collect (emptyPolls + 1) records
            Just record -> collect 0 (record : records)

readInt :: ByteString.ByteString -> Maybe Int
readInt bytes = case reads (ByteString.unpack bytes) of [(value, "")] -> Just value; _ -> Nothing
