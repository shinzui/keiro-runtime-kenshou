module Kenshou.Suite.Shibuya.Fixture.SyntheticAdapter
  ( FinalizerOutcome (..),
    ShutdownBehaviour (..),
    SyntheticConfig (..),
    defaultSyntheticConfig,
    SyntheticBroker,
    BrokerStats (..),
    BrokerEvent (..),
    newSyntheticBroker,
    publish,
    closeInput,
    syntheticAdapter,
    brokerStats,
    brokerEvents,
  )
where

import Control.Concurrent (threadDelay)
import Control.Concurrent.STM (TVar, atomically, modifyTVar', newTVarIO, readTVar, retry, throwSTM, writeTVar)
import Data.ByteString (ByteString)
import Data.IORef (IORef, atomicModifyIORef', newIORef)
import Data.IntMap.Strict (IntMap)
import Data.IntMap.Strict qualified as IntMap
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time.Clock (NominalDiffTime, UTCTime, addUTCTime, getCurrentTime)
import Effectful (Eff, IOE, liftIO, (:>))
import Shibuya.Adapter (Adapter (..))
import Shibuya.Core.Ack (AckDecision (..), RetryDelay (..))
import Shibuya.Core.AckHandle (AckHandle (..))
import Shibuya.Core.Ingested (Ingested, mkIngested)
import Shibuya.Core.Types (Attempt (..), Envelope (..), MessageId (..), mkEnvelope)
import Streamly.Data.Stream qualified as Stream

data FinalizerOutcome = FinalizeSucceeds | FinalizeThrows !Text
  deriving stock (Eq, Show)

data ShutdownBehaviour = ShutdownEndsSource | ShutdownThrows !Text | ShutdownBlocksForever
  deriving stock (Eq, Show)

data SyntheticConfig = SyntheticConfig
  { leaseSeconds :: !(Maybe NominalDiffTime),
    finalizerScript :: !(MessageId -> Int -> FinalizerOutcome),
    shutdownBehaviour :: !ShutdownBehaviour,
    sourceFault :: !(Maybe (Int, Text))
  }

defaultSyntheticConfig :: SyntheticConfig
defaultSyntheticConfig =
  SyntheticConfig
    { leaseSeconds = Nothing,
      finalizerScript = \_ _ -> FinalizeSucceeds,
      shutdownBehaviour = ShutdownEndsSource,
      sourceFault = Nothing
    }

data BrokerStats = BrokerStats
  { published :: !Int,
    yielded :: !Int,
    sourcePulls :: !Int,
    finalizedOk :: !Int,
    retried :: !Int,
    deadLettered :: !Int,
    halted :: !Int,
    redeliveries :: !Int,
    shutdownCalls :: !Int,
    leasedUnfinalized :: !Int,
    leasedUnfinalizedHighWater :: !Int
  }
  deriving stock (Eq, Show)

data BrokerEvent
  = Published !MessageId
  | Yielded !MessageId !Int
  | FinalizeAttempt !MessageId !Int !AckDecision
  | Finalized !MessageId !Int !AckDecision
  | DuplicateFinalize !MessageId !Int
  | LeaseExpired !MessageId !Int
  | InputClosed
  | ShutdownCalled
  deriving stock (Eq, Show)

data MessageStatus = Pending !UTCTime | Leased !UTCTime !Int | Finished

data BrokerMessage = BrokerMessage
  { identifier :: !MessageId,
    partitionKey :: !(Maybe Text),
    payload :: !ByteString,
    deliveries :: !Int,
    status :: !MessageStatus
  }

data BrokerState = BrokerState
  { nextId :: !Int,
    messages :: !(IntMap BrokerMessage),
    inputClosed :: !Bool,
    stopped :: !Bool,
    stats :: !BrokerStats,
    events :: ![BrokerEvent]
  }

data SyntheticBroker = SyntheticBroker
  { config :: !SyntheticConfig,
    state :: !(TVar BrokerState)
  }

emptyStats :: BrokerStats
emptyStats = BrokerStats 0 0 0 0 0 0 0 0 0 0 0

newSyntheticBroker :: SyntheticConfig -> IO SyntheticBroker
newSyntheticBroker config =
  SyntheticBroker config <$> newTVarIO (BrokerState 1 IntMap.empty False False emptyStats [])

publish :: SyntheticBroker -> Maybe Text -> ByteString -> IO MessageId
publish broker partitionKey payload = do
  now <- getCurrentTime
  atomically $ do
    current <- readTVar broker.state
    if current.inputClosed || current.stopped
      then throwSTM (userError "synthetic broker input is closed")
      else do
        let number = current.nextId
            identifier = MessageId ("synthetic-" <> Text.pack (show number))
            message = BrokerMessage identifier partitionKey payload 0 (Pending now)
            stats = current.stats {published = current.stats.published + 1}
        writeTVar broker.state current {nextId = number + 1, messages = IntMap.insert number message current.messages, stats, events = Published identifier : current.events}
        pure identifier

closeInput :: SyntheticBroker -> IO ()
closeInput broker = atomically $ modifyTVar' broker.state $ \current -> current {inputClosed = True, events = InputClosed : current.events}

brokerStats :: SyntheticBroker -> IO BrokerStats
brokerStats broker = (.stats) <$> atomically (readTVar broker.state)

brokerEvents :: SyntheticBroker -> IO [BrokerEvent]
brokerEvents broker = reverse . (.events) <$> atomically (readTVar broker.state)

syntheticAdapter :: (IOE :> es) => SyntheticBroker -> Adapter es ByteString
syntheticAdapter broker =
  Adapter
    { adapterName = "kenshou:synthetic",
      source = Stream.unfoldrM step (),
      shutdown = liftIO $ shutdownBroker broker
    }
  where
    step () = do
      delivery <- liftIO $ nextDelivery broker
      traverse (\item -> (,()) <$> makeIngested broker item) delivery

data Delivery = Delivery !MessageId !(Maybe Text) !ByteString !Int !Int

data Poll = PollClosed | PollWait | PollDelivery !Delivery

nextDelivery :: SyntheticBroker -> IO (Maybe Delivery)
nextDelivery broker = do
  atomically $ modifyTVar' broker.state $ \current -> current {stats = current.stats {sourcePulls = current.stats.sourcePulls + 1}}
  loop
  where
    loop = do
      now <- getCurrentTime
      result <- atomically $ do
        current <- readTVar broker.state
        case broker.config.sourceFault of
          Just (after, reason) | current.stats.yielded >= after -> pure (Left reason)
          _ -> case firstReady now current.messages of
            Just (number, message, wasExpired) -> do
              let token = message.deliveries + 1
                  untilTime = maybe (addUTCTime 86400 now) (`addUTCTime` now) broker.config.leaseSeconds
                  leased = message {deliveries = token, status = Leased untilTime token}
                  leasedCount = current.stats.leasedUnfinalized + if wasExpired then 0 else 1
                  stats =
                    current.stats
                      { yielded = current.stats.yielded + 1,
                        redeliveries = current.stats.redeliveries + if message.deliveries > 0 then 1 else 0,
                        leasedUnfinalized = leasedCount,
                        leasedUnfinalizedHighWater = max current.stats.leasedUnfinalizedHighWater leasedCount
                      }
                  expiryEvent = [LeaseExpired message.identifier message.deliveries | wasExpired]
              writeTVar broker.state current {messages = IntMap.insert number leased current.messages, stats, events = Yielded message.identifier (token - 1) : (expiryEvent <> current.events)}
              pure (Right (PollDelivery (Delivery message.identifier message.partitionKey message.payload (token - 1) token)))
            Nothing
              | current.stopped || current.inputClosed && allFinished current.messages -> pure (Right PollClosed)
              | otherwise -> pure (Right PollWait)
      case result of
        Left reason -> ioError (userError (Text.unpack reason))
        Right PollClosed -> pure Nothing
        Right PollWait -> threadDelay 5000 >> loop
        Right (PollDelivery delivery) -> pure (Just delivery)

firstReady :: UTCTime -> IntMap BrokerMessage -> Maybe (Int, BrokerMessage, Bool)
firstReady now = go . IntMap.toAscList
  where
    go [] = Nothing
    go ((number, message) : rest) = case message.status of
      Pending available | available <= now -> Just (number, message, False)
      Leased untilTime _ | untilTime <= now -> Just (number, message, True)
      _ -> go rest

allFinished :: IntMap BrokerMessage -> Bool
allFinished = all (\message -> case message.status of Finished -> True; _ -> False) . IntMap.elems

makeIngested :: (IOE :> es) => SyntheticBroker -> Delivery -> Eff es (Ingested es ByteString)
makeIngested broker (Delivery identifier partitionKey payload attempt token) = do
  attemptCounter <- liftIO $ newIORef (0 :: Int)
  pure $
    mkIngested
      ((mkEnvelope identifier payload) {partition = partitionKey, attempt = Just (Attempt (fromIntegral attempt))})
      (AckHandle $ \decision -> liftIO $ finalizeDelivery broker identifier token attemptCounter decision)

finalizeDelivery :: SyntheticBroker -> MessageId -> Int -> IORef Int -> AckDecision -> IO ()
finalizeDelivery broker identifier token callCount decision = do
  let finalizeOne = do
        attemptNumber <- atomicModifyIORef' callCount (\value -> let next = value + 1 in (next, next))
        atomically $ modifyTVar' broker.state $ \current -> current {events = FinalizeAttempt identifier attemptNumber decision : current.events}
        case broker.config.finalizerScript identifier attemptNumber of
          FinalizeThrows reason -> ioError (userError (Text.unpack reason))
          FinalizeSucceeds -> do
            now <- getCurrentTime
            atomically $ modifyTVar' broker.state (applyDecision now identifier token decision)
  finalizeOne

applyDecision :: UTCTime -> MessageId -> Int -> AckDecision -> BrokerState -> BrokerState
applyDecision now identifier token decision current =
  case [(number, message) | (number, message) <- IntMap.toAscList current.messages, message.identifier == identifier] of
    [] -> current
    (number, message) : _ -> case message.status of
      Leased _ activeToken
        | activeToken == token ->
            let nextStatus = case decision of
                  AckRetry (RetryDelay delay) -> Pending (addUTCTime delay now)
                  _ -> Finished
                updated = message {status = nextStatus}
                oldStats = current.stats
                stats =
                  oldStats
                    { finalizedOk = oldStats.finalizedOk + if decision == AckOk then 1 else 0,
                      retried = oldStats.retried + case decision of AckRetry _ -> 1; _ -> 0,
                      deadLettered = oldStats.deadLettered + case decision of AckDeadLetter _ -> 1; _ -> 0,
                      halted = oldStats.halted + case decision of AckHalt _ -> 1; _ -> 0,
                      leasedUnfinalized = max 0 (oldStats.leasedUnfinalized - 1)
                    }
             in current {messages = IntMap.insert number updated current.messages, stats, events = Finalized identifier token decision : current.events}
      _ -> current {events = DuplicateFinalize identifier token : current.events}

shutdownBroker :: SyntheticBroker -> IO ()
shutdownBroker broker = do
  atomically $ modifyTVar' broker.state $ \current ->
    current
      { stats = current.stats {shutdownCalls = current.stats.shutdownCalls + 1},
        events = ShutdownCalled : current.events
      }
  case broker.config.shutdownBehaviour of
    ShutdownEndsSource -> atomically $ modifyTVar' broker.state $ \current -> current {stopped = True}
    ShutdownThrows reason -> ioError (userError (Text.unpack reason))
    ShutdownBlocksForever -> atomically retry
