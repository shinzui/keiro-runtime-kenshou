module Kenshou.Check.Oracle.Pgmq (queueDepth) where

import Data.Text (Text)
import Data.Text qualified as Text
import Kenshou.Check.Oracle

queueDepth :: Text -> OracleQuery Text
queueDepth queue = OracleQuery ("pgmq-queue-depth-" <> queue) ("SELECT json_build_object('visibleOrLeased', count(*), 'maxReadCount', coalesce(max(read_ct), 0))::text FROM pgmq.q_" <> quoteIdentifier queue) Right

quoteIdentifier :: Text -> Text
quoteIdentifier value = "\"" <> Text.replace "\"" "\"\"" value <> "\""
