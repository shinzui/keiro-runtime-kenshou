module Kenshou.Suite.Shibuya.Concurrency.KeyedModel (scenario, Action (..), Item (..), ModelCase (..), modelProperty, runCase) where

import Control.Concurrent (threadDelay)
import Control.Exception (SomeException, displayException, try)
import Control.Monad (forM)
import Data.ByteString.Char8 qualified as ByteString
import Data.List (nub, sort)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time.Clock (getCurrentTime)
import Effectful (liftIO, runEff)
import Hedgehog (PropertyT, forAll)
import Hedgehog qualified
import Hedgehog.Gen qualified as Gen
import Hedgehog.Range qualified as Range
import Kenshou.Check.Model (ModelRun (..), runModel)
import Kenshou.Check.Scenario (finishWithVerdicts, withCheck)
import Kenshou.Check.Verdict (InvariantClass (..))
import Kenshou.Core.Context (RunContext (..))
import Kenshou.Core.Dimension (noDimensions)
import Kenshou.Core.Env (noEnvironment)
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Knob (Allowed (..), KnobSpec (..), KnobType (..), KnobValue (..), knobInt, mkKnobName)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Scenario (Placement (..), Scenario (..), Tier (..))
import Kenshou.Suite.Shibuya.Fixture.Handlers (HandlerEvent (..), HandlerScript (..), HandlerStats (..), defaultHandlerScript, handlerEvents, handlerStats, newHandlerProbe, scriptedHandler)
import Kenshou.Suite.Shibuya.Fixture.SyntheticAdapter (BrokerEvent (..), BrokerStats (..), brokerEvents, brokerStats, closeInput, defaultSyntheticConfig, newSyntheticBroker, publish, syntheticAdapter)
import Shibuya.App (QueueProcessor (..), ShutdownConfig (..), defaultAppConfig, defaultShutdownConfig, mkProcessor, runApp, stopAppGracefully, waitApp)
import Shibuya.Core.Ack (AckDecision (..), DeadLetterReason (..), RetryDelay (..))
import Shibuya.Core.Metrics (ProcessorId (..))
import Shibuya.Core.Types (MessageId)
import Shibuya.Policy (Concurrency (..), OrderingPolicy (..))
import Shibuya.Telemetry.Effect (runTracingNoop)
import System.Timeout (timeout)

data Action = Succeed | RetryOnce | DeadLetter | ThrowOnce
  deriving stock (Eq, Show, Enum, Bounded)

data Item = Item {key :: !Int, delayMicros :: !Int, action :: !Action}
  deriving stock (Eq, Show)

data ModelCase = ModelCase {items :: ![Item], stopAfterMicros :: !(Maybe Int)}
  deriving stock (Eq, Show)

scenario :: Scenario
scenario =
  Scenario
    { id = either (error . Text.unpack) id (parseScenarioId "shibuya/core-ordering/concurrency/keyed-scheduler-model"),
      revision = 1,
      summary = "Seeded per-key delivery histories preserve order, serialization, finalization and graceful stop boundaries.",
      tier = TierStandard,
      placement = PlaceEither,
      knobs = [KnobSpec modelCases "Generated scheduler histories" KnobInt (VInt 200) (IntRange 1 10000) []],
      dimensions = noDimensions,
      phases = zeroPhases,
      requires = noEnvironment,
      knownDefect = Nothing,
      run = \context -> withCheck context $ \check -> do
        let count = fromIntegral (knobInt context.knobs modelCases)
        verdict <- runModel check (ModelRun "keyed-scheduler-queue-model" Contract count 50 modelProperty)
        finishWithVerdicts check [verdict]
    }
  where
    modelCases = either (error . Text.unpack) id (mkKnobName "model.cases")

modelProperty :: PropertyT IO ()
modelProperty = do
  modelCase <- forAll $ do
    items <- Gen.list (Range.linear 1 12) $ Item <$> Gen.int (Range.linear 0 3) <*> Gen.int (Range.linear 0 2000) <*> Gen.element [Succeed, RetryOnce, DeadLetter, ThrowOnce]
    stopAfterMicros <- Gen.element [Nothing, Just 0, Just 500, Just 1500, Just 3000]
    pure ModelCase {items, stopAfterMicros}
  failures <- Hedgehog.evalIO (runCase modelCase)
  Hedgehog.footnote (show failures)
  Hedgehog.assert (null failures)

