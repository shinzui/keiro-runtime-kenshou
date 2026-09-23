module Kenshou.Suite.Kiroku.Roles (roles, appenderRoleName, readerRoleName, subscriberRoleName, txAppenderRoleName) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar (newEmptyMVar, newMVar, putMVar, takeMVar, withMVar)
import Control.Exception (SomeException, try)
import Control.Monad (forM, forM_, replicateM)
import Data.Aeson (Value, object, withObject, (.:), (.:?), (.=))
import Data.Aeson.Types (Parser, parseMaybe)
import Data.ByteString.Char8 qualified as ByteString
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Data.Int (Int32, Int64)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time.Clock (getCurrentTime)
import Data.UUID qualified as UUID
import Data.Vector qualified as Vector
import Data.Word (Word64)
import GHC.Clock (getMonotonicTimeNSec)
import Hasql.Transaction qualified as Tx
import Kenshou.Core.Role (ControlMessage (..), PostgresConnInfo (..), RoleContext (..), RoleName, WorkerInit (..), WorkerMessage (..), WorkerRole (..), mkRoleName)
import Kenshou.Suite.Kiroku.Fixture.Workload (eventIdFor)
import Kiroku.Store hiding (id)

roles :: [WorkerRole]
roles = [WorkerRole appenderRoleName "Races expected-version appends from a separate process." runAppender, WorkerRole readerRoleName "Tails the global event stream from a separate process." runReader, WorkerRole subscriberRoleName "Collects group delivery in a separate process." runSubscriber, WorkerRole fanoutRoleName "Runs several subscriptions on one publisher." runFanout, WorkerRole poisonRoleName "Retries and dead-letters poison events through process crashes." runPoisonSubscriber, WorkerRole txAppenderRoleName "Holds the global append lock inside a transaction continuation." runTxAppender]

appenderRoleName :: RoleName
appenderRoleName = either (error . show) id (mkRoleName "kiroku/appender")

readerRoleName :: RoleName
readerRoleName = either (error . show) id (mkRoleName "kiroku/reader")

subscriberRoleName :: RoleName
subscriberRoleName = either (error . show) id (mkRoleName "kiroku/subscriber")

fanoutRoleName :: RoleName
fanoutRoleName = either (error . show) id (mkRoleName "kiroku/fanout")

poisonRoleName :: RoleName
poisonRoleName = either (error . show) id (mkRoleName "kiroku/poison-subscriber")

txAppenderRoleName :: RoleName
txAppenderRoleName = either (error . show) id (mkRoleName "kiroku/tx-appender")

runTxAppender :: RoleContext -> IO ()
runTxAppender context = case context.init.postgres of
  Nothing -> context.send (WrkError "transaction appender requires PostgreSQL")
  Just postgres -> withStore (defaultConnectionSettings (postgres.connectionString <> " application_name=kenshou-tx-appender")) \store -> do
    context.send WrkReady
    let loop =
          context.receive >>= \case
            Just (CtlCustom "hold" payload) -> case parseMaybe (withObject "hold" (.: "sleepMs")) payload of
              Nothing -> context.send (WrkError "invalid transaction hold") >> loop
              Just sleepMs -> do
                let event = EventData (Just (eventIdFor context.init.seed 0 0)) (EventType "TxHold") (object []) Nothing Nothing Nothing
                    seconds = fromIntegral (sleepMs :: Int) / 1000 :: Double
                    continuation _ = do
                      Tx.sql "insert into kenshou_kiroku.tx_hold_probe (value) values (1)"
                      Tx.sql (ByteString.pack ("select pg_sleep(" <> show seconds <> ")"))
                context.send (WrkCustom "hold-start" (object ["sleepMs" .= sleepMs]))
                result <- runStoreIO store (runTransactionAppending (StreamName "tx-held") NoStream [event] continuation)
                context.send (WrkCustom "hold-done" (object ["result" .= show result]))
                loop
            Just (CtlStop _) -> pure ()
            Just _ -> loop
            Nothing -> pure ()
    loop

data SubscriberArgs = SubscriberArgs
  { name :: Text,
    group :: Maybe (Int32, Int32),
    guardEnabled :: Bool,
    emitDeliveries :: Bool,
    compactDeliveries :: Bool,
    targetName :: Text,
    requestedBatchSize :: Int32,
    handlerDelayMicros :: Int
  }

