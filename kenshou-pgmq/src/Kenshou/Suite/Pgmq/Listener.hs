module Kenshou.Suite.Pgmq.Listener
  ( Notification (..),
    withListener,
    awaitNotifications,
  )
where

import Control.Concurrent (threadDelay)
import Control.Exception (bracket)
import Data.ByteString.Char8 qualified as ByteString
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as Text
import Database.PostgreSQL.LibPQ qualified as LibPQ
import System.Timeout (timeout)

data Notification = Notification {channel :: Text, payload :: Text} deriving stock (Eq, Show)

withListener :: Text -> Text -> (LibPQ.Connection -> IO a) -> IO a
withListener connectionString channel action =
  bracket (LibPQ.connectdb (Text.encodeUtf8 connectionString)) LibPQ.finish \connection -> do
    status <- LibPQ.status connection
    if status /= LibPQ.ConnectionOk
      then ioError (userError "failed to open PostgreSQL LISTEN connection")
      else do
        let quoted = ByteString.concat ["LISTEN \"", Text.encodeUtf8 (escape channel), "\""]
        _ <- LibPQ.exec connection quoted
        action connection
  where
    escape = T.replace "\"" "\"\""

awaitNotifications :: LibPQ.Connection -> Int -> IO [Notification]
awaitNotifications connection timeoutMs = maybe [] id <$> timeout (timeoutMs * 1000) loop
  where
    loop = do
      _ <- LibPQ.consumeInput connection
      drain [] >>= \case
        [] -> threadDelay 10000 >> loop
        values -> pure values
    drain acc =
      LibPQ.notifies connection >>= \case
        Nothing -> pure (reverse acc)
        Just notice -> drain (Notification (Text.decodeUtf8 (LibPQ.notifyRelname notice)) (Text.decodeUtf8 (LibPQ.notifyExtra notice)) : acc)
