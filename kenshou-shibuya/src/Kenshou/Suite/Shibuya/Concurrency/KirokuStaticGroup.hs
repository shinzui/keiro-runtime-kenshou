module Kenshou.Suite.Shibuya.Concurrency.KirokuStaticGroup (scenario) where

import Control.Concurrent (threadDelay)
import Control.Exception (SomeException, displayException, try)
import Control.Monad (unless)
import Data.Aeson (object, (.=))
import Data.Either (isLeft)
import Data.Foldable (traverse_)
import Data.Int (Int32, Int64)
import Data.List (sortOn)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time.Clock (getCurrentTime)
import Effectful (liftIO, runEff)
import Hasql.Pool (Pool)
import Kenshou.Check.Process (awaitMark, awaitReady, killChild, roleProcess, sendCommand, spawn, stopGracefully, withSupervisor)
import Kenshou.Check.Scenario (withCheck)
import Kenshou.Core.Context (RunContext (..), SummarySection (..), putSummary)
import Kenshou.Core.Dimension (PgDurability (..), PgVersion (..), noDimensions, postgresDimensions)
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Knob (Allowed (..), KnobSpec (..), KnobType (..), KnobValue (..), knobInt, mkKnobName)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Role (ControlMessage (..))
import Kenshou.Core.Scenario (Placement (..), Scenario (..), ScenarioReport, Tier (..), failedWith, passed)
import Kenshou.Suite.Shibuya.Fixture.Kiroku (EffectRow (..), KirokuFixture (..), appendEvents, appendMoreEvents, checkpointOf, effectsOf, ensureEffectsTable, eventPositions, insertEffect, subscriptionFor, withKirokuFixture)
import Kiroku.Store (CategoryName (..), GlobalPosition (..), RecordedEvent (..), StreamName (..))
import Kiroku.Store.Subscription.Types (InvalidConsumerGroup (..))
import Shibuya.Adapter.Kiroku (KirokuConsumerGroupConfig (..), SubscriptionName (..), SubscriptionTarget (..), defaultConsumerGroupConfig, kirokuConsumerGroupProcessors)
import Shibuya.App (defaultAppConfig, defaultShutdownConfig, runApp, stopAppGracefully, waitApp)
import Shibuya.Core.Ack (AckDecision (..))
import Shibuya.Core.Ingested (Message (..))
import Shibuya.Core.Types (Attempt (..), Envelope (..), MessageId (..))
import Shibuya.Policy (Concurrency (..))
import Shibuya.Telemetry.Effect (runTracingNoop)
import System.Exit (ExitCode (..))
import System.Timeout (timeout)

scenario :: Scenario
scenario =
  Scenario
    { id = either (error . Text.unpack) id (parseScenarioId "shibuya/kiroku-adapter/concurrency/consumer-group-is-static"),
      revision = 1,
      summary = "Checks four Kiroku group partitions in one app and four processes, then a dead member's static lag and restart.",
      tier = TierStandard,
      placement = PlaceEither,
      knobs = [KnobSpec observeKnob "Seconds to observe a dead group member without rebalancing" KnobInt (VInt 20) (IntRange 1 120) []],
      dimensions = postgresDimensions (PgDurable :| []) (Pg18 :| [Pg17]) noDimensions,
      phases = zeroPhases,
      requires = noEnvironment {postgres = Just (PostgresRequirement [SchemaKiroku] [] False)},
      knownDefect = Nothing,
      run = runStaticGroup
    }
  where
    observeKnob = either (error . Text.unpack) id (mkKnobName "kiroku-adapter.observe-seconds")

data GroupEvidence = GroupEvidence
  { invalidSizeRejected :: !Bool,
    invalidConcurrencyRejected :: !Bool,
    localStreams :: ![(StreamName, [Int64])],
    localEffects :: ![EffectRow],
    localDrained :: !Bool,
    processStreams :: ![(StreamName, [Int64], [Int64])],
    beforeKill :: ![EffectRow],
    whileDead :: ![EffectRow],
    afterRestart :: ![EffectRow],
    checkpointBeforeKill :: !(Maybe Int64),
    checkpointWhileDead :: !(Maybe Int64),
    finalCheckpoints :: ![Maybe Int64],
    workerExits :: ![ExitCode],
    observedSeconds :: !Int
  }