runSubscriber :: RoleContext -> IO ()
runSubscriber context = case (context.init.postgres, parseMaybe parseSubscriberArgs context.init.args) of
  (Nothing, _) -> context.send (WrkError "subscriber requires PostgreSQL")
  (_, Nothing) -> context.send (WrkError "invalid subscriber arguments")
  (Just postgres, Just args) -> withStore (defaultConnectionSettings postgres.connectionString) \store -> do
    delivered <- newIORef ([] :: [Int64])
    emitted <- newIORef (0 :: Int)
    let handler row = do
          let GlobalPosition position = row.globalPosition
          if args.compactDeliveries then pure () else atomicModifyIORef' delivered (\positions -> (position : positions, ()))
          if args.emitDeliveries
            then do
              sequenceNumber <- atomicModifyIORef' emitted (\count -> (count + 1, count))
              receivedAt <- getCurrentTime
              receivedMonoNs <- getMonotonicTimeNSec
              let EventId uuid = row.eventId
              context.send (WrkCustom (if args.compactDeliveries then "delivery-latest" else "delivery-" <> Text.pack (show sequenceNumber)) (object ["sequence" .= sequenceNumber, "position" .= position, "eventId" .= UUID.toText uuid, "receivedAt" .= receivedAt, "receivedMonoNs" .= receivedMonoNs]))
            else pure ()
          threadDelay args.handlerDelayMicros
          pure Continue
        target = if args.targetName == "category" then Category (CategoryName "crash") else AllStreams
        config = (defaultSubscriptionConfig (SubscriptionName args.name) target handler) {consumerGroup = uncurry ConsumerGroup <$> args.group, consumerGroupGuard = args.guardEnabled, batchSize = args.requestedBatchSize}
        loop =
          context.receive >>= \case
            Just CtlStart -> loop
            Just (CtlCustom "snapshot" request) -> do
              positions <- reverse <$> readIORef delivered
              let marker = maybe "snapshot" ("snapshot-" <>) (parseMaybe (withObject "snapshot request" (.: "requestId")) request :: Maybe Text)
              context.send (WrkCustom marker (object ["positions" .= positions]))
              loop
            Just (CtlStop _) -> pure ()
            Just _ -> loop
            Nothing -> pure ()
    withSubscription store config \_ -> context.send WrkReady >> loop

parseSubscriberArgs :: Value -> Parser SubscriberArgs
parseSubscriberArgs = withObject "subscriber arguments" \value -> do
  name <- value .: "name"
  member <- value .:? "member"
  size <- value .:? "size"
  guardEnabled <- value .: "guard"
  emitDeliveries <- maybe False id <$> value .:? "emitDeliveries"
  compactDeliveries <- maybe False id <$> value .:? "compactDeliveries"
  targetName <- maybe "all" id <$> value .:? "target"
  requestedBatchSize <- maybe 100 id <$> value .:? "batchSize"
  handlerDelayMicros <- maybe 0 id <$> value .:? "handlerDelayMicros"
  pure (SubscriberArgs name ((,) <$> member <*> size) guardEnabled emitDeliveries compactDeliveries targetName requestedBatchSize handlerDelayMicros)

runPoisonSubscriber :: RoleContext -> IO ()
runPoisonSubscriber context = case context.init.postgres of
  Nothing -> context.send (WrkError "poison subscriber requires PostgreSQL")
  Just postgres -> withStore (defaultConnectionSettings postgres.connectionString) \store -> do
    let handler row = pure $ if row.eventType == EventType "SoakPoison" then Retry (RetryDelay 0.001) else Continue
        config = (defaultSubscriptionConfig (SubscriptionName "soak-dead-letter") AllStreams handler) {retryPolicy = RetryPolicy 3}
        loop =
          context.receive >>= \case
            Just (CtlStop _) -> pure ()
            Just _ -> loop
            Nothing -> pure ()
    withSubscription store config \_ -> context.send WrkReady >> loop

