module Kenshou.Suite.Keiro.Queue.WorkerOracle (workerOutcomeCells) where

import Control.Monad (unless)
import Data.Aeson (FromJSON (..), Value (..), object, toJSON, withObject, (.:), (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (Parser, parseEither, parseMaybe)
import Data.Int (Int64)
import Data.List (sort)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime, diffUTCTime)

data Arm = Arm
  { label :: Text,
    queue :: Text,
    identifier :: Int64,
    payload :: Value,
    headers :: Value,
    completed :: Bool,
    mainRows :: [Value],
    archiveRows :: [Value],
    dlqRows :: [Value],
    deliveries :: [Value],
    readSnapshots :: [[Value]]
  }

instance FromJSON Arm where
  parseJSON = withObject "worker outcome arm" \o -> Arm <$> o .: "case" <*> o .: "queue" <*> o .: "messageId" <*> o .: "payload" <*> o .: "headers" <*> o .: "completed" <*> o .: "mainRows" <*> o .: "archiveRows" <*> o .: "dlqRows" <*> o .: "deliveries" <*> o .: "readSnapshots"

field :: Key.Key -> Value -> Maybe Value
field key (Object values) = KeyMap.lookup key values
field _ _ = Nothing

stamp :: Key.Key -> Value -> Maybe UTCTime
stamp key value = field key value >>= parseMaybe parseJSON

workerOutcomeCells :: Value -> Either Text [(Text, Bool)]
workerOutcomeCells = either (Left . Text.pack) Right . parseEither parse
  where
    parse = withObject "worker boundary observations" \o -> do
      schema <- o .: "schema"
      unless (schema == ("kenshou.queue-worker-outcomes/v1" :: Text)) (fail "unsupported worker outcomes")
      arms <- o .: "arms" :: Parser [Arm]
      unless (sort (map (.label) arms) == ["archive", "default", "future", "malformed", "retry", "zero"]) (fail "incomplete worker boundary cases")
      pure (concatMap cells arms)
    cells arm =
      let prefix = "worker-" <> arm.label <> "-"
          attempts = if arm.label `elem` ["retry", "default"] then [0, 1] else if arm.label == "archive" then [0] else [] :: [Int]
          expectedPayload = if arm.label `elem` ["malformed", "future"] then object ["boundary" .= arm.label] else String arm.label
          callMatches attempt call = field "queue" call == Just (String arm.queue) && field "payload" call == Just expectedPayload && field "attempt" call == Just (toJSON attempt) && field "headers" call == Just Null
          callsMatch = arm.payload == expectedPayload && length arm.deliveries == length attempts && and (zipWith callMatches attempts arm.deliveries)
          archive = object ["messageId" .= arm.identifier, "message" .= arm.payload, "headers" .= arm.headers, "readCount" .= (1 :: Int)]
          wrapperMatches row = case field "message" row of
            Just body ->
              field "original_message_id" body == Just (toJSON arm.identifier)
                && field "original_message" body == Just arm.payload
                && field "original_headers" body == Just arm.headers
                && field "read_count" body == Just (Number (if arm.label == "future" then 3 else 1))
                && stamp "original_enqueued_at" body /= Nothing
                && case field "dead_letter_reason" body of
                  Just (String reason) -> if arm.label == "malformed" then Text.isPrefixOf "invalid_payload" reason else reason == "max_retries_exceeded"
                  _ -> False
            _ -> False
          placed
            | arm.label `elem` ["retry", "default"] = null arm.archiveRows && null arm.dlqRows
            | arm.label == "archive" = arm.archiveRows == [archive] && null arm.dlqRows
            | otherwise = null arm.archiveRows && length arm.dlqRows == 1 && all wrapperMatches arm.dlqRows
          retryDelay = case traverse (stamp "at") arm.deliveries of
            Just [first, second] -> diffUTCTime second first >= 2
            _ -> False
          readTimes = Map.fromListWith min [(count, at) | row <- concat arm.readSnapshots, Just count <- [field "readCount" row >>= parseMaybe parseJSON :: Maybe Int], Just at <- [stamp "lastReadAt" row]]
          futureDelay = case (Map.lookup 1 readTimes, Map.lookup 2 readTimes, arm.dlqRows) of
            (Just first, Just second, [row]) -> case field "message" row >>= stamp "last_read_at" of
              Just final -> diffUTCTime second first >= 2 && diffUTCTime final second >= 2
              _ -> False
            _ -> False
       in [(prefix <> "completed", arm.completed), (prefix <> "handler-context", callsMatch), (prefix <> "physical-placement", null arm.mainRows && placed)]
            <> (if arm.label `elem` ["retry", "default"] then [(prefix <> "fractional-delay-rounded-up", retryDelay)] else [])
            <> (if arm.label == "future" then [(prefix <> "deferred-before-ceiling", futureDelay)] else [])
