module Kenshou.Env.Kafka
  ( BrokerBackend (..),
    BrokerControlHooks (..),
    KafkaEnvSpec (..),
    kafkaEnvSpecFromValue,
    kafkaEnvSpecFromRunSpec,
    BrokerLane (..),
    BrokerControl (..),
    KafkaEnv (..),
    withKafkaEnv,
    TopicSpec (..),
    topicName,
    groupName,
    createTopics,
    PartitionOffsets (..),
    GroupMember (..),
    GroupSnapshot (..),
    describeGroup,
    awaitGroup,
    deleteRunTopics,
    deleteRunGroups,
  )
where

import Control.Exception (IOException, bracket, try)
import Control.Monad (forM_, unless, when)
import Data.Aeson (object, (.=))
import Data.List (isPrefixOf)
import Data.Text (Text)
import Data.Text qualified as Text
import Kenshou.Core.Context (RunContext (..), SummarySection (..), putSummary)
import Kenshou.Env.Kafka.Admin
import Kenshou.Env.Kafka.External (withExternalBrokers)
import Kenshou.Env.Kafka.Naming (groupName, runPrefix, topicName)
import Kenshou.Env.Kafka.RedpandaContainer (withRedpandaContainer)
import Kenshou.Env.Kafka.Spec
import Kenshou.Env.Kafka.Types
import System.Directory (createDirectory, doesFileExist, getTemporaryDirectory, listDirectory, removePathForcibly)
import System.FilePath ((</>))
import System.Posix.Process (getProcessID)
import System.Posix.Signals (nullSignal, signalProcess)
import System.Process (readProcessWithExitCode)
import Text.Read (readMaybe)

withKafkaEnv :: RunContext -> KafkaEnvSpec -> (KafkaEnv -> IO a) -> IO a
withKafkaEnv context rawSpec action = do
  spec <- either (ioError . userError . Text.unpack) pure (validateKafkaEnvSpec rawSpec)
  temporary <- getTemporaryDirectory
  sweepStale temporary
  let prefix = runPrefix context.runId
      workDir = temporary </> ("kenshou-kafka-" <> Text.unpack (Text.drop 8 prefix))
      run env = do
        putSummary context Measurements "kafka" $
          object
            [ "backend" .= backendName env.backend,
              "brokerVersion" .= env.brokerVersion,
              "lanes" .= length env.lanes,
              "brokerProps" .= spec.brokerProps
            ]
        action env
  bracket
    ( do
        createDirectory workDir
        writeFile (workDir </> "rpk.yaml") ""
        pid <- getProcessID
        writeFile (workDir </> "harness.pid") (show pid)
        when spec.keepData (writeFile (workDir </> "keep-data") "")
        pure ()
    )
    (\_ -> if spec.keepData then pure () else removePathForcibly workDir)
    ( \_ -> case spec.backend of
        RedpandaContainer -> withRedpandaContainer context spec workDir prefix run
        ExternalBrokers -> withExternalBrokers context spec workDir prefix run
    )

backendName :: BrokerBackend -> Text
backendName RedpandaContainer = "redpanda-container"
backendName ExternalBrokers = "external"

sweepStale :: FilePath -> IO ()
sweepStale temporary = do
  entries <- listDirectory temporary
  forM_ (filter ("kenshou-kafka-" `isPrefixOf`) entries) \entry -> do
    let directory = temporary </> entry
        pidFile = directory </> "harness.pid"
    marked <- doesFileExist pidFile
    retained <- doesFileExist (directory </> "keep-data")
    when (marked && not retained) do
      pidText <- readFile pidFile
      let pid = readMaybe @Int pidText
      alive <- maybe (pure False) processAlive pid
      unless alive do
        runtimeFile <- doesFileExist (directory </> "container-runtime")
        nameFile <- doesFileExist (directory </> "container-name")
        when (runtimeFile && nameFile) do
          runtime <- readFile (directory </> "container-runtime")
          name <- readFile (directory </> "container-name")
          when ("kenshou-rp-" `isPrefixOf` name && runtime `elem` ["container", "docker"]) do
            _ <- readProcessWithExitCode runtime ["stop", name] ""
            _ <- readProcessWithExitCode runtime [if runtime == "container" then "delete" else "rm", name] ""
            pure ()
        removePathForcibly directory

processAlive :: Int -> IO Bool
processAlive pid = do
  result <- try @IOException (signalProcess nullSignal (fromIntegral pid))
  pure case result of Right () -> True; Left _ -> False
