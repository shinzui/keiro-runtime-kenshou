module Kenshou.Suite.Keiro.Workflow.TerminalRace
  ( scenarios,
    Marker (..),
    postMarkerBounded,
    cancelOutcomesAgree,
    unjournaledEffectsBounded,
  )
where

import Control.Concurrent (threadDelay)
import Control.Monad (forM, forM_)
import Data.Aeson (Value, object, withObject, (.:), (.=))
import Data.Aeson.Types (parseMaybe)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Vector qualified as Vector
import Keiro.Codec (decodeRecorded)
import Keiro.Workflow (WorkflowId (..), WorkflowJournalEvent (..), WorkflowName (..), workflowJournalCodec, workflowStreamName)
import Keiro.Workflow.Instance (WorkflowInstanceRow (..), WorkflowStatus (..), lookupInstance, upsertInstanceTx)
import Kenshou.Check.Fact (Fact (..), FactKind (..))
import Kenshou.Check.Ledger (sealLedger)
import Kenshou.Check.Ledger.Read (discoverLedgers, foldFacts)
import Kenshou.Check.Process (awaitReady, readChildMessages, roleProcess, sendCommand, spawn, stopGracefully, withSupervisor)
import Kenshou.Check.Scenario (CheckEnv (..), withCheck)
import Kenshou.Core.Context (RunContext (..), SummarySection (..), putSummary, requirePostgres)
import Kenshou.Core.Dimension
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Env.Postgres (PostgresEnv (..))
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Knob (Allowed (..), KnobSpec (..), KnobType (..), KnobValue (..), knobInt)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Role (ControlMessage (..), WorkerMessage (..))
import Kenshou.Core.Scenario (Placement (..), Scenario (..), ScenarioReport, Tier (..))
import Kenshou.Suite.Keiro.Workflow.Definitions (DefinitionParams (..), defaultDefinitionParams, expectedLinearSteps, flakyName, linearName)
import Kenshou.Suite.Keiro.Workflow.Fixture (durableKirokuStore, withDurableStore)
import Kenshou.Suite.Keiro.Workflow.Knobs (workflowKnobName, workflowKnobs)
import Kenshou.Suite.Keiro.Workflow.Oracle (recordWorkflowExampleCells)
import Kiroku.Store (defaultConnectionSettings, readStreamForward, runStoreIO, runTransaction)
import Kiroku.Store.Types (StreamVersion (..))

scenarios :: [Scenario]
scenarios = [terminalMarkerFirstWriterWins]

raceKnobs :: [KnobSpec]
raceKnobs =
  [ integer "workflow.race.complete-instances" 24 1 1000,
    integer "workflow.race.fail-instances" 8 0 1000,
    integer "workflow.race.cancel-processes" 3 2 16,
    integer "workflow.race.step-delay-ms" 20 0 1000,
    integer "workflow.race.cancel-after-ms" 400 0 60000,
    integer "workflow.race.fail-lead-ms" 100 0 60000
  ]
  where
    integer key def low high = KnobSpec (workflowKnobName key) key KnobInt (VInt def) (IntRange low high) []

terminalMarkerFirstWriterWins :: Scenario
terminalMarkerFirstWriterWins =
  Scenario
    { id = either (error . show) id (parseScenarioId "keiro/workflow/concurrency/terminal-marker-first-writer-wins"),
      revision = 1,
      summary = "Races operator cancels from several processes against completion and against failure at the attempt ceiling, then checks one lifecycle marker per instance and agreeing outcomes.",
      tier = TierStandard,
      placement = PlaceEither,
      knobs = workflowKnobs <> raceKnobs,
      dimensions =
        DimensionSupport
          { tracing = Supported (Support (TracingOff :| []) TracingOff),
            metrics = Supported (Support (MetricsOff :| []) MetricsOff),
            pgDurability = Supported (Support (PgDurable :| []) PgDurable),
            pgVersion = Supported (Support (Pg18 :| []) Pg18)
          },
      phases = zeroPhases,
      requires = noEnvironment {postgres = Just (PostgresRequirement [SchemaKiroku, SchemaKeiro] [] False)},
      knownDefect = Nothing,
      run = runRace
    }

