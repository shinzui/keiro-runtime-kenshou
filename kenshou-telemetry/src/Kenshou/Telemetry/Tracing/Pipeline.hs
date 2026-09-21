module Kenshou.Telemetry.Tracing.Pipeline
  ( PipelineStats,
    PipelineSnapshot (..),
    LatencySummary (..),
    newPipelineStats,
    countingProcessor,
    instrumentProcessorSuccess,
    instrumentExporter,
    snapshotPipeline,
  )
where

import Control.Exception (displayException, onException)
import Control.Monad (void)
import Data.Aeson (ToJSON (..), object, (.=))
import Data.HashMap.Strict qualified as HashMap
import Data.IORef
import Data.List (sort)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Vector qualified as Vector
import GHC.Clock (getMonotonicTimeNSec)
import OpenTelemetry.Exporter.Span (ExportResult (..), SpanExporter (..))
import OpenTelemetry.Internal.Common.Types (FlushResult (FlushSuccess), ShutdownResult (ShutdownSuccess))
import OpenTelemetry.Processor.Span (SpanProcessor (..))

data PipelineStats = PipelineStats
  { started :: IORef Int,
    ended :: IORef Int,
    exportedOk :: IORef Int,
    exportFailed :: IORef Int,
    exportCalls :: IORef Int,
    exportLatencies :: IORef [Integer],
    maxQueueDepth :: IORef Int,
    lastExportError :: IORef (Maybe Text)
  }

data LatencySummary = LatencySummary {p50 :: Integer, p99 :: Integer, maximum :: Integer}
  deriving stock (Eq, Show)

data PipelineSnapshot = PipelineSnapshot
  { spansStarted :: Int,
    spansEnded :: Int,
    spansExportedOk :: Int,
    spansExportFailed :: Int,
    spansDropped :: Int,
    maxQueueDepth :: Int,
    exportCalls :: Int,
    exportLatencyNs :: LatencySummary,
    lastExportError :: Maybe Text
  }
  deriving stock (Eq, Show)

instance ToJSON LatencySummary where
  toJSON summary = object ["p50" .= summary.p50, "p99" .= summary.p99, "max" .= summary.maximum]

instance ToJSON PipelineSnapshot where
  toJSON snapshot =
    object
      [ "spansStarted" .= snapshot.spansStarted,
        "spansEnded" .= snapshot.spansEnded,
        "spansExportedOk" .= snapshot.spansExportedOk,
        "spansExportFailed" .= snapshot.spansExportFailed,
        "spansDropped" .= snapshot.spansDropped,
        "maxQueueDepth" .= snapshot.maxQueueDepth,
        "exportCalls" .= snapshot.exportCalls,
        "exportLatencyNs" .= snapshot.exportLatencyNs,
        "lastExportError" .= snapshot.lastExportError
      ]

newPipelineStats :: IO PipelineStats
newPipelineStats = PipelineStats <$> newIORef 0 <*> newIORef 0 <*> newIORef 0 <*> newIORef 0 <*> newIORef 0 <*> newIORef [] <*> newIORef 0 <*> newIORef Nothing

countingProcessor :: PipelineStats -> SpanProcessor
countingProcessor stats =
  SpanProcessor
    { spanProcessorOnStart = \_ _ -> increment stats.started 1,
      spanProcessorOnEnd = \_ -> increment stats.ended 1 >> updateQueueHighWater stats,
      spanProcessorShutdown = pure ShutdownSuccess,
      spanProcessorForceFlush = pure FlushSuccess
    }

instrumentProcessorSuccess :: PipelineStats -> SpanProcessor -> SpanProcessor
instrumentProcessorSuccess stats processor =
  processor
    { spanProcessorOnEnd = \spanValue -> processor.spanProcessorOnEnd spanValue >> increment stats.exportedOk 1
    }

instrumentExporter :: PipelineStats -> SpanExporter -> SpanExporter
instrumentExporter stats exporter =
  exporter
    { spanExporterExport = \batch -> do
        let spanCount = sum (fmap Vector.length (HashMap.elems batch))
        startedAt <- getMonotonicTimeNSec
        increment stats.exportCalls 1
        result <-
          exporter.spanExporterExport batch
            `onException` do
              increment stats.exportFailed spanCount
              writeIORef stats.lastExportError (Just "exporter raised an exception")
        endedAt <- getMonotonicTimeNSec
        modifyIORef' stats.exportLatencies (fromIntegral (endedAt - startedAt) :)
        case result of
          Success -> increment stats.exportedOk spanCount
          Failure exception -> do
            increment stats.exportFailed spanCount
            writeIORef stats.lastExportError (fmap (Text.pack . displayException) exception)
        pure result
    }

snapshotPipeline :: PipelineStats -> IO PipelineSnapshot
snapshotPipeline stats = do
  spansStarted <- readIORef stats.started
  spansEnded <- readIORef stats.ended
  spansExportedOk <- readIORef stats.exportedOk
  spansExportFailed <- readIORef stats.exportFailed
  exportCalls <- readIORef stats.exportCalls
  latencies <- readIORef stats.exportLatencies
  maxQueueDepth <- readIORef stats.maxQueueDepth
  lastExportError <- readIORef stats.lastExportError
  let spansDropped = max 0 (spansEnded - spansExportedOk - spansExportFailed)
  pure
    PipelineSnapshot
      { spansStarted,
        spansEnded,
        spansExportedOk,
        spansExportFailed,
        spansDropped,
        maxQueueDepth,
        exportCalls,
        exportLatencyNs = summarize latencies,
        lastExportError
      }

increment :: IORef Int -> Int -> IO ()
increment ref amount = void (atomicModifyIORef' ref (\value -> let updated = value + amount in (updated, updated)))

updateQueueHighWater :: PipelineStats -> IO ()
updateQueueHighWater stats = do
  ended <- readIORef stats.ended
  exportedOk <- readIORef stats.exportedOk
  exportFailed <- readIORef stats.exportFailed
  let queued = max 0 (ended - exportedOk - exportFailed)
  atomicModifyIORef' stats.maxQueueDepth (\high -> (max high queued, ()))

summarize :: [Integer] -> LatencySummary
summarize [] = LatencySummary 0 0 0
summarize values =
  let ordered = sort values
   in LatencySummary (quantile 0.50 ordered) (quantile 0.99 ordered) (last ordered)

quantile :: Double -> [Integer] -> Integer
quantile fraction values = values !! min (length values - 1) (floor (fraction * fromIntegral (length values - 1)))
