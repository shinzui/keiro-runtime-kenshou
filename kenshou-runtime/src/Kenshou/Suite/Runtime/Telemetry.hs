module Kenshou.Suite.Runtime.Telemetry
  ( RoleTelemetry (..),
    noRoleTelemetry,
    withRoleTelemetry,
    SpanRecord (..),
    readSpanRecords,
  )
where

import Control.Exception (finally)
import Control.Monad (forM, void)
import Data.Aeson (FromJSON, ToJSON, eitherDecodeStrict')
import Data.Aeson qualified as Aeson
import Data.ByteString qualified as ByteString
import Data.ByteString.Char8 qualified as ByteString.Char8
import Data.ByteString.Lazy qualified as LazyByteString
import Data.HashMap.Strict qualified as HashMap
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Word (Word64)
import GHC.Generics (Generic)
import Keiro.Telemetry (newKeiroMetrics)
import Kenshou.Core.Dimension (MetricsArm (..), TracingArm (..))
import Kenshou.Core.Role (RoleContext (..), WorkerInit (..))
import Kenshou.Suite.Runtime.System.Trace (Signals (..), TraceSabotage, noSignals)
import Kenshou.Telemetry (TelemetryHandles (..), TelemetrySpec (..), telemetrySpecFromWorker, withTelemetry)
import Kenshou.Telemetry.Tracing.Probe (SpanView (..), readSpans)
import OpenTelemetry.Attributes (Attribute (..), PrimitiveAttribute (..), getAttributeMap)
import OpenTelemetry.Trace.Id (Base (Base16), spanIdBaseEncodedText, traceIdBaseEncodedText)
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, doesFileExist, listDirectory)
import System.FilePath ((</>))
import System.IO (IOMode (WriteMode), withFile)

-- | What one role process passes to the runtime components it runs. Every
-- field is empty when both telemetry dimensions are @off@.
data RoleTelemetry = RoleTelemetry
  { signals :: !Signals,
    handles :: !(Maybe TelemetryHandles)
  }

noRoleTelemetry :: RoleTelemetry
noRoleTelemetry = RoleTelemetry noSignals Nothing

-- | Give a role process its own providers for the run's telemetry
-- dimensions. The child writes its telemetry summary and, when the
-- in-memory span probe exists, every retained span to
-- @children/<instance>/spans.jsonl@ when it stops, so that cross-process
-- trace assertions can read all processes' spans after the run.
withRoleTelemetry :: TraceSabotage -> (Text -> Text -> IO ()) -> RoleContext -> (RoleTelemetry -> IO a) -> IO a
withRoleTelemetry sabotage observe context action = case telemetrySpecFromWorker context directory of
  Left problem -> ioError (userError ("invalid role telemetry: " <> Text.unpack problem))
  Right spec
    | spec.tracing == TracingOff && spec.metrics == MetricsOff -> action noRoleTelemetry {signals = noSignals {observe}}
    | otherwise -> withTelemetry spec \handles -> do
        metrics <- traverse newKeiroMetrics handles.meter
        action (RoleTelemetry (Signals handles.tracer handles.tracerProvider metrics sabotage observe) (Just handles)) `finally` writeSpans handles
  where
    directory = context.init.outDir </> "children" </> Text.unpack (Text.replace "/" "-" context.init.instanceName)
    writeSpans handles = case handles.spans of
      Nothing -> pure ()
      Just probe -> do
        void handles.flushTelemetry
        views <- readSpans probe
        createDirectoryIfMissing True directory
        withFile (directory </> "spans.jsonl") WriteMode \file ->
          mapM_ (\view -> LazyByteString.hPut file (Aeson.encode (spanRecord context.init.instanceName view) <> "\n")) views

-- | One finished span as a role process exported it.
data SpanRecord = SpanRecord
  { process :: !Text,
    name :: !Text,
    kind :: !Text,
    traceId :: !Text,
    spanId :: !Text,
    parentSpanId :: !(Maybe Text),
    attributes :: !(Map Text Text),
    startNs :: !Word64,
    endNs :: !Word64
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

spanRecord :: Text -> SpanView -> SpanRecord
spanRecord process view =
  SpanRecord
    { process,
      name = view.name,
      kind = Text.pack (show view.kind),
      traceId = traceIdBaseEncodedText Base16 view.traceId,
      spanId = spanIdBaseEncodedText Base16 view.spanId,
      parentSpanId = spanIdBaseEncodedText Base16 <$> view.parentSpanId,
      attributes = Map.fromList [(key, renderAttribute value) | (key, value) <- HashMap.toList (getAttributeMap view.attributes)],
      startNs = view.startNs,
      endNs = view.endNs
    }
  where
    renderAttribute = \case
      AttributeValue primitive -> renderPrimitive primitive
      AttributeArray values -> Text.intercalate "," (fmap renderPrimitive values)
    renderPrimitive = \case
      TextAttribute value -> value
      BoolAttribute value -> if value then "true" else "false"
      DoubleAttribute value -> Text.pack (show value)
      IntAttribute value -> Text.pack (show value)

-- | Every span exported by every role process of a run.
readSpanRecords :: FilePath -> IO [SpanRecord]
readSpanRecords outDir = do
  let children = outDir </> "children"
  present <- doesDirectoryExist children
  if not present
    then pure []
    else do
      entries <- listDirectory children
      fmap concat . forM entries $ \entry -> do
        let path = children </> entry </> "spans.jsonl"
        exists <- doesFileExist path
        if not exists
          then pure []
          else do
            contents <- ByteString.readFile path
            pure [record | line <- ByteString.Char8.lines contents, not (ByteString.null line), Right record <- [eitherDecodeStrict' line]]
