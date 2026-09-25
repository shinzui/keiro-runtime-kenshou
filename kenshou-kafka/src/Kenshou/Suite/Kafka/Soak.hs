module Kenshou.Suite.Kafka.Soak (scenarios) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (async, wait)
import Control.Monad (foldM, forM, forM_, when)
import Data.Aeson (FromJSON (..), object, withObject, (.:), (.=))
import Data.Aeson qualified as Aeson
import Data.Bits (shiftL, testBit, (.|.))
import Data.ByteString qualified as Bytes
import Data.ByteString.Char8 qualified as Char8
import Data.ByteString.Lazy qualified as LazyBytes
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as TextIO
import Data.Vector.Unboxed qualified as Vector
import Data.Vector.Unboxed.Mutable qualified as MutableVector
import Data.Word (Word64, Word8)
import Effectful (liftIO, runEff)
import Effectful.Error.Static (runError)
import GHC.Clock (getMonotonicTimeNSec)
import Kafka.Consumer.Types (ConsumerGroupId (..))
import Kafka.Effectful.Producer qualified as P
import Kafka.Types (BrokerAddress (..), KafkaError, TopicName (..))
import Kenshou.Check.Process (Child, Supervisor, awaitReady, readChildMessages, roleProcess, sendCommand, spawn, stopGracefully, withSupervisor)
import Kenshou.Check.Scenario (CheckEnv, withCheck)
import Kenshou.Core.Context (ArtifactDir (..), RunContext (..), SummarySection (..), artifactPath, declareMediaType, putSummary)
import Kenshou.Core.Dimension (noDimensions)
import Kenshou.Core.Env (noEnvironment)
import Kenshou.Core.Id (parseScenarioId, unSeed)
import Kenshou.Core.Knob (knobInt, mkKnobName)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Role (ControlMessage (..), WorkerMessage (..))
import Kenshou.Core.Scenario (CohortScope (..), KnownDefect (..), PackageCondition (..), Placement (..), Scenario (..), ScenarioReport, Tier (..), failedWith, inconclusiveBecause, passed)
import Kenshou.Diagnose.Leak (LeakReport (..), LeakSpec (..), LeakVerdict (..), ProbeReport (..), ProbeSpec (..), analyseSeriesDirectory, defaultLeakSpec)
import Kenshou.Env.Kafka
import Kenshou.Suite.Kafka.Fixture (firstBrokers, intKnob)
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))

data Mode = Stability | Churn deriving stock (Eq)

data Profile = Full | Reduced deriving stock (Eq)

scenarios :: [Scenario]
scenarios = [scenario mode profile | mode <- [Stability, Churn], profile <- [Full, Reduced]]

scenario :: Mode -> Profile -> Scenario
scenario mode profile =
  Scenario
    { id = either (error . Text.unpack) id (parseScenarioId ("kafka/" <> component <> "/soak/" <> name <> suffix)),
      revision = 1,
      summary = if mode == Stability then "Judges two adapter consumers for resource growth, delivery loss, and lag under sustained traffic." else "Judges native memory growth while a second consumer repeatedly joins and leaves.",
      tier = if profile == Full then TierSoak else TierExtended,
      placement = if profile == Full then PlaceCell else PlaceEither,
      knobs =
        [ intKnob "soak.duration-minutes" "Traffic duration" (if profile == Full then 240 else 20) 1 480,
          intKnob "soak.sample-seconds" "Resource sample interval" 10 1 60,
          intKnob "kafka.rate-per-second" "Open-loop producer rate" 500 1 5000,
          intKnob "soak.restart-every-minutes" "Consumer restart interval" 5 1 120,
          intKnob "soak.churn-seconds" "Membership change interval" 10 1 120
        ],
      dimensions = noDimensions,
      phases = zeroPhases,
      requires = noEnvironment,
      knownDefect =
        if mode == Churn
          then
            Just
              KnownDefect
                { reference = "mori://shinzui/hw-kafka-client/commits/6caed636898a78e9f6e5a9c93eeb5562cbb2580a",
                  summary = "Hackage hw-kafka-client discards redirect-race records without destroying native messages.",
                  expectedFailures = ["native-memory-leak"],
                  appliesTo = OnlyWhen (ResolvedFromHackage "hw-kafka-client" :| [])
                }
          else Nothing,
      run = runSoak mode profile
    }
  where
    component = if mode == Stability then "pipeline" else "consumer"
    name = if mode == Stability then "consumer-memory-and-fd-stability" else "rebalance-churn-native-memory"
    suffix = if profile == Full then "" else "-reduced"

