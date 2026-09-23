module Kenshou.Suite.Kiroku.Soak.Retention (scenarios) where

import Control.Concurrent (threadDelay)
import Data.Aeson (object, (.=))
import Data.Int (Int64)
import Data.Text qualified as Text
import Data.Time.Clock (getCurrentTime, secondsToDiffTime)
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Hasql.Statement qualified as Statement
import Kenshou.Core.Context (RunContext (..), SummarySection (..), putSummary)
import Kenshou.Core.Knob (knobInt, mkKnobName)
import Kenshou.Core.Outcome (Outcome (..))
import Kenshou.Core.Scenario (Scenario, ScenarioReport (..), failedWith, passed)
import Kenshou.Diagnose.Leak (LeakReport (..), judgeLeaks)
import Kenshou.Measure.Knobs (loadModelFromKnobs)
import Kenshou.Measure.Load (LoadReport (..), Operation (..), runLoad)
import Kenshou.Measure.Recorder (ErrorCause (..), OpName (..), OpResult (..))
import Kenshou.Measure.Sampler.Postgres (PgSamplerConfig (..))
import Kenshou.Measure.Session (MeasureConfig (..), MeasurementReport (..), measureConfigFromKnobs, measuredOutcome, phasePlanFromCore, withMeasurement)
import Kenshou.Suite.Kiroku.Fixture.Store (withKirokuStore)
import Kenshou.Suite.Kiroku.Soak.Common (SoakDefinition (..), SoakProfile, applyLeakVerdict, effectivePhases, soakLeakSpec, soakPair)
import Kiroku.Store hiding (id, withKirokuStore)

scenarios :: [Scenario]
scenarios = soakPair (SoakDefinition "retention" "lease-churn" "Churns retention leases while hard-delete attempts and pruning run." runLeaseChurn)

runLeaseChurn :: SoakProfile -> RunContext -> IO ScenarioReport
runLeaseChurn profile context = case (loadModelFromKnobs context.knobs, measureConfigFromKnobs context (phasePlanFromCore (effectivePhases profile context))) of
  (Left reason, _) -> pure (failedWith ["invalid-load-config"] reason)
  (_, Left reason) -> pure (failedWith ["invalid-measure-config"] reason)
  (Right loadModel, Right baseConfig) -> withKirokuStore context \store -> do
    let name = either (error . show) id . mkKnobName
        verifyMinutes = fromIntegral (knobInt context.knobs (name "soak.verify-interval-minutes")) :: Int
        duration = either (error . show) id (mkHistoryRetentionLeaseDuration (secondsToDiffTime 1))
        owner = either (error . show) id (mkHistoryRetentionLeaseOwner "lease-churn")
        reason = either (error . show) id (mkHistoryRetentionLeaseReason "soak")
        request = HistoryRetentionLeaseRequest owner reason duration
        config = baseConfig {postgres = fmap (\pg -> pg {relations = ["kiroku.history_retention_leases"]}) baseConfig.postgres}
        operation _ sequenceNumber = do
          let stream = StreamName ("lease-churn-" <> Text.pack (show sequenceNumber))
              event = EventData Nothing (EventType "LeaseChurn") (object ["sequence" .= sequenceNumber]) Nothing Nothing Nothing
          appended <- runStoreIO store (appendToStream stream NoStream [event])
          case appended of
            Left err -> pure (OpFailed (ErrorCause (Text.pack (show err))))
            Right _ -> do
              acquired <- runStoreIO store (acquireHistoryRetentionLease request)
              case acquired of
                Left err -> pure (OpFailed (ErrorCause (Text.pack (show err))))
                Right lease -> do
                  let handle = HistoryRetentionLeaseHandle lease.leaseId owner
                  blocked <- runStoreIO store (hardDeleteStream stream)
                  renewed <- runStoreIO store (renewHistoryRetentionLease handle duration)
                  released <- if sequenceNumber `mod` 100 == 0 then pure Nothing else Just <$> runStoreIO store (releaseHistoryRetentionLease handle)
                  _ <- runStoreIO store (hardDeleteStream stream)
                  if sequenceNumber `mod` 1000 == 0
                    then do
                      now <- getCurrentTime
                      _ <- runStoreIO store (pruneHistoryRetentionLeases now)
                      pure ()
                    else pure ()
                  bounded <-
                    if sequenceNumber > 0 && sequenceNumber `mod` fromIntegral (max 1000 (verifyMinutes * 60 * 200)) == 0
                      then do
                        observed <- Pool.use store.pool (Session.statement () leaseCountStatement)
                        pure (either (const False) (< 10000) observed)
                      else pure True
                  let active = case blocked of Left (HistoryRetentionActive _ _) -> True; _ -> False
                      renewal = case renewed of Right (Right leaseValue) -> leaseValue.state == HistoryRetentionLeaseActive; _ -> False
                      releaseOk = case released of Nothing -> True; Just (Right (HistoryRetentionReleased _)) -> True; _ -> False
                  pure (if active && renewal && releaseOk && bounded then OpOk 1 else OpFailed (ErrorCause "lease-contract-or-growth"))
    (_, measurement) <- withMeasurement context config \session -> runLoad session loadModel (Operation (OpName "lease-churn") operation)
    threadDelay 2000000
    now <- getCurrentTime
    pruned <- runStoreIO store (pruneHistoryRetentionLeases now)
    remaining <- Pool.use store.pool (Session.statement () leaseCountStatement)
    let completed = sum [load.completed | load <- measurement.loads]
        failed = sum [load.failed | load <- measurement.loads]
        rowCount = either (const Nothing) Just remaining
        base = if completed > 0 && failed == 0 && rowCount == Just 0 && either (const False) (const True) pruned then passed else failedWith ["lease-churn-contract-or-growth"] ("completed=" <> Text.pack (show completed) <> ", failed=" <> Text.pack (show failed) <> ", remaining-leases=" <> Text.pack (show rowCount))
        measured = if base.outcome == Passed then base {outcome = measuredOutcome measurement base.outcome} else base
    putSummary context Verdicts "lease-churn" (object ["completed" .= completed, "failed" .= failed, "remainingLeases" .= rowCount, "pruned" .= show pruned])
    leak <- judgeLeaks context (soakLeakSpec profile)
    pure (applyLeakVerdict leak.verdict measured)

leaseCountStatement :: Statement.Statement () Int64
leaseCountStatement = Statement.preparable "select count(*) from kiroku.history_retention_leases" Encoders.noParams (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.int8)))
