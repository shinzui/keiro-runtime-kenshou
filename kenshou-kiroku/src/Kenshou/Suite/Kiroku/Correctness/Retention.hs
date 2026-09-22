module Kenshou.Suite.Kiroku.Correctness.Retention (scenarios) where

import Control.Concurrent (threadDelay)
import Data.Aeson (object)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Time.Clock (secondsToDiffTime)
import Data.Vector qualified as Vector
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Errors qualified as Errors
import Hasql.Pool qualified as Pool
import Hasql.Statement qualified as Statement
import Hasql.Transaction qualified as Tx
import Hasql.Transaction.Sessions qualified as TxSessions
import Kenshou.Core.Context (RunContext (..))
import Kenshou.Core.Dimension
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Knob (Allowed (..), KnobSpec (..), KnobType (..), KnobValue (..), knobInt, mkKnobName)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Scenario
import Kenshou.Suite.Kiroku.Correctness.Append (recordCells)
import Kenshou.Suite.Kiroku.Fixture.Store (withKirokuStore)
import Kenshou.Suite.Kiroku.Knobs (storeKnobs)
import Kiroku.Store hiding (id, withKirokuStore)

scenarios :: [Scenario]
scenarios = [leasesBlockHardDelete]

leasesBlockHardDelete :: Scenario
leasesBlockHardDelete =
  Scenario
    { id = either (error . show) id (parseScenarioId "kiroku/retention/correctness/leases-block-hard-delete"),
      revision = 1,
      summary = "Checks active lease protection, raw SQL guard, release and passive expiry.",
      tier = TierSmoke,
      placement = PlaceEither,
      knobs = storeKnobs <> [KnobSpec (either (error . show) id (mkKnobName "kiroku.retention.lease-seconds")) "Lease duration in seconds" KnobInt (VInt 5) (IntRange 1 3600) [VInt 1, VInt 5]],
      dimensions =
        DimensionSupport
          { tracing = Supported (Support (TracingOff :| []) TracingOff),
            metrics = Supported (Support (MetricsOff :| []) MetricsOff),
            pgDurability = Supported (Support (PgFsyncOff :| [PgDurable]) PgFsyncOff),
            pgVersion = Supported (Support (Pg18 :| [Pg17]) Pg18)
          },
      phases = zeroPhases,
      requires = noEnvironment {postgres = Just (PostgresRequirement [SchemaKiroku] [] False)},
      knownDefect = Nothing,
      run = runRetention
    }

runRetention :: RunContext -> IO ScenarioReport
runRetention context = withKirokuStore context \store -> do
  let seconds = knobInt context.knobs (either (error . show) id (mkKnobName "kiroku.retention.lease-seconds"))
      validated = either (error . show) id
      duration = validated (mkHistoryRetentionLeaseDuration (secondsToDiffTime (fromIntegral seconds)))
      owner = validated (mkHistoryRetentionLeaseOwner "retention-owner")
      otherOwner = validated (mkHistoryRetentionLeaseOwner "other-owner")
      reason = validated (mkHistoryRetentionLeaseReason "verification")
      request = HistoryRetentionLeaseRequest owner reason duration
      stream = StreamName "retention-release"
      expiredStream = StreamName "retention-expiry"
      event = EventData Nothing (EventType "Retention") (object []) Nothing Nothing Nothing
  seeded <- runStoreIO store (appendToStream stream NoStream [event])
  acquired <- runStoreIO store (acquireHistoryRetentionLease request)
  blocked <- runStoreIO store (hardDeleteStream stream)
  raw <- Pool.use store.pool (TxSessions.transaction TxSessions.ReadCommitted TxSessions.Write (Tx.sql "SET LOCAL kiroku.enable_hard_deletes = 'on'" >> Tx.statement () rawDeleteStatement))
  untouched <- runStoreIO store (readStreamForward stream (StreamVersion 0) 10)
  mismatch <- case acquired of
    Right lease -> runStoreIO store (renewHistoryRetentionLease (HistoryRetentionLeaseHandle lease.leaseId otherOwner) duration)
    Left _ -> pure (Left (ConnectionError "lease acquisition failed"))
  released <- case acquired of
    Right lease -> runStoreIO store (releaseHistoryRetentionLease (HistoryRetentionLeaseHandle lease.leaseId owner))
    Left _ -> pure (Left (ConnectionError "lease acquisition failed"))
  deleted <- runStoreIO store (hardDeleteStream stream)
  seededExpiry <- runStoreIO store (appendToStream expiredStream NoStream [event])
  acquiredExpiry <- runStoreIO store (acquireHistoryRetentionLease request)
  stillBlocked <- runStoreIO store (hardDeleteStream expiredStream)
  threadDelay (fromIntegral (seconds + 1) * 1000000)
  expiredDeleted <- runStoreIO store (hardDeleteStream expiredStream)
  let blockedOne = \case Left (HistoryRetentionActive actual conflict) -> actual == stream && conflict.activeLeaseCount == 1; _ -> False
      blockedExpiry = \case Left (HistoryRetentionActive actual conflict) -> actual == expiredStream && conflict.activeLeaseCount == 1; _ -> False
      sqlState = \case
        Left (Pool.SessionUsageError (Errors.StatementSessionError _ _ _ _ _ (Errors.ServerStatementError (Errors.ServerError actual _ _ _ _)))) -> actual == "KR001"
        _ -> False
      cells =
        [ ("duration-rejects-zero", case mkHistoryRetentionLeaseDuration (secondsToDiffTime 0) of Left _ -> True; _ -> False),
          ("duration-rejects-over-hour", case mkHistoryRetentionLeaseDuration (secondsToDiffTime 3601) of Left _ -> True; _ -> False),
          ("protected-stream-seeded", case seeded of Right result -> result.streamVersion == StreamVersion 1; _ -> False),
          ("lease-acquired", case acquired of Right lease -> lease.state == HistoryRetentionLeaseActive; _ -> False),
          ("hard-delete-blocked-by-one-lease", blockedOne blocked),
          ("raw-delete-raises-kr001", sqlState raw),
          ("blocked-delete-preserves-events", case untouched of Right rows -> Vector.length rows == 1; _ -> False),
          ("wrong-owner-renewal-rejected", mismatch == Right (Left HistoryRetentionRenewalOwnerMismatch)),
          ("release-succeeds", case released of Right (HistoryRetentionReleased _) -> True; _ -> False),
          ("delete-succeeds-after-release", case deleted of Right (Just _) -> True; _ -> False),
          ("expiry-stream-seeded", case seededExpiry of Right _ -> True; _ -> False),
          ("expiry-lease-acquired", case acquiredExpiry of Right _ -> True; _ -> False),
          ("expiry-blocks-before-deadline", blockedExpiry stillBlocked),
          ("delete-succeeds-after-passive-expiry", case expiredDeleted of Right (Just _) -> True; _ -> False)
        ]
  recordCells context "leases-block-hard-delete" [] cells

rawDeleteStatement :: Statement.Statement () ()
rawDeleteStatement =
  Statement.unpreparable
    "delete from kiroku.stream_events"
    Encoders.noParams
    Decoders.noResult
