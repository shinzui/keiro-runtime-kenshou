module Kenshou.Remote.Perf.Lock (withPerformanceLock) where

import Control.Concurrent.MVar
import Control.Exception (bracket, bracket_)
import Data.Map.Strict qualified as Map
import System.Directory (canonicalizePath)
import System.FilePath ((</>))
import System.IO (SeekMode (AbsoluteSeek))
import System.IO.Unsafe (unsafePerformIO)
import System.Posix.IO (LockRequest (WriteLock), OpenFileFlags (creat), OpenMode (ReadWrite), closeFd, defaultFileFlags, openFd, setLock)

-- POSIX record locks serialize processes, while the MVar closes their same-
-- process loophole. Neither lock leaves stale ownership after client death.
-- Canonical dependency owner: mori://haskell/unix (artifact URI pending),
-- project-relative System/Posix/IO/Common.hsc.
withPerformanceLock :: FilePath -> IO a -> IO a
withPerformanceLock directory action = do
  canonical <- canonicalizePath directory
  lock <- modifyMVar locks \known -> case Map.lookup canonical known of
    Just existing -> pure (known, existing)
    Nothing -> do
      created <- newMVar ()
      pure (Map.insert canonical created known, created)
  bracket_ (claim lock) (putMVar lock ()) $
    bracket (openFd (canonical </> ".client.lock") ReadWrite defaultFileFlags {creat = Just 0o600}) closeFd \fd -> do
      setLock fd (WriteLock, AbsoluteSeek, 0, 0)
      action
  where
    claim lock = tryTakeMVar lock >>= maybe (ioError (userError "performance session is already controlled by another client")) pure

{-# NOINLINE locks #-}
locks :: MVar (Map.Map FilePath (MVar ()))
locks = unsafePerformIO (newMVar Map.empty)
