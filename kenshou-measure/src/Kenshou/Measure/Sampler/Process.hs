{-# LANGUAGE CPP #-}
{-# LANGUAGE ForeignFunctionInterface #-}

module Kenshou.Measure.Sampler.Process
  ( ProcessSample (..),
    parseProcSample,
    readProcessSample,
    ProcessSampler,
    openProcessSampler,
    sampleProcess,
    closeProcessSampler,
  )
where

import Data.Char (isSpace)
import Data.List (find)
import Data.Text (Text)
import Data.Text qualified as Text
import Kenshou.Measure.Sampler.Csv
import System.CPUTime (getCPUTime)
import System.Directory (listDirectory)
import Text.Read (readMaybe)

#ifdef linux_HOST_OS
import Data.Text.IO qualified as Text
#endif

#ifdef darwin_HOST_OS
import Foreign
import Foreign.C.Types

foreign import ccall unsafe "kenshou_proc_taskinfo" c_procTaskInfo :: Ptr Word64 -> Ptr CInt -> IO CInt
#endif

data ProcessSample = ProcessSample
  { rssBytes :: Maybe Word64,
    rssMaxBytes :: Maybe Word64,
    osThreads :: Maybe Word64,
    openFds :: Maybe Word64,
    cpuUserNs :: Maybe Word64,
    cpuSystemNs :: Maybe Word64,
    cpuTotalNs :: Maybe Word64,
    voluntaryContextSwitches :: Maybe Word64,
    nonvoluntaryContextSwitches :: Maybe Word64
  }
  deriving stock (Eq, Show)

newtype ProcessSampler = ProcessSampler CsvWriter

openProcessSampler :: FilePath -> IO ProcessSampler
openProcessSampler path =
  ProcessSampler
    <$> openCsv
      path
      [ "t_mono_ns",
        "t_wall_ms",
        "phase",
        "rss_bytes",
        "rss_max_bytes",
        "os_threads",
        "open_fds",
        "cpu_user_ns",
        "cpu_system_ns",
        "cpu_total_ns",
        "voluntary_ctxt_switches",
        "nonvoluntary_ctxt_switches"
      ]

sampleProcess :: ProcessSampler -> [Text] -> IO ()
sampleProcess (ProcessSampler writer) prefix = do
  sample <- readProcessSample
  let field = maybe "" (Text.pack . show)
  appendCsv
    writer
    ( prefix
        <> fmap
          field
          [ sample.rssBytes,
            sample.rssMaxBytes,
            sample.osThreads,
            sample.openFds,
            sample.cpuUserNs,
            sample.cpuSystemNs,
            sample.cpuTotalNs,
            sample.voluntaryContextSwitches,
            sample.nonvoluntaryContextSwitches
          ]
    )

closeProcessSampler :: ProcessSampler -> IO ()
closeProcessSampler (ProcessSampler writer) = closeCsv writer

readProcessSample :: IO ProcessSample
#ifdef linux_HOST_OS
readProcessSample = do
  stat <- Text.readFile "/proc/self/stat"
  status <- Text.readFile "/proc/self/status"
  fds <- listDirectory "/proc/self/fd"
  pure (parseProcSample stat status (fromIntegral (length fds)))
#elif darwin_HOST_OS
readProcessSample = do
  total <- (`div` 1_000) <$> getCPUTime
  fds <- listDirectory "/dev/fd"
  alloca \rssPointer -> alloca \threadsPointer -> do
    ok <- c_procTaskInfo rssPointer threadsPointer
    rss <- if ok == 0 then pure Nothing else Just <$> peek rssPointer
    threads <- if ok == 0 then pure Nothing else Just . fromIntegral <$> peek threadsPointer
    pure (ProcessSample rss Nothing threads (Just (fromIntegral (length fds))) Nothing Nothing (Just (fromIntegral total)) Nothing Nothing)
#else
readProcessSample = do
  total <- (`div` 1_000) <$> getCPUTime
  pure (ProcessSample Nothing Nothing Nothing Nothing Nothing Nothing (Just (fromIntegral total)) Nothing Nothing)
#endif

parseProcSample :: Text -> Text -> Word64 -> ProcessSample
parseProcSample stat status fdCount =
  ProcessSample
    { rssBytes = kilobytes "VmRSS:",
      rssMaxBytes = kilobytes "VmHWM:",
      osThreads = statusNumber "Threads:",
      openFds = Just fdCount,
      cpuUserNs = ticksToNs <$> statNumber 11,
      cpuSystemNs = ticksToNs <$> statNumber 12,
      cpuTotalNs = (+) <$> (ticksToNs <$> statNumber 11) <*> (ticksToNs <$> statNumber 12),
      voluntaryContextSwitches = statusNumber "voluntary_ctxt_switches:",
      nonvoluntaryContextSwitches = statusNumber "nonvoluntary_ctxt_switches:"
    }
  where
    -- Linux kernels expose USER_HZ as 100 on supported benchmark hosts.
    ticksToNs value = value * 10_000_000
    afterCommand = snd (Text.breakOnEnd ") " stat)
    statFields = Text.words afterCommand
    statNumber index = atMay statFields index >>= readWord
    statusLines = Text.lines status
    statusValue key = Text.strip . Text.drop (Text.length key) <$> find (Text.isPrefixOf key) statusLines
    statusNumber key = statusValue key >>= readWord . Text.takeWhile (not . isSpace)
    kilobytes key = (* 1_024) <$> statusNumber key

atMay :: [value] -> Int -> Maybe value
atMay values index = case drop index values of value : _ -> Just value; [] -> Nothing

readWord :: Text -> Maybe Word64
readWord = readMaybe . Text.unpack
