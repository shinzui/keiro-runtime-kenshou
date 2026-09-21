module Kenshou.Diagnose.Threads
  ( ThreadEntry (..),
    ThreadDump (..),
    labelMe,
    forkLabelled,
    dumpThreads,
    installThreadDumpSignal,
  )
where

import Control.Concurrent (ThreadId, forkIO, myThreadId)
import Control.Exception (SomeException, try)
import Data.Aeson (FromJSON (..), ToJSON (..), object, toJSON, withObject, (.!=), (.:), (.:?), (.=))
import Data.ByteString.Lazy qualified as LazyByteString
import Data.IORef
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime, getCurrentTime)
import GHC.Conc (labelThread, listThreads, threadCapability, threadStatus)
import GHC.Conc.Sync (ThreadStatus (..), fromThreadId, threadLabel)
import GHC.Stack.CloneStack (StackEntry (..), cloneThreadStack, decode)
import Kenshou.Diagnose.Document (Diagnosis (..), DiagnosisKind (ThreadDumpDiagnosis), Generator (..), encodeDiagnosis)
import System.Directory (createDirectoryIfMissing)
import System.FilePath (takeFileName, (</>))
import System.Posix.Process (getProcessID)
import System.Posix.Signals (Handler (Catch), installHandler, sigUSR2)
import System.Timeout (timeout)

data ThreadEntry = ThreadEntry
  { id :: !Text,
    label :: !(Maybe Text),
    status :: !Text,
    blockReason :: !(Maybe Text),
    capability :: !Int,
    locked :: !Bool,
    stack :: ![Text]
  }
  deriving stock (Eq, Show)

data ThreadDump = ThreadDump
  { generatedAt :: !UTCTime,
    processId :: !Int,
    entries :: ![ThreadEntry],
    truncated :: !Bool
  }
  deriving stock (Eq, Show)

labelMe :: String -> IO ()
labelMe name = myThreadId >>= \thread -> labelThread thread name

forkLabelled :: String -> IO () -> IO ThreadId
forkLabelled name action = forkIO (labelMe name >> action)

dumpThreads :: Bool -> IO ThreadDump
dumpThreads captureStacks = do
  now <- getCurrentTime
  pid <- fromIntegral <$> getProcessID
  threads <- listThreads
  let selected = take 200 threads
  entries <- traverse (dumpOne captureStacks) selected
  pure (ThreadDump now pid entries (length threads > length selected))

dumpOne :: Bool -> ThreadId -> IO ThreadEntry
dumpOne captureStacks thread = do
  label <- fmap Text.pack <$> threadLabel thread
  status <- threadStatus thread
  (capability, locked) <- threadCapability thread
  stack <- if captureStacks then decodeStack thread else pure []
  let (statusText, block) = statusParts status
  pure (ThreadEntry (Text.pack (show (fromThreadId thread))) label statusText block capability locked stack)

statusParts :: ThreadStatus -> (Text, Maybe Text)
statusParts ThreadRunning = ("running", Nothing)
statusParts ThreadFinished = ("finished", Nothing)
statusParts ThreadDied = ("died", Nothing)
statusParts (ThreadBlocked reason) = ("blocked", Just (Text.pack (show reason)))

decodeStack :: ThreadId -> IO [Text]
decodeStack thread = do
  decoded <- timeout 250_000 (try @SomeException (cloneThreadStack thread >>= decode))
  pure case decoded of
    Just (Right entries) -> fmap renderStackEntry entries
    _ -> []

renderStackEntry :: StackEntry -> Text
renderStackEntry entry = Text.pack entry.moduleName <> "." <> Text.pack entry.functionName <> " (" <> Text.pack entry.srcLoc <> ", " <> Text.pack (show entry.closureType) <> ")"

installThreadDumpSignal :: FilePath -> Text -> IO ()
installThreadDumpSignal root role = do
  counter <- newIORef (0 :: Int)
  _ <- installHandler sigUSR2 (Catch (capture counter)) Nothing
  pure ()
  where
    capture counter = do
      _ <- forkIO do
        dump <- dumpThreads True
        number <- atomicModifyIORef' counter (\value -> let next = value + 1 in (next, next))
        createDirectoryIfMissing True (root </> "diagnosis")
        let path = root </> "diagnosis" </> ("threads-" <> Text.unpack role <> "-" <> show dump.processId <> "-" <> show number <> ".json")
            document = Diagnosis ThreadDumpDiagnosis (Text.pack (takeFileName root)) ("worker/" <> role) dump.generatedAt (Generator "kenshou-diagnose" "0.1.0.0" "thread-dump-v1") (toJSON dump)
        LazyByteString.writeFile path (encodeDiagnosis document)
      pure ()

instance ToJSON ThreadEntry where
  toJSON entry = object ["id" .= entry.id, "label" .= entry.label, "status" .= entry.status, "blockReason" .= entry.blockReason, "capability" .= entry.capability, "locked" .= entry.locked, "stack" .= entry.stack]

instance FromJSON ThreadEntry where
  parseJSON = withObject "ThreadEntry" \value -> ThreadEntry <$> value .: "id" <*> value .:? "label" <*> value .: "status" <*> value .:? "blockReason" <*> value .: "capability" <*> value .: "locked" <*> value .:? "stack" .!= []

instance ToJSON ThreadDump where
  toJSON dump = object ["generatedAt" .= dump.generatedAt, "processId" .= dump.processId, "entries" .= dump.entries, "truncated" .= dump.truncated]

instance FromJSON ThreadDump where
  parseJSON = withObject "ThreadDump" \value -> ThreadDump <$> value .: "generatedAt" <*> value .: "processId" <*> value .: "entries" <*> value .:? "truncated" .!= False
