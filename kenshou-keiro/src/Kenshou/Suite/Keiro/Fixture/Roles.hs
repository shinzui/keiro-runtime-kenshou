module Kenshou.Suite.Keiro.Fixture.Roles (roles) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (withAsync)
import Control.Exception (bracket)
import Control.Monad (forM, forever)
import Data.Aeson (Value, object, withObject, (.!=), (.:), (.:?), (.=))
import Data.Aeson.Types (Parser, parseMaybe)
import Data.IORef (atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (getCurrentTime)
import Data.Time.Clock.POSIX (getPOSIXTime)
import Effectful (liftIO)
import GHC.Clock (getMonotonicTimeNSec)
import Keiro.Command (RunCommandOptions (..), defaultRunCommandOptions)
import Keiro.ProcessManager (PMCommandResult (..), ProcessManagerResult (..), RejectedCommandPolicy (..), WorkerOptions (..), defaultWorkerOptions, runProcessManagerOnce, runProcessManagerWorkerWith)
import Keiro.Projection (AsyncApplyOutcome (..))
import Keiro.Router (runRouterWorkerWith)
import Keiro.Subscription.Shard.Worker (RetryDelay (..), ShardAck (..), ShardDelivery (..), ShardedWorkerOptions (..), defaultShardedWorkerOptions, runShardedSubscriptionGroupAck)
import Kenshou.Core.Id (unSeed)
import Kenshou.Core.Role (ControlMessage (..), PostgresConnInfo (..), RoleContext (..), RoleName, WorkerInit (..), WorkerMessage (..), WorkerRole (..), mkRoleName)
import Kenshou.Measure.Sampler.Csv (CsvWriter, appendCsv, closeCsv, openCsv)
import Kenshou.Measure.Sampler.Process qualified as ProcessSample
import Kenshou.Measure.Sampler.Rts (closeRtsSampler, openRtsSampler, sampleRts)
import Kenshou.Suite.Keiro.Fixture.Account
import Kenshou.Suite.Keiro.Fixture.Bonus
import Kenshou.Suite.Keiro.Fixture.Bridge
import Kenshou.Suite.Keiro.Fixture.Projection
import Kenshou.Suite.Keiro.Fixture.Runtime
import Kenshou.Suite.Keiro.Fixture.Transfer
import Kenshou.Suite.Keiro.Fixture.Workload qualified as Workload
import Kiroku.Store (defaultConnectionSettings)
import Kiroku.Store.Subscription.Types (ConsumerGroup (..), SubscriptionName (..), SubscriptionTarget (..))
import Kiroku.Store.Types (CategoryName (..), RecordedEvent (..))
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))

roles :: [WorkerRole]
roles =
  [ WorkerRole (roleName "keiro/command-writer") "Submits a deterministic sequence of account and bonus operations." commandWriter,
    WorkerRole (roleName "keiro/pm-worker") "Dispatches transfer saga inputs from a durable subscription." processManagerWorker,
    WorkerRole (roleName "keiro/pm-sharded-worker") "Dispatches transfer saga inputs from owned Kiroku shards." processManagerShardedWorker,
    WorkerRole (roleName "keiro/router-worker") "Dispatches bonus fanout from a durable subscription." routerWorker,
    WorkerRole (roleName "keiro/projection-worker") "Applies the asynchronous account activity projection." projectionWorker
  ]

roleName :: Text -> RoleName
roleName = either (error . Text.unpack) id . mkRoleName

awaitStart :: RoleContext -> IO Bool
awaitStart context =
  context.receive >>= \case
    Just CtlStart -> pure True
    Just (CtlStop _) -> pure False
    Just _ -> awaitStart context
    Nothing -> pure False

withPostgres :: RoleContext -> (PostgresConnInfo -> IO ()) -> IO ()
withPostgres context action = case context.init.postgres of
  Nothing -> context.send (WrkError "Keiro worker requires PostgreSQL")
  Just postgres -> action postgres

withRoleSampler :: RoleContext -> Bool -> IO value -> IO value
withRoleSampler _ False action = action
withRoleSampler context True action = bracket open close \(rts, process, start) -> withAsync (sampleLoop rts process start) (const action)
  where
    label = Text.unpack (Text.replace "/" "-" context.init.instanceName)
    directory = context.init.outDir </> "series" </> "children" </> label
    open = do
      createDirectoryIfMissing True directory
      rts <- openRtsSampler (directory </> "rts.csv")
      process <- ProcessSample.openProcessSampler (directory </> "proc.csv")
      start <- getMonotonicTimeNSec
      pure (rts, process, start)
    close (rts, process, _) = do
      maybe (pure ()) closeRtsSampler rts
      ProcessSample.closeProcessSampler process
    sampleLoop rts process start = forever do
      now <- getMonotonicTimeNSec
      wall <- getPOSIXTime
      let prefix = [Text.pack (show (now - start)), Text.pack (show (round (wall * 1000) :: Integer)), "steady"]
      maybe (pure ()) (\sampler -> sampleRts sampler prefix) rts
      ProcessSample.sampleProcess process prefix
      threadDelay 1000000

