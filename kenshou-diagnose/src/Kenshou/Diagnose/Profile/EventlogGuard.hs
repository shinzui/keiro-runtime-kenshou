{-# LANGUAGE ForeignFunctionInterface #-}

module Kenshou.Diagnose.Profile.EventlogGuard
  ( withEventlogGuard,
  )
where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (withAsync)
import Kenshou.Diagnose.Threads (labelMe)
import System.Directory (doesFileExist, getFileSize)
import System.Environment (lookupEnv)
import System.IO (hPutStrLn, stderr)
import Text.Read (readMaybe)

foreign import ccall safe "endEventLogging" endEventLogging :: IO ()

withEventlogGuard :: IO value -> IO value
withEventlogGuard action = do
  configuration <- guardConfiguration
  case configuration of
    Nothing -> action
    Just (path, limit) -> withAsync (guard path limit) (const action)

guardConfiguration :: IO (Maybe (FilePath, Integer))
guardConfiguration = do
  path <- lookupEnv "KENSHOU_EVENTLOG_PATH"
  rawLimit <- lookupEnv "KENSHOU_EVENTLOG_MAX_BYTES"
  pure do
    eventlogPath <- path
    limit <- rawLimit >>= readMaybe
    if limit > 0 then Just (eventlogPath, limit) else Nothing

guard :: FilePath -> Integer -> IO ()
guard path limit = do
  labelMe "kenshou:diagnose:eventlog-guard"
  waitForLimit
  endEventLogging
  writeFile (path <> ".truncated") "event logging stopped at configured byte limit\n"
  hPutStrLn stderr ("kenshou: event log reached " <> show limit <> " bytes; logging stopped")
  where
    waitForLimit = do
      exists <- doesFileExist path
      size <- if exists then getFileSize path else pure 0
      if size >= limit then pure () else threadDelay 1_000_000 >> waitForLimit