runFanout :: RoleContext -> IO ()
runFanout context = case (context.init.postgres, parseMaybe parseArgs context.init.args) of
  (Nothing, _) -> context.send (WrkError "fan-out requires PostgreSQL")
  (_, Nothing) -> context.send (WrkError "invalid fan-out arguments")
  (Just postgres, Just (offset, subscribers, targetName, sampleEvery)) -> withStore (defaultConnectionSettings postgres.connectionString) \store -> do
    sendLock <- newMVar ()
    counters <- forM [offset .. offset + subscribers - 1] \index -> do
      state <- newIORef (0 :: Int64, 0 :: Int64, 0 :: Int64)
      pure (index, state)
    let target = if targetName == "category" then Category (CategoryName "fanout") else AllStreams
        send message = withMVar sendLock (\_ -> context.send message)
        handler index state row = do
          let GlobalPosition position = row.globalPosition
          atomicModifyIORef' state \(count, previous, violations) ->
            let bad = if count > 0 && position /= previous + 1 then 1 else 0
             in ((count + 1, position, violations + bad), ())
          if position `mod` fromIntegral sampleEvery == 0
            then case parseMaybe (withObject "fan-out payload" (.: "issuedMonoNs")) row.payload of
              Just (issuedMonoNs :: Word64) -> do
                receivedMonoNs <- getMonotonicTimeNSec
                send (WrkCustom ("fanout-sample-" <> Text.pack (show index)) (object ["subscriber" .= index, "position" .= position, "issuedMonoNs" .= issuedMonoNs, "receivedMonoNs" .= receivedMonoNs]))
              Nothing -> pure ()
            else pure ()
          pure Continue
        withMembers [] action = action
        withMembers ((index, state) : rest) action =
          withSubscription store (defaultSubscriptionConfig (SubscriptionName ("fanout-" <> Text.pack (show index))) target (handler index state)) \_ -> withMembers rest action
        loop =
          context.receive >>= \case
            Just (CtlCustom "snapshot" payload) -> do
              let token = parseMaybe (withObject "snapshot" (.: "token")) payload :: Maybe Text
              rows <- forM counters \(index, state) -> do
                (count, lastPosition, violations) <- readIORef state
                pure (object ["subscriber" .= index, "count" .= count, "lastPosition" .= lastPosition, "orderViolations" .= violations])
              send (WrkCustom "fanout-snapshot" (object ["token" .= token, "subscribers" .= rows]))
              loop
            Just (CtlStop _) -> pure ()
            Just _ -> loop
            Nothing -> pure ()
    withMembers counters (send WrkReady >> loop)
  where
    parseArgs :: Value -> Parser (Int, Int, Text, Int)
    parseArgs = withObject "fan-out arguments" \value ->
      (,,,) <$> value .: "offset" <*> value .: "subscribers" <*> value .: "target" <*> value .: "sampleEvery"

runReader :: RoleContext -> IO ()
runReader context = case context.init.postgres of
  Nothing -> context.send (WrkError "reader requires PostgreSQL")
  Just postgres -> withStore (defaultConnectionSettings postgres.connectionString) \store -> do
    context.send WrkReady
    loop store 0
  where
    loop store cursor =
      context.receive >>= \case
        Just CtlStart -> loop store cursor
        Just (CtlCustom "tail-to" payload) -> case parseMaybe (withObject "tail target" (.: "target")) payload of
          Nothing -> context.send (WrkError "invalid tail target") >> loop store cursor
          Just target -> do
            result <- tailTo store cursor target []
            case result of
              Left message -> context.send (WrkError message) >> loop store cursor
              Right (next, observations) -> context.send (WrkCustom "tail-to" (object ["rows" .= observations])) >> loop store next
        Just (CtlStop _) -> pure ()
        Just _ -> loop store cursor
        Nothing -> pure ()
    tailTo store cursor target accumulated
      | cursor >= target = pure (Right (cursor, reverse accumulated))
      | otherwise = do
          result <- runStoreIO store (readAllForward (GlobalPosition cursor) 256)
          case result of
            Left err -> pure (Left (Text.pack (show err)))
            Right rows | Vector.null rows -> threadDelay 1000 >> tailTo store cursor target accumulated
            Right rows -> do
              let observed = [(position, UUID.toText uuid) | row <- Vector.toList rows, let GlobalPosition position = row.globalPosition, let EventId uuid = row.eventId]
                  next = fst (last observed)
              tailTo store next target (reverse observed <> accumulated)

runAppender :: RoleContext -> IO ()
runAppender context = do
  sendLock <- newMVar ()
  runAppenderBody (context {send = \message -> withMVar sendLock (\_ -> context.send message)})

