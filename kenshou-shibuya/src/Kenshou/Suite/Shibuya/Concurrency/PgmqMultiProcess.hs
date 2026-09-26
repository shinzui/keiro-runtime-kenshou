module Kenshou.Suite.Shibuya.Concurrency.PgmqMultiProcess (scenario) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.STM (atomically)
import Control.Exception (SomeException, displayException, try)
import Control.Monad (unless)
import Data.Aeson (Value, object, withObject, (.:), (.=))
import Data.Aeson.Types (parseEither)
import Data.Foldable (traverse_)
import Data.Int (Int64)
import Data.List (sortOn)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time.Clock (UTCTime)
import Kenshou.Check.Process (ProgressSnapshot (..), awaitMark, awaitReady, progress, roleProcess, sendCommand, spawn, stopGracefully, withSupervisor)
import Kenshou.Check.Scenario (withCheck)
import Kenshou.Core.Context (RunContext (..), SummarySection (..), putSummary)
import Kenshou.Core.Dimension (PgDurability (..), PgVersion (..), noDimensions, postgresDimensions)
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Role (ControlMessage (..))
import Kenshou.Core.Scenario (Placement (..), Scenario (..), ScenarioReport, Tier (..), failedWith, passed)
import Kenshou.Suite.Shibuya.Fixture.Pgmq (PgmqFixture (..), effectDeliveries, ensureEffectsTable, queueRows, withPgmqFixture)
import Shibuya.Adapter.Pgmq (queueNameToText)
import System.Exit (ExitCode (..))
import System.Timeout (timeout)

scenario :: Scenario
scenario =
  Scenario
    { id = either (error . Text.unpack) id (parseScenarioId "shibuya/pgmq-adapter/concurrency/multi-process-competition"),
      revision = 1,
      summary = "Four consumer processes conserve grouped messages and test FIFO head ordering across a retry.",
      tier = TierStandard,
      placement = PlaceEither,
      knobs = [],
      dimensions = postgresDimensions (PgDurable :| []) (Pg18 :| [Pg17]) noDimensions,
      phases = zeroPhases,
      requires = noEnvironment {postgres = Just (PostgresRequirement [SchemaPgmq] [] False)},
      knownDefect = Nothing,
      run = runCompetition
    }

data Delivery = Delivery
  { identifier :: !Text,
    attempt :: !Int64,
    startedAt :: !UTCTime,
    completedAt :: !UTCTime,
    worker :: !Text
  }

data ArmEvidence = ArmEvidence
  { sent :: ![(Text, Text, Int)],
    deliveries :: ![Delivery],
    remainingRows :: !Int64,
    workerExits :: ![ExitCode],
    producerExit :: !ExitCode
  }

data Arm = Arm
  { label :: !Text,
    strategy :: !(Maybe Text),
    batch :: !Int,
    concurrency :: !Int,
    injectRetry :: !Bool,
    processBase :: !Int
  }

arms :: [Arm]
arms =
  [ Arm "ordinary" Nothing 1 1 False 0,
    Arm "head" (Just "head-per-group") 4 1 True 5,
    Arm "throughput" (Just "throughput-optimized") 4 4 False 10,
    Arm "round_robin" (Just "round-robin") 4 4 False 15
  ]

runCompetition :: RunContext -> IO ScenarioReport
runCompetition context = do
  result <- try @SomeException $ timeout 180000000 (traverse (runArm context) arms)
  case result of
    Left err -> pure (failedWith ["multi-process-exception"] (Text.pack (displayException err)))
    Right Nothing -> pure (failedWith ["multi-process-timeout"] "The four process-competition arms exceeded 180 seconds")
    Right (Just evidence) -> do
      let failures = concat (zipWith checkArm arms evidence)
      putSummary context Verdicts "pgmq-multi-process-competition" (object ["arms" .= zipWith armValue arms evidence])
      pure $ if null failures then passed else failedWith failures (Text.intercalate "; " failures)

runArm :: RunContext -> Arm -> IO ArmEvidence
runArm context arm = withPgmqFixture context arm.label 4 $ \fixture -> do
  ensureEffectsTable fixture.pool
  (sent, workerExits, producerExit) <- withCheck context $ \check -> withSupervisor check $ \supervisor -> do
    let workerLabels = labels arm
        workerArgs label =
          object
            [ "queue" .= queueNameToText fixture.queue,
              "arm" .= label,
              "visibilitySeconds" .= (30 :: Int),
              "extendLease" .= False,
              "handlerMicros" .= (20000 :: Int),
              "slowEvery" .= (if arm.concurrency > 1 then 4 else 0 :: Int),
              "slowHandlerMicros" .= (150000 :: Int),
              "readBatchSize" .= arm.batch,
              "concurrentHandlers" .= arm.concurrency,
              "fifoStrategy" .= arm.strategy,
              "retryGroup" .= (if arm.injectRetry then Just "g0" else Nothing :: Maybe Text),
              "retrySequence" .= (if arm.injectRetry then Just (5 :: Int) else Nothing)
            ]
    workerSpecs <- traverse (\(index, label) -> roleProcess check "shibuya/pgmq-consumer" index (workerArgs label)) (zip [arm.processBase ..] workerLabels)
    producerSpec <- roleProcess check "shibuya/pgmq-producer" (arm.processBase + 4) (object ["queue" .= queueNameToText fixture.queue, "total" .= (80 :: Int), "groups" .= (4 :: Int), "intervalMicros" .= (1000 :: Int)])
    workers <- traverse (spawn supervisor) workerSpecs
    producer <- spawn supervisor producerSpec
    traverse_ (`awaitReady` 5000) workers
    awaitReady producer 5000
    traverse_ (`sendCommand` CtlStart) workers
    traverse_ (\child -> awaitMark child "running" 5000) workers
    sendCommand producer CtlStart
    awaitMark producer "produced" 20000
    producerSnapshot <- atomically (progress producer)
    items <- case Map.lookup "produced" producerSnapshot.marks of
      Nothing -> fail "PGMQ producer did not return its item ledger"
      Just value -> either fail pure (parseEither (withObject "produced" (.: "items")) value)
    completed <- timeout 60000000 (waitForEffects fixture workerLabels 80)
    unless (completed == Just ()) (fail "PGMQ consumers did not record 80 effects")
    workerExits <- traverse (\child -> stopGracefully supervisor child 5000) workers
    producerExit <- stopGracefully supervisor producer 2000
    pure (items, workerExits, producerExit)
  deliveries <- concat <$> traverse (loadDeliveries fixture) (labels arm)
  remainingRows <- queueRows fixture
  pure ArmEvidence {sent, deliveries, remainingRows, workerExits, producerExit}

