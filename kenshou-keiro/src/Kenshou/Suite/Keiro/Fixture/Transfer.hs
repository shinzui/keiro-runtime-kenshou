module Kenshou.Suite.Keiro.Fixture.Transfer
  ( TransferSignal (..),
    SagaPhi,
    TransferSagaEventStream,
    TransferManager,
    ReactionSignal (..),
    TransferReaction,
    transferManagerName,
    transferManager,
    strictTransferManager,
    renamedTransferManager,
    transferReaction,
    transferSagaStream,
    transferSignalTypes,
    decodeTransferSignal,
    decodeReactionSignal,
    transferTimeoutTimerId,
    transferReminderTimerId,
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
import Data.Void (Void)
import Keiki.Builder qualified as B
import Keiki.Core (HsPred, RegFile (..), SymTransducer)
import Keiki.Generics.TH (deriveAggregate)
import Keiro.Codec (Codec (..))
import Keiro.Command (DomainCommandHandler (..), SilentDomainDecision (..))
import Keiro.EventStream (EventStream (..), SnapshotPolicy (..))
import Keiro.EventStream.Validate (ValidatedEventStream, mkEventStreamOrThrow)
import Keiro.ProcessManager (PMCommand (..), ProcessManager (..), ProcessManagerAction (..))
import Keiro.ProcessManager.Reaction (FollowUp (..), ReactionPlan (..), ReactiveProcessManager (..), ScheduleMode (..))
import Keiro.Projection (InlineProjection)
import Keiro.Stream (Stream)
import Keiro.Stream qualified as Stream
import Keiro.Timer (TimerId (..), TimerRequest (..))
import Kenshou.Suite.Keiro.Fixture.Account
import Kenshou.Suite.Keiro.Fixture.Domain
import Kiroku.Store.Types (EventType (..), RecordedEvent (..))

data TransferSignal = SignalDebited !TransferDebitedData | SignalAnnounced !TransferAnnouncedData
  deriving stock (Eq, Show)

data ReactionSignal = ReactDebited !TransferDebitedData | ReactAnnounced !TransferAnnouncedData | ReactCredited !TransferCreditedData
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

type TransferReaction =
  ReactiveProcessManager
    ReactionSignal
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
    Void
    ()

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

transferReaction :: ValidatedAccountEventStream -> TransferReaction
transferReaction accountEvents =
  ReactiveProcessManager
    { name = "transferReaction",
      correlate = \case
        ReactDebited d -> correlation d.transferId
        ReactAnnounced d -> correlation d.transferId
        ReactCredited d -> correlation d.transferId,
      sagaHandler = DomainCommandHandler {eventStream = sagaEventStream True, classifySilent = const (SilentNoOp ())},
      streamFor = Stream.entityStream (Stream.categoryUnsafe "pm:transferReaction"),
      targetEventStream = accountEvents,
      targetProjections = const [],
      react = \case
        ReactDebited d ->
          let credit = PMCommand (accountCommandStream d.destination) (CreditTransfer (CreditTransferData d.destination d.transferId d.accountId d.amount))
              confirm = PMCommand (accountCommandStream d.accountId) (ConfirmTransfer (ConfirmTransferData d.accountId d.transferId))
           in AdvanceReaction
                { command = ObserveDebit (ObserveDebitData d.transferId d.accountId d.destination d.amount d.deadlineEpochSeconds),
                  followUps = [FollowSchedule Rearm (reminder d.transferId (d.deadlineEpochSeconds - 60))],
                  onAccepted = [FollowDispatch credit, FollowDispatch confirm, FollowSchedule Once (timeout d.transferId d.deadlineEpochSeconds)]
                }
        ReactAnnounced d ->
          AdvanceReaction
            { command = ObserveAnnounce (ObserveAnnounceData d.transferId d.accountId),
              followUps = [FollowSchedule Rearm (reminder d.transferId 4102444740)],
              onAccepted = [FollowSchedule Once (timeout d.transferId 4102444800)]
            }
        ReactCredited d -> NoAdvance [FollowCancel (transferTimeoutTimerId d.transferId)]
    }
  where
    correlation (TransferId value) = value
    timeout :: TransferId -> Int -> TimerRequest
    timeout transfer due = TimerRequest (transferTimeoutTimerId transfer) "transferReaction" (correlation transfer) (posixSecondsToUTCTime (fromIntegral due)) (toJSON transfer)
    reminder :: TransferId -> Int -> TimerRequest
    reminder transfer due = TimerRequest (transferReminderTimerId transfer) "transferReaction" (correlation transfer) (posixSecondsToUTCTime (fromIntegral due)) (toJSON transfer)

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

decodeReactionSignal :: RecordedEvent -> Maybe (RecordedEvent, ReactionSignal)
decodeReactionSignal recorded =
  case accountCodec.decode recorded.eventType recorded.payload of
    Right (TransferDebited d) -> Just (recorded, ReactDebited d)
    Right (TransferAnnounced d) -> Just (recorded, ReactAnnounced d)
    Right (TransferCredited d) -> Just (recorded, ReactCredited d)
    _ -> Nothing

transferTimeoutTimerId :: TransferId -> TimerId
transferTimeoutTimerId (TransferId transfer) =
  TimerId (UUID.V5.generateNamed UUID.V5.namespaceURL (ByteString.unpack (Text.encodeUtf8 ("kenshou:transfer-timeout:" <> transfer))))

transferReminderTimerId :: TransferId -> TimerId
transferReminderTimerId (TransferId transfer) =
  TimerId (UUID.V5.generateNamed UUID.V5.namespaceURL (ByteString.unpack (Text.encodeUtf8 ("kenshou:transfer-reminder:" <> transfer))))