runStaticGroup :: RunContext -> IO ScenarioReport
runStaticGroup context = do
  let observeSeconds = fromIntegral (knobInt context.knobs (either (error . Text.unpack) id (mkKnobName "kiroku-adapter.observe-seconds")))
  outcome <- try @SomeException $ timeout 180000000 $ withKirokuFixture context (runFixture context observeSeconds)
  case outcome of
    Left err -> pure (failedWith ["kiroku-static-group-exception"] (Text.pack (displayException err)))
    Right Nothing -> pure (failedWith ["kiroku-static-group-timeout"] "Kiroku static group did not finish within 180 seconds")
    Right (Just evidence) -> do
      let localExpected = Set.fromList (concatMap snd evidence.localStreams)
          localActual = Set.fromList [row.position | row <- evidence.localEffects]
          initialPositions = Set.fromList [position | (_, positions, _) <- evidence.processStreams, position <- positions]
          extraPositions = Set.fromList [position | (_, _, positions) <- evidence.processStreams, position <- positions]
          finalPositions = Set.union initialPositions extraPositions
          initialEffects = filter (\row -> row.position `Set.member` initialPositions) evidence.beforeKill
          assignments = streamAssignments evidence.processStreams initialEffects
          memberZeroExtra = Set.fromList [position | (stream, _, positions) <- evidence.processStreams, Map.lookup stream assignments == Just 0, position <- positions]
          otherExtra = Set.difference extraPositions memberZeroExtra
          whileDeadPositions = Set.fromList [row.position | row <- evidence.whileDead]
          finalActual = Set.fromList [row.position | row <- evidence.afterRestart]
          memberSets = [Set.fromList [row.member | row <- evidence.afterRestart, row.position `elem` (initial <> extra)] | (_, initial, extra) <- evidence.processStreams]
          requiredFinalCheckpoints = Map.fromListWith max [(member, maximum (initial <> extra)) | (stream, initial, extra) <- evidence.processStreams, Just member <- [Map.lookup stream assignments]]
          localOrdered = all (orderedStream evidence.localEffects . snd) evidence.localStreams
          processOrdered = all (orderedByProcess evidence.afterRestart . (\(_, initial, extra) -> initial <> extra)) evidence.processStreams
          failures =
            ["group-size-zero-accepted" | not evidence.invalidSizeRejected]
              <> ["group-member-concurrency-accepted" | not evidence.invalidConcurrencyRejected]
              <> ["local-helper-lost-event" | localActual /= localExpected]
              <> ["local-helper-duplicated-event" | length evidence.localEffects /= Set.size localExpected]
              <> ["local-helper-order" | not localOrdered]
              <> ["local-helper-did-not-drain" | not evidence.localDrained]
              <> ["group-initial-loss" | Set.fromList [row.position | row <- evidence.beforeKill] /= initialPositions]
              <> ["group-initial-duplicate" | length evidence.beforeKill /= Set.size initialPositions]
              <> ["group-member-coverage" | Set.fromList (Map.elems assignments) /= Set.fromList [0 .. 3 :: Int32]]
              <> ["partition-changed-member" | any ((/= 1) . Set.size) memberSets]
              <> ["group-process-order" | not processOrdered]
              <> ["dead-member-handled-new-event" | not (Set.null (Set.intersection memberZeroExtra whileDeadPositions))]
              <> ["other-members-did-not-progress" | not (otherExtra `Set.isSubsetOf` whileDeadPositions)]
              <> ["dead-member-checkpoint-advanced" | evidence.checkpointBeforeKill /= evidence.checkpointWhileDead]
              <> ["dead-member-has-no-lag" | Set.null memberZeroExtra || maybe True (>= maximum memberZeroExtra) evidence.checkpointWhileDead]
              <> ["restart-lost-event" | finalActual /= finalPositions]
              <> ["restart-duplicate-event" | length evidence.afterRestart /= Set.size finalPositions]
              <> ["worker-exit" | any (/= ExitSuccess) evidence.workerExits]
              <> ["final-checkpoint-missing" | any (== Nothing) evidence.finalCheckpoints]
              <> ["final-checkpoint-behind-partition" | any (\(member, position) -> maybe True (< position) (evidence.finalCheckpoints !! fromIntegral member)) (Map.toList requiredFinalCheckpoints)]
      putSummary context Verdicts "kiroku-consumer-group-static" $
        object
          [ "localEvents" .= Set.size localExpected,
            "invalidSizeRejected" .= evidence.invalidSizeRejected,
            "invalidConcurrencyRejected" .= evidence.invalidConcurrencyRejected,
            "localEffects" .= length evidence.localEffects,
            "initialProcessEvents" .= Set.size initialPositions,
            "newProcessEvents" .= Set.size extraPositions,
            "partitionMembers" .= [(name, member) | (StreamName name, member) <- Map.toList assignments],
            "deadMemberNewPositions" .= Set.toList memberZeroExtra,
            "checkpointBeforeKill" .= evidence.checkpointBeforeKill,
            "checkpointWhileDead" .= evidence.checkpointWhileDead,
            "finalCheckpoints" .= evidence.finalCheckpoints,
            "observedSeconds" .= evidence.observedSeconds,
            "finalEffects" .= length evidence.afterRestart,
            "workerExits" .= map show evidence.workerExits
          ]
      pure $ if null failures then passed else failedWith failures (Text.intercalate "; " failures)

