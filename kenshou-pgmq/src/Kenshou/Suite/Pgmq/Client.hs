module Kenshou.Suite.Pgmq.Client (Layer (..), PgmqClient (..), mkClient) where

import Data.Int (Int32)
import Data.Vector (Vector)
import Hasql.Pool (Pool)
import Kenshou.Suite.Pgmq.Harness (runOps)
import OpenTelemetry.Trace.Core (Tracer)
import Pgmq.Effectful
  ( BatchSendMessage (..),
    Message,
    MessageBody,
    MessageId,
    MessageQuery (..),
    PopMessage (..),
    QueueName,
    ReadMessage (..),
    SendMessage (..),
    batchSendMessage,
    deleteMessage,
    pop,
    readMessage,
    sendMessage,
  )

data Layer = RawSql | HasqlLayer | EffectfulLayer deriving stock (Eq, Ord, Show)

data PgmqClient = PgmqClient
  { send :: QueueName -> MessageBody -> IO MessageId,
    sendBatch :: QueueName -> [MessageBody] -> IO [MessageId],
    readBatch :: QueueName -> Int32 -> Int32 -> IO (Vector Message),
    delete :: QueueName -> MessageId -> IO Bool,
    popBatch :: QueueName -> Int32 -> IO (Vector Message)
  }

mkClient :: Layer -> Maybe Tracer -> Pool -> PgmqClient
mkClient layer tracer pool =
  PgmqClient
    { send = \queue body -> unwrap =<< runOps selectedTracer pool (sendMessage (SendMessage queue body Nothing)),
      sendBatch = \queue bodies -> unwrap =<< runOps selectedTracer pool (batchSendMessage (BatchSendMessage queue bodies Nothing)),
      readBatch = \queue delay qty -> unwrap =<< runOps selectedTracer pool (readMessage (ReadMessage queue delay (Just qty) Nothing)),
      delete = \queue messageId -> unwrap =<< runOps selectedTracer pool (deleteMessage (MessageQuery queue messageId)),
      popBatch = \queue qty -> unwrap =<< runOps selectedTracer pool (pop (PopMessage queue (Just qty)))
    }
  where
    selectedTracer = case layer of EffectfulLayer -> tracer; _ -> Nothing
    unwrap = either (ioError . userError . show) pure
