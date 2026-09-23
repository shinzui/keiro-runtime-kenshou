module Kenshou.Suite.Keiro.Fixture.Bridge
  ( AckRecord (..),
    listAdapter,
    kirokuBridge,
    ackStreamAdapter,
    sagaAdapterConfig,
    bonusAdapterConfig,
    interposeAck,
  )
where

import Data.IORef (IORef, modifyIORef')
import Data.Text (Text)
import Data.UUID qualified as UUID
import Effectful (Eff, IOE, liftIO, (:>))
import Kenshou.Suite.Keiro.Fixture.Transfer (transferSignalTypes)
import Kiroku.Store (KirokuStore)
import Kiroku.Store.Subscription.Stream (subscriptionAckStream)
import Kiroku.Store.Subscription.Types (ConsumerGroup (..), SubscriptionConfig, SubscriptionConfigM (..), SubscriptionName (..))
import Kiroku.Store.Types (CategoryName (..), EventId (..), RecordedEvent (..))
import Numeric.Natural (Natural)
import Shibuya.Adapter (Adapter (..))
import Shibuya.Adapter.Kiroku (EventTypeFilter (..), KirokuAdapterConfig (..), SubscriptionTarget (..), defaultKirokuAdapterConfig, kirokuAdapter)
import Shibuya.Adapter.Kiroku qualified as KirokuAdapter
import Shibuya.Adapter.Kiroku.Convert (kirokuEnvelopeAttrs, toIngestedAck)
import Shibuya.Core.Ack (AckDecision)
import Shibuya.Core.AckHandle (AckHandle (..))
import Shibuya.Core.Ingested (Ingested (..))
import Shibuya.Core.Types (Attempt (..), Envelope (..), MessageId (..))
import Streamly.Data.Stream qualified as Streamly

data AckRecord = AckRecord
  { messageId :: !MessageId,
    attempt :: !(Maybe Attempt),
    decision :: !AckDecision
  }
  deriving stock (Eq, Show)

kirokuBridge :: (IOE :> es) => KirokuStore -> KirokuAdapterConfig -> Eff es (Adapter es RecordedEvent)
kirokuBridge = kirokuAdapter

ackStreamAdapter :: (IOE :> es) => KirokuStore -> SubscriptionConfig -> Natural -> Eff es (Adapter es RecordedEvent)
ackStreamAdapter store config capacity = do
  (items, cancel) <- liftIO (subscriptionAckStream store config capacity)
  let SubscriptionName name = config.name
      memberIndex = fromIntegral . (.member) <$> config.consumerGroup
      attributes = kirokuEnvelopeAttrs name memberIndex
  pure
    Adapter
      { adapterName = name,
        source = fmap (toIngestedAck attributes cancel) (Streamly.morphInner liftIO items),
        shutdown = liftIO cancel
      }

sagaAdapterConfig :: SubscriptionName -> Maybe ConsumerGroup -> KirokuAdapterConfig
sagaAdapterConfig subscription group =
  (defaultKirokuAdapterConfig subscription (Category (CategoryName "account")))
    { KirokuAdapter.consumerGroup = group,
      KirokuAdapter.eventTypeFilter = OnlyEventTypes transferSignalTypes
    }

bonusAdapterConfig :: SubscriptionName -> KirokuAdapterConfig
bonusAdapterConfig subscription = defaultKirokuAdapterConfig subscription (Category (CategoryName "bonus"))

listAdapter :: (IOE :> es) => Text -> IORef [AckRecord] -> [(RecordedEvent, Maybe Word)] -> Adapter es RecordedEvent
listAdapter adapterLabel acknowledgementLog input =
  Adapter
    { adapterName = adapterLabel,
      source = Streamly.fromList (map toIngested input),
      shutdown = pure ()
    }
  where
    toIngested (recorded, attemptNumber) =
      let EventId uuid = recorded.eventId
          identifier = MessageId (UUID.toText uuid)
          attempt = Attempt <$> attemptNumber
       in Ingested
            { envelope =
                Envelope
                  { messageId = identifier,
                    cursor = Nothing,
                    partition = Nothing,
                    enqueuedAt = Just recorded.createdAt,
                    traceContext = Nothing,
                    headers = Nothing,
                    attempt = attempt,
                    attributes = mempty,
                    payload = recorded
                  },
              ack = AckHandle (\decision -> liftIO (modifyIORef' acknowledgementLog (<> [AckRecord identifier attempt decision]))),
              lease = Nothing
            }

interposeAck :: (Envelope msg -> AckDecision -> Eff es ()) -> Adapter es msg -> Adapter es msg
interposeAck before adapter =
  adapter
    { source = Streamly.mapM (pure . wrap) adapter.source
    }
  where
    wrap ingested =
      let AckHandle finalize = ingested.ack
       in ingested {ack = AckHandle (\decision -> before ingested.envelope decision >> finalize decision)}
