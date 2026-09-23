module Kenshou.Suite.Shibuya.Correctness.CoreRunner (scenarios) where

import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Text (Text)
import Data.Text qualified as Text
import Effectful (IOE, liftIO, runEff)
import Kenshou.Core.Dimension (noDimensions)
import Kenshou.Core.Env (noEnvironment)
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Scenario (KnownDefect (..), Placement (..), Scenario (..), Tier (..), failedWith, passed)
import Kenshou.Suite.Shibuya.Cohort (knownOnReleasedCore, rev)
import Shibuya.Adapter (Adapter (..))
import Shibuya.App (AppConfig (..), QueueProcessor (..), defaultAppConfig, mkProcessor, runApp, stopApp)
import Shibuya.Core.Ack (AckDecision (..))
import Shibuya.Core.AckHandle (AckHandle (..))
import Shibuya.Core.Ingested (mkIngested)
import Shibuya.Core.Metrics (ProcessorId (..))
import Shibuya.Core.Types (MessageId (..), mkEnvelope)
import Shibuya.Handler (Handler)
import Shibuya.Policy (Concurrency (..), OrderingPolicy (..))
import Shibuya.Telemetry.Effect (Tracing, runTracingNoop)
import Streamly.Data.Stream qualified as Stream

scenarios :: [Scenario]
scenarios =
  [ coreScenario
      "shibuya/core-runner/correctness/invalid-config-rejected-before-effects"
      "Rejects invalid inbox and ordering policies before pulling a source or shutting down an adapter."
      Nothing
      invalidConfiguration,
    coreScenario
      "shibuya/core-runner/correctness/duplicate-processor-ids-are-rejected"
      "Rejects duplicate processor identities before either source is pulled."
      (knownOnReleasedCore (rev 3 "REV-3-F2"))
      duplicateProcessorIds
  ]

coreScenario :: Text -> Text -> Maybe KnownDefect -> IO [Text] -> Scenario
coreScenario identifier description defect action =
  Scenario
    { id = either (error . Text.unpack) id (parseScenarioId identifier),
      revision = 1,
      summary = description,
      tier = TierSmoke,
      placement = PlaceEither,
      knobs = [],
      dimensions = noDimensions,
      phases = zeroPhases,
      requires = noEnvironment,
      knownDefect = defect,
      run = \_ -> do
        failures <- action
        pure $ if null failures then passed else failedWith (maybe failures (.expectedFailures) defect) (Text.intercalate "; " failures)
    }

invalidConfiguration :: IO [Text]
invalidConfiguration = do
  inbox <- checkRejected "inbox-size-zero" $ \adapter ->
    (defaultAppConfig {inboxSize = 0}, [(ProcessorId "invalid-inbox", mkProcessor adapter alwaysAckOk)])
  strictAsync <- checkRejected "strict-async" $ \adapter ->
    (defaultAppConfig, [(ProcessorId "invalid-policy", (mkProcessor adapter alwaysAckOk) {ordering = StrictInOrder, concurrency = Async 2})])
  pure (inbox <> strictAsync)

duplicateProcessorIds :: IO [Text]
duplicateProcessorIds =
  checkRejected "duplicate-processor-id" $ \adapter ->
    ( defaultAppConfig,
      [ (ProcessorId "duplicate", mkProcessor adapter alwaysAckOk),
        (ProcessorId "duplicate", mkProcessor adapter alwaysAckOk)
      ]
    )

-- A rejected configuration must not touch the adapter, even on a failing cohort.
checkRejected :: Text -> (Adapter '[Tracing, IOE] Text -> (AppConfig, [(ProcessorId, QueueProcessor '[Tracing, IOE])])) -> IO [Text]
checkRejected label configure = do
  pulls <- newIORef (0 :: Int)
  shutdowns <- newIORef (0 :: Int)
  rejected <- runEff $ runTracingNoop $ do
    let delivery = mkIngested (mkEnvelope (MessageId "configuration-probe") ("probe" :: Text)) (AckHandle (\_ -> pure ()))
        adapter =
          Adapter
            { adapterName = "kenshou:configuration-probe",
              source = Stream.mapM (\message -> liftIO (modifyIORef' pulls (+ 1)) >> pure message) (Stream.fromList [delivery]),
              shutdown = liftIO (modifyIORef' shutdowns (+ 1))
            }
        (config, processors) = configure adapter
    result <- runApp config processors
    case result of
      Left _ -> pure True
      Right handle -> stopApp handle >> pure False
  pulled <- readIORef pulls
  stopped <- readIORef shutdowns
  pure $
    [label <> ": runApp accepted invalid configuration" | not rejected]
      <> [label <> ": source was pulled before validation" | pulled /= 0]
      <> [label <> ": shutdown ran before validation" | stopped /= 0 && rejected]

alwaysAckOk :: Handler es Text
alwaysAckOk _ = pure AckOk
