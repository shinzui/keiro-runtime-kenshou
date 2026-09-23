module Kenshou.Suite.Keiro.Fixture.Bridge
  ( AckRecord (..),
    listAdapter,
    interposeAck,
  )
where

import Data.IORef (IORef, modifyIORef')
import Data.Text (Text)
import Data.UUID qualified as UUID
import Effectful (Eff, IOE, liftIO, (:>))
import Kiroku.Store.Types (EventId (..), RecordedEvent (..))
import Shibuya.Adapter (Adapter (..))
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
