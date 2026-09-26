module Kenshou.Suite.Shibuya.Fixture.PgmqProducer (role) where

import Control.Concurrent (threadDelay)
import Control.Monad (when)
import Data.Aeson (Value, object, withObject, (.!=), (.:), (.:?), (.=))
import Data.Aeson.Types (Parser, parseEither)
import Data.Text (Text)
import Data.Text qualified as Text
import Effectful (liftIO)
import Kenshou.Core.Role (ControlMessage (..), PostgresConnInfo (..), RoleContext (..), RoleName, WorkerInit (..), WorkerMessage (..), WorkerRole (..), mkRoleName)
import Kenshou.Suite.Shibuya.Fixture.Pgmq (runPgmqStack, withPgmqConnectionPool)
import Pgmq.Effectful (MessageBody (..), MessageHeaders (..), SendMessageWithHeaders (..), sendMessageWithHeaders)
import Pgmq.Effectful qualified as Pgmq
import Shibuya.Adapter.Pgmq (parseQueueName)

role :: WorkerRole
role = WorkerRole roleName "Produces a grouped PGMQ workload from a separate process." worker

roleName :: RoleName
roleName = either (error . Text.unpack) id (mkRoleName "shibuya/pgmq-producer")

data Args = Args {queue :: !Text, total :: !Int, groups :: !Int, intervalMicros :: !Int}

parseArgs :: Value -> Parser Args
parseArgs = withObject "PGMQ producer arguments" $ \value ->
  Args <$> value .: "queue" <*> value .: "total" <*> value .: "groups" <*> (value .:? "intervalMicros" .!= 0)

worker :: RoleContext -> IO ()
worker context = do
  postgres <- maybe (fail "PGMQ producer requires PostgreSQL") pure context.init.postgres
  args <- either fail pure (parseEither parseArgs context.init.args)
  queue <- either (fail . show) pure (parseQueueName args.queue)
  when (args.total < 1 || args.groups < 1 || args.intervalMicros < 0) (fail "invalid PGMQ producer workload")
  context.send WrkReady
  awaitStart
  withPgmqConnectionPool postgres.connectionString 4 $ \pool -> do
    result <- runPgmqStack pool $ traverse (sendOne args queue) [0 .. args.total - 1]
    items <- either (fail . show) pure result
    context.send (WrkCustom "produced" (object ["items" .= items]))
  awaitStop
  where
    sendOne args queue index = do
      let group = "g" <> Text.pack (show (index `mod` args.groups))
          sequenceNumber = index `div` args.groups
          query =
            SendMessageWithHeaders
              queue
              (MessageBody (object ["group" .= group, "sequence" .= sequenceNumber]))
              (MessageHeaders (object ["x-pgmq-group" .= group]))
              Nothing
      identifier <- sendMessageWithHeaders query
      liftIO $ when (args.intervalMicros > 0) (threadDelay args.intervalMicros)
      pure (Text.pack (show (Pgmq.unMessageId identifier)), group, sequenceNumber)
    awaitStart =
      context.receive >>= \case
        Just CtlStart -> pure ()
        Just (CtlStop _) -> fail "PGMQ producer stopped before start"
        Nothing -> fail "PGMQ producer parent disconnected before start"
        _ -> awaitStart
    awaitStop =
      context.receive >>= \case
        Just (CtlStop _) -> pure ()
        Nothing -> pure ()
        _ -> awaitStop