runCase :: ModelCase -> IO [Text]
runCase modelCase = do
  broker <- newSyntheticBroker defaultSyntheticConfig
  published <- forM modelCase.items $ \item -> do
    identifier <- publish broker (Just (keyText item.key)) (ByteString.pack (show item))
    pure (identifier, item)
  closeInput broker
  let specs = Map.fromList published
      scriptedDecision identifier attempt =
        case Map.lookup identifier specs of
          Nothing -> Left "unknown generated delivery"
          Just item -> case item.action of
            Succeed -> Right AckOk
            RetryOnce | attempt == 0 -> Right (AckRetry (RetryDelay 0))
            RetryOnce -> Right AckOk
            DeadLetter -> Right (AckDeadLetter (PoisonPill "model-dead-letter"))
            ThrowOnce | attempt == 0 -> Left "scripted model handler error"
            ThrowOnce -> Right AckOk
      scriptedDelay identifier _ = maybe 0 (.delayMicros) (Map.lookup identifier specs)
  probe <- newHandlerProbe defaultHandlerScript {decisionFor = scriptedDecision, delayFor = scriptedDelay}
  completed <- try @SomeException $ timeout 3000000 $ runEff $ runTracingNoop $ do
    let processor = (mkProcessor (syntheticAdapter broker) (scriptedHandler probe)) {ordering = PartitionedInOrder, concurrency = Async 4}
        shutdown = defaultShutdownConfig {drainTimeout = 1}
    started <- runApp defaultAppConfig [(ProcessorId "keyed-model", processor)]
    case started of
      Left err -> error (show err)
      Right handle -> do
        case modelCase.stopAfterMicros of
          Nothing -> waitApp handle
          Just delay -> liftIO (threadDelay delay)
        drained <- stopAppGracefully shutdown handle
        stoppedAt <- liftIO getCurrentTime
        yieldedAtStop <- (.yielded) <$> liftIO (brokerStats broker)
        drainedAgain <- stopAppGracefully shutdown handle
        pure (drained, drainedAgain, stoppedAt, yieldedAtStop)
  threadDelay 5000
  facts <- brokerEvents broker
  handlers <- handlerEvents probe
  brokerState <- brokerStats broker
  handlerState <- handlerStats probe
  let completionFailure = case completed of
        Left err -> ["application failed: " <> Text.pack (displayException err)]
        Right Nothing -> ["application timed out"]
        Right (Just _) -> []
      stopFacts = case completed of
        Right (Just (drained, drainedAgain, stoppedAt, yieldedAtStop)) ->
          ["graceful stop failed to drain" | not drained]
            <> ["repeated stop changed result" | drainedAgain /= drained]
            <> ["handler started after stop returned" | HandlerStarted _ _ at _ <- handlers, at > stoppedAt]
            <> ["adapter yielded a delivery after stop returned" | brokerState.yielded /= yieldedAtStop]
        _ -> []
  pure $ completionFailure <> stopFacts <> checkHistory modelCase specs facts handlers brokerState handlerState

checkHistory :: ModelCase -> Map MessageId Item -> [BrokerEvent] -> [HandlerEvent] -> BrokerStats -> HandlerStats -> [Text]
checkHistory modelCase specs facts handlers brokerState handlerState =
  let yielded = [(identifier, attempt) | Yielded identifier attempt <- facts]
      started = [(identifier, attempt) | HandlerStarted identifier attempt _ _ <- handlers]
      ended = [(identifier, attempt) | HandlerEnded identifier attempt _ _ _ <- handlers]
      effective = [(identifier, token - 1, decision) | Finalized identifier token decision <- facts]
      finalizations = [(identifier, attempt) | (identifier, attempt, _) <- effective]
      keys = nub (map (.key) (Map.elems specs))
      onKey key delivery = maybe False ((== key) . (.key)) (Map.lookup (fst delivery) specs)
      perKeyOrder = all (\key -> let actual = filter (onKey key) started; expected = filter (onKey key) yielded in actual == take (length actual) expected) keys
      perKeyFinalization = all (\key -> let actual = filter (onKey key) finalizations; expected = filter (onKey key) yielded in actual == take (length actual) expected) keys
      noOverlap = all (\key -> keyIntervalsWellFormed key specs handlers) keys
      oneEach deliveries = all (\count -> count == (1 :: Int)) (Map.elems (Map.fromListWith (+) [(delivery, 1 :: Int) | delivery <- deliveries]))
      complete = modelCase.stopAfterMicros == Nothing
      expectedDecision (identifier, attempt, decision) = case Map.lookup identifier specs of
        Nothing -> False
        Just item -> case item.action of
          Succeed -> decision == AckOk
          RetryOnce -> if attempt == 0 then decision == AckRetry (RetryDelay 0) else decision == AckOk
          DeadLetter -> decision == AckDeadLetter (PoisonPill "model-dead-letter")
          ThrowOnce -> if attempt == 0 then decision == AckRetry (RetryDelay 0) else decision == AckOk
      failIf condition reason = [reason | condition]
   in failIf (not perKeyOrder) "per-key handler order differs from delivered queue order"
        <> failIf (not perKeyFinalization) "per-key finalization order differs from delivered queue order"
        <> failIf (not noOverlap) "same-key handlers overlapped or intervals were unbalanced"
        <> failIf (handlerState.highWater > 4 || handlerState.active /= 0) "handler concurrency exceeded four or remained active"
        <> failIf (not (oneEach started && oneEach ended && oneEach finalizations)) "a delivery started, ended or finalized more than once"
        <> failIf (not (all (`elem` yielded) started && all (`elem` started) ended && all (`elem` yielded) finalizations)) "handler or finalizer referenced an undelivered item"
        <> failIf (not (all expectedDecision effective)) "finalization decision differs from scripted decision"
        <> failIf (not (null [() | DuplicateFinalize _ _ <- facts])) "duplicate effective finalization attempted"
        <> failIf (complete && (sort started /= sort yielded || sort ended /= sort yielded || sort finalizations /= sort yielded || brokerState.leasedUnfinalized /= 0)) "finite run did not conserve every delivery"
        <> failIf (not complete && not (all (`elem` finalizations) ended)) "gracefully stopped run left a completed handler unfinalized"

keyIntervalsWellFormed :: Int -> Map MessageId Item -> [HandlerEvent] -> Bool
keyIntervalsWellFormed key specs = (== Just 0) . foldl step (Just (0 :: Int))
  where
    belongs identifier = maybe False ((== key) . (.key)) (Map.lookup identifier specs)
    step Nothing _ = Nothing
    step (Just count) event = case event of
      HandlerStarted identifier _ _ _ | belongs identifier -> if count == 0 then Just 1 else Nothing
      HandlerEnded identifier _ _ _ _ | belongs identifier -> if count == 1 then Just 0 else Nothing
      _ -> Just count

keyText :: Int -> Text
keyText key = "key-" <> Text.pack (show key)
