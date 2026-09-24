module Kenshou.Suite.Keiro.Timer.Roles (roles, businessEventId) where

import Control.Concurrent (threadDelay)
import Control.Monad (void)
import Data.Aeson (object, withObject, (.:), (.:?), (.=))
import Data.Aeson.Types (parseMaybe)
import Data.ByteString qualified as ByteString
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.Time (getCurrentTime)
import Data.UUID qualified as UUID
import Data.UUID.V5 qualified as UUID.V5
import Effectful (Eff, IOE, liftIO)
import Effectful.Error.Static (Error)
import Effectful.Error.Static qualified as Error
import Keiro.Timer (DeadTimerClaimRequest (..), TimerId (..), TimerRow (..), claimDeadTimer, claimDueTimer, completeTimerResume, drainDueTimersWith, markTimerFired, renewTimerResume, resumeClaimTimer, runTimerWorkerWith)
import Keiro.Workflow.Sleep (workflowSleepFireAction)
import Kenshou.Core.Knob (knobInt, resolvedKnobsMap)
import Kenshou.Core.Role (ControlMessage (..), PostgresConnInfo (..), RoleContext (..), WorkerInit (..), WorkerMessage (..), WorkerRole (..), mkRoleName)
import Kenshou.Suite.Keiro.Timer.Knobs (timerKnobName, timerOptionsFrom)
import Kenshou.Suite.Keiro.Workflow.Effects (BoundaryPoint (..), CrashPlan (..), EffectFact (..), EffectSink (..), withEffectSink)
import Kenshou.Suite.Keiro.Workflow.Fixture (durableKirokuStore, withDurableStore)
import Kiroku.Store (Store, appendToStream, defaultConnectionSettings, runStoreIO)
import Kiroku.Store.Error (StoreError (..))
import Kiroku.Store.Types (EventData (..), EventId (..), EventType (..), ExpectedVersion (..), StreamName (..))
import System.Timeout (timeout)

roles :: [WorkerRole]
roles =
  [ WorkerRole roleName "Claims and fires durable timers, with an optional self-kill after the fire effect." timerWorker,
    WorkerRole resumeName "Claims and renews a guarded foreground resume for a dead timer." resumeWorker
  ]
  where
    roleName = either (error . Text.unpack) id (mkRoleName "keiro/timer-worker")
    resumeName = either (error . Text.unpack) id (mkRoleName "keiro/timer-resume-claimer")

resumeWorker :: RoleContext -> IO ()
resumeWorker context = case context.init.postgres of
  Nothing -> context.send (WrkError "timer resume claimer requires PostgreSQL")
  Just postgres -> case parseMaybe (withObject "timer resume args" (\value -> (,,,) <$> value .: "timerId" <*> value .: "reason" <*> value .: "maxAttempts" <*> value .: "leaseSeconds")) context.init.args of
    Nothing -> context.send (WrkError "invalid timer resume arguments")
    Just (rawId, reason, attemptCeiling, lease) -> case UUID.fromText rawId of
      Nothing -> context.send (WrkError "invalid timer identifier")
      Just identifier -> do
        context.send WrkReady
        context.receive >>= \case
          Just CtlStart -> withDurableStore (defaultConnectionSettings postgres.connectionString) \fixture -> do
            let store = durableKirokuStore fixture
                request = DeadTimerClaimRequest (TimerId identifier) "kenshou" reason attemptCeiling lease
            result <- runStoreIO store (claimDeadTimer request)
            case result of
              Left err -> context.send (WrkError (Text.pack (show err)))
              Right (Left err) -> context.send (WrkError (Text.pack (show err)))
              Right (Right Nothing) -> context.send (WrkCustom "resume-claim" (object ["claimed" .= False])) >> context.send (WrkDone Nothing)
              Right (Right (Just claim)) -> do
                context.send (WrkCustom "resume-claim" (object ["claimed" .= True, "attempts" .= (resumeClaimTimer claim).attempts]))
                let loop =
                      context.receive >>= \case
                        Just (CtlCustom "renew" _) -> do
                          renewed <- runStoreIO store (renewTimerResume claim lease)
                          context.send (WrkCustom "resume-renew" (object ["renewed" .= case renewed of Right (Right True) -> True; _ -> False]))
                          loop
                        Just (CtlCustom "complete" _) -> do
                          completed <- runStoreIO store (completeTimerResume claim (businessEventId (TimerId identifier)))
                          context.send (WrkCustom "resume-complete" (object ["completed" .= case completed of Right True -> True; _ -> False]))
                          context.send (WrkDone Nothing)
                        _ -> context.send (WrkDone Nothing)
                loop
          _ -> context.send (WrkDone (Just "not started"))

