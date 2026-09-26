module Kenshou.Suite.Shibuya.Matrix
  ( Boundary (..),
    LifecycleCase (..),
    Cell,
    allCells,
    renderBoundary,
    renderLifecycleCase,
    cellsOf,
    uncovered,
  )
where

import Data.Text (Text)
import Kenshou.Core.Id (ScenarioId, renderScenarioId)

data Boundary
  = StartupRegistration
  | IngestionBackpressure
  | Dispatch
  | KeyedOrdering
  | Batching
  | RetryLease
  | Finalization
  | DrainCancel
  | Supervision
  | MetricsHealth
  | MetricsWebSocket
  | PgmqPersistence
  | KirokuPersistence
  deriving stock (Eq, Ord, Show, Enum, Bounded)

data LifecycleCase = Normal | SynchronousException | Cancellation | Timeout | RepeatedStop
  deriving stock (Eq, Ord, Show, Enum, Bounded)

type Cell = (Boundary, LifecycleCase)

allCells :: [Cell]
allCells = [(boundary, lifecycleCase) | boundary <- [minBound .. maxBound], lifecycleCase <- [minBound .. maxBound]]

renderBoundary :: Boundary -> Text
renderBoundary StartupRegistration = "startup-registration"
renderBoundary IngestionBackpressure = "ingestion-backpressure"
renderBoundary Dispatch = "dispatch"
renderBoundary KeyedOrdering = "keyed-ordering"
renderBoundary Batching = "batching"
renderBoundary RetryLease = "retry-lease"
renderBoundary Finalization = "finalization"
renderBoundary DrainCancel = "drain-cancel"
renderBoundary Supervision = "supervision"
renderBoundary MetricsHealth = "metrics-health"
renderBoundary MetricsWebSocket = "metrics-websocket"
renderBoundary PgmqPersistence = "pgmq-persistence"
renderBoundary KirokuPersistence = "kiroku-persistence"

renderLifecycleCase :: LifecycleCase -> Text
renderLifecycleCase Normal = "normal"
renderLifecycleCase SynchronousException = "synchronousException"
renderLifecycleCase Cancellation = "cancellation"
renderLifecycleCase Timeout = "timeout"
renderLifecycleCase RepeatedStop = "repeatedStop"

-- Only cells actually exercised by an executable scenario belong here.
cellsOf :: ScenarioId -> [Cell]
cellsOf scenario = case renderScenarioId scenario of
  "shibuya/core-runner/correctness/every-delivery-is-finalized-exactly-once" -> [(Dispatch, Normal), (Finalization, Normal), (IngestionBackpressure, Normal)]
  "shibuya/core-runner/correctness/invalid-config-rejected-before-effects" -> [(StartupRegistration, Normal), (StartupRegistration, SynchronousException)]
  "shibuya/core-runner/correctness/duplicate-processor-ids-are-rejected" -> [(StartupRegistration, SynchronousException)]
  "shibuya/core-runner/correctness/nonpositive-concurrency-is-rejected" -> [(Dispatch, SynchronousException)]
  "shibuya/core-runner/correctness/a-failed-processor-is-never-restarted" -> [(IngestionBackpressure, SynchronousException), (Supervision, Normal)]
  "shibuya/core-runner/concurrency/halt-wakes-idle-intake" -> [(Dispatch, Timeout)]
  "shibuya/core-runner/concurrency/finalization-failure-is-a-failure-not-a-halt" -> [(Finalization, SynchronousException), (Finalization, Timeout), (Supervision, SynchronousException)]
  "shibuya/core-runner/concurrency/stop-all-on-failure-delivers-once" -> [(Supervision, SynchronousException), (Supervision, Normal)]
  "shibuya/core-runner/concurrency/gc-liveness-with-dropped-handle" -> [(Supervision, Timeout)]
  "shibuya/core-runner/concurrency/startup-cancellation-leaks-nothing" -> [(StartupRegistration, Cancellation), (StartupRegistration, RepeatedStop)]
  "shibuya/core-runner/concurrency/adapter-shutdown-failure-does-not-skip-siblings" -> [(DrainCancel, SynchronousException), (DrainCancel, RepeatedStop), (Supervision, RepeatedStop)]
  "shibuya/core-runner/concurrency/blocking-adapter-shutdown-is-bounded" -> [(DrainCancel, Timeout)]
  "shibuya/core-runner/concurrency/forced-shutdown-abandons-but-never-loses" -> [(Dispatch, Cancellation), (Finalization, Cancellation), (DrainCancel, Normal), (DrainCancel, Cancellation), (IngestionBackpressure, Timeout), (RetryLease, Timeout)]
  "shibuya/core-runner/concurrency/halt-strands-leased-messages" -> [(IngestionBackpressure, Cancellation)]
  "shibuya/core-runner/concurrency/leased-but-unfinalized-upper-bound" -> [(IngestionBackpressure, Normal)]
  "shibuya/core-ordering/correctness/policy-matrix" -> [(Dispatch, Normal), (KeyedOrdering, Normal)]
  "shibuya/core-ordering/concurrency/hot-key-head-of-line" -> [(KeyedOrdering, Normal)]
  "shibuya/core-ordering/concurrency/keyed-scheduler-model" -> [(KeyedOrdering, SynchronousException), (KeyedOrdering, Cancellation), (KeyedOrdering, RepeatedStop)]
  "shibuya/core-ordering/concurrency/keyed-worker-failure-stops-intake" -> [(KeyedOrdering, SynchronousException)]
  "shibuya/core-batch/concurrency/shutdown-with-partial-batches" -> [(Batching, Cancellation), (Batching, RepeatedStop), (RetryLease, Cancellation)]
  "shibuya/core-batch/correctness/conservation-triggers-and-decisions" -> [(Batching, Normal), (Batching, SynchronousException)]
  "shibuya/metrics/correctness/endpoint-contract" -> [(MetricsHealth, Normal)]
  "shibuya/metrics/correctness/ready-reflects-a-failed-processor" -> [(MetricsHealth, SynchronousException)]
  "shibuya/metrics/correctness/live-reflects-a-stopped-master" -> [(MetricsHealth, Cancellation), (MetricsHealth, RepeatedStop)]
  "shibuya/metrics/correctness/counters-distinguish-retries-from-success" -> [(MetricsHealth, Normal)]
  "shibuya/metrics/correctness/ready-not-stuck-under-sustained-load" -> [(MetricsHealth, Timeout)]
  "shibuya/metrics/correctness/ready-recovers-after-transient-handler-exception" -> [(MetricsHealth, SynchronousException)]
  "shibuya/metrics/correctness/websocket-flag-gates-upgrades" -> [(MetricsWebSocket, Timeout)]
  "shibuya/metrics/correctness/websocket-unsubscribe-all-suppresses-updates" -> [(MetricsWebSocket, Timeout)]
  "shibuya/metrics/concurrency/websocket-slot-accounting" -> [(MetricsWebSocket, Normal), (MetricsWebSocket, SynchronousException), (MetricsWebSocket, Cancellation), (MetricsWebSocket, RepeatedStop)]
  _ -> []

-- Add reasons only for cells which cannot be exercised through public APIs.
uncovered :: [(Cell, Text)]
uncovered = []