withLatencyCsv :: RoleContext -> Bool -> (Maybe CsvWriter -> IO value) -> IO value
withLatencyCsv _ False action = action Nothing
withLatencyCsv context True action =
  let label = Text.unpack (Text.replace "/" "-" context.init.instanceName)
      path = context.init.outDir </> "series" </> "children" </> label </> "latency.csv"
   in bracket (openCsv path ["t_mono_ns", "duration_ns", "operation"]) closeCsv (action . Just)

data WriterArgs = WriterArgs
  { worker :: !Int,
    workers :: !Int,
    startIndex :: !Int,
    count :: !Int,
    accounts :: !Int,
    clientRetryBudget :: !Int,
    parkAfterIndex :: !(Maybe Int),
    inlineProjectionSleep :: !Bool,
    inlineProjection :: !Bool,
    seedVerifySampleRate :: !Int,
    postSubmissionDelayMicros :: !Int,
    reportEvery :: !Int,
    sampleProcess :: !Bool
  }

parseWriterArgs :: Value -> Parser WriterArgs
parseWriterArgs = withObject "keiro command writer" \value ->
  WriterArgs
    <$> value .: "worker"
    <*> value .: "workers"
    <*> value .:? "startIndex" .!= 0
    <*> value .: "count"
    <*> value .:? "accounts" .!= 100
    <*> value .:? "clientRetryBudget" .!= 5
    <*> value .:? "parkAfterIndex"
    <*> value .:? "inlineProjectionSleep" .!= False
    <*> value .:? "inlineProjection" .!= False
    <*> value .:? "seedVerifySampleRate" .!= 1000
    <*> value .:? "postSubmissionDelayMicros" .!= 0
    <*> value .:? "reportEvery" .!= 1
    <*> value .:? "sampleProcess" .!= False

commandWriter :: RoleContext -> IO ()
commandWriter context = case parseMaybe parseWriterArgs context.init.args of
  Nothing -> context.send (WrkError "invalid command-writer arguments")
  Just args -> withPostgres context \postgres -> do
    context.send WrkReady
    started <- awaitStart context
    if not started
      then pure ()
      else withRoleSampler context args.sampleProcess $ withLatencyCsv context args.sampleProcess \latency -> withFixtureEnv (defaultConnectionSettings postgres.connectionString) \fixture -> do
        stopRequested <- newIORef False
        let receiveStop =
              context.receive >>= \case
                Just (CtlStop _) -> writeIORef stopRequested True
                Nothing -> writeIORef stopRequested True
                Just _ -> receiveStop
            spec = Workload.defaultWorkloadSpec {Workload.accounts = args.accounts}
            operations = take args.count (drop args.startIndex (Workload.workerOps (unSeed context.init.seed) spec args.worker args.workers))
            eventStream = accountEventStream (SnapEvery 100)
            loop completed [] = context.send (WrkDone (Just ("completed=" <> Text.pack (show completed))))
            loop completed (operation : rest) = do
              stopping <- readIORef stopRequested
              if stopping
                then context.send (WrkDone (Just ("completed=" <> Text.pack (show completed))))
                else do
                  startedAt <- getMonotonicTimeNSec
                  outcomes <- forM (Workload.opCommands (unSeed context.init.seed) operation) \(choice, eventId) ->
                    case choice of
                      Left (_, bonusCommand) -> submitBonusCommand fixture defaultRunCommandOptions eventId bonusCommand
                      Right (_, accountCommand) ->
                        let runnerKind = if args.inlineProjectionSleep then RunnerWithProjections [accountBalanceProjection, parkingProjection] else if args.inlineProjection then RunnerWithProjections [accountBalanceProjection] else RunnerPlain
                         in submitAccountCommand fixture eventStream runnerKind defaultRunCommandOptions {seedVerifySampleRate = args.seedVerifySampleRate} args.clientRetryBudget eventId accountCommand
                  endedAt <- getMonotonicTimeNSec
                  maybe (pure ()) (\writer -> appendCsv writer [Text.pack (show endedAt), Text.pack (show (endedAt - startedAt)), Text.pack (show operation.index)]) latency
                  threadDelay args.postSubmissionDelayMicros
                  if any isFailure outcomes
                    then context.send (WrkError ("command writer operation failed at index " <> Text.pack (show operation.index)))
                    else do
                      if args.parkAfterIndex == Just (fromIntegral operation.index)
                        then parkForever context ("after-operation-" <> Text.pack (show operation.index))
                        else pure ()
                      if operation.index `mod` fromIntegral (max 1 args.reportEvery) == 0
                        then do
                          context.send (WrkCustom "submission" (object ["index" .= operation.index, "outcomes" .= map show outcomes]))
                          context.send (WrkFacts [object ["worker" .= args.worker, "index" .= operation.index, "outcomes" .= map show outcomes]])
                          now <- getCurrentTime
                          context.send (WrkProgress (fromIntegral operation.index) now)
                        else pure ()
                      loop (completed + 1) rest
        withAsync receiveStop \_ -> loop (0 :: Int) operations
  where
    isFailure = \case SubmitFailed _ -> True; SubmitRejected -> True; _ -> False

