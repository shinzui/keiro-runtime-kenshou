{-# LANGUAGE ForeignFunctionInterface #-}

module Main (main) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Monad (forever, unless)
import Debug.Trace (traceEventIO)
import System.Directory (getFileSize)
import System.Environment (getArgs)
import System.Exit (exitFailure)

foreign import ccall safe "endEventLogging" endEventLogging :: IO ()

main :: IO ()
main = do
  [path] <- getArgs
  _ <- forkIO $ forever (traceEventIO (replicate 4096 'e'))
  waitForSize path (1024 * 1024)
  endEventLogging
  stoppedAt <- getFileSize path
  threadDelay 1_000_000
  finalSize <- getFileSize path
  putStrLn ("stoppedAt=" <> show stoppedAt <> " finalSize=" <> show finalSize)
  unless (stoppedAt == finalSize) exitFailure

waitForSize :: FilePath -> Integer -> IO ()
waitForSize path limit = do
  size <- getFileSize path
  if size >= limit then pure () else threadDelay 10_000 >> waitForSize path limit
