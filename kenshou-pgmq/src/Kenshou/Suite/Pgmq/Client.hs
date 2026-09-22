module Kenshou.Suite.Pgmq.Client (Layer (..), PgmqClient (..), mkClient, parseLayer) where

import Data.Int (Int32)
import Data.Text (Text)
import Data.Vector (Vector)
import Effectful (Eff, IOE)
import Effectful.Error.Static (Error)
import Hasql.Pool (Pool)
import Hasql.Pool qualified as Pool
import Hasql.Session qualified as Session
import Kenshou.Suite.Pgmq.Harness (runOps)
import Kenshou.Suite.Pgmq.RawSql qualified as RawSql
import OpenTelemetry.Trace.Core (Tracer)
import Pgmq.Effectful (Pgmq, PgmqRuntimeError)
import Pgmq.Effectful qualified as Effectful
import Pgmq.Hasql.Sessions qualified as Sessions
import Pgmq.Hasql.Statements.Types
  ( BatchSendMessage (..),
    MessageQuery (..),
    PopMessage (..),
    ReadMessage (..),
    SendMessage (..),
  )
import Pgmq.Types (Message, MessageBody, MessageId, QueueName)

data Layer = RawSql | HasqlLayer | EffectfulLayer deriving stock (Eq, Ord, Show)

data PgmqClient = PgmqClient
  { send :: QueueName -> MessageBody -> IO MessageId,
    sendBatch :: QueueName -> [MessageBody] -> IO [MessageId],
    readBatch :: QueueName -> Int32 -> Int32 -> IO (Vector Message),
    delete :: QueueName -> MessageId -> IO Bool,
    popBatch :: QueueName -> Int32 -> IO (Vector Message)
  }

parseLayer :: Text -> Either Text Layer
parseLayer = \case
  "raw-sql" -> Right RawSql
  "hasql" -> Right HasqlLayer
  "effectful" -> Right EffectfulLayer
  value -> Left ("unknown pgmq.layer " <> value)

mkClient :: Layer -> Maybe Tracer -> Pool -> PgmqClient
mkClient layer tracer pool = case layer of
  RawSql -> sessionClient (\value -> Session.statement value RawSql.sendMessage) (\value -> Session.statement value RawSql.batchSendMessage) (\value -> Session.statement value RawSql.readMessage) (\value -> Session.statement value RawSql.deleteMessage) (\value -> Session.statement value RawSql.pop)
  HasqlLayer -> sessionClient Sessions.sendMessage Sessions.batchSendMessage Sessions.readMessage Sessions.deleteMessage Sessions.pop
  EffectfulLayer ->
    PgmqClient
      { send = \queue body -> effect (Effectful.sendMessage (SendMessage queue body Nothing)),
        sendBatch = \queue bodies -> effect (Effectful.batchSendMessage (BatchSendMessage queue bodies Nothing)),
        readBatch = \queue delay qty -> effect (Effectful.readMessage (ReadMessage queue delay (Just qty) Nothing)),
        delete = \queue messageId -> effect (Effectful.deleteMessage (MessageQuery queue messageId)),
        popBatch = \queue qty -> effect (Effectful.pop (PopMessage queue (Just qty)))
      }
  where
    sessionClient ::
      (SendMessage -> Session.Session MessageId) ->
      (BatchSendMessage -> Session.Session [MessageId]) ->
      (ReadMessage -> Session.Session (Vector Message)) ->
      (MessageQuery -> Session.Session Bool) ->
      (PopMessage -> Session.Session (Vector Message)) ->
      PgmqClient
    sessionClient sendOne sendMany readMany deleteOne popMany =
      PgmqClient
        { send = \queue body -> use (sendOne (SendMessage queue body Nothing)),
          sendBatch = \queue bodies -> use (sendMany (BatchSendMessage queue bodies Nothing)),
          readBatch = \queue delay qty -> use (readMany (ReadMessage queue delay (Just qty) Nothing)),
          delete = \queue messageId -> use (deleteOne (MessageQuery queue messageId)),
          popBatch = \queue qty -> use (popMany (PopMessage queue (Just qty)))
        }
    use :: Session.Session value -> IO value
    use action = unwrap =<< Pool.use pool action
    effect :: Eff '[Pgmq, Error PgmqRuntimeError, IOE] value -> IO value
    effect action = unwrap =<< runOps tracer pool action
    unwrap :: (Show err) => Either err value -> IO value
    unwrap = either (ioError . userError . show) pure
