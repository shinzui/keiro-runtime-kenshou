module Kenshou.Remote.Cell.Session.Build
  ( BuildOptions (..),
    BuiltSession (..),
    buildSession,
  )
where

import Data.Aeson (eitherDecode, encode)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Int (Int64)
import Data.List.NonEmpty qualified as NonEmpty
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (getCurrentTime)
import Kenshou.Core.Bundle (Registry)
import Kenshou.Core.Id (RunId, newRunId, renderRunId)
import Kenshou.Plan.RunPlan (PlannedRun (..), RunPlan (..))
import Kenshou.Remote.Cell.Docs (CellBuckets (..), CellDescriptor (..), WorkObject (..))
import Kenshou.Remote.Cell.Lease (CellRef (..))
import Kenshou.Remote.Cell.Prepare (Granularity, OtlpSink, PrepareOptions, Prepared (..), PreparedRun (..), Slice (..), SubmissionInputs (..), prepareForCell, sliceRuns, submissionFor)
import Kenshou.Remote.Cell.RouteRules (CellCapabilities, RoutingRule)
import Kenshou.Remote.Cell.Session.Journal (LeaseMode (..), RejectedRun (..), SessionJournal (..), SliceJournal (..), SliceState (..))
import Kenshou.Remote.Cell.Submit (workObjectFor)
import Kenshou.Remote.Cell.WorkJson (decodeWorkPlan, renderPreparedWork)
import Kenshou.Remote.Payload (PayloadDescriptor)
import Kenshou.Remote.Store (Bucket (..))

data BuildOptions = BuildOptions
  { preparation :: !PrepareOptions,
    granularity :: !Granularity,
    skipIncompatible :: !Bool,
    otlpSink :: !OtlpSink,
    rtsOptions :: !(Maybe Text),
    memoryMaxBytes :: !Int64,
    outputMaxBytes :: !Int64,
    minAgentVersion :: !Text
  }
  deriving stock (Eq, Show)

data BuiltSession = BuiltSession
  { journal :: !SessionJournal,
    workFiles :: ![(FilePath, LazyByteString.ByteString)]
  }
  deriving stock (Eq, Show)

-- Plan bytes are kept for their original digest, while each work file is
-- rendered from the original JSON so that provenance survives slicing.
buildSession :: Registry -> CellDescriptor -> Maybe CellCapabilities -> [RoutingRule] -> Map Text PayloadDescriptor -> BuildOptions -> Text -> RunId -> LazyByteString.ByteString -> IO (Either Text BuiltSession)
buildSession registry descriptor capabilities rules payloads options storeLabel leaseId planBytes =
  case eitherDecode planBytes of
    Left failure -> pure (Left ("run plan: " <> Text.pack failure))
    Right document -> case decodeWorkPlan document of
      Left problem -> pure (Left problem)
      Right plan -> do
        let prepared = prepareForCell registry descriptor capabilities rules payloads options.preparation plan
            rejected = [RejectedRun entry.runId (Text.pack (show reason)) | (entry, reason) <- prepared.rejected]
        if not options.skipIncompatible && not (null rejected)
          then pure (Left ("cell cannot run " <> Text.intercalate ", " [renderRunId run.runId <> ": " <> run.reason | run <- rejected]))
          else case sliceRuns options.granularity prepared.accepted of
            Left problem -> pure (Left problem)
            Right [] -> pure (Left "no compatible runs remain in the plan")
            Right slices -> case traverse (buildWork document payloads) slices of
              Left problem -> pure (Left problem)
              Right work -> do
                sessionId <- newRunId
                cellRuns <- traverse (const newRunId) slices
                now <- getCurrentTime
                let ref = CellRef descriptor.name (Bucket descriptor.buckets.control)
                    planHash = (workObjectFor "application/json" planBytes).sha256
                    results = Bucket descriptor.buckets.results
                    mkSlice slice (payload, path, bytes) cellRun = do
                      let inputs =
                            SubmissionInputs
                              cellRun
                              leaseId
                              sessionId
                              plan.planId
                              options.otlpSink
                              options.rtsOptions
                              options.memoryMaxBytes
                              options.outputMaxBytes
                              options.minAgentVersion
                              Nothing
                      submission <- submissionFor ref inputs payload slice (workObjectFor "application/json" bytes)
                      pure
                        ( SliceJournal slice.index cellRun (fmap (.ordinal) (NonEmpty.toList slice.entries)) (fmap (.runId) (NonEmpty.toList slice.entries)) slice.reset submission path SlicePlanned Nothing Nothing Nothing Nothing Nothing,
                          (path, bytes)
                        )
                pure do
                  if options.memoryMaxBytes <= 0 || options.outputMaxBytes <= 0
                    then Left "cell memory and output limits must be positive"
                    else pure ()
                  assembled <- sequence (zipWith3 mkSlice slices work cellRuns)
                  let journal =
                        SessionJournal
                          sessionId
                          descriptor.name
                          storeLabel
                          (Just descriptor.project)
                          ref.controlBucket.unBucket
                          results.unBucket
                          leaseId
                          Held
                          payloads
                          planHash
                          rejected
                          (fmap fst assembled)
                          now
                          now
                  pure (BuiltSession journal (fmap snd assembled))
  where
    buildWork document available slice = do
      payload <- maybe (Left ("slice payload label is absent: " <> slice.payloadLabel)) Right (Map.lookup slice.payloadLabel available)
      rendered <- renderPreparedWork document (NonEmpty.toList slice.entries)
      let path = "slice-" <> show slice.index <> "/work.json"
      pure (payload, path, encode rendered)
