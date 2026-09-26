module Kenshou.Suite.Shibuya.Correctness.KirokuAckMapping (scenario) where

import Control.Concurrent (threadDelay)
import Control.Exception (SomeException, displayException, try)
import Control.Monad (when)
import Data.Aeson (Result (..), Value (..), fromJSON, object, (.=))
import Data.Aeson.KeyMap qualified as KeyMap
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Data.Int (Int64)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time.Clock (UTCTime, diffUTCTime, getCurrentTime)
import Effectful (liftIO, runEff)
import Kenshou.Core.Context (RunContext, SummarySection (..), putSummary)
import Kenshou.Core.Dimension (PgDurability (..), PgVersion (..), noDimensions, postgresDimensions)
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Scenario (Placement (..), Scenario (..), ScenarioReport, Tier (..), failedWith, passed)
import Kenshou.Suite.Shibuya.Fixture.Kiroku (DeadLetterRow (..), KirokuFixture (..), appendTypedEvents, checkpointOf, deadLettersOf, eventPositions, subscriptionFor, withKirokuFixture)
import Kiroku.Store (EventType (..), RecordedEvent (..))
import Shibuya.Adapter.Kiroku (EventTypeFilter (..), KirokuAdapterConfig (..), SubscriptionName, SubscriptionTarget (..), defaultKirokuAdapterConfig, kirokuAdapter)
import Shibuya.App (defaultAppConfig, defaultShutdownConfig, mkProcessor, runApp, stopAppGracefully, waitApp)
import Shibuya.Core.Ack (AckDecision (..), DeadLetterReason (..), RetryDelay (..), mkDeadLetterCode)
import Shibuya.Core.Ingested (Message (..))
import Shibuya.Core.Metrics (ProcessorId (..))
import Shibuya.Core.Types (Attempt (..), Envelope (..))
import Shibuya.Telemetry.Effect (runTracingNoop)
import System.Timeout (timeout)

scenario :: Scenario
scenario =
  Scenario
    { id = either (error . Text.unpack) id (parseScenarioId "shibuya/kiroku-adapter/correctness/ack-decision-mapping"),
      revision = 1,
      summary = "Checks retry attempts, dead-letter reason mapping, filtered delivery and persisted checkpoint progress.",
      tier = TierSmoke,
      placement = PlaceEither,
      knobs = [],
      dimensions = postgresDimensions (PgDurable :| []) (Pg18 :| [Pg17]) noDimensions,
      phases = zeroPhases,
      requires = noEnvironment {postgres = Just (PostgresRequirement [SchemaKiroku] [] False)},
      knownDefect = Nothing,
      run = runMapping
    }

data Observation = Observation {number :: !Int, attempt :: !(Maybe Int), at :: !UTCTime}

runMapping :: RunContext -> IO ScenarioReport
runMapping context = do
  outcome <- try @SomeException $ timeout 30000000 $ withKirokuFixture context runFixture
  case outcome of
    Left err -> pure (failedWith ["kiroku-ack-mapping-exception"] (Text.pack (displayException err)))
    Right Nothing -> pure (failedWith ["kiroku-ack-mapping-timeout"] "Kiroku acknowledgement mapping did not finish within 30 seconds")
    Right (Just (observations, deadLetters, checkpoint, finalPosition, positions, drained)) -> do
      let attemptsFor number = [attempt | Observation {number = observed, attempt} <- observations, observed == number]
          timesFor number = [at | Observation {number = observed, at} <- observations, observed == number]
          retryDelay = case timesFor 2 of
            [first, second] -> realToFrac (diffUTCTime second first) :: Double
            _ -> -1
          expectedLetters = zip ([3 .. 7] :: [Int]) (take 5 (drop 2 positions))
          letterFor number = case lookup number expectedLetters of
            Nothing -> Nothing
            Just position -> case filter ((== position) . (.position)) deadLetters of
              [row] -> Just row
              _ -> Nothing
          hasReason number value = maybe False ((== value) . (.reason)) (letterFor number)
          failures =
            ["ack-ok-delivery" | attemptsFor 1 /= [Just 0] || attemptsFor 8 /= [Just 0] || attemptsFor 9 /= [Just 0]]
              <> ["retry-attempts" | attemptsFor 2 /= [Just 0, Just 1]]
              <> ["retry-delay" | retryDelay < 0.18]
              <> ["retry-budget" | attemptsFor 3 /= map Just [0 .. 4]]
              <> ["dead-letter-count-or-positions" | length deadLetters /= 5 || map (.position) deadLetters /= map snd expectedLetters]
              <> ["direct-dead-letter-attempt-count" | any (maybe True ((/= 1) . (.attempts)) . letterFor) [4 .. 7]]
              <> ["dead-letter-id-missing" | any (Text.null . (.eventId)) deadLetters]
              <> ["retry-budget-dead-letter" | maybe True ((/= 5) . (.attempts)) (letterFor 3) || not (hasReason 3 (object ["kind" .= ("max_attempts_exceeded" :: Text), "attempts" .= (5 :: Int)]))]
              <> ["poison-reason" | not (hasReason 4 (object ["kind" .= ("poison" :: Text), "detail" .= ("poison" :: Text)]))]
              <> ["invalid-reason" | not (hasReason 5 (object ["kind" .= ("invalid_payload" :: Text), "detail" .= ("invalid" :: Text)]))]
              <> ["max-attempts-reason" | not (hasReason 6 (object ["kind" .= ("max_attempts_exceeded" :: Text), "attempts" .= (0 :: Int)]))]
              <> ["application-reason" | not (hasReason 7 (object ["kind" .= ("other" :: Text), "summary" .= ("projection.rejected: policy" :: Text), "detail" .= object ["code" .= ("projection.rejected" :: Text), "detail" .= ("policy" :: Text)]]))]
              <> ["filtered-event-delivered" | not (null (attemptsFor 10))]
              <> ["checkpoint-not-at-batch-tail" | checkpoint /= Just finalPosition]
              <> ["adapter-did-not-drain" | not drained]
      putSummary context Verdicts "kiroku-ack-decision-mapping" $
        object
          [ "deliveries" .= [(number, attempt) | Observation {number, attempt} <- observations],
            "retryDelaySeconds" .= retryDelay,
            "deadLetters" .= [object ["position" .= row.position, "eventId" .= row.eventId, "reason" .= row.reason, "attempts" .= row.attempts] | row <- deadLetters],
            "checkpoint" .= checkpoint,
            "lastEventPosition" .= finalPosition,
            "drained" .= drained
          ]
      pure $ if null failures then passed else failedWith failures (Text.intercalate "; " failures)

