module Kenshou.Suite.Keiro.Fixture.Transfer
  ( TransferSignal (..),
    SagaPhi,
    TransferSagaEventStream,
    TransferManager,
    transferManagerName,
    transferManager,
    strictTransferManager,
    renamedTransferManager,
    transferSagaStream,
    transferSignalTypes,
    decodeTransferSignal,
    transferTimeoutTimerId,
  )
where

import Data.Aeson (parseJSON, toJSON)
import Data.Aeson.Types (parseEither)
import Data.ByteString qualified as ByteString
import Data.List.NonEmpty (NonEmpty (..))
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import Data.UUID.V5 qualified as UUID.V5
import Keiki.Builder qualified as B
import Keiki.Core (HsPred, RegFile (..), SymTransducer)
import Keiki.Generics.TH (deriveAggregate)
import Keiro.Codec (Codec (..))
import Keiro.EventStream (EventStream (..), SnapshotPolicy (..))
import Keiro.EventStream.Validate (ValidatedEventStream, mkEventStreamOrThrow)
import Keiro.ProcessManager (PMCommand (..), ProcessManager (..), ProcessManagerAction (..))
import Keiro.Projection (InlineProjection)
import Keiro.Stream (Stream)
import Keiro.Stream qualified as Stream
import Keiro.Timer (TimerId (..), TimerRequest (..))
import Kenshou.Suite.Keiro.Fixture.Account
import Kenshou.Suite.Keiro.Fixture.Domain
import Kiroku.Store.Types (EventType (..), RecordedEvent (..))

data TransferSignal = SignalDebited !TransferDebitedData | SignalAnnounced !TransferAnnouncedData
  deriving stock (Eq, Show)

type SagaPhi = HsPred TransferSagaRegs TransferSagaCommand

type TransferSagaEventStream = EventStream SagaPhi TransferSagaRegs TransferSagaState TransferSagaCommand TransferSagaEvent

type ValidatedTransferSagaEventStream = ValidatedEventStream SagaPhi TransferSagaRegs TransferSagaState TransferSagaCommand TransferSagaEvent

type TransferManager =
  ProcessManager
    TransferSignal
    SagaPhi
    TransferSagaRegs
    TransferSagaState
    TransferSagaCommand
    TransferSagaEvent
    AccountPhi
    AccountRegs
    AccountState
    AccountCommand
    AccountEvent

$(deriveAggregate ''TransferSagaCommand ''TransferSagaRegs ''TransferSagaEvent)

transferSagaTransducer :: Bool -> SymTransducer SagaPhi TransferSagaRegs TransferSagaState TransferSagaCommand TransferSagaEvent
transferSagaTransducer allowAnnounceFirst =
  B.buildTransducer SagaIdle RNil (== SagaJoined) do
    B.from SagaIdle do
      B.onCmd inCtorObserveDebit $ \d -> B.do
        emitDebit d
        B.goto SagaDebitSeen
      if allowAnnounceFirst
        then B.onCmd inCtorObserveAnnounce $ \d -> B.do
          emitAnnounce d
          B.goto SagaAnnounceSeen
        else pure ()
    B.from SagaDebitSeen do
      B.onCmd inCtorObserveAnnounce $ \d -> B.do
        emitAnnounce d
        B.goto SagaJoined
    if allowAnnounceFirst
      then B.from SagaAnnounceSeen do
        B.onCmd inCtorObserveDebit $ \d -> B.do
          emitDebit d
          B.goto SagaJoined
      else pure ()
  where
    emitDebit d =
      B.emit
        wireDebitObserved
        DebitObservedTermFields
          { transferId = d.transferId,
            accountId = d.accountId,
            destination = d.destination,
            amount = d.amount,
            deadlineEpochSeconds = d.deadlineEpochSeconds
          }
    emitAnnounce d =
      B.emit
        wireAnnounceObserved
        AnnounceObservedTermFields
          { transferId = d.transferId,
            accountId = d.accountId
          }

transferSagaCodec :: Codec TransferSagaEvent
transferSagaCodec =
  Codec
    { eventTypes = EventType "DebitObserved" :| [EventType "AnnounceObserved"],
      eventType = \case DebitObserved {} -> EventType "DebitObserved"; AnnounceObserved {} -> EventType "AnnounceObserved",
      schemaVersion = 1,
      encode = \case DebitObserved d -> toJSON d; AnnounceObserved d -> toJSON d,
      decode = \(EventType tag) value ->
        let parseRecord v = either (Left . Text.pack) Right (parseEither parseJSON v)
         in case tag of
              "DebitObserved" -> DebitObserved <$> parseRecord value
              "AnnounceObserved" -> AnnounceObserved <$> parseRecord value
              _ -> Left ("unknown transfer saga event type: " <> tag),
      upcasters = []
    }