runAppenderBody :: RoleContext -> IO ()
runAppenderBody context = case context.init.postgres of
  Nothing -> context.send (WrkError "appender requires PostgreSQL")
  Just postgres -> withStore (defaultConnectionSettings postgres.connectionString) \store -> do
    context.send WrkReady
    loop store
  where
    loop store =
      context.receive >>= \case
        Just CtlStart -> loop store
        Just (CtlCustom "bench-append" payload) -> case parseMaybe parseBenchAppend payload of
          Nothing -> context.send (WrkError "invalid benchmark append request") >> loop store
          Just (token, stream, rawId) -> case UUID.fromText rawId of
            Nothing -> context.send (WrkError "invalid benchmark event ID") >> loop store
            Just uuid -> do
              _ <- forkIO do
                let event = EventData (Just (EventId uuid)) (EventType "BenchSubscription") (object []) Nothing Nothing Nothing
                result <- try @SomeException (runStoreIO store (appendToStream (StreamName stream) AnyVersion [event]))
                ackAt <- getCurrentTime
                ackMonoNs <- getMonotonicTimeNSec
                let status = case result of Right (Right _) -> "success" :: Text; Right (Left _) -> "store-error"; Left _ -> "exception"
                context.send (WrkCustom ("bench-ack-" <> Text.takeWhile (/= '-') token) (object ["token" .= token, "eventId" .= rawId, "status" .= status, "ackAt" .= ackAt, "ackMonoNs" .= ackMonoNs]))
              loop store
        Just (CtlCustom "race" payload) -> case parseMaybe parseRace payload of
          Nothing -> context.send (WrkError "invalid race request") >> loop store
          Just (stream, version, writers) -> do
            replies <- newEmptyMVar
            forM_ [1 .. writers] \index -> do
              _ <- forkIO do
                let event = EventData Nothing (EventType "Race") (object ["writer" .= (index :: Int)]) Nothing Nothing Nothing
                outcome <- try @SomeException (runStoreIO store (appendToStream (StreamName stream) (ExactVersion (StreamVersion (fromIntegral version))) [event]))
                putMVar replies $ case outcome of
                  Right (Right _) -> "success" :: Text
                  Right (Left (WrongExpectedVersion _ _ _)) -> "conflict"
                  Right (Left _) -> "store-error"
                  Left _ -> "exception"
              pure ()
            outcomes <- replicateM writers (takeMVar replies)
            context.send (WrkCustom "race" (object ["successes" .= length (filter (== "success") outcomes), "conflicts" .= length (filter (== "conflict") outcomes), "errors" .= length (filter (`elem` ["store-error", "exception"]) outcomes)]))
            loop store
        Just (CtlCustom "duplicate" payload) -> case parseMaybe parseDuplicate payload of
          Nothing -> context.send (WrkError "invalid duplicate request") >> loop store
          Just (stream, rawIds, mode, version) -> case traverse UUID.fromText rawIds of
            Nothing -> context.send (WrkError "invalid caller event ID") >> loop store
            Just identifiers -> do
              let expected = if mode == "exact" then ExactVersion (StreamVersion (fromIntegral version)) else AnyVersion
                  events = [EventData (Just (EventId uuid)) (EventType "DuplicateRace") (object []) Nothing Nothing Nothing | uuid <- identifiers]
              outcome <- try @SomeException (runStoreIO store (appendToStream (StreamName stream) expected events))
              let (status, finalVersion) = case outcome of
                    Right (Right result) -> ("success" :: Text, Just (case result.streamVersion of StreamVersion value -> value))
                    Right (Left (DuplicateEvent _)) -> ("duplicate", Nothing)
                    Right (Left (WrongExpectedVersion _ _ _)) -> ("version", Nothing)
                    _ -> ("error", Nothing)
              context.send (WrkCustom "duplicate" (object ["status" .= status, "version" .= finalVersion]))
              loop store
        Just (CtlCustom "fresh-deadlock" payload) -> case parseMaybe parseFreshDeadlock payload of
          Nothing -> context.send (WrkError "invalid fresh-deadlock request") >> loop store
          Just (mode, rawA, rawB, rawIdA, rawIdB) -> case (UUID.fromText rawIdA, UUID.fromText rawIdB) of
            (Just idA, Just idB) -> do
              let event uuid = EventData (Just (EventId uuid)) (EventType "FreshDeadlock") (object []) Nothing Nothing Nothing
                  first = StreamName rawA
                  second = StreamName rawB
                  action =
                    if mode == "multi"
                      then fmap (fmap (const ())) (runStoreIO store (appendMultiStream [(first, NoStream, [event idA]), (second, NoStream, [event idB])]))
                      else fmap (fmap (const ())) (runStoreIO store (appendToStream second NoStream [event idB]))
              outcome <- try @SomeException action
              let status = case outcome of
                    Right (Right ()) -> "success" :: Text
                    Right (Left (TransientTransactionFailure _ _)) -> "transient"
                    Right (Left (StreamAlreadyExists _)) -> "conflict"
                    Right (Left (WrongExpectedVersion _ _ _)) -> "conflict"
                    Right (Left (DuplicateEvent _)) -> "duplicate"
                    Right (Left _) -> "store-error"
                    Left _ -> "exception"
              context.send (WrkCustom "fresh-deadlock" (object ["status" .= status]))
              loop store
            _ -> context.send (WrkError "invalid fresh-deadlock event ID") >> loop store
        Just (CtlCustom "crash-batch" payload) -> case parseMaybe parseCrashBatch payload of
          Nothing -> context.send (WrkError "invalid crash-batch request") >> loop store
          Just (stream, rawIds) -> case traverse UUID.fromText rawIds of
            Nothing -> context.send (WrkError "invalid crash-batch event ID") >> loop store
            Just identifiers -> do
              let events = [EventData (Just (EventId uuid)) (EventType "CrashBatch") (object []) Nothing Nothing Nothing | uuid <- identifiers]
              outcome <- try @SomeException (runStoreIO store (appendToStream (StreamName stream) NoStream events))
              let status = case outcome of
                    Right (Right _) -> "success" :: Text
                    Right (Left (StreamAlreadyExists _)) -> "already-exists"
                    Right (Left (DuplicateEvent _)) -> "duplicate"
                    Right (Left _) -> "store-error"
                    Left _ -> "exception"
              context.send (WrkCustom "crash-batch" (object ["status" .= status, "stream" .= stream]))
              loop store
        Just (CtlCustom "order-write" payload) -> case parseMaybe parseOrderWrite payload of
          Nothing -> context.send (WrkError "invalid order-write request") >> loop store
          Just (prefix, count, writers, writerBase, ordinalBase) -> do
            replies <- newEmptyMVar
            forM_ [0 .. writers - 1] \localWriter -> do
              _ <- forkIO do
                let writer = writerBase + localWriter
                    stream = StreamName (prefix <> "-w" <> Text.pack (show writer))
                    indexes = [localWriter, localWriter + writers .. count - 1]
                    batches = makeBatches writer indexes
                outcomes <-
                  traverse
                    ( \batch -> do
                        let events = [EventData (Just (eventIdFor context.init.seed writer (fromIntegral (ordinalBase + index)))) (EventType "Order") (object []) Nothing Nothing Nothing | index <- batch]
                        result <- try @SomeException (runStoreIO store (appendToStream stream AnyVersion events))
                        pure (length batch, result)
                    )
                    batches
                let positions = [position | (_, Right (Right result)) <- outcomes, let GlobalPosition position = result.globalPosition]
                    monotonic = and (zipWith (<) positions (drop 1 positions))
                putMVar replies (sum [size | (size, Right (Right _)) <- outcomes], length [() | (_, outcome) <- outcomes, case outcome of Right (Right _) -> False; _ -> True], monotonic)
              pure ()
            outcomes <- replicateM writers (takeMVar replies)
            context.send (WrkCustom "order-write" (object ["committed" .= sum [committed | (committed, _, _) <- outcomes], "errors" .= sum [errors | (_, errors, _) <- outcomes], "acknowledgementsMonotonic" .= and [monotonic | (_, _, monotonic) <- outcomes]]))
            loop store
        Just (CtlStop _) -> pure ()
        Just _ -> loop store
        Nothing -> pure ()