data DispatcherArgs = DispatcherArgs
  { subscription :: !Text,
    parkBeforeAppend :: !(Maybe Int),
    parkBeforeAck :: !Bool,
    reverseRecipients :: !Bool,
    rejectedDeadLetter :: !Bool,
    inlineProjection :: !Bool,
    sampleProcess :: !Bool,
    reportAcks :: !Bool,
    groupMember :: !(Maybe Int),
    groupSize :: !(Maybe Int)
  }

parseDispatcherArgs :: Value -> Parser DispatcherArgs
parseDispatcherArgs = withObject "keiro dispatcher" \value ->
  DispatcherArgs
    <$> value .: "subscription"
    <*> value .:? "parkBeforeAppend"
    <*> value .:? "parkBeforeAck" .!= False
    <*> value .:? "reverseRecipients" .!= False
    <*> value .:? "rejectedDeadLetter" .!= False
    <*> value .:? "inlineProjection" .!= False
    <*> value .:? "sampleProcess" .!= False
    <*> value .:? "reportAcks" .!= False
    <*> value .:? "groupMember"
    <*> value .:? "groupSize"

parkForever :: RoleContext -> Text -> IO ()
parkForever context point = do
  context.send (WrkCustom "parked" (object ["window" .= point]))
  forever (threadDelay 1000000)

dispatchOptions :: RoleContext -> DispatcherArgs -> IO RunCommandOptions
dispatchOptions context args = do
  invocations <- newIORef (0 :: Int)
  pure
    defaultRunCommandOptions
      { beforeAppend = do
          invocation <- atomicModifyIORef' invocations (\n -> (n + 1, n + 1))
          if args.parkBeforeAppend == Just invocation
            then parkForever context ("before-append-" <> Text.pack (show invocation))
            else pure ()
      }

processManagerWorker :: RoleContext -> IO ()
processManagerWorker context = case parseMaybe parseDispatcherArgs context.init.args of
  Nothing -> context.send (WrkError "invalid pm-worker arguments")
  Just args -> withPostgres context \postgres -> do
    context.send WrkReady
    started <- awaitStart context
    if not started
      then pure ()
      else withRoleSampler context args.sampleProcess $ withFixtureEnv (defaultConnectionSettings postgres.connectionString) \fixture -> do
        options <- dispatchOptions context args
        let KeiroRunner runFixture = fixture.runner
        result <- runFixture do
          let group = ConsumerGroup <$> (fromIntegral <$> args.groupMember) <*> (fromIntegral <$> args.groupSize)
          adapter <- kirokuBridge fixture.store (sagaAdapterConfig (SubscriptionName args.subscription) group)
          let observed =
                interposeAck
                  ( \_ decision -> do
                      if args.reportAcks then liftIO (context.send (WrkCustom "acknowledged" (object ["decision" .= show decision]))) else pure ()
                      if args.parkBeforeAck then liftIO (parkForever context "before-ack") else pure ()
                  )
                  adapter
          runProcessManagerWorkerWith defaultWorkerOptions options (transferManager (accountEventStream SnapNever) (const (if args.inlineProjection then [accountBalanceProjection] else []))) observed decodeTransferSignal
        case result of
          Left issue -> context.send (WrkError (Text.pack (show issue)))
          Right () -> context.send (WrkDone Nothing)