data Marker = MarkerCompleted | MarkerCancelled | MarkerFailed
  deriving stock (Eq, Ord, Show)

-- | Exactly one canceller may record the marker, and only when the cancel
-- marker won. Every other caller must name the winner's terminal state.
cancelOutcomesAgree :: Marker -> [Text] -> Bool
cancelOutcomesAgree marker outcomes =
  case marker of
    MarkerCancelled -> recorded == 1 && all (`elem` ["recorded", "already-cancelled"]) outcomes
    MarkerCompleted -> recorded == 0 && all (== "already-completed") outcomes
    MarkerFailed -> recorded == 0 && all (== "already-failed") outcomes
  where
    recorded = length (filter (== "recorded") outcomes)

-- | After the lifecycle marker the journal may hold only the step that was
-- already executing when the marker committed: cancelWorkflow lets it finish
-- and journal, but no later boundary may start.
postMarkerBounded :: [WorkflowJournalEvent] -> Bool
postMarkerBounded events = case break (not . null . markerOf) events of
  (_, _ : after) -> case after of
    [] -> True
    [StepRecorded {}] -> True
    _ -> False
  _ -> False

-- | A cancel stops the next boundary, not the step already executing: at
-- most one step effect may lack a journal entry (ADR-27).
unjournaledEffectsBounded :: Set.Set Text -> Set.Set Text -> Bool
unjournaledEffectsBounded journaled effected = Set.size (effected `Set.difference` journaled) <= 1

