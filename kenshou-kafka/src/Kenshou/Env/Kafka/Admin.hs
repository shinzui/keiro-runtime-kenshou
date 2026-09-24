module Kenshou.Env.Kafka.Admin
  ( TopicSpec (..),
    PartitionOffsets (..),
    GroupMember (..),
    GroupSnapshot (..),
    createTopics,
    describeGroup,
    awaitGroup,
    deleteRunTopics,
    deleteRunGroups,
    runRpk,
  )
where

import Control.Applicative ((<|>))
import Control.Concurrent (threadDelay)
import Control.Monad (forM, forM_)
import Data.Aeson (Value (..), decodeStrict')
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Char8 qualified as ByteString
import Data.Int (Int64)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (mapMaybe)
import Data.Scientific (toBoundedInteger)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Vector qualified as Vector
import Kafka.Consumer (ConsumerGroupId (..), PartitionId (..))
import Kafka.Types (BrokerAddress (..), TopicName (..))
import Kenshou.Env.Kafka.Naming (topicName)
import Kenshou.Env.Kafka.Types (BrokerLane (..), KafkaEnv (..))
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.Process (readProcessWithExitCode)

data TopicSpec = TopicSpec {name :: Text, partitions :: Int, config :: Map Text Text}
  deriving stock (Eq, Show)

data PartitionOffsets = PartitionOffsets
  { topic :: TopicName,
    partition :: PartitionId,
    committed :: Maybe Int64,
    logEnd :: Int64,
    lag :: Maybe Int64
  }
  deriving stock (Eq, Show)

data GroupMember = GroupMember {memberId :: Text, clientId :: Text, host :: Text}
  deriving stock (Eq, Show)

data GroupSnapshot = GroupSnapshot
  { group :: ConsumerGroupId,
    state :: Text,
    members :: [GroupMember],
    offsets :: [PartitionOffsets]
  }
  deriving stock (Eq, Show)

runRpk :: KafkaEnv -> [String] -> IO String
runRpk env args = do
  let address = case env.lanes of
        lane :| _ -> case lane.laneBrokers of
          BrokerAddress value : _ -> Text.unpack value
          [] -> error "Kafka lane has no broker"
      configPath = env.workDir </> "rpk.yaml"
  (code, output, errorOutput) <- readProcessWithExitCode "rpk" (["--config", configPath, "-X", "brokers=" <> address] <> args) ""
  case code of
    ExitSuccess -> pure output
    ExitFailure _ -> ioError (userError ("rpk " <> unwords args <> ": " <> errorOutput))

createTopics :: KafkaEnv -> [TopicSpec] -> IO [TopicName]
createTopics env specs = forM specs \spec -> do
  let topic@(TopicName fullName) = topicName env spec.name
      configArgs = concat [["-c", Text.unpack key <> "=" <> Text.unpack value] | (key, value) <- Map.toAscList spec.config]
  if spec.partitions < 1 || spec.partitions > 64
    then ioError (userError "Kafka topic partitions must be between 1 and 64")
    else runRpk env (["topic", "create", Text.unpack fullName, "-p", show spec.partitions, "-r", "1"] <> configArgs) >> pure topic

describeGroup :: KafkaEnv -> ConsumerGroupId -> IO GroupSnapshot
describeGroup env group@(ConsumerGroupId name) = do
  output <- runRpk env ["group", "describe", Text.unpack name, "--format", "json"]
  case decodeStrict' (ByteString.pack output) of
    Nothing -> ioError (userError "rpk group describe returned invalid JSON")
    Just value -> pure (snapshot group value)

awaitGroup :: KafkaEnv -> ConsumerGroupId -> Int -> (GroupSnapshot -> Bool) -> IO (Either GroupSnapshot GroupSnapshot)
awaitGroup env group seconds predicate = do
  initial <- describeGroup env group
  loop (seconds * 5) initial
  where
    loop 0 previous = pure (Left previous)
    loop remaining previous
      | predicate previous = pure (Right previous)
      | otherwise = do
          threadDelay 200000
          current <- describeGroup env group
          loop (remaining - 1) current

deleteRunTopics :: KafkaEnv -> IO Int
deleteRunTopics env = do
  output <- runRpk env ["topic", "list", "--format", "json"]
  names <- decodeNames "name" output
  let owned = filter (Text.isPrefixOf (env.prefix <> "-")) names
  forM_ owned \name -> do
    _ <- runRpk env ["topic", "delete", Text.unpack name]
    pure ()
  pure (length owned)

deleteRunGroups :: KafkaEnv -> IO Int
deleteRunGroups env = do
  output <- runRpk env ["group", "list", "--format", "json"]
  names <- decodeNames "group" output
  let owned = filter (Text.isPrefixOf (env.prefix <> "-")) names
  forM_ owned \name -> do
    _ <- runRpk env ["group", "delete", Text.unpack name]
    pure ()
  pure (length owned)

decodeNames :: Text -> String -> IO [Text]
decodeNames key output = case decodeStrict' (ByteString.pack output) of
  Nothing -> ioError (userError "rpk list returned invalid JSON")
  Just value -> pure (mapMaybe (fieldText key) (arrayMembers value))

snapshot :: ConsumerGroupId -> Value -> GroupSnapshot
snapshot group value = GroupSnapshot group (maybe "unknown" id (fieldText "state" detail)) memberValues offsetValues
  where
    detail = case arrayMembers value of item : _ -> item; [] -> value
    memberValues = [GroupMember (text "member_id" item) (text "client_id" item) (text "host" item) | item <- arrayMembers =<< maybe [] pure (field "members_details" detail)]
    offsetValues =
      [ PartitionOffsets (TopicName (text "topic" item)) (PartitionId (fromIntegral (number "partition" item))) (numberMaybe "current_offset" item) (number "log_end_offset" item) (numberMaybe "lag" item)
      | item <- arrayMembers =<< maybe [] pure (field "partitions" detail)
      ]
    text key item = maybe "" id (fieldText key item)
    number key item = maybe 0 id (numberMaybe key item)

arrayMembers :: Value -> [Value]
arrayMembers (Array values) = Vector.toList values
arrayMembers (Object value) = maybe [] arrayMembers (KeyMap.lookup "topics" value <|> KeyMap.lookup "groups" value)
arrayMembers _ = []

field :: Text -> Value -> Maybe Value
field key (Object value) = KeyMap.lookup (Key.fromText key) value
field _ _ = Nothing

fieldText :: Text -> Value -> Maybe Text
fieldText key value = field key value >>= \case String text -> Just text; _ -> Nothing

numberMaybe :: Text -> Value -> Maybe Int64
numberMaybe key value =
  field key value >>= \case
    Number number -> toBoundedInteger number
    _ -> Nothing
