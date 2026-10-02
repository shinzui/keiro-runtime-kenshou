module Kenshou.Suite.Keiro.Queue.Oracle (batchRowsMatch, deadLetterPreserves) where

import Data.Aeson (Value (..), toJSON)
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Int (Int64)
import Data.List (nub, sortOn)
import Data.Text (Text)
import Data.Text qualified as Text
import Keiro.PGMQ.Dlq (DlqEntry (..))

batchRowsMatch :: [Int64] -> [Text] -> [(Int64, Value, Maybe Value, Int64)] -> Bool
batchRowsMatch ids payloads rows =
  length ids == length payloads
    && length (nub ids) == length ids
    && sortOn (\(identifier, _, _, _) -> identifier) rows == sortOn (\(identifier, _, _, _) -> identifier) [(identifier, String payload, Nothing, 0) | (identifier, payload) <- zip ids payloads]

deadLetterPreserves :: Text -> Int64 -> Value -> [DlqEntry Text] -> Bool
deadLetterPreserves payload identifier headers entries = case entries of
  [entry] ->
    entry.originalPayload == Right payload
      && entry.originalMessageId == Just identifier
      && entry.originalEnqueuedAt /= Nothing
      && entry.readCount == Just 1
      && entry.originalHeaders == Just headers
      && Text.isPrefixOf "poison_pill" entry.reason
      && ( case entry.rawBody of
             Object body ->
               KeyMap.lookup "original_headers" body == Just headers
                 && KeyMap.lookup "original_message" body == Just (String payload)
                 && KeyMap.lookup "original_message_id" body == Just (toJSON identifier)
                 && KeyMap.lookup "read_count" body == Just (Number 1)
                 && KeyMap.lookup "dead_letter_reason" body == Just (String entry.reason)
             _ -> False
         )
  _ -> False
