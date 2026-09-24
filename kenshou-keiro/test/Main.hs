module Main (main) where

import Data.Aeson (object)
import Data.Aeson qualified as Aeson
import Data.ByteString qualified as ByteString
import Data.IORef (newIORef, readIORef)
import Data.List (intersect)
import Data.Map.Strict qualified as Map
import Data.Proxy (Proxy (..))
import Data.Text (Text)
import Data.Time (NominalDiffTime, addUTCTime, getCurrentTime)
import Data.Time.Clock (UTCTime)
import Data.UUID qualified as UUID
import Effectful (runEff)
import Hedgehog (forAll)
import Hedgehog qualified
import Hedgehog.Gen qualified as Gen
import Hedgehog.Range qualified as Range
import Keiki.Core (RegFile (..), step)
import Keiro.Codec (Codec (..))
import Keiro.EventStream (SnapshotPolicy (..))
import Keiro.Integration.Event (IntegrationContentType (..), IntegrationEvent (..))
import Keiro.Outbox (OutboxId (..), OutboxRow (..), OutboxStatus (..))
import Keiro.ProcessManager (ProcessManager (..), deterministicCommandId)
import Keiro.Router (deterministicRouterCommandId)
import Keiro.Subscription.Shard.Worker (ShardedWorkerOptions (..))
import Keiro.Timer (TimerWorkerOptions (..))
import Keiro.Workflow (WorkflowId (..), WorkflowRunOptions (..), deterministicJournalId)
import Keiro.Workflow.Resume (WorkflowResumeOptions (..))
import Kenshou.Core.Knob (RawKnob (..), resolveKnobs)
import Kenshou.Suite.Keiro.Fixture.Account
import Kenshou.Suite.Keiro.Fixture.Bonus
import Kenshou.Suite.Keiro.Fixture.Bridge
import Kenshou.Suite.Keiro.Fixture.Domain
import Kenshou.Suite.Keiro.Fixture.Model qualified as Model
import Kenshou.Suite.Keiro.Fixture.Oracle qualified as Oracle
import Kenshou.Suite.Keiro.Fixture.Transfer
import Kenshou.Suite.Keiro.Fixture.Workload qualified as Workload
import Kenshou.Suite.Keiro.Outbox.Broker qualified as Broker
import Kenshou.Suite.Keiro.Outbox.Oracle qualified as OutboxOracle
import Kenshou.Suite.Keiro.Shard.Knobs qualified as ShardKnobs
import Kenshou.Suite.Keiro.Shard.Oracle qualified as ShardOracle
import Kenshou.Suite.Keiro.Timer.Knobs qualified as TimerKnobs
import Kenshou.Suite.Keiro.Workflow.Definitions qualified as WorkflowDefinitions
import Kenshou.Suite.Keiro.Workflow.Effects qualified as WorkflowEffects
import Kenshou.Suite.Keiro.Workflow.Knobs qualified as WorkflowKnobs
import Kenshou.Suite.Keiro.Workflow.Oracle qualified as WorkflowOracle
import Kiroku.Store.Subscription.Types (SubscriptionTarget (..))
import Kiroku.Store.Types (EventId (..), EventType (..), GlobalPosition (..), RecordedEvent (..), StreamId (..), StreamVersion (..))
import Shibuya.Adapter (Adapter (..))
import Shibuya.Core.Ack (AckDecision (..))
import Shibuya.Core.AckHandle (AckHandle (..))
import Shibuya.Core.Ingested (Ingested (..))
import Streamly.Data.Fold qualified as Fold
import Streamly.Data.Stream qualified as Stream
import Test.Hspec
import Test.Hspec.Hedgehog (hedgehog)