runFixture :: RunContext -> Int -> KirokuFixture -> IO GroupEvidence
runFixture context observeSeconds fixture = do
  (invalidSizeRejected, invalidConcurrencyRejected) <- validateGroupConfig fixture
  ensureEffectsTable fixture.pool
  localStreams <- appendStreams fixture 16 3
  (localEffects, localDrained) <- runLocalGroup fixture localStreams
  let CategoryName baseCategory = fixture.category
      processCategory = CategoryName (baseCategory <> "b")
      processFixture = fixture {category = processCategory}
      subscription@(SubscriptionName subscriptionName) = subscriptionFor fixture "group-processes"
      CategoryName categoryName = processCategory
      arm = "group-processes"
      args member processIndex =
        object
          [ "subscription" .= subscriptionName,
            "category" .= categoryName,
            "arm" .= arm,
            "member" .= member,
            "groupSize" .= (4 :: Int32),
            "processIndex" .= processIndex
          ]
  (processStreams, beforeKill, whileDead, afterRestart, checkpointBeforeKill, checkpointWhileDead, finalCheckpoints, workerExits) <-
    withCheck context $ \check -> withSupervisor check $ \supervisor -> do
      specs <- traverse (\member -> roleProcess check "shibuya/kiroku-consumer" (fromIntegral member) (args member member)) ([0 .. 3] :: [Int32])
      workers <- traverse (spawn supervisor) specs
      (victim, survivors) <- case workers of
        first : rest -> pure (first, rest)
        [] -> fail "consumer group started no workers"
      traverse_ (`awaitReady` 5000) workers
      traverse_ (`sendCommand` CtlStart) workers
      traverse_ (\worker -> awaitMark worker "running" 10000) workers
      initialStreams <- appendStreams processFixture 24 4
      let initialPositions = Set.fromList (concatMap snd initialStreams)
      waitForPositions fixture.pool arm initialPositions
      beforeKill <- effectsOf fixture.pool arm
      let assignments = streamAssignments [(stream, positions, []) | (stream, positions) <- initialStreams] beforeKill
      unless (Set.fromList (Map.elems assignments) == Set.fromList [0 .. 3 :: Int32]) (fail "initial group did not cover all members")
      waitForAssignedCheckpoints fixture subscription initialStreams assignments
      checkpointBeforeKill <- checkpointOf fixture subscription 0
      killChild supervisor victim
      processStreams <- traverse (appendToExisting processFixture) initialStreams
      let extraPositions = Set.fromList [position | (_, _, positions) <- processStreams, position <- positions]
          memberZeroExtra = Set.fromList [position | (stream, _, positions) <- processStreams, Map.lookup stream assignments == Just 0, position <- positions]
      waitForPositions fixture.pool arm (Set.difference extraPositions memberZeroExtra)
      threadDelay (observeSeconds * 1000000)
      whileDead <- effectsOf fixture.pool arm
      checkpointWhileDead <- checkpointOf fixture subscription 0
      replacementSpec <- roleProcess check "shibuya/kiroku-consumer" 4 (args (0 :: Int32) (4 :: Int32))
      replacement <- spawn supervisor replacementSpec
      awaitReady replacement 5000
      sendCommand replacement CtlStart
      awaitMark replacement "running" 10000
      waitForPositions fixture.pool arm extraPositions
      workerExits <- traverse (\worker -> stopGracefully supervisor worker 5000) (survivors <> [replacement])
      finalCheckpoints <- traverse (checkpointOf fixture subscription) [0 .. 3]
      afterRestart <- effectsOf fixture.pool arm
      pure (processStreams, beforeKill, whileDead, afterRestart, checkpointBeforeKill, checkpointWhileDead, finalCheckpoints, workerExits)
  pure GroupEvidence {invalidSizeRejected, invalidConcurrencyRejected, localStreams, localEffects, localDrained, processStreams, beforeKill, whileDead, afterRestart, checkpointBeforeKill, checkpointWhileDead, finalCheckpoints, workerExits, observedSeconds = observeSeconds}