runRace :: RunContext -> IO ScenarioReport
runRace context = withCheck context \check ->
  withDurableStore (defaultConnectionSettings (requirePostgres context).connectionString) \fixture -> do
    let store = durableKirokuStore fixture
        knob = fromIntegral . knobInt context.knobs . workflowKnobName
        completeIds = [WorkflowId ("race-complete-" <> Text.pack (show index)) | index <- [0 .. knob "workflow.race.complete-instances" - 1 :: Int]]
        failIds = [WorkflowId ("race-fail-" <> Text.pack (show index)) | index <- [0 .. knob "workflow.race.fail-instances" - 1 :: Int]]
        targets = [(linearName, wid) | wid <- completeIds] <> [(flakyName, wid) | wid <- failIds]
        cancellers = knob "workflow.race.cancel-processes" :: Int
        -- Each canceller walks its batch from a different offset, so every
        -- instance sees cancels from processes at different moments.
        orderFor batch index =
          let offset = (index * length batch) `div` cancellers
              rotated = drop offset batch <> take offset batch
           in if odd index then reverse rotated else rotated
        steps = expectedLinearSteps defaultDefinitionParams {steps = knob "workflow.steps"}
        terminal (name, wid) = do
          row <- runStoreIO store (lookupInstance name wid)
          pure case row of
            Right (Just current) -> current.status `elem` [WfCompleted, WfCancelled, WfFailed]
            _ -> False
        allTerminal batch = and <$> traverse terminal batch
        seed batch = forM batch \(name, WorkflowId wid) -> runStoreIO store (runTransaction (upsertInstanceTx wid (unWorkflowName name) 0 WfRunning Nothing))
        (linearTargets, flakyTargets) = splitAt (length completeIds) targets
    seededLinear <- seed linearTargets
    sealLedger check.ledger
    (seededFlaky, finished, outcomes) <- withSupervisor check \supervisor -> do
      workers <- forM [0, 1] \index -> do
        spec <- roleProcess check "keiro/workflow-resume-worker" index (object ["stepDelayMicros" .= (knob "workflow.race.step-delay-ms" * 1000 :: Int), "maxAttempts" .= (1 :: Int)])
        worker <- spawn supervisor spec
        awaitReady worker 10000
        pure worker
      let cancellersFor first batch = forM [0 .. cancellers - 1] \index -> do
            spec <- roleProcess check "keiro/workflow-driver" (first + index) (object ["op" .= ("cancel" :: Text), "targets" .= [(unWorkflowName name, unWorkflowId wid) | (name, wid) <- orderFor batch index]])
            driver <- spawn supervisor spec
            awaitReady driver 10000
            pure driver
          awaitCancellers drivers batch = waitUntil (and <$> traverse (fmap ((== length batch) . length . cancelResults) . readChildMessages) drivers) 60
      -- Phase one: cancels against completion while workers are mid-backlog.
      linearDrivers <- cancellersFor 0 linearTargets
      forM_ workers (`sendCommand` CtlStart)
      threadDelay (knob "workflow.race.cancel-after-ms" * 1000)
      forM_ linearDrivers (`sendCommand` CtlStart)
      linearDone <- waitUntil (allTerminal linearTargets) 240
      linearCancelled <- awaitCancellers linearDrivers linearTargets
      -- Phase two: a flaky instance fails on its first claim by idle workers.
      -- Seeding it about one poll before the cancels lets either writer win.
      flakyDrivers <- cancellersFor cancellers flakyTargets
      seededFlaky <- seed flakyTargets
      threadDelay (knob "workflow.race.fail-lead-ms" * 1000)
      forM_ flakyDrivers (`sendCommand` CtlStart)
      flakyDone <- waitUntil (allTerminal flakyTargets) 240
      flakyCancelled <- awaitCancellers flakyDrivers flakyTargets
      forM_ workers \worker -> stopGracefully supervisor worker 5000
      messages <- traverse readChildMessages (linearDrivers <> flakyDrivers)
      pure (seededFlaky, and [linearDone, linearCancelled, flakyDone, flakyCancelled], concatMap cancelResults messages)
    rows <- forM targets \(name, wid) -> do
      instanceRow <- runStoreIO store (lookupInstance name wid)
      journal <- runStoreIO store (readStreamForward (workflowStreamName name wid) (StreamVersion 0) (fromIntegral (length steps + 4)))
      pure ((name, wid), instanceRow, journal)
    effects <- effectKeys check
    let outcomesFor wid = [outcome | (target, outcome) <- outcomes, target == unWorkflowId wid]
        examine ((name, wid), instanceRow, journal) =
          let decoded = either (const Nothing) (either (const Nothing) Just . traverse (decodeRecorded workflowJournalCodec) . Vector.toList) journal
              markers = maybe [] (concatMap markerOf) decoded
              lastIsMarker = maybe False postMarkerBounded decoded
              journaled = Set.fromList [stepName | Just events <- [decoded], StepRecorded stepName _ _ <- events]
              effected = Set.fromList [stepName | stepName <- steps, (unWorkflowId wid <> "/0/" <> stepName) `Set.member` effects]
              status = either (const Nothing) (fmap (.status)) instanceRow
           in ( name,
                markers,
                case markers of [marker] -> status == Just (statusOf marker); _ -> False,
                case markers of [marker] -> cancelOutcomesAgree marker (outcomesFor wid) && length (outcomesFor wid) == cancellers; _ -> False,
                lastIsMarker,
                name /= linearName || unjournaledEffectsBounded journaled effected
              )
        evidence ((name, wid), instanceRow, journal) =
          object
            [ "workflow" .= unWorkflowName name,
              "workflowId" .= unWorkflowId wid,
              "status" .= either (const Nothing) (fmap (Text.pack . show . (.status))) instanceRow,
              "journal" .= case journal of
                Left err -> [Text.pack (show err)]
                Right events -> case traverse (decodeRecorded workflowJournalCodec) (Vector.toList events) of
                  Left err -> ["undecodable: " <> Text.pack (show err)]
                  Right decoded -> map renderEvent decoded,
              "cancelOutcomes" .= outcomesFor wid,
              "effectedSteps" .= [stepName | stepName <- steps, (unWorkflowId wid <> "/0/" <> stepName) `Set.member` effects]
            ]
        examined = zip rows (map examine rows)
        failing predicate = [evidence row | (row, result) <- examined, not (predicate result)]
        winners = Map.fromListWith (+) [((unWorkflowName name, Text.pack (show marker)), 1 :: Int) | (_, (name, [marker], _, _, _, _)) <- examined]
    putSummary context Measurements "terminal-marker-first-writer-wins" (object ["winners" .= [object ["workflow" .= name, "marker" .= marker, "count" .= count] | ((name, marker), count) <- Map.toList winners], "cancelResults" .= length outcomes, "inFlightStepsJournaledAfterMarker" .= length [() | (_, Right events) <- [(row, journal) | row@(_, _, journal) <- rows], Right decoded <- [traverse (decodeRecorded workflowJournalCodec) (Vector.toList events)], StepRecorded {} : _ <- [drop 1 (dropWhile (null . markerOf) decoded)]]])
    recordWorkflowExampleCells
      check
      [ ("instances-seeded", length targets, [object ["seeded" .= False] | not (all (== Right ()) (seededLinear <> seededFlaky))]),
        ("all-instances-terminal", length targets, [object ["terminal" .= False] | not finished]),
        ("one-lifecycle-marker-per-instance", length targets, failing (\(_, markers, _, _, _, _) -> length markers == 1)),
        ("status-matches-marker", length targets, failing (\(_, _, matches, _, _, _) -> matches)),
        ("cancel-outcomes-agree-with-winner", length targets, failing (\(_, _, _, agree, _, _) -> agree)),
        ("no-later-boundary-after-marker", length targets, failing (\(_, _, _, _, lastIsMarker, _) -> lastIsMarker)),
        ("at-most-one-in-flight-step-after-cancel", length targets, failing (\(_, _, _, _, _, bounded) -> bounded))
      ]