data Worker = Worker {index :: Int, child :: Child, ledger :: FilePath}

data Sample = Sample
  { monoNs :: Word64,
    rssBytes :: Maybe Word64,
    osThreads :: Maybe Word64,
    fds :: Maybe Word64,
    majorGcs :: Maybe Word64,
    liveBytes :: Maybe Word64,
    memInUseBytes :: Maybe Word64,
    haskellThreads :: Int
  }

instance FromJSON Sample where
  parseJSON = withObject "soak sample" \v -> Sample <$> v .: "monoNs" <*> v .: "rssBytes" <*> v .: "osThreads" <*> v .: "fds" <*> v .: "majorGcs" <*> v .: "liveBytes" <*> v .: "memInUseBytes" <*> v .: "haskellThreads"

runSoak :: Mode -> Profile -> RunContext -> IO ScenarioReport
runSoak mode profile context = do
  spec <- either (ioError . userError . Text.unpack) pure (kafkaEnvSpecFromRunSpec context)
  withKafkaEnv context spec \env -> do
    let minutes = knob "soak.duration-minutes"
        rate = knob "kafka.rate-per-second"
        sampleSeconds = knob "soak.sample-seconds"
        restartMinutes = knob "soak.restart-every-minutes"
        churnSeconds = knob "soak.churn-seconds"
        target = minutes * 60 * rate
        group = groupName env "soak"
    [topic] <- createTopics env [TopicSpec "soak" 4 mempty]
    (workers, acknowledgements, lagSamples, exits, drained) <- withCheck context \check -> withSupervisor check \supervisor -> do
      nextIndex <- newIORef (0 :: Int)
      let startWorker = do
            index <- atomicModifyIORef' nextIndex (\old -> (old + 1, old))
            startMember context check supervisor env topic group target sampleSeconds index
      first <- startWorker
      second <- if mode == Stability then Just <$> startWorker else pure Nothing
      acknowledgements <- newIORef (0 :: Int, 0 :: Int)
      producer <- async (producePaced env topic target rate acknowledgements)
      let ticks = (minutes * 60 + sampleSeconds - 1) `div` sampleSeconds
          step (activeFirst, activeSecond, history, exits, lags) tick = do
            threadDelay (min sampleSeconds (minutes * 60 - (tick - 1) * sampleSeconds) * 1000000)
            snapshot <- describeGroup env group
            let lag = sum [maybe 0 fromIntegral offset.lag | offset <- snapshot.offsets]
                lags' = (tick * sampleSeconds, lag) : lags
            if mode == Stability && tick * sampleSeconds < minutes * 60 && tick * sampleSeconds `mod` (restartMinutes * 60) == 0
              then do
                exit <- stopGracefully supervisor activeFirst.child 20000
                replacement <- startWorker
                pure (replacement, activeSecond, history <> [replacement], exit : exits, lags')
              else
                if mode == Churn && tick * sampleSeconds < minutes * 60 && tick * sampleSeconds `mod` churnSeconds == 0
                  then case activeSecond of
                    Nothing -> do
                      joined <- startWorker
                      pure (activeFirst, Just joined, history <> [joined], exits, lags')
                    Just member -> do
                      exit <- stopGracefully supervisor member.child 20000
                      pure (activeFirst, Nothing, history, exit : exits, lags')
                  else pure (activeFirst, activeSecond, history, exits, lags')
      (lastFirst, lastSecond, history, earlyExits, lags) <- foldM step (first, second, first : maybe [] pure second, [], []) [1 .. ticks]
      wait producer
      drained <- awaitGroup env group 300 (\snapshot -> length snapshot.offsets == 4 && all ((== Just 0) . (.lag)) snapshot.offsets)
      lastExits <- forM (lastFirst : maybe [] pure lastSecond) (\member -> stopGracefully supervisor member.child 20000)
      ack <- readIORef acknowledgements
      pure (history, ack, reverse lags, earlyExits <> lastExits, drained)
    results <- forM workers (inspectWorker context profile mode target)
    _ <- deleteRunGroups env
    _ <- deleteRunTopics env
    ledgerBits <- MutableVector.replicate ((target + 7) `div` 8) (0 :: Word8)
    ledgerPresent <- forM workers (mergeLedger ledgerBits)
    combined <- Vector.freeze ledgerBits
    let (missingCount, missingFirst) = foldl' (\(count, first) value -> if testBit (combined Vector.! (value `div` 8)) (value `mod` 8) then (count, first) else (count + 1, if length first < 20 then first <> [value] else first)) (0 :: Int, []) [0 .. target - 1]
        leakVerdicts = [(worker.index, report.verdict) | (worker, report, _) <- results]
        judgedIndex = if mode == Churn then 0 else 1
        judgedVerdicts = [verdict | (index, verdict) <- leakVerdicts, index == judgedIndex]
        workerErrors = [(worker.index, problem) | (worker, _, problems) <- results, problem <- problems]
        (acked, deliveryFailures) = acknowledgements
        zeroLag = case drained of Right _ -> True; Left _ -> False
        lagLimit = rate * 10
        lagOver = [(second, lag) | (second, lag) <- lagSamples, lag > lagLimit, mode == Stability, second `mod` (restartMinutes * 60) > 20]
        leakFailures = [if mode == Churn then "native-memory-leak" else "resource-leak" | (_, LeakSuspected) <- leakVerdicts]
        failures =
          ["soak-acknowledgements" | acked /= target || deliveryFailures /= 0]
            <> ["soak-no-loss" | missingCount /= 0]
            <> ["soak-ledger-missing" | not (and ledgerPresent)]
            <> ["soak-zero-lag" | not zeroLag]
            <> ["soak-worker-exit" | any (/= ExitSuccess) exits || not (null workerErrors)]
            <> ["soak-lag-bound" | not (null lagOver)]
            <> leakFailures
    putSummary context Verdicts "kafkaSoak" (object ["target" .= target, "acknowledged" .= acked, "deliveryFailures" .= deliveryFailures, "missingCount" .= missingCount, "missingFirst" .= missingFirst, "zeroLag" .= zeroLag, "lagOver" .= take 20 lagOver, "workerErrors" .= workerErrors, "leakVerdicts" .= [(index, show verdict) | (index, verdict) <- leakVerdicts], "judgedWorker" .= judgedIndex])
    pure $
      if not (null failures)
        then failedWith failures ("missing=" <> Text.pack (show missingFirst) <> " workerErrors=" <> Text.pack (show workerErrors))
        else
          if null judgedVerdicts || any (== InsufficientData) judgedVerdicts
            then inconclusiveBecause "long-lived consumer leak series have insufficient duration or samples"
            else passed
  where
    knob name = fromIntegral (knobInt context.knobs (either (error . Text.unpack) id (mkKnobName name)))

startMember :: RunContext -> CheckEnv -> Supervisor -> KafkaEnv -> TopicName -> ConsumerGroupId -> Int -> Int -> Int -> IO Worker
startMember context check supervisor env (TopicName topic) (ConsumerGroupId group) target sampleSeconds index = do
  let ledger = context.outDir </> "ledgers" </> ("consumer-" <> show index <> ".bits")
      args =
        object
          [ "brokers" .= fmap unBrokerAddress (firstBrokers env),
            "topic" .= topic,
            "group" .= group,
            "autoCommitMillis" .= (500 :: Int),
            "emitOkFacts" .= False,
            "progressEvery" .= (1000 :: Int),
            "ledgerPath" .= ledger,
            "ledgerRecords" .= target,
            "sampleEverySeconds" .= sampleSeconds,
            "streamMode" .= True
          ]
  spec <- roleProcess check "kafka/soak-consumer" index args
  child <- spawn supervisor spec
  awaitReady child 10000
  sendCommand child CtlStart
  pure (Worker index child ledger)

producePaced :: KafkaEnv -> TopicName -> Int -> Int -> IORef (Int, Int) -> IO ()
producePaced env topic target rate counter = do
  let props = P.brokersList (firstBrokers env) <> P.extraProp "acks" "all"
      intervalNs = max 1 (1000000000 `div` fromIntegral rate)
  result <- runEff . runError @KafkaError $ P.runKafkaProducer props $ do
    start <- liftIO getMonotonicTimeNSec
    forM_ [0 .. target - 1] \value -> do
      now <- liftIO getMonotonicTimeNSec
      let intended = start + fromIntegral value * intervalNs
      liftIO $ when (intended > now) (threadDelay (fromIntegral ((intended - now) `div` 1000)))
      let bytes = Char8.pack (show value)
          record = P.ProducerRecord topic P.UnassignedPartition (Just bytes) (Just bytes) mempty
      _ <- P.produceMessage' record (\report -> atomicModifyIORef' counter (\(ok, bad) -> case report of P.DeliverySuccess _ _ -> ((ok + 1, bad), ()); P.DeliveryFailure _ _ -> ((ok, bad + 1), ()); P.NoMessageError _ -> ((ok, bad + 1), ())))
      pure ()
    P.flushProducer
  either (ioError . userError . show) pure result

inspectWorker :: RunContext -> Profile -> Mode -> Int -> Worker -> IO (Worker, LeakReport, [Text])
inspectWorker context profile mode target worker = do
  messages <- readChildMessages worker.child
  let samples :: [Sample]
      samples =
        mapMaybe
          ( \case
              WrkCustom "soak-sample" value -> case Aeson.fromJSON value of
                Aeson.Success sample -> Just sample
                _ -> Nothing
              _ -> Nothing
          )
          messages
      problems = [problem | WrkError problem <- messages]
      root = context.outDir </> "soak" </> ("consumer-" <> show worker.index)
      series = root </> "series"
      cell :: (Show a) => Maybe a -> Text
      cell = maybe "" (Text.pack . show)
      csvRow columns = Text.intercalate "," columns <> "\n"
      proc =
        csvRow ["t_mono_ns", "phase", "rss_bytes", "os_threads", "open_fds"]
          <> mconcat [csvRow [cell (Just sample.monoNs), "steady", cell sample.rssBytes, cell sample.osThreads, cell sample.fds] | sample <- samples]
      rts =
        csvRow ["t_mono_ns", "phase", "live_bytes_last_gc", "major_gcs", "mem_in_use_bytes", "haskell_threads"]
          <> mconcat [csvRow [cell (Just sample.monoNs), "steady", cell sample.liveBytes, cell sample.majorGcs, cell sample.memInUseBytes, cell (Just sample.haskellThreads)] | sample <- samples]
      selected = if mode == Churn then ["process.native-bytes"] else ["heap.live-bytes", "process.native-bytes", "haskell.threads", "os.threads", "os.fds"]
      leakSpec =
        defaultLeakSpec
          { probes = filter (\probe -> probe.name `elem` selected) defaultLeakSpec.probes,
            warmupCutSeconds = if profile == Full then 300 else 60,
            minDurationSeconds = if profile == Full then 1200 else 900
          }
  createDirectoryIfMissing True series
  TextIO.writeFile (series </> "proc.csv") proc
  TextIO.writeFile (series </> "rts.csv") rts
  report <- analyseSeriesDirectory root leakSpec (unSeed context.seed + fromIntegral worker.index)
  path <- artifactPath context DiagnosisDir ("soak-consumer-" <> show worker.index <> ".json")
  LazyBytes.writeFile path (Aeson.encode (object ["verdict" .= show report.verdict, "probes" .= [object ["name" .= probe.probe, "verdict" .= show probe.verdict, "reason" .= probe.reason, "points" .= probe.points, "slopePerHour" .= probe.slopePerHour] | probe <- report.probes], "sampleCount" .= length samples, "ledgerExpectedBytes" .= ((target + 7) `div` 8)]))
  declareMediaType context ("diagnosis/soak-consumer-" <> show worker.index <> ".json") "application/json"
  declareMediaType context ("soak/consumer-" <> show worker.index <> "/series/proc.csv") "text/csv"
  declareMediaType context ("soak/consumer-" <> show worker.index <> "/series/rts.csv") "text/csv"
  pure (worker, report, problems)

mergeLedger :: MutableVector.IOVector Word8 -> Worker -> IO Bool
mergeLedger merged worker = do
  exists <- doesFileExist worker.ledger
  if not exists
    then pure False
    else do
      bytes <- Bytes.readFile worker.ledger
      let body = Bytes.drop 4 bytes
          unionAt index value = do
            old <- MutableVector.read merged index
            MutableVector.write merged index (old .|. value)
      case Bytes.take 4 bytes of
        "KDL1" | Bytes.length body == MutableVector.length merged -> do
          forM_ [0 .. Bytes.length body - 1] (\index -> unionAt index (Bytes.index body index))
          pure True
        "KSL1" | Bytes.length body `mod` 5 == 0 -> do
          forM_ [0, 5 .. Bytes.length body - 5] \position -> do
            let index = sum [fromIntegral (Bytes.index body (position + shift)) `shiftL` (8 * shift) | shift <- [0 .. 3]]
            if index >= MutableVector.length merged then ioError (userError ("soak ledger index out of range: " <> worker.ledger)) else unionAt index (Bytes.index body (position + 4))
          pure True
        _ -> ioError (userError ("invalid soak ledger format: " <> worker.ledger))