parseRace :: Value -> Parser (Text, Int, Int)
parseRace = withObject "race request" \value -> (,,) <$> value .: "stream" <*> value .: "version" <*> value .: "writers"

parseBenchAppend :: Value -> Parser (Text, Text, Text)
parseBenchAppend = withObject "benchmark append request" \value -> (,,) <$> value .: "token" <*> value .: "stream" <*> value .: "eventId"

parseDuplicate :: Value -> Parser (Text, [Text], Text, Int)
parseDuplicate = withObject "duplicate request" \value -> (,,,) <$> value .: "stream" <*> value .: "eventIds" <*> value .: "mode" <*> value .: "version"

parseFreshDeadlock :: Value -> Parser (Text, Text, Text, Text, Text)
parseFreshDeadlock = withObject "fresh-deadlock request" \value -> (,,,,) <$> value .: "mode" <*> value .: "a" <*> value .: "b" <*> value .: "idA" <*> value .: "idB"

parseCrashBatch :: Value -> Parser (Text, [Text])
parseCrashBatch = withObject "crash-batch request" \value -> (,) <$> value .: "stream" <*> value .: "eventIds"

parseOrderWrite :: Value -> Parser (Text, Int, Int, Int, Int)
parseOrderWrite = withObject "order-write request" \value -> (,,,,) <$> value .: "prefix" <*> value .: "count" <*> value .: "writers" <*> value .: "writerBase" <*> value .: "ordinalBase"

makeBatches :: Int -> [Int] -> [[Int]]
makeBatches _ [] = []
makeBatches writer indexes@(first : _) =
  let size = 1 + (writer + first) `mod` 20
      (batch, rest) = splitAt size indexes
   in batch : makeBatches writer rest
