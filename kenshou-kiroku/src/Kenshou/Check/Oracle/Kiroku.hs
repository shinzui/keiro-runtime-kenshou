module Kenshou.Check.Oracle.Kiroku
  ( globalPositionGaps,
    streamVersionGaps,
    checkpoints,
  )
where

import Data.Aeson (Value)
import Data.Aeson qualified as Aeson
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Kenshou.Check.Oracle

globalPositionGaps :: OracleQuery Value
globalPositionGaps = jsonQuery "kiroku-global-position-gaps" "SELECT json_build_object('eventCount', count(*), 'gapCount', coalesce(max(stream_version) - min(stream_version) + 1 - count(*), 0)) FROM kiroku.stream_events WHERE stream_id = 0"

streamVersionGaps :: OracleQuery Value
streamVersionGaps = jsonQuery "kiroku-stream-version-gaps" "SELECT coalesce(json_agg(gaps), '[]'::json) FROM (SELECT stream_id, count(*) AS count, min(stream_version) AS minVersion, max(stream_version) AS maxVersion FROM kiroku.stream_events WHERE stream_id <> 0 GROUP BY stream_id HAVING max(stream_version) - min(stream_version) + 1 <> count(*) OR min(stream_version) <> 1) gaps"

checkpoints :: OracleQuery Value
checkpoints = jsonQuery "kiroku-checkpoints" "SELECT coalesce(json_agg(checkpoints), '[]'::json) FROM (SELECT subscription_name, consumer_group_member, checkpoint_position FROM kiroku.subscription_checkpoints_v1) checkpoints"

jsonQuery :: Text -> Text -> OracleQuery Value
jsonQuery name sql = OracleQuery name sql (either (Left . Text.pack) Right . Aeson.eitherDecodeStrict' . TextEncoding.encodeUtf8)
