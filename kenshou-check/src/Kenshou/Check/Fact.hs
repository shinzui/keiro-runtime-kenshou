module Kenshou.Check.Fact
  ( FactKind (..),
    ProcId (..),
    Fact (..),
    factKindText,
    parseFactKind,
    renderProcId,
    parseProcId,
  )
where

import Data.Aeson
import Data.Aeson.KeyMap (KeyMap)
import Data.Int (Int64)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Word (Word64)

data FactKind
  = Intent
  | Produced
  | Observed
  | Effect
  | Terminal
  | Acquired
  | Acted
  | Released
  | Checkpoint
  | DisturbanceStart
  | DisturbanceEnd
  | Mark
  deriving stock (Eq, Ord, Show, Enum, Bounded)

data ProcId = ProcId
  { role :: !Text,
    index :: !Int,
    incarnation :: !Int
  }
  deriving stock (Eq, Ord, Show)

data Fact = Fact
  { kind :: !FactKind,
    key :: !Text,
    seq :: !Int64,
    id :: !Text,
    scope :: !Text,
    proc :: !ProcId,
    n :: !Word64,
    mono :: !Word64,
    wall :: !Int64,
    attrs :: !(KeyMap Value)
  }
  deriving stock (Eq, Show)

factKindText :: FactKind -> Text
factKindText Intent = "intent"
factKindText Produced = "produced"
factKindText Observed = "observed"
factKindText Effect = "effect"
factKindText Terminal = "terminal"
factKindText Acquired = "acquired"
factKindText Acted = "acted"
factKindText Released = "released"
factKindText Checkpoint = "checkpoint"
factKindText DisturbanceStart = "disturbance-start"
factKindText DisturbanceEnd = "disturbance-end"
factKindText Mark = "mark"

parseFactKind :: Text -> Maybe FactKind
parseFactKind value = lookup value [(factKindText item, item) | item <- [minBound .. maxBound]]

renderProcId :: ProcId -> Text
renderProcId value = value.role <> "/" <> Text.pack (show value.index) <> "." <> Text.pack (show value.incarnation)

parseProcId :: Text -> Either Text ProcId
parseProcId value = case Text.breakOnEnd "/" value of
  (roleWithSlash, suffix)
    | not (Text.null roleWithSlash),
      (indexText, incarnationTextWithDot) <- Text.breakOn "." suffix,
      Just index <- readText indexText,
      Just incarnation <- readText (Text.drop 1 incarnationTextWithDot),
      not (Text.null incarnationTextWithDot) ->
        Right (ProcId (Text.dropEnd 1 roleWithSlash) index incarnation)
  _ -> Left "process id must be <role>/<index>.<incarnation>"
  where
    readText input = case reads (Text.unpack input) of [(parsed, "")] -> Just parsed; _ -> Nothing

instance ToJSON FactKind where toJSON = String . factKindText

instance FromJSON FactKind where
  parseJSON = withText "FactKind" (maybe (fail "unknown fact kind") pure . parseFactKind)

instance ToJSON ProcId where toJSON = String . renderProcId

instance FromJSON ProcId where
  parseJSON = withText "ProcId" (either (fail . Text.unpack) pure . parseProcId)

instance ToJSON Fact where
  toJSON fact =
    object
      [ "schema" .= ("kenshou.ledger-fact/v1" :: Text),
        "kind" .= fact.kind,
        "key" .= fact.key,
        "seq" .= fact.seq,
        "id" .= fact.id,
        "scope" .= fact.scope,
        "proc" .= fact.proc,
        "n" .= fact.n,
        "mono" .= fact.mono,
        "wall" .= fact.wall,
        "attrs" .= Object fact.attrs
      ]

instance FromJSON Fact where
  parseJSON = withObject "Fact" \value -> do
    schema <- value .: "schema"
    if schema /= ("kenshou.ledger-fact/v1" :: Text) then fail "unsupported ledger fact schema" else pure ()
    Fact
      <$> value .: "kind"
      <*> value .: "key"
      <*> value .: "seq"
      <*> value .: "id"
      <*> value .: "scope"
      <*> value .: "proc"
      <*> value .: "n"
      <*> value .: "mono"
      <*> value .: "wall"
      <*> (value .: "attrs" >>= withObject "attrs" pure)