validateGroupConfig :: KirokuFixture -> IO (Bool, Bool)
validateGroupConfig fixture = do
  let config = defaultConsumerGroupConfig (subscriptionFor fixture "invalid-group") (Category fixture.category) 4
      handler _ = pure AckOk
  invalidSize <-
    try @InvalidConsumerGroup $
      runEff $
        runTracingNoop $
          kirokuConsumerGroupProcessors fixture.store (config {groupSize = 0}) handler
  invalidConcurrency <-
    runEff $
      runTracingNoop $
        kirokuConsumerGroupProcessors fixture.store (config {memberConcurrency = Async 2}) handler
  pure (isLeft invalidSize, isLeft invalidConcurrency)

appendStreams :: KirokuFixture -> Int -> Int -> IO [(StreamName, [Int64])]
appendStreams fixture count perStream =
  traverse appendOne [1 .. count]
  where
    CategoryName categoryName = fixture.category
    appendOne index = do
      let stream = StreamName (categoryName <> "-" <> Text.pack (show index))
          memberFixture = fixture {stream}
      appendEvents memberFixture perStream
      positions <- eventPositions memberFixture
      pure (stream, positions)

appendToExisting :: KirokuFixture -> (StreamName, [Int64]) -> IO (StreamName, [Int64], [Int64])
appendToExisting fixture (stream, initial) = do
  let memberFixture = fixture {stream}
  appendMoreEvents memberFixture 5 4
  allPositions <- eventPositions memberFixture
  pure (stream, initial, drop (length initial) allPositions)

runLocalGroup :: KirokuFixture -> [(StreamName, [Int64])] -> IO ([EffectRow], Bool)
runLocalGroup fixture streams = do
  let subscription = subscriptionFor fixture "group-local"
      expected = Set.fromList (concatMap snd streams)
      arm = "group-local"
  drained <- runEff $ runTracingNoop $ do
    let handler message = do
          let GlobalPosition position = message.envelope.payload.globalPosition
              MessageId eventId = message.envelope.messageId
              attempt = maybe (-1) (\(Attempt index) -> fromIntegral index) message.envelope.attempt
          at <- liftIO getCurrentTime
          liftIO $ insertEffect fixture.pool arm (EffectRow position eventId (-1) (-1) attempt at)
          pure AckOk
    built <- kirokuConsumerGroupProcessors fixture.store (defaultConsumerGroupConfig subscription (Category fixture.category) 4) handler
    processors <- either (error . show) pure built
    unless (length processors == 4) (error "consumer-group helper returned other than four processors")
    started <- runApp defaultAppConfig processors
    case started of
      Left err -> error (show err)
      Right handle -> do
        liftIO $ waitForPositions fixture.pool arm expected
        drained <- stopAppGracefully defaultShutdownConfig handle
        waitApp handle
        pure drained
  effects <- effectsOf fixture.pool arm
  pure (effects, drained)

streamAssignments :: [(StreamName, [Int64], [Int64])] -> [EffectRow] -> Map StreamName Int32
streamAssignments streams effects =
  Map.fromList
    [ (stream, Set.findMin members)
    | (stream, initial, _) <- streams,
      let members = Set.fromList [row.member | row <- effects, row.position `elem` initial],
      not (Set.null members)
    ]

orderedStream :: [EffectRow] -> [Int64] -> Bool
orderedStream effects positions =
  [row.position | row <- sortOn (.at) effects, row.position `elem` positions] == positions

orderedByProcess :: [EffectRow] -> [Int64] -> Bool
orderedByProcess effects positions =
  all ordered (Set.toList (Set.fromList [row.process | row <- effects, row.position `elem` positions]))
  where
    ordered processIndex =
      let observed = [row.position | row <- sortOn (.at) effects, row.process == processIndex, row.position `elem` positions]
       in observed == sortOn id observed

waitForPositions :: Pool -> Text -> Set Int64 -> IO ()
waitForPositions pool arm expected = do
  effects <- effectsOf pool arm
  unless (expected `Set.isSubsetOf` Set.fromList [row.position | row <- effects]) $ threadDelay 20000 >> waitForPositions pool arm expected

waitForAssignedCheckpoints :: KirokuFixture -> SubscriptionName -> [(StreamName, [Int64])] -> Map StreamName Int32 -> IO ()
waitForAssignedCheckpoints fixture subscription streams assignments = do
  checkpoints <- traverse (checkpointOf fixture subscription) [0 .. 3]
  let required = Map.fromListWith max [(member, maximum positions) | (stream, positions) <- streams, Just member <- [Map.lookup stream assignments]]
      complete = and [maybe False (>= position) (checkpoints !! fromIntegral member) | (member, position) <- Map.toList required]
  unless complete $ threadDelay 20000 >> waitForAssignedCheckpoints fixture subscription streams assignments