processManagerShardedWorker :: RoleContext -> IO ()
processManagerShardedWorker context = case parseMaybe parseDispatcherArgs context.init.args of
  Nothing -> context.send (WrkError "invalid pm-sharded-worker arguments")
  Just args -> withPostgres context \postgres -> do
    context.send WrkReady
    started <- awaitStart context
    if not started
      then pure ()
      else withRoleSampler context args.sampleProcess $ withFixtureEnv (defaultConnectionSettings postgres.connectionString) \fixture -> do
        let KeiroRunner runFixture = fixture.runner
            manager = transferManager (accountEventStream SnapNever) (const [])
            options = (defaultShardedWorkerOptions (Category (CategoryName "account")) 8) {renewInterval = 0.2, leaseTtl = 2}
            handle delivery = case decodeTransferSignal delivery.event of
              Nothing -> pure ShardAckOk
              Just (recorded, signal) ->
                runFixture (runProcessManagerOnce defaultRunCommandOptions manager recorded signal) >>= \case
                  Left _ -> pure (ShardAckRetry (RetryDelay 0.2))
                  Right (Left _) -> pure (ShardAckRetry (RetryDelay 0.2))
                  Right (Right result) ->
                    if any (\case PMCommandFailed {} -> True; _ -> False) result.commandResults
                      then pure (ShardAckRetry (RetryDelay 0.2))
                      else pure ShardAckOk
        runShardedSubscriptionGroupAck fixture.store (SubscriptionName args.subscription) options handle

routerWorker :: RoleContext -> IO ()
routerWorker context = case parseMaybe parseDispatcherArgs context.init.args of
  Nothing -> context.send (WrkError "invalid router-worker arguments")
  Just args -> withPostgres context \postgres -> do
    context.send WrkReady
    started <- awaitStart context
    if not started
      then pure ()
      else withRoleSampler context args.sampleProcess $ withFixtureEnv (defaultConnectionSettings postgres.connectionString) \fixture -> do
        options <- dispatchOptions context args
        let KeiroRunner runFixture = fixture.runner
        result <- runFixture do
          adapter <- kirokuBridge fixture.store (bonusAdapterConfig (SubscriptionName args.subscription))
          let observed =
                interposeAck
                  ( \_ decision -> do
                      if args.reportAcks then liftIO (context.send (WrkCustom "acknowledged" (object ["decision" .= show decision]))) else pure ()
                      if args.parkBeforeAck then liftIO (parkForever context "before-ack") else pure ()
                  )
                  adapter
              recipients bonus = do
                selected <- directoryRecipients bonus
                pure (if args.reverseRecipients then reverse selected else selected)
              workerOptions = defaultWorkerOptions {rejectedCommandPolicy = if args.rejectedDeadLetter then RejectedDeadLetter else RejectedHalt}
          runRouterWorkerWith workerOptions options (bonusRouterWith bonusRouterName (accountEventStream SnapNever) recipients) observed decodeBonusDeclared
        case result of
          Left issue -> context.send (WrkError (Text.pack (show issue)))
          Right () -> context.send (WrkDone Nothing)

data ProjectionArgs = ProjectionArgs {batchSize :: !Int, skipDedup :: !Bool, parkAfterApply :: !Bool, sampleProcess :: !Bool}

parseProjectionArgs :: Value -> Parser ProjectionArgs
parseProjectionArgs = withObject "keiro projection worker" \value ->
  ProjectionArgs <$> value .:? "batchSize" .!= 100 <*> value .:? "skipDedup" .!= False <*> value .:? "parkAfterApply" .!= False <*> value .:? "sampleProcess" .!= False

projectionWorker :: RoleContext -> IO ()
projectionWorker context = case parseMaybe parseProjectionArgs context.init.args of
  Nothing -> context.send (WrkError "invalid projection-worker arguments")
  Just args -> withPostgres context \postgres -> do
    context.send WrkReady
    started <- awaitStart context
    if not started
      then pure ()
      else withRoleSampler context args.sampleProcess $ withFixtureEnv (defaultConnectionSettings postgres.connectionString) \fixture -> do
        let sabotage = if args.skipDedup then SkipDedup else NoProjectionSabotage
        duplicates <- newIORef (0 :: Int)
        runAccountActivityWorker fixture.store (fromIntegral args.batchSize) sabotage \recorded outcome -> do
          context.send (WrkFacts [object ["eventId" .= show recorded.eventId, "outcome" .= show outcome]])
          case outcome of
            AsyncDuplicate -> do
              count <- atomicModifyIORef' duplicates (\n -> (n + 1, n + 1))
              context.send (WrkCustom "projection-duplicate" (object ["eventId" .= show recorded.eventId]))
              context.send (WrkCustom "projection-duplicate-count" (object ["count" .= count]))
            AsyncApplied -> context.send (WrkCustom "projection-applied" (object ["eventId" .= show recorded.eventId]))
            AsyncFenced -> pure ()
          if args.parkAfterApply && outcome == AsyncApplied
            then parkForever context "after-projection-apply"
            else pure ()
