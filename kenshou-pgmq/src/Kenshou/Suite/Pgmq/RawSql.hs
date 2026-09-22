module Kenshou.Suite.Pgmq.RawSql
  ( sendMessage,
    batchSendMessage,
    readMessage,
    deleteMessage,
    pop,
  )
where

import Data.Vector (Vector)
import Hasql.Decoders qualified as Decoders
import Hasql.Statement (Statement)
import Hasql.Statement qualified as Statement
import Pgmq.Hasql.Decoders (messageDecoder, messageIdDecoder)
import Pgmq.Hasql.Encoders
  ( batchSendMessageEncoder,
    messageQueryEncoder,
    popMessageEncoder,
    readMessageEncoder,
    sendMessageEncoder,
  )
import Pgmq.Hasql.Statements.Types
  ( BatchSendMessage,
    MessageQuery,
    PopMessage,
    ReadMessage,
    SendMessage,
  )
import Pgmq.Types (Message, MessageId)

-- These statements deliberately spell out the PGMQ calls instead of reusing
-- pgmq-hasql's Statement values. The layer ladder therefore keeps the same
-- driver and codecs while isolating the wrapper and effect-dispatch costs.
sendMessage :: Statement SendMessage MessageId
sendMessage = Statement.preparable "select * from pgmq.send($1,$2,coalesce($3,0))" sendMessageEncoder (Decoders.singleRow messageIdDecoder)

batchSendMessage :: Statement BatchSendMessage [MessageId]
batchSendMessage = Statement.preparable "select * from pgmq.send_batch($1,$2,coalesce($3,0))" batchSendMessageEncoder (Decoders.rowList messageIdDecoder)

readMessage :: Statement ReadMessage (Vector Message)
readMessage = Statement.preparable "select * from pgmq.read($1,$2,coalesce($3,1),coalesce($4,'{}'::jsonb))" readMessageEncoder (Decoders.rowVector messageDecoder)

deleteMessage :: Statement MessageQuery Bool
deleteMessage = Statement.preparable "select * from pgmq.delete($1,$2)" messageQueryEncoder (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.bool)))

pop :: Statement PopMessage (Vector Message)
pop = Statement.preparable "select * from pgmq.pop($1,coalesce($2,1))" popMessageEncoder (Decoders.rowVector messageDecoder)