labels :: Arm -> [Text]
labels arm = [arm.label <> "_" <> Text.pack (show index) | index <- [0 .. 3 :: Int]]

loadDeliveries :: PgmqFixture -> Text -> IO [Delivery]
loadDeliveries fixture worker = do
  rows <- effectDeliveries fixture.pool worker
  pure [Delivery identifier attempt startedAt completedAt worker | (identifier, attempt, startedAt, completedAt) <- rows]

waitForEffects :: PgmqFixture -> [Text] -> Int -> IO ()
waitForEffects fixture workerLabels target = do
  count <- sum . fmap length <$> traverse (effectDeliveries fixture.pool) workerLabels
  unless (count >= target) $ threadDelay 50000 >> waitForEffects fixture workerLabels target

checkArm :: Arm -> ArmEvidence -> [Text]
checkArm arm evidence =
  let expected = Set.fromList [identifier | (identifier, _, _) <- evidence.sent]
      actual = Set.fromList [item.identifier | item <- evidence.deliveries]
      counts = Map.fromListWith (+) [(item.identifier, 1 :: Int) | item <- evidence.deliveries]
      retryId = [identifier | (identifier, group, sequenceNumber) <- evidence.sent, group == "g0", sequenceNumber == 5]
      retryAttempts = [item.attempt | item <- evidence.deliveries, item.identifier `elem` retryId]
      prefix = arm.label <> ": "
   in [prefix <> "producer-count" | length evidence.sent /= 80]
        <> [prefix <> "missing-effect" | expected /= actual]
        <> [prefix <> "duplicate-effect" | any (/= 1) (Map.elems counts)]
        <> [prefix <> "overlapping-delivery" | overlappingDeliveries evidence > 0]
        <> [prefix <> "queue-not-drained" | evidence.remainingRows /= 0]
        <> [prefix <> "worker-exit" | any (/= ExitSuccess) (evidence.producerExit : evidence.workerExits)]
        <> [prefix <> "head-order-inversion" | arm.injectRetry && inversions evidence /= 0]
        <> [prefix <> "retry-not-observed" | arm.injectRetry && (length retryId /= 1 || retryAttempts /= [1])]

armValue :: Arm -> ArmEvidence -> Value
armValue arm evidence =
  object
    [ "arm" .= arm.label,
      "strategy" .= arm.strategy,
      "batchSize" .= arm.batch,
      "concurrency" .= arm.concurrency,
      "sent" .= length evidence.sent,
      "effects" .= length evidence.deliveries,
      "workers" .= Map.unionWith (+) (Map.fromList [(label, 0 :: Int) | label <- labels arm]) (Map.fromListWith (+) [(item.worker, 1 :: Int) | item <- evidence.deliveries]),
      "inversions" .= inversions evidence,
      "retryAttempts" .= [item.attempt | item <- evidence.deliveries, item.identifier `elem` [identifier | (identifier, group, sequenceNumber) <- evidence.sent, group == "g0", sequenceNumber == 5]],
      "overlappingDeliveries" .= overlappingDeliveries evidence,
      "remainingRows" .= evidence.remainingRows,
      "workerExits" .= fmap show evidence.workerExits,
      "producerExit" .= show evidence.producerExit
    ]

inversions :: ArmEvidence -> Int
inversions evidence =
  let sentMap = Map.fromList [(identifier, (group, sequenceNumber)) | (identifier, group, sequenceNumber) <- evidence.sent]
      ordered = sortOn (\item -> (item.completedAt, item.identifier)) evidence.deliveries
      perGroup = Map.fromListWith (flip (<>)) [(group, [sequenceNumber]) | item <- ordered, Just (group, sequenceNumber) <- [Map.lookup item.identifier sentMap]]
   in sum [length [() | (left, right) <- zip positions (drop 1 positions), left > right] | positions <- Map.elems perGroup]

overlappingDeliveries :: ArmEvidence -> Int
overlappingDeliveries evidence =
  length
    [ ()
    | (index, first) <- zip [0 :: Int ..] evidence.deliveries,
      second <- drop (index + 1) evidence.deliveries,
      first.identifier == second.identifier,
      first.startedAt < second.completedAt,
      second.startedAt < first.completedAt
    ]
