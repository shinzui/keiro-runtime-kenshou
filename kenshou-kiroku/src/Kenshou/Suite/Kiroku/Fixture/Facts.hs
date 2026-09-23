module Kenshou.Suite.Kiroku.Fixture.Facts
  ( Produced (..),
    Delivered (..),
    CheckpointSample (..),
    KirokuFact (..),
  )
where

import Data.Aeson (FromJSON (..), ToJSON (..), object, withObject, (.:), (.=))
import Data.Aeson.Types (Parser)
import Data.Int (Int32, Int64)
import Data.Text (Text)
import Data.UUID (UUID)

data Produced = Produced
  { stream :: Text,
    lastVersion :: Int64,
    lastPosition :: Int64,
    eventIds :: [UUID],
    ackWallNanos :: Int64
  }
  deriving stock (Eq, Show)

data Delivered = Delivered
  { subscription :: Text,
    member :: Int32,
    position :: Int64,
    eventId :: UUID,
    originStreamId :: Int64,
    originVersion :: Int64,
    attempt :: Int,
    incarnation :: Int,
    recvWallNanos :: Int64
  }
  deriving stock (Eq, Show)

data CheckpointSample = CheckpointSample
  { subscription :: Text,
    member :: Int32,
    position :: Int64,
    sampledWallNanos :: Int64
  }
  deriving stock (Eq, Show)

data KirokuFact = ProducedFact Produced | DeliveredFact Delivered | CheckpointFact CheckpointSample
  deriving stock (Eq, Show)

instance ToJSON KirokuFact where
  toJSON = \case
    ProducedFact fact -> object ["kind" .= ("produced" :: Text), "stream" .= fact.stream, "lastVersion" .= fact.lastVersion, "lastPosition" .= fact.lastPosition, "eventIds" .= fact.eventIds, "ackWallNanos" .= fact.ackWallNanos]
    DeliveredFact fact -> object ["kind" .= ("delivered" :: Text), "subscription" .= fact.subscription, "member" .= fact.member, "position" .= fact.position, "eventId" .= fact.eventId, "originStreamId" .= fact.originStreamId, "originVersion" .= fact.originVersion, "attempt" .= fact.attempt, "incarnation" .= fact.incarnation, "recvWallNanos" .= fact.recvWallNanos]
    CheckpointFact fact -> object ["kind" .= ("checkpoint" :: Text), "subscription" .= fact.subscription, "member" .= fact.member, "position" .= fact.position, "sampledWallNanos" .= fact.sampledWallNanos]

instance FromJSON KirokuFact where
  parseJSON = withObject "KirokuFact" \value -> do
    kind <- value .: "kind" :: Parser Text
    case kind of
      "produced" -> ProducedFact <$> (Produced <$> value .: "stream" <*> value .: "lastVersion" <*> value .: "lastPosition" <*> value .: "eventIds" <*> value .: "ackWallNanos")
      "delivered" -> DeliveredFact <$> (Delivered <$> value .: "subscription" <*> value .: "member" <*> value .: "position" <*> value .: "eventId" <*> value .: "originStreamId" <*> value .: "originVersion" <*> value .: "attempt" <*> value .: "incarnation" <*> value .: "recvWallNanos")
      "checkpoint" -> CheckpointFact <$> (CheckpointSample <$> value .: "subscription" <*> value .: "member" <*> value .: "position" <*> value .: "sampledWallNanos")
      _ -> fail "unknown kiroku fact kind"
