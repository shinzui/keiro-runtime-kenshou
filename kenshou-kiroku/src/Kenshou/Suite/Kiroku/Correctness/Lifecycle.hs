module Kenshou.Suite.Kiroku.Correctness.Lifecycle (scenarios) where

import Control.Concurrent (threadDelay)
import Data.Aeson (object, (.=))
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Vector qualified as Vector
import Kenshou.Core.Context (RunContext, SummarySection (..), putSummary)
import Kenshou.Core.Dimension
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Scenario
import Kenshou.Suite.Kiroku.Correctness.Append (recordCells)
import Kenshou.Suite.Kiroku.Fixture.Store (withKirokuStoreWithTap)
import Kenshou.Suite.Kiroku.Knobs (storeKnobs)
import Kiroku.Store hiding (id, withKirokuStore)
import System.Timeout (timeout)

scenarios :: [Scenario]
scenarios = [deleteAndTruncate]

deleteAndTruncate :: Scenario
deleteAndTruncate =
  Scenario
    { id = either (error . show) id (parseScenarioId "kiroku/lifecycle/correctness/delete-and-truncate"),
      revision = 1,
      summary = "Checks soft delete, restoration, truncation and hard delete against global history.",
      tier = TierSmoke,
      placement = PlaceEither,
      knobs = storeKnobs,
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
      run = runLifecycle
    }

runLifecycle :: RunContext -> IO ScenarioReport
runLifecycle context = do
  eventsSeen <- newIORef []
  deliveries <- newIORef []
  withKirokuStoreWithTap context (Just (\event -> modifyIORef' eventsSeen (event :))) \store -> do
    let name = StreamName "lifecycle-main"
        system = StreamName "$all"
        event = EventData Nothing (EventType "Lifecycle") (object []) Nothing Nothing Nothing
    appended <- runStoreIO store (appendToStream name NoStream (replicate 5 event))
    original <- runStoreIO store (readStreamForward name (StreamVersion 0) 10)
    let handler row = modifyIORef' deliveries (row.globalPosition :) >> pure Continue
        config = defaultSubscriptionConfig (SubscriptionName "lifecycle-observer") AllStreams handler
        awaitInitial = do
          received <- readIORef deliveries
          if length received >= 5 then pure True else threadDelay 10000 >> awaitInitial
    subscription <- subscribe store config
    caughtUp <- timeout 10000000 awaitInitial
    soft <- runStoreIO store (softDeleteStream name)
    hidden <- runStoreIO store (readStreamForward name (StreamVersion 0) 10)
    rejected <- runStoreIO store (appendToStream name AnyVersion [event])
    globalSoft <- runStoreIO store (readAllForward (GlobalPosition 0) 10)
    categorySoft <- runStoreIO store (readCategory (CategoryName "lifecycle") (GlobalPosition 0) 10)
    restored <- runStoreIO store (undeleteStream name)
    visible <- runStoreIO store (readStreamForward name (StreamVersion 0) 10)
    truncated <- runStoreIO store (setStreamTruncateBefore name (StreamVersion 4))
    truncatedAgain <- runStoreIO store (setStreamTruncateBefore name (StreamVersion 4))
    shortRead <- runStoreIO store (readStreamForward name (StreamVersion 0) 10)
    globalTruncated <- runStoreIO store (readAllForward (GlobalPosition 0) 10)
    cleared <- runStoreIO store (clearStreamTruncateBefore name)
    fullRead <- runStoreIO store (readStreamForward name (StreamVersion 0) 10)
    reservedSoft <- runStoreIO store (softDeleteStream system)
    reservedHard <- runStoreIO store (hardDeleteStream system)
    reservedUndelete <- runStoreIO store (undeleteStream system)
    reservedTruncate <- runStoreIO store (setStreamTruncateBefore system (StreamVersion 2))
    reservedClear <- runStoreIO store (clearStreamTruncateBefore system)
    hard <- runStoreIO store (hardDeleteStream name)
    gone <- runStoreIO store (getStream name)
    globalHard <- runStoreIO store (readAllForward (GlobalPosition 0) 10)
    tapped <- readIORef eventsSeen
    subscriptionState <- subscription.currentState
    subscription.cancel
    delivered <- reverse <$> readIORef deliveries
    let expectedPositions = fmap (.globalPosition) (Vector.toList (either (const Vector.empty) id globalSoft))
    putSummary context Verdicts "lifecycle-delivery" (object ["delivered" .= show delivered, "expected" .= show expectedPositions])
    let vectorLength = either (const (-1)) Vector.length
        sameIds left right = case (left, right) of
          (Right lhs, Right rhs) -> fmap (.eventId) lhs == fmap (.eventId) rhs
          _ -> False
        reserved = \case Left (ReservedStreamName target) -> target == system; _ -> False
        cells =
          [ ("initial-events", vectorLength original == 5 && case appended of Right result -> result.streamVersion == StreamVersion 5; _ -> False),
            ("soft-delete-hides-stream", case soft of Right (Just _) -> vectorLength hidden == 0; _ -> False),
            ("soft-delete-rejects-append", rejected == Left (StreamNotFound name)),
            ("soft-delete-preserves-global", vectorLength globalSoft == 5),
            ("soft-delete-preserves-category", vectorLength categorySoft == 5),
            ("undelete-restores-history", case restored of Right (Just _) -> sameIds original visible; _ -> False),
            ("truncate-idempotent", truncated == truncatedAgain && case truncated of Right (Just _) -> True; _ -> False),
            ("truncate-hides-prefix", case shortRead of Right rows -> fmap (.streamVersion) (Vector.toList rows) == [StreamVersion 4, StreamVersion 5]; _ -> False),
            ("truncate-preserves-global", vectorLength globalTruncated == 5),
            ("clear-restores-prefix", case cleared of Right (Just _) -> sameIds original fullRead; _ -> False),
            ("reserved-soft-delete", reserved reservedSoft),
            ("reserved-hard-delete", reserved reservedHard),
            ("reserved-undelete", reserved reservedUndelete),
            ("reserved-truncate", reserved reservedTruncate),
            ("reserved-clear", reserved reservedClear),
            ("hard-delete-removes-stream", case hard of Right (Just _) -> gone == Right Nothing; _ -> False),
            ("hard-delete-removes-global-events", vectorLength globalHard == 0),
            ("hard-delete-emits-event", any (\case KirokuEventHardDeleteIssued target _ -> target == name; _ -> False) tapped),
            ("subscriber-caught-up-before-delete", caughtUp == Just True),
            ("subscriber-stays-live-through-delete", case subscriptionState of Just _ -> True; _ -> False),
            ("subscriber-keeps-global-order", delivered == expectedPositions)
          ]
    recordCells context "delete-and-truncate" [] cells
