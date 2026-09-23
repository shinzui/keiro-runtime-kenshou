module Kenshou.Suite.Keiro.Fixture.Roles (roles) where

import Control.Concurrent (threadDelay)
import Control.Monad (forM, forever)
import Data.Aeson (Value, object, withObject, (.!=), (.:), (.:?), (.=))
import Data.Aeson.Types (Parser, parseMaybe)
import Data.IORef (atomicModifyIORef', newIORef)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (getCurrentTime)
import Effectful (liftIO)
import Keiro.Command (RunCommandOptions (..), defaultRunCommandOptions)
import Keiro.ProcessManager (RejectedCommandPolicy (..), WorkerOptions (..), defaultWorkerOptions, runProcessManagerWorkerWith)
import Keiro.Projection (AsyncApplyOutcome (..))
import Keiro.Router (runRouterWorkerWith)
import Kenshou.Core.Id (unSeed)
import Kenshou.Core.Role (ControlMessage (..), PostgresConnInfo (..), RoleContext (..), RoleName, WorkerInit (..), WorkerMessage (..), WorkerRole (..), mkRoleName)
import Kenshou.Suite.Keiro.Fixture.Account
import Kenshou.Suite.Keiro.Fixture.Bonus
import Kenshou.Suite.Keiro.Fixture.Bridge
import Kenshou.Suite.Keiro.Fixture.Projection
import Kenshou.Suite.Keiro.Fixture.Runtime
import Kenshou.Suite.Keiro.Fixture.Transfer
import Kenshou.Suite.Keiro.Fixture.Workload qualified as Workload
import Kiroku.Store (defaultConnectionSettings)
import Kiroku.Store.Subscription.Types (SubscriptionName (..))
import Kiroku.Store.Types (RecordedEvent (..))

roles :: [WorkerRole]
roles =
  [ WorkerRole (roleName "keiro/command-writer") "Submits a deterministic sequence of account and bonus operations." commandWriter,
    WorkerRole (roleName "keiro/pm-worker") "Dispatches transfer saga inputs from a durable subscription." processManagerWorker,
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

data WriterArgs = WriterArgs
  { worker :: !Int,
    workers :: !Int,
    startIndex :: !Int,
    count :: !Int,
    accounts :: !Int,
    clientRetryBudget :: !Int,
    parkAfterIndex :: !(Maybe Int),
    inlineProjectionSleep :: !Bool
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

commandWriter :: RoleContext -> IO ()
commandWriter context = case parseMaybe parseWriterArgs context.init.args of
  Nothing -> context.send (WrkError "invalid command-writer arguments")
  Just args -> withPostgres context \postgres -> do
    context.send WrkReady
    started <- awaitStart context
    if not started
      then pure ()
      else withFixtureEnv (defaultConnectionSettings postgres.connectionString) \fixture -> do
        let spec = Workload.defaultWorkloadSpec {Workload.accounts = args.accounts}
            operations = take args.count (drop args.startIndex (Workload.workerOps (unSeed context.init.seed) spec args.worker args.workers))
            eventStream = accountEventStream (SnapEvery 100)
            loop [] = context.send (WrkDone Nothing)
            loop (operation : rest) = do
              outcomes <- forM (Workload.opCommands (unSeed context.init.seed) operation) \(choice, eventId) ->
                case choice of
                  Left (_, bonusCommand) -> submitBonusCommand fixture defaultRunCommandOptions eventId bonusCommand
                  Right (_, accountCommand) ->
                    let runnerKind = if args.inlineProjectionSleep then RunnerWithProjections [accountBalanceProjection, parkingProjection] else RunnerPlain
                     in submitAccountCommand fixture eventStream runnerKind defaultRunCommandOptions args.clientRetryBudget eventId accountCommand
              if any isFailure outcomes
                then context.send (WrkError ("command writer operation failed at index " <> Text.pack (show operation.index)))
                else do
                  if args.parkAfterIndex == Just (fromIntegral operation.index)
                    then parkForever context ("after-operation-" <> Text.pack (show operation.index))
                    else pure ()
                  context.send (WrkCustom "submission" (object ["index" .= operation.index, "outcomes" .= map show outcomes]))
                  context.send (WrkFacts [object ["worker" .= args.worker, "index" .= operation.index, "outcomes" .= map show outcomes]])
                  now <- getCurrentTime
                  context.send (WrkProgress (fromIntegral operation.index) now)
                  loop rest
        loop operations
  where
    isFailure = \case SubmitFailed _ -> True; SubmitRejected -> True; _ -> False

data DispatcherArgs = DispatcherArgs
  { subscription :: !Text,
    parkBeforeAppend :: !(Maybe Int),
    parkBeforeAck :: !Bool,
    reverseRecipients :: !Bool,
    rejectedDeadLetter :: !Bool,
    reportAcks :: !Bool
  }

parseDispatcherArgs :: Value -> Parser DispatcherArgs
parseDispatcherArgs = withObject "keiro dispatcher" \value ->
  DispatcherArgs
    <$> value .: "subscription"
    <*> value .:? "parkBeforeAppend"
    <*> value .:? "parkBeforeAck" .!= False
    <*> value .:? "reverseRecipients" .!= False
    <*> value .:? "rejectedDeadLetter" .!= False
    <*> value .:? "reportAcks" .!= False

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
      else withFixtureEnv (defaultConnectionSettings postgres.connectionString) \fixture -> do
        options <- dispatchOptions context args
        let KeiroRunner runFixture = fixture.runner
        result <- runFixture do
          adapter <- kirokuBridge fixture.store (sagaAdapterConfig (SubscriptionName args.subscription) Nothing)
          let observed =
                interposeAck
                  ( \_ decision -> do
                      if args.reportAcks then liftIO (context.send (WrkCustom "acknowledged" (object ["decision" .= show decision]))) else pure ()
                      if args.parkBeforeAck then liftIO (parkForever context "before-ack") else pure ()
                  )
                  adapter
          runProcessManagerWorkerWith defaultWorkerOptions options (transferManager (accountEventStream SnapNever) (const [])) observed decodeTransferSignal
        case result of
          Left issue -> context.send (WrkError (Text.pack (show issue)))
          Right () -> context.send (WrkDone Nothing)

routerWorker :: RoleContext -> IO ()
routerWorker context = case parseMaybe parseDispatcherArgs context.init.args of
  Nothing -> context.send (WrkError "invalid router-worker arguments")
  Just args -> withPostgres context \postgres -> do
    context.send WrkReady
    started <- awaitStart context
    if not started
      then pure ()
      else withFixtureEnv (defaultConnectionSettings postgres.connectionString) \fixture -> do
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

data ProjectionArgs = ProjectionArgs {batchSize :: !Int, skipDedup :: !Bool, parkAfterApply :: !Bool}

parseProjectionArgs :: Value -> Parser ProjectionArgs
parseProjectionArgs = withObject "keiro projection worker" \value ->
  ProjectionArgs <$> value .:? "batchSize" .!= 100 <*> value .:? "skipDedup" .!= False <*> value .:? "parkAfterApply" .!= False

projectionWorker :: RoleContext -> IO ()
projectionWorker context = case parseMaybe parseProjectionArgs context.init.args of
  Nothing -> context.send (WrkError "invalid projection-worker arguments")
  Just args -> withPostgres context \postgres -> do
    context.send WrkReady
    started <- awaitStart context
    if not started
      then pure ()
      else withFixtureEnv (defaultConnectionSettings postgres.connectionString) \fixture -> do
        let sabotage = if args.skipDedup then SkipDedup else NoProjectionSabotage
        runAccountActivityWorker fixture.store (fromIntegral args.batchSize) sabotage \recorded outcome -> do
          context.send (WrkFacts [object ["eventId" .= show recorded.eventId, "outcome" .= show outcome]])
          case outcome of
            AsyncDuplicate -> context.send (WrkCustom "projection-duplicate" (object ["eventId" .= show recorded.eventId]))
            AsyncApplied -> context.send (WrkCustom "projection-applied" (object ["eventId" .= show recorded.eventId]))
            AsyncFenced -> pure ()
          if args.parkAfterApply && outcome == AsyncApplied
            then parkForever context "after-projection-apply"
            else pure ()