sagaEventStream :: Bool -> ValidatedTransferSagaEventStream
sagaEventStream allowAnnounceFirst =
  mkEventStreamOrThrow
    "kenshou-transfer-saga"
    EventStream
      { transducer = transferSagaTransducer allowAnnounceFirst,
        initialState = SagaIdle,
        initialRegisters = RNil,
        eventCodec = transferSagaCodec,
        resolveStreamName = Stream.streamName,
        snapshotPolicy = Never,
        stateCodec = Nothing
      }

transferManagerName :: Text
transferManagerName = "transferSaga"

transferManager :: ValidatedAccountEventStream -> (Stream AccountCommand -> [InlineProjection AccountEvent]) -> TransferManager
transferManager accountEvents projections =
  namedManager transferManagerName True accountEvents projections

strictTransferManager :: ValidatedAccountEventStream -> TransferManager
strictTransferManager accountEvents =
  namedManager "transferSagaStrict" False accountEvents (const [])

renamedTransferManager :: Text -> ValidatedAccountEventStream -> TransferManager
renamedTransferManager managerName accountEvents =
  namedManager managerName True accountEvents (const [])

namedManager :: Text -> Bool -> ValidatedAccountEventStream -> (Stream AccountCommand -> [InlineProjection AccountEvent]) -> TransferManager
namedManager managerName allowAnnounceFirst accountEvents projections =
  ProcessManager
    { name = managerName,
      correlate = \case
        SignalDebited d -> let TransferId transfer = d.transferId in transfer
        SignalAnnounced d -> let TransferId transfer = d.transferId in transfer,
      eventStream = sagaEventStream allowAnnounceFirst,
      streamFor = \transfer -> Stream.entityStream (Stream.categoryUnsafe ("pm:" <> managerName)) transfer,
      targetEventStream = accountEvents,
      targetProjections = projections,
      handle = \case
        SignalDebited d ->
          let TransferId transfer = d.transferId
           in ProcessManagerAction
                { command = ObserveDebit (ObserveDebitData d.transferId d.accountId d.destination d.amount d.deadlineEpochSeconds),
                  commands =
                    [ PMCommand (accountCommandStream d.destination) (CreditTransfer (CreditTransferData d.destination d.transferId d.accountId d.amount)),
                      PMCommand (accountCommandStream d.accountId) (ConfirmTransfer (ConfirmTransferData d.accountId d.transferId))
                    ],
                  timers =
                    [ TimerRequest
                        { timerId = transferTimeoutTimerId d.transferId,
                          processManagerName = managerName,
                          correlationId = transfer,
                          fireAt = posixSecondsToUTCTime (fromIntegral d.deadlineEpochSeconds),
                          payload = toJSON d
                        }
                    ]
                }
        SignalAnnounced d ->
          ProcessManagerAction
            { command = ObserveAnnounce (ObserveAnnounceData d.transferId d.accountId),
              commands = [],
              timers = []
            }
    }

transferSagaStream :: TransferId -> Stream TransferSagaEventStream
transferSagaStream (TransferId transfer) =
  Stream.entityStream (Stream.categoryUnsafe "pm:transferSaga") transfer

transferSignalTypes :: Set EventType
transferSignalTypes = Set.fromList [EventType "TransferDebited", EventType "TransferAnnounced"]

decodeTransferSignal :: RecordedEvent -> Maybe (RecordedEvent, TransferSignal)
decodeTransferSignal recorded =
  case accountCodec.decode recorded.eventType recorded.payload of
    Right (TransferDebited d) -> Just (recorded, SignalDebited d)
    Right (TransferAnnounced d) -> Just (recorded, SignalAnnounced d)
    _ -> Nothing

transferTimeoutTimerId :: TransferId -> TimerId
transferTimeoutTimerId (TransferId transfer) =
  TimerId (UUID.V5.generateNamed UUID.V5.namespaceURL (ByteString.unpack (Text.encodeUtf8 ("kenshou:transfer-timeout:" <> transfer))))
