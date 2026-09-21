{-# LANGUAGE CPP #-}

module Kenshou.Measure.Sampler.Host
  ( HostSample (..),
    parseHostSample,
    HostSampler,
    openHostSampler,
    sampleHost,
    closeHostSampler,
  )
where

import Data.List (find)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Word (Word64)
import Kenshou.Measure.Sampler.Csv
import Text.Read (readMaybe)

#ifdef linux_HOST_OS
import Data.Text.IO qualified as Text
#endif

data HostSample = HostSample
  { cpuUser :: Maybe Word64,
    cpuNice :: Maybe Word64,
    cpuSystem :: Maybe Word64,
    cpuIdle :: Maybe Word64,
    cpuIowait :: Maybe Word64,
    cpuIrq :: Maybe Word64,
    cpuSoftirq :: Maybe Word64,
    cpuSteal :: Maybe Word64,
    loadAverage1 :: Maybe Double,
    memAvailableBytes :: Maybe Word64
  }
  deriving stock (Eq, Show)

newtype HostSampler = HostSampler CsvWriter

openHostSampler :: FilePath -> IO (Maybe HostSampler)
#ifdef linux_HOST_OS
openHostSampler path = Just . HostSampler <$> openCsv path
  [ "t_mono_ns", "t_wall_ms", "phase", "cpu_user", "cpu_nice", "cpu_system", "cpu_idle", "cpu_iowait",
    "cpu_irq", "cpu_softirq", "cpu_steal", "loadavg1", "mem_available_bytes"
  ]
#else
openHostSampler _ = pure Nothing
#endif

sampleHost :: HostSampler -> [Text] -> IO ()
#ifdef linux_HOST_OS
sampleHost (HostSampler writer) prefix = do
  stat <- Text.readFile "/proc/stat"
  loadavg <- Text.readFile "/proc/loadavg"
  meminfo <- Text.readFile "/proc/meminfo"
  let sample = parseHostSample stat loadavg meminfo
      integral = maybe "" (Text.pack . show)
      floating = maybe "" (Text.pack . show)
  appendCsv writer (prefix <> fmap integral
    [ sample.cpuUser, sample.cpuNice, sample.cpuSystem, sample.cpuIdle, sample.cpuIowait,
      sample.cpuIrq, sample.cpuSoftirq, sample.cpuSteal
    ] <> [floating sample.loadAverage1, integral sample.memAvailableBytes])
#else
sampleHost _ _ = pure ()
#endif

closeHostSampler :: HostSampler -> IO ()
closeHostSampler (HostSampler writer) = closeCsv writer

parseHostSample :: Text -> Text -> Text -> HostSample
parseHostSample stat loadavg meminfo =
  HostSample
    { cpuUser = cpu 0,
      cpuNice = cpu 1,
      cpuSystem = cpu 2,
      cpuIdle = cpu 3,
      cpuIowait = cpu 4,
      cpuIrq = cpu 5,
      cpuSoftirq = cpu 6,
      cpuSteal = cpu 7,
      loadAverage1 = case Text.words loadavg of value : _ -> readDouble value; [] -> Nothing,
      memAvailableBytes = (* 1_024) <$> memAvailable
    }
  where
    cpuFields = maybe [] (drop 1 . Text.words) (find (Text.isPrefixOf "cpu ") (Text.lines stat))
    cpu index = case drop index cpuFields of value : _ -> readWord value; [] -> Nothing
    memAvailable = do
      line <- find (Text.isPrefixOf "MemAvailable:") (Text.lines meminfo)
      case Text.words line of _ : value : _ -> readWord value; _ -> Nothing

readWord :: Text -> Maybe Word64
readWord = readMaybe . Text.unpack

readDouble :: Text -> Maybe Double
readDouble = readMaybe . Text.unpack
