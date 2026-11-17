module Kenshou.Cli.Attest.KeiroQueueWorkers (replayWorkerOutcomes) where

import Control.Monad (unless)
import Data.Aeson (FromJSON (..), Value (..), object, toJSON, withObject, (.:), (.=))
import Data.Aeson.Key (Key)
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (Parser, parseEither, parseMaybe)
import Data.Int (Int64)
import Data.List (sort)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime, diffUTCTime)

get :: (FromJSON a) => Key -> Value -> Parser a
get key = withObject "worker observation" (.: key)

field :: Key -> Value -> Maybe Value
field key (Object values) = KeyMap.lookup key values
field _ _ = Nothing

time :: Key -> Value -> Maybe UTCTime
time key value = field key value >>= parseMaybe parseJSON

separated :: Maybe UTCTime -> Maybe UTCTime -> Bool
separated (Just earlier) (Just later) = diffUTCTime later earlier >= 2
separated _ _ = False

-- This replay depends only on the sealed observations and the revision's fixed
-- contract. It does not link to Keiro or the scenario's worker oracle.
replayWorkerOutcomes :: Value -> Either Text [(Text, Bool)]
replayWorkerOutcomes = either (Left . Text.pack) Right . parseEither replay
  where
    replay raw = do
      schema <- get "schema" raw :: Parser Text
      unless (schema == "kenshou.queue-worker-outcomes/v1") (fail "unsupported worker observations")
      arms <- get "arms" raw :: Parser [Value]
      names <- traverse (get "case") arms :: Parser [Text]
      unless (sort names == ["archive", "default", "future", "malformed", "retry", "zero"]) (fail "missing, duplicate or unknown worker case")
      concat <$> traverse check arms
    check arm = do
      name <- get "case" arm :: Parser Text
      queue <- get "queue" arm :: Parser Text
      identifier <- get "messageId" arm :: Parser Int64
      payload <- get "payload" arm :: Parser Value
      headers <- get "headers" arm :: Parser Value
      completed <- get "completed" arm :: Parser Bool
      source <- get "mainRows" arm :: Parser [Value]
      archived <- get "archiveRows" arm :: Parser [Value]
      dead <- get "dlqRows" arm :: Parser [Value]
      calls <- get "deliveries" arm :: Parser [Value]
      snapshots <- get "readSnapshots" arm :: Parser [[Value]]
      let retrying = name `elem` ["retry", "default"]
          attempts = if retrying then [0, 1] else if name == "archive" then [0] else [] :: [Int]
          expectedPayload = if name `elem` ["future", "malformed"] then object ["boundary" .= name] else String name
          expectedCall attempt call = all (\(key, value) -> field key call == Just value) [("queue", String queue), ("payload", expectedPayload), ("attempt", toJSON attempt), ("headers", Null)]
          handler = payload == expectedPayload && length calls == length attempts && and (zipWith expectedCall attempts calls)
          archive = object ["messageId" .= identifier, "message" .= payload, "headers" .= headers, "readCount" .= (1 :: Int)]
          wrapper body =
            all (\(key, value) -> field key body == Just value) [("original_message_id", toJSON identifier), ("original_message", payload), ("original_headers", headers), ("read_count", Number (if name == "future" then 3 else 1))]
              && time "original_enqueued_at" body /= Nothing
              && case field "dead_letter_reason" body of
                Just (String reason) -> if name == "malformed" then "invalid_payload" `Text.isPrefixOf` reason else reason == "max_retries_exceeded"
                _ -> False
          placement =
            null source && case name of
              "retry" -> null archived && null dead
              "default" -> null archived && null dead
              "archive" -> archived == [archive] && null dead
              _ -> null archived && case dead of [row] -> maybe False wrapper (field "message" row); _ -> False
          delay = case calls of [first, second] -> separated (time "at" first) (time "at" second); _ -> False
          firstRead count = case [at | row <- concat snapshots, field "readCount" row == Just (Number count), Just at <- [time "lastReadAt" row]] of [] -> Nothing; values -> Just (minimum values)
          finalRead = case dead of [row] -> field "message" row >>= time "last_read_at"; _ -> Nothing
          deferred = separated (firstRead 1) (firstRead 2) && separated (firstRead 2) finalRead
          label suffix = "worker-" <> name <> "-" <> suffix
      pure $
        [(label "completed", completed), (label "handler-context", handler), (label "physical-placement", placement)]
          <> [(label "fractional-delay-rounded-up", delay) | retrying]
          <> [(label "deferred-before-ceiling", deferred) | name == "future"]