renderEvent :: WorkflowJournalEvent -> Text
renderEvent = \case
  StepRecorded stepName _ _ -> "step:" <> stepName
  WorkflowCompleted {} -> "marker:completed"
  WorkflowCancelled {} -> "marker:cancelled"
  WorkflowFailed {} -> "marker:failed"
  other -> Text.takeWhile (/= ' ') (Text.pack (show other))

markerOf :: WorkflowJournalEvent -> [Marker]
markerOf = \case
  WorkflowCompleted {} -> [MarkerCompleted]
  WorkflowCancelled {} -> [MarkerCancelled]
  WorkflowFailed {} -> [MarkerFailed]
  _ -> []

statusOf :: Marker -> WorkflowStatus
statusOf = \case
  MarkerCompleted -> WfCompleted
  MarkerCancelled -> WfCancelled
  MarkerFailed -> WfFailed

cancelResults :: [WorkerMessage] -> [(Text, Text)]
cancelResults messages = [result | WrkCustom "cancel-result" payload <- messages, Just result <- [parseResult payload]]
  where
    parseResult :: Value -> Maybe (Text, Text)
    parseResult = parseMaybe (withObject "cancel result" \value -> (,) <$> value .: "workflowId" <*> value .: "outcome")

effectKeys :: CheckEnv -> IO (Set.Set Text)
effectKeys check = do
  ledgers <- discoverLedgers check.ledgerDirectory
  foldFacts ledgers Set.empty \keys fact -> pure if fact.kind == Effect then Set.insert fact.key keys else keys

-- | Poll every 250 ms; @seconds@ bounds the total wait.
waitUntil :: IO Bool -> Int -> IO Bool
waitUntil predicate seconds = go (seconds * 4)
  where
    go 0 = predicate
    go remaining = do
      done <- predicate
      if done then pure True else threadDelay 250000 >> go (remaining - 1)