main :: IO ()
main = hspec do
  describe "workflow crash schedule" do
    it "arms only the named positive occurrence of a matching boundary" do
      let boundary = WorkflowEffects.AfterStepAction "s3"
          plans = [WorkflowEffects.CrashPlan boundary 2]
      WorkflowEffects.shouldCrash plans boundary 1 `shouldBe` False
      WorkflowEffects.shouldCrash plans boundary 2 `shouldBe` True
      WorkflowEffects.shouldCrash plans boundary 3 `shouldBe` False
      WorkflowEffects.shouldCrash plans (WorkflowEffects.AfterStepAction "s4") 2 `shouldBe` False
      WorkflowEffects.shouldCrash [WorkflowEffects.CrashPlan boundary 0] boundary 0 `shouldBe` False
  describe "linear workflow model" do
    it "predicts the named journal steps and stable result" do
      let params = WorkflowDefinitions.DefinitionParams 7 3
          wid = WorkflowId "wf-1"
      WorkflowDefinitions.expectedLinearSteps params `shouldBe` ["s0", "s1", "s2"]
      WorkflowDefinitions.expectedLinearResult params wid `shouldBe` 7 * 3 + 31 * 4 * 3 + 3
  describe "workflow oracles" do
    it "rejects a duplicated or wrong-ID journal step" do
      let name = WorkflowDefinitions.linearName
          wid = WorkflowId "oracle"
          first = deterministicJournalId name wid 0 "s0"
          second = deterministicJournalId name wid 0 "s1"
          expected = ["s0", "s1"]
      WorkflowOracle.journalStepIdentity name wid 0 expected [("s0", first), ("s1", second)] `shouldBe` True
      WorkflowOracle.journalStepIdentity name wid 0 expected [("s0", first), ("s0", first), ("s1", second)] `shouldBe` False
      WorkflowOracle.journalStepIdentity name wid 0 expected [("s0", second), ("s1", second)] `shouldBe` False
    it "allows duplicate effects only under a recorded crash window" do
      let keys = ["s0", "s1"]
          effects = Map.fromList [("s0", 2), ("s1", 1)]
      WorkflowOracle.effectCoverage keys effects (Map.singleton "s0" 1) `shouldBe` True
      WorkflowOracle.effectCoverage keys effects Map.empty `shouldBe` False
      WorkflowOracle.effectCoverage keys (Map.insert "s2" 1 effects) (Map.singleton "s0" 1) `shouldBe` False
      WorkflowOracle.effectCoverage keys (Map.delete "s1" effects) (Map.singleton "s0" 1) `shouldBe` False
    it "rejects retry gaps that are too short or too long" do
      now <- getCurrentTime
      let good = [now, addUTCTime 2 now, addUTCTime 6 now, addUTCTime 14 now]
      WorkflowOracle.backoffLadder 2 0.2 good `shouldBe` Right ()
      WorkflowOracle.backoffLadder 2 0.2 [now, addUTCTime 1 now] `shouldSatisfy` either (const True) (const False)
      WorkflowOracle.backoffLadder 2 0.2 [now, addUTCTime 3 now] `shouldSatisfy` either (const True) (const False)
  describe "workflow knobs" do
    it "maps resolved defaults to short lease and polling options" do
      case resolveKnobs WorkflowKnobs.workflowKnobs [] of
        Left errors -> expectationFailure (show errors)
        Right knobs -> case WorkflowKnobs.resumeOptionsFrom knobs of
          Left err -> expectationFailure (show err)
          Right options -> do
            options.leaseTtl `shouldBe` 3
            options.pollInterval `shouldBe` 100000
            options.maxConcurrentAdvances `shouldBe` 1
            case options.runOptions.snapshotPolicy of
              Never -> pure ()
              _ -> expectationFailure "default workflow snapshot policy was not Never"
    it "rejects a nonpositive snapshot interval after parsing" do
      let override = [(WorkflowKnobs.workflowKnobName "workflow.snapshot-policy", RawText "every-0")]
      case resolveKnobs WorkflowKnobs.workflowKnobs override of
        Left errors -> expectationFailure (show errors)
        Right knobs -> case WorkflowKnobs.runOptionsFrom knobs of
          Left _ -> pure ()
          Right _ -> expectationFailure "every-0 snapshot policy was accepted"
  describe "timer knobs" do
    it "maps defaults and the disabled recovery arm" do
      case resolveKnobs TimerKnobs.timerKnobs [] of
        Left errors -> expectationFailure (show errors)
        Right knobs -> TimerKnobs.timerOptionsFrom knobs `shouldBe` Right (TimerWorkerOptions Nothing (Just 2))
      let overrides = [(TimerKnobs.timerKnobName "timer.max-attempts", RawText "3"), (TimerKnobs.timerKnobName "timer.requeue-stuck-after-seconds", RawText "none")]
      case resolveKnobs TimerKnobs.timerKnobs overrides of
        Left errors -> expectationFailure (show errors)
        Right knobs -> TimerKnobs.timerOptionsFrom knobs `shouldBe` Right (TimerWorkerOptions (Just 3) Nothing)
    it "rejects nonpositive recovery and negative attempt ceilings" do
      let parse knob value = resolveKnobs TimerKnobs.timerKnobs [(TimerKnobs.timerKnobName knob, RawText value)]
      case parse "timer.max-attempts" "-1" of
        Left errors -> expectationFailure (show errors)
        Right knobs -> TimerKnobs.timerOptionsFrom knobs `shouldSatisfy` either (const True) (const False)
      case parse "timer.requeue-stuck-after-seconds" "0" of
        Left errors -> expectationFailure (show errors)
        Right knobs -> TimerKnobs.timerOptionsFrom knobs `shouldSatisfy` either (const True) (const False)
  describe "shard oracles" do
    it "includes one reconciliation pass per lost bucket per survivor" do
      ShardOracle.failoverDeadline (ShardOracle.ShardTiming 3 0.5) 5 2 `shouldBe` 5.5
    it "rejects missing and overlapping bucket owners" do
      ShardOracle.coverageAndDisjointness 2 [(0, ["a"]), (1, ["b"])] `shouldBe` True
      ShardOracle.coverageAndDisjointness 2 [(0, ["a", "b"]), (1, ["b"])] `shouldBe` False
      ShardOracle.coverageAndDisjointness 2 [(0, ["a"])] `shouldBe` False
    it "rejects a regressing checkpoint for one member" do
      ShardOracle.checkpointsMonotonic [("a", 1), ("b", 5), ("a", 2), ("b", 5)] `shouldBe` True
      ShardOracle.checkpointsMonotonic [("a", 2), ("b", 5), ("a", 1)] `shouldBe` False
  describe "shard knobs" do
    it "maps resolved defaults to valid short leases" do
      case resolveKnobs ShardKnobs.shardKnobs [] of
        Left errors -> expectationFailure (show errors)
        Right knobs -> case ShardKnobs.shardOptionsFrom AllStreams knobs of
          Left err -> expectationFailure (show err)
          Right options -> do
            options.shardCount `shouldBe` 8
            options.leaseTtl `shouldBe` (3 :: NominalDiffTime)
            options.renewInterval `shouldBe` (0.5 :: NominalDiffTime)
    it "rejects a renew interval at the lease deadline" do
      let override = [(ShardKnobs.shardKnobName "shard.renew-interval-seconds", RawText "3")]
      case resolveKnobs ShardKnobs.shardKnobs override of
        Left errors -> expectationFailure (show errors)
        Right knobs -> case ShardKnobs.shardOptionsFrom AllStreams knobs of
          Left _ -> pure ()
          Right _ -> expectationFailure "renew interval at the lease deadline was accepted"
    it "keeps integral decimal defaults valid across worker JSON" do
      case resolveKnobs ShardKnobs.shardKnobs [] of
        Left errors -> expectationFailure (show errors)
        Right knobs -> case Aeson.decode (Aeson.encode knobs) of
          Nothing -> expectationFailure "resolved shard knobs failed to decode"
          Just decoded -> case ShardKnobs.shardOptionsFrom AllStreams decoded of
            Left err -> expectationFailure (show err)
            Right options -> options.leaseTtl `shouldBe` (3 :: NominalDiffTime)
  describe "Outbox broker" do
    it "makes stable decisions from seed, identity and attempt" do
      now <- getCurrentTime
      let row = brokerRow now "one" (Just "group")
          plan = Broker.FaultPlan 912 0.3 0.2 0.1 0.05 0.15
          retryPlan = Broker.FaultPlan 912 1 0 0 0 0
      Broker.decide plan row `shouldBe` Broker.decide plan (brokerRow now "one" (Just "group"))
      Broker.decide retryPlan row `shouldBe` Broker.FailOnce
      Broker.decide retryPlan (row {attemptCount = 2}) `shouldBe` Broker.Succeed
      let poisonPlan = Broker.FaultPlan 1 0 0 1 0 0
      Broker.decide poisonPlan row `shouldBe` Broker.AlwaysFail
      Broker.decide poisonPlan (row {attemptCount = 7}) `shouldBe` Broker.AlwaysFail
    it "never appends a later row of a failed key in the same callback" do
      now <- getCurrentTime
      broker <- Broker.newBroker
      let model = Broker.BrokerModel 0 0 4
          plan = Broker.FaultPlan 1 0 0 1 0 0
          hooks = Broker.PublishHook (const (pure ())) (const (pure ()))
      outcomes <- runEff (Broker.publishCallback broker model plan hooks "test" [brokerRow now "first" (Just "group"), brokerRow now "second" (Just "group")])
      length outcomes `shouldBe` 2
      records <- Broker.readBroker broker
      records `shouldBe` []
  describe "Outbox oracles" do
    it "rejects a later broker offset carrying an earlier sequence of the same key" do
      OutboxOracle.perKeyOrder [("a" :: Text, 1), ("b", 9), ("a", 3), ("a", 2)] `shouldBe` False
      OutboxOracle.perKeyOrder [("a" :: Text, 1), ("b", 9), ("a", 2)] `shouldBe` True
    it "rejects a duplicate outside every recorded crash window" do
      OutboxOracle.boundedDuplicates (Map.singleton ("in-flight" :: Text) 1) ["in-flight", "in-flight", "outside", "outside"] `shouldBe` False
      OutboxOracle.boundedDuplicates (Map.singleton ("in-flight" :: Text) 1) ["in-flight", "in-flight", "outside"] `shouldBe` True
  describe "account event stream validation" do
    it "accepts every snapshot policy" do
      let accepted = accountEventStream SnapNever `seq` accountEventStream (SnapEvery 1) `seq` accountEventStream (SnapEvery 10) `seq` accountEventStream SnapOnTerminal `seq` True
      accepted `shouldBe` True
    it "accepts the bonus and transfer transducers" do
      let manager = transferManager (accountEventStream SnapNever) (const [])
          strict = strictTransferManager (accountEventStream SnapNever)
          accepted = bonusEventStream `seq` manager.eventStream `seq` strict.eventStream `seq` True
      accepted `shouldBe` True
  describe "account codec" do
    it "round trips every event constructor" do
      mapM_ checkCodec events
  describe "reference model" do
    it "agrees with the keiki transducer on a command sequence" do
      compareSteps commands
    it "agrees on generated accepts, no-ops, rejections, and balances" $ hedgehog do
      generated <- forAll (Gen.list (Range.linear 1 80) genCommand)
      Hedgehog.assert (matchesSequence generated)
  describe "workload" do
    it "is deterministic for a seed and worker" do
      take 50 (Workload.workerOps 91 Workload.defaultWorkloadSpec 0 2)
        `shouldBe` take 50 (Workload.workerOps 91 Workload.defaultWorkloadSpec 0 2)
    it "gives setup and generated operations different event identifiers" do
      let setup = Workload.Op (-1) 0 (Workload.ActOpen (AccountId "0") 100)
          generated = Workload.Op 0 0 (Workload.ActDeposit (AccountId "0") 1)
      Workload.opEventId 91 setup 0 `shouldNotBe` Workload.opEventId 91 generated 0
    it "separates event identifiers across workers" $ hedgehog do
      seed <- forAll (Gen.word64 Range.constantBounded)
      let spec = Workload.defaultWorkloadSpec
          identifiers worker = [Workload.opEventId seed operation leg | operation <- take 100 (Workload.workerOps seed spec worker 2), leg <- [0, 1]]
      Hedgehog.assert (null (identifiers 0 `intersect` identifiers 1))
  describe "dispatch identifiers" do
    it "matches process-manager identity and a fixed UUID witness" do
      let source = EventId UUID.nil
          expected = Oracle.expectedSagaCommandId "transferSaga" (TransferId "t") source 0
      expected `shouldBe` deterministicCommandId "transferSaga" "t" source 0
      expected `shouldBe` EventId (read "bb2033a0-9c9d-5a6e-afbc-520a4c80c0d5")
      Oracle.expectedSagaStateId "transferSaga" (TransferId "t") source
        `shouldBe` deterministicCommandId "transferSaga" "t" source (-1)
    it "matches router identity and a fixed UUID witness" do
      let source = EventId UUID.nil
          expected = Oracle.expectedRouterCommandId "bonusRouter" (BonusId "b") source (AccountId "a") 0
      expected `shouldBe` deterministicRouterCommandId "bonusRouter" "b" source (accountStreamName (AccountId "a")) 0
      expected `shouldBe` EventId (read "2fa4be29-7c5d-5665-b5a2-b5a7a6054754")
  describe "list adapter" do
    it "records one acknowledgement for every delivery" do
      now <- getCurrentTime
      acknowledgements <- newIORef []
      let recorded =
            RecordedEvent
              { eventId = EventId UUID.nil,
                eventType = EventType "TransferDebited",
                streamVersion = StreamVersion 1,
                globalPosition = GlobalPosition 1,
                originalStreamId = StreamId 1,
                originalVersion = StreamVersion 1,
                payload = object [],
                metadata = Nothing,
                causationId = Nothing,
                correlationId = Nothing,
                createdAt = now
              }
          adapter = listAdapter "test" acknowledgements [(recorded, Just 0), (recorded, Just 1)]
      runEff do
        ingested <- Stream.fold Fold.toList adapter.source
        mapM_ (\item -> let AckHandle finalize = item.ack in finalize AckOk) ingested
      records <- readIORef acknowledgements
      map (.decision) records `shouldBe` [AckOk, AckOk]
      length records `shouldBe` 2
  where
    a = AccountId "a"
    b = AccountId "b"
    t = TransferId "t"
    events =
      [ AccountOpened (AccountOpenedData a 100),
        Deposited (DepositedData a 7 "memo"),
        Withdrawn (WithdrawnData a 2),
        TransferDebited (TransferDebitedData a t b 3 900),
        TransferAnnounced (TransferAnnouncedData a t),
        TransferCredited (TransferCreditedData a t b 3),
        TransferConfirmed (TransferConfirmedData a t),
        BonusCredited (BonusCreditedData a (BonusId "bonus") 1),
        AccountClosed (AccountClosedData a)
      ]
    checkCodec event = accountCodec.decode (accountCodec.eventType event) (accountCodec.encode event) `shouldBe` Right event
    commands =
      [ OpenAccount (OpenAccountData a 100),
        Deposit (DepositData a 7 "memo"),
        Withdraw (WithdrawData a 2),
        DebitTransfer (DebitTransferData a t b 3 900),
        AnnounceTransfer (AnnounceTransferData a t),
        CreditTransfer (CreditTransferData a t b 3),
        ConfirmTransfer (ConfirmTransferData a t),
        CreditBonus (CreditBonusData a (BonusId "bonus") 1)
      ]
    compareSteps = go Model.emptyModel (AcctUnopened, RCons (Proxy @"balance") (0 :: Int) (RCons (Proxy @"entries") (0 :: Int) RNil))
    go _ _ [] = pure ()
    go model state (command : rest) =
      case (Model.decide model command, step accountTransducer state command) of
        (Model.ModelAccepts expected, Just (nextState, nextRegs, [actual])) -> do
          actual `shouldBe` expected
          go (Model.apply actual model) (nextState, nextRegs) rest
        other -> expectationFailure ("model/transducer disagreement: " <> show (fst other))

    genCommand = do
      amount <- Gen.int (Range.linear (-2) 20)
      Gen.element
        [ OpenAccount (OpenAccountData a amount),
          Deposit (DepositData a amount "generated"),
          Withdraw (WithdrawData a amount),
          DebitTransfer (DebitTransferData a t b amount 4102444800),
          AnnounceTransfer (AnnounceTransferData a t),
          CreditTransfer (CreditTransferData a t b amount),
          ConfirmTransfer (ConfirmTransferData a t),
          CreditBonus (CreditBonusData a (BonusId "generated") amount),
          CloseAccount (CloseAccountData a)
        ]
    matchesSequence = check Model.emptyModel (AcctUnopened, RCons (Proxy @"balance") (0 :: Int) (RCons (Proxy @"entries") (0 :: Int) RNil))
    check _ _ [] = True
    check model state (command : rest) =
      case (Model.decide model command, step accountTransducer state command) of
        (Model.ModelAccepts expected, Just (nextState, nextRegs, [actual])) ->
          let nextModel = Model.apply actual model
              RCons _ balance (RCons _ entries RNil) = nextRegs
              account = Model.lookupAccount a nextModel
           in actual == expected && balance == account.balance && entries == account.entries && check nextModel (nextState, nextRegs) rest
        (Model.ModelNoOp, Just (nextState, nextRegs, [])) -> check model (nextState, nextRegs) rest
        (Model.ModelRejects, Nothing) -> check model state rest
        _ -> False

brokerRow :: UTCTime -> Text -> Maybe Text -> OutboxRow
brokerRow now messageId key =
  OutboxRow
    { outboxId = OutboxId UUID.nil,
      event = IntegrationEvent messageId "source" "topic" key "Test" 1 ApplicationJson Nothing Nothing Nothing ByteString.empty now Nothing Nothing Nothing Nothing,
      status = OutboxPending,
      attemptCount = 1,
      nextAttemptAt = now,
      lastError = Nothing,
      publishedAt = Nothing,
      rejectedAt = Nothing,
      rejection = Nothing,
      createdAt = now,
      updatedAt = now
    }
