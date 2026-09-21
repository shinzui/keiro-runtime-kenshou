module Kenshou.Core.Role.Dispatch (runWorker) where

import Control.Exception (SomeException, displayException, try)
import Data.Aeson qualified as Aeson
import Data.ByteString.Char8 qualified as ByteString
import Data.ByteString.Lazy.Char8 qualified as LazyByteString
import Data.IORef
import Data.Text qualified as Text
import GHC.IO.Handle (hDuplicate, hDuplicateTo)
import Kenshou.Core.Bundle (Registry, lookupRole)
import Kenshou.Core.Log (nullLogger)
import Kenshou.Core.Role
import System.Exit (ExitCode (..))
import System.IO (Handle, hFlush, hIsEOF, stderr, stdin, stdout)

runWorker :: Registry -> RoleName -> IO ExitCode
runWorker registry roleName = case lookupRole registry roleName of
  Nothing -> pure (ExitFailure 2)
  Just role -> do
    channel <- hDuplicate stdout
    hDuplicateTo stderr stdout
    initial <- receiveControl stdin
    case initial of
      Just (CtlInit workerInit) | workerInit.role == roleName -> do
        parentGone <- newIORef False
        let receive = receiveControl stdin >>= \case Nothing -> writeIORef parentGone True >> pure Nothing; message -> pure message
        outcome <- try (role.run (RoleContext workerInit receive (sendWorker channel) nullLogger)) :: IO (Either SomeException ())
        case outcome of
          Left exception -> sendWorker channel (WrkError (Text.pack (displayException exception))) >> pure (ExitFailure 70)
          Right () -> do
            orphaned <- readIORef parentGone
            if orphaned then pure (ExitFailure 75) else sendWorker channel (WrkDone Nothing) >> pure ExitSuccess
      _ -> pure (ExitFailure 2)

receiveControl :: Handle -> IO (Maybe ControlMessage)
receiveControl handle = do
  atEnd <- hIsEOF handle
  if atEnd
    then pure Nothing
    else do
      line <- ByteString.hGetLine handle
      pure (either (const Nothing) Just (Aeson.eitherDecodeStrict' line))

sendWorker :: Handle -> WorkerMessage -> IO ()
sendWorker handle message = LazyByteString.hPutStrLn handle (Aeson.encode message) >> hFlush handle