timerWorker :: RoleContext -> IO ()
timerWorker context = case context.init.postgres of
  Nothing -> context.send (WrkError "timer worker requires PostgreSQL")
  Just postgres -> case parseMaybe (withObject "timer worker args" (\value -> (,) <$> value .:? "killAfterFire" <*> value .:? "slowFireMicros")) context.init.args of
    Nothing -> context.send (WrkError "invalid timer worker arguments")
    Just (killAfterFire, slowFireMicros) -> case timerOptionsFrom context.init.knobs of
      Left err -> context.send (WrkError (Text.pack (show err)))
      Right options -> do
        context.send WrkReady
        context.receive >>= \case
          Just CtlStart -> withDurableStore (defaultConnectionSettings postgres.connectionString) \fixture ->
            withEffectSink context (if killAfterFire == Just True then [CrashPlan AfterTimerFire 1] else []) \sink -> do
              let store = durableKirokuStore fixture
                  tick = do
                    now <- getCurrentTime
                    result <-
                      runStoreIO store $
                        if drainLimit == 1
                          then maybe 0 (const 1) <$> runTimerWorkerWith Nothing options now (fire sink)
                          else drainDueTimersWith Nothing options now drainLimit (fire sink)
                    case result of
                      Left err -> context.send (WrkError (Text.pack (show err)))
                      Right count -> context.send (WrkCustom "timer-pass" (object ["claimed" .= count]))
                  loop = do
                    command <- timeout 1000 context.receive
                    case command of
                      Just (Just (CtlStop _)) -> context.send (WrkDone Nothing)
                      Just Nothing -> pure ()
                      _ -> tick >> threadDelay tickMicros >> loop
              case slowFireMicros of
                Just delay -> do
                  now <- getCurrentTime
                  outcome <- runStoreIO store do
                    claimed <- claimDueTimer now
                    case claimed of
                      Nothing -> pure Nothing
                      Just row -> do
                        produced <- fire sink row
                        liftIO (threadDelay delay)
                        marked <- maybe (pure False) (markTimerFired row.timerId) produced
                        pure (Just marked)
                  case outcome of
                    Left err -> context.send (WrkError (Text.pack (show err)))
                    Right marked -> context.send (WrkCustom "slow-mark" (object ["marked" .= marked]))
                  context.send (WrkDone Nothing)
                Nothing -> loop
          _ -> void (context.send (WrkDone (Just "not started")))
      where
        configured = resolvedKnobsMap context.init.knobs
        drainLimit = if timerKnobName "timer.drain-limit" `Map.member` configured then fromIntegral (knobInt context.init.knobs (timerKnobName "timer.drain-limit")) else 1
        tickMicros = if timerKnobName "timer.tick-interval-ms" `Map.member` configured then fromIntegral (knobInt context.init.knobs (timerKnobName "timer.tick-interval-ms")) * 1000 else 50000

fire :: EffectSink -> TimerRow -> Eff '[Store, Error StoreError, IOE] (Maybe EventId)
fire sink row =
  workflowSleepFireAction row >>= \case
    Just produced -> pure (Just produced)
    Nothing -> do
      let eid = businessEventId row.timerId
          event = EventData (Just eid) (EventType "kenshou.timer.fired") (object ["timerId" .= timerText row.timerId]) Nothing Nothing Nothing
          stream = StreamName ("kenshouTimer-" <> timerText row.timerId)
      liftIO $ sink.recordEffect (EffectFact "timer-fire" (timerText row.timerId) "timer-worker" (object ["attempt" .= row.attempts]))
      _ <- Error.catchError (void (appendToStream stream AnyVersion [event])) \_ err -> case err of
        DuplicateEvent _ -> pure ()
        other -> Error.throwError other
      liftIO $ sink.boundary AfterTimerFire
      pure (Just eid)

businessEventId :: TimerId -> EventId
businessEventId timerId =
  EventId (UUID.V5.generateNamed UUID.V5.namespaceURL (ByteString.unpack (Text.encodeUtf8 ("kenshou:timer:" <> timerText timerId))))

timerText :: TimerId -> Text
timerText (TimerId value) = UUID.toText value