runFixture :: KirokuFixture -> IO ([Observation], [DeadLetterRow], Maybe Int64, Int64, [Int64], Bool)
runFixture fixture = do
  appendTypedEvents fixture ([(number, "Keep") | number <- [1 .. 9]] <> [(10, "Drop")])
  positions <- eventPositions fixture
  finalPosition <- case reverse positions of
    position : _ | length positions == 10 -> pure position
    _ -> ioError (userError "fixture did not append 10 events")
  let subscription = subscriptionFor fixture "mapping"
      code = either (error . Text.unpack) id (mkDeadLetterCode "projection.rejected")
      config = (defaultKirokuAdapterConfig subscription (Category fixture.category)) {eventTypeFilter = OnlyEventTypes (Set.singleton (EventType "Keep"))}
  observed <- newIORef ([] :: [Observation])
  drained <- runEff $ runTracingNoop $ do
    adapter <- kirokuAdapter fixture.store config
    let handler message = do
          let number = sequenceOf message
              attempt = fromIntegral . (.unAttempt) <$> message.envelope.attempt
          now <- liftIO getCurrentTime
          liftIO $ atomicModifyIORef' observed (\values -> (Observation number attempt now : values, ()))
          pure $ case number of
            2 | attempt == Just 0 -> AckRetry (RetryDelay 0.2)
            3 -> AckRetry (RetryDelay 0)
            4 -> AckDeadLetter (PoisonPill "poison")
            5 -> AckDeadLetter (InvalidPayload "invalid")
            6 -> AckDeadLetter MaxRetriesExceeded
            7 -> AckDeadLetter (ApplicationFailure code "policy")
            _ -> AckOk
    started <- runApp defaultAppConfig [(ProcessorId "kiroku-ack-mapping", mkProcessor adapter handler)]
    case started of
      Left err -> error (show err)
      Right handle -> do
        liftIO $ waitForCheckpoint fixture subscription finalPosition
        drained <- stopAppGracefully defaultShutdownConfig handle
        waitApp handle
        pure drained
  observations <- reverse <$> readIORef observed
  deadLetters <- deadLettersOf fixture subscription 0
  checkpoint <- checkpointOf fixture subscription 0
  pure (observations, deadLetters, checkpoint, finalPosition, positions, drained)

sequenceOf :: Message es RecordedEvent -> Int
sequenceOf message = case message.envelope.payload.payload of
  Object fields -> case KeyMap.lookup "sequence" fields >>= parseInt of
    Just number -> number
    Nothing -> error "Kiroku event lacks a sequence number"
  _ -> error "Kiroku event payload is not an object"
  where
    parseInt value = case fromJSON value of
      Success number -> Just number
      Error _ -> Nothing

waitForCheckpoint :: KirokuFixture -> SubscriptionName -> Int64 -> IO ()
waitForCheckpoint fixture subscription finalPosition = do
  checkpoint <- checkpointOf fixture subscription 0
  when (checkpoint /= Just finalPosition) $ threadDelay 10000 >> waitForCheckpoint fixture subscription finalPosition
