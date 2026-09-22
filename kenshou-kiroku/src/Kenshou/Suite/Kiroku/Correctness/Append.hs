module Kenshou.Suite.Kiroku.Correctness.Append (scenarios, recordCells) where

import Control.Monad (forM)
import Data.Aeson (object, (.=))
import Data.Int (Int64)
import Data.List (nub, sort)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (getCurrentTime)
import Data.UUID qualified as UUID
import Data.Vector qualified as Vector
import Kenshou.Check.Verdict (InvariantClass (..), RunInfo (..), Verdict (..), VerdictStatus (..), writeVerdict)
import Kenshou.Core.Context (RunContext (..), SummarySection (..), putSummary)
import Kenshou.Core.Dimension
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Knob (Allowed (..), KnobName, KnobSpec (..), KnobType (..), KnobValue (..), knobInt, mkKnobName)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Scenario
import Kenshou.Suite.Kiroku.Fixture.Store (withKirokuStore)
import Kenshou.Suite.Kiroku.Knobs (storeKnobs)
import Kiroku.Store hiding (id, withKirokuStore)
import System.FilePath ((</>))

scenarios :: [Scenario]
scenarios = [expectedVersionMatrix, idempotentEventIds, allOrderAndGaps, multiStreamAtomicity]

allOrderAndGaps :: Scenario
allOrderAndGaps =
  expectedVersionMatrix
    { id = either (error . show) id (parseScenarioId "kiroku/append/correctness/all-order-and-gaps"),
      summary = "Checks global append order, paged reads, and gaps created by hard deletes.",
      tier = TierStandard,
      knobs = storeKnobs <> [KnobSpec (knobName "workload.events") "Event count" KnobInt (VInt 5000) (IntRange 100 100000) [], KnobSpec (knobName "kiroku.append.streams") "Stream count" KnobInt (VInt 50) (IntRange 5 1000) []],
      run = runOrderAndGaps
    }

knobName :: Text -> KnobName
knobName = either (error . show) id . mkKnobName

idempotentEventIds :: Scenario
idempotentEventIds =
  expectedVersionMatrix
    { id = either (error . show) id (parseScenarioId "kiroku/append/correctness/idempotent-event-ids"),
      summary = "Checks caller event identifiers reject duplicate appends without partial commits.",
      run = runIdempotence
    }

multiStreamAtomicity :: Scenario
multiStreamAtomicity =
  expectedVersionMatrix
    { id = either (error . show) id (parseScenarioId "kiroku/append/correctness/multi-stream-atomicity"),
      summary = "Checks multi-stream append commits all operations or none.",
      run = runMultiStream
    }

expectedVersionMatrix :: Scenario
expectedVersionMatrix =
  Scenario
    { id = either (error . show) id (parseScenarioId "kiroku/append/correctness/expected-version-matrix"),
      revision = 1,
      summary = "Checks optimistic append preconditions against missing, live and soft-deleted streams.",
      tier = TierSmoke,
      placement = PlaceEither,
      knobs = storeKnobs,
      dimensions =
        DimensionSupport
          { tracing = Supported (Support (TracingOff :| []) TracingOff),
            metrics = Supported (Support (MetricsOff :| []) MetricsOff),
            pgDurability = Supported (Support (PgFsyncOff :| [PgDurable]) PgFsyncOff),
            pgVersion = Supported (Support (Pg18 :| [Pg17]) Pg18)
          },
      phases = zeroPhases,
      requires = noEnvironment {postgres = Just (PostgresRequirement [SchemaKiroku] [] False)},
      knownDefect = Nothing,
      run = runMatrix
    }

runMatrix :: RunContext -> IO ScenarioReport
runMatrix context = withKirokuStore context \store -> do
  let event = EventData Nothing (EventType "Matrix") (object ["case" .= ("expected-version" :: Text)]) Nothing Nothing Nothing
      append name expected = runStoreIO store (appendToStream (StreamName name) expected [event])
      check label predicate result = (label, predicate result)
      wrong name version = \case Left (WrongExpectedVersion actual (ExactVersion expected) (StreamVersion 0)) -> actual == StreamName name && expected == StreamVersion version; _ -> False
      success = \case Right _ -> True; _ -> False
      missing = "matrix-missing"
      live = "matrix-live"
      deleted = "matrix-deleted"
  missingExact <- append missing (ExactVersion (StreamVersion 0))
  missingAfter <- runStoreIO store (getStream (StreamName missing))
  missingExists <- append missing StreamExists
  missingAny <- append missing AnyVersion
  liveNo <- append missing NoStream
  liveWrong <- append missing (ExactVersion (StreamVersion 0))
  liveAfterWrong <- runStoreIO store (getStream (StreamName missing))
  liveExact <- append missing (ExactVersion (StreamVersion 1))
  liveExists <- append missing StreamExists
  let seven = StreamName "matrix-version-seven"
  sevenCreated <- runStoreIO store (appendToStream seven NoStream (replicate 7 event))
  sevenWrong <- append "matrix-version-seven" (ExactVersion (StreamVersion 1))
  sevenAfter <- runStoreIO store (getStream seven)
  created <- append live NoStream
  _ <- runStoreIO store (softDeleteStream (StreamName live))
  deletedBefore <- runStoreIO store (readAllForward (GlobalPosition 0) 100)
  deletedNo <- append live NoStream
  deletedAny <- append live AnyVersion
  deletedExists <- append live StreamExists
  deletedExact <- append live (ExactVersion (StreamVersion 1))
  deletedAfter <- runStoreIO store (readAllForward (GlobalPosition 0) 100)
  invalidBefore <- runStoreIO store (readAllForward (GlobalPosition 0) 100)
  empty <- runStoreIO store (appendToStream (StreamName deleted) AnyVersion [])
  reserved <- append "$all" AnyVersion
  tooLong <- append (Text.replicate 513 "a") AnyVersion
  invalidAfter <- runStoreIO store (readAllForward (GlobalPosition 0) 100)
  maxLength <- append (Text.replicate 512 "b") NoStream
  let cells =
        [ check "missing-exact-zero" (wrong missing 0) missingExact,
          check "missing-still-absent" (== Right Nothing) missingAfter,
          check "missing-stream-exists" (== Left (StreamNotFound (StreamName missing))) missingExists,
          check "missing-any-version" success missingAny,
          check "live-no-stream" (== Left (StreamAlreadyExists (StreamName missing))) liveNo,
          check "live-wrong-version" (wrong missing 0) liveWrong,
          check "live-rejection-preserves-version" (\case Right (Just info) -> info.version == StreamVersion 1; _ -> False) liveAfterWrong,
          check "live-exact-version" success liveExact,
          check "live-stream-exists" success liveExists,
          check "version-seven-created" (\case Right result -> result.streamVersion == StreamVersion 7; _ -> False) sevenCreated,
          check "version-seven-error-reports-zero" (\case Left (WrongExpectedVersion name (ExactVersion (StreamVersion 1)) (StreamVersion 0)) -> name == seven; _ -> False) sevenWrong,
          check "version-seven-rejection-preserves-version" (\case Right (Just info) -> info.version == StreamVersion 7; _ -> False) sevenAfter,
          check "created-for-delete" success created,
          check "deleted-no-stream" (== Left (StreamAlreadyExists (StreamName live))) deletedNo,
          check "deleted-any-version" (== Left (StreamNotFound (StreamName live))) deletedAny,
          check "deleted-stream-exists" (== Left (StreamNotFound (StreamName live))) deletedExists,
          check "deleted-exact-version" (wrong live 1) deletedExact,
          check "deleted-rejections-preserve-all" (\case (Right before, Right after) -> Vector.length before == Vector.length after; _ -> False) (deletedBefore, deletedAfter),
          check "empty-batch" (== Left (EmptyAppendBatch (StreamName deleted))) empty,
          check "reserved-all" (== Left (ReservedStreamName (StreamName "$all"))) reserved,
          check "overlong-name" (\case Left (StreamNameTooLong _ 513) -> True; _ -> False) tooLong,
          check "invalid-rejections-preserve-all" (\case (Right before, Right after) -> Vector.length before == Vector.length after; _ -> False) (invalidBefore, invalidAfter),
          check "max-length-name" success maxLength
        ]
  recordCells context "expected-version-matrix" [] cells

runOrderAndGaps :: RunContext -> IO ScenarioReport
runOrderAndGaps context = withKirokuStore context \store -> do
  let eventCount = fromIntegral (knobInt context.knobs (knobName "workload.events")) :: Int
      streamCount = fromIntegral (knobInt context.knobs (knobName "kiroku.append.streams")) :: Int
      streamName :: Int -> StreamName
      streamName i = StreamName ("order-" <> Text.pack (show i))
      event = EventData Nothing (EventType "Ordered") (object []) Nothing Nothing Nothing
      populate remaining step versions results
        | remaining == 0 = pure (versions, reverse results)
        | otherwise = do
            let i = step `mod` streamCount
                count = min remaining (1 + step `mod` 20)
                current = Map.findWithDefault 0 i versions
                expected = if current == 0 then NoStream else ExactVersion (StreamVersion (fromIntegral current))
            appended <- runStoreIO store (appendToStream (streamName i) expected (replicate count event))
            case appended of
              Left err -> fail ("order workload append failed: " <> show err)
              Right result -> populate (remaining - count) (step + 1) (Map.insert i (current + count) versions) ((i, current + count, result) : results)
  (versions, results) <- populate eventCount 0 Map.empty []
  before <- readAllPaged store True
  beforeBackward <- readAllPaged store False
  headBefore <- runStoreIO store visibleGlobalHeadPosition
  let streamIds = Map.fromList [(i, result.streamId) | (i, _, result) <- results]
      deletedIds = [streamIds Map.! i | i <- [0 .. 4]]
      deletedPositions = sort [positionValue row.globalPosition | row <- before, row.originalStreamId `elem` deletedIds]
      expectedAfter = filter (\row -> row.originalStreamId `notElem` deletedIds) before
      maxPosition = maximum (0 : fmap (positionValue . (.globalPosition)) before)
      beforeGaps = missingPositions maxPosition before
  streamAudits <- forM (Map.toList versions) \(i, version) -> do
    value <- runStoreIO store (readStreamForward (streamName i) (StreamVersion 0) (fromIntegral eventCount))
    pure $ case value of
      Right rows -> fmap (.streamVersion) (Vector.toList rows) == fmap (StreamVersion . fromIntegral) [1 .. version]
      Left _ -> False
  deletionResults <- forM [0 .. 4] \i -> runStoreIO store (hardDeleteStream (streamName i))
  after <- readAllPaged store True
  afterBackward <- readAllPaged store False
  headAfter <- runStoreIO store visibleGlobalHeadPosition
  let positions = fmap (.globalPosition) before
      appendPositions = [result.globalPosition | (_, _, result) <- results]
      afterGaps = missingPositions maxPosition after
      cells =
        [ ("append-result-versions", and [result.streamVersion == StreamVersion (fromIntegral expectedVersion) | (_, expectedVersion, result) <- results]),
          ("append-results-strict-order", appendPositions == sort (nub appendPositions)),
          ("global-forward-complete", length before == eventCount),
          ("global-forward-strict-order", positions == sort (nub positions)),
          ("global-backward-reverse", reverse beforeBackward == before),
          ("per-stream-versions", and streamAudits),
          ("hard-deletes-succeed", all (\case Right (Just _) -> True; _ -> False) deletionResults),
          ("hard-delete-removes-only-target-events", fmap (.eventId) after == fmap (.eventId) expectedAfter),
          ("post-delete-forward-strict-order", fmap (.globalPosition) after == sort (nub (fmap (.globalPosition) after))),
          ("post-delete-backward-reverse", reverse afterBackward == after),
          ("visible-head-before", headBefore == Right (GlobalPosition maxPosition)),
          ("visible-head-after", case headAfter of Right value -> value <= GlobalPosition maxPosition; _ -> False),
          ("before-gapless", null beforeGaps),
          ("after-gaps-match-deletes", afterGaps == deletedPositions)
        ]
  putSummary context Verdicts "gap-report" (object ["beforeMissingPositions" .= beforeGaps, "afterMissingPositions" .= afterGaps, "deletedPositions" .= deletedPositions])
  recordCells context "all-order-and-gaps" ["before-gapless", "after-gaps-match-deletes"] cells

readAllPaged :: KirokuStore -> Bool -> IO [RecordedEvent]
readAllPaged store forward = go (GlobalPosition 0) []
  where
    go cursor chunks = do
      result <- runStoreIO store (if forward then readAllForward cursor 256 else readAllBackward cursor 256)
      case result of
        Left err -> fail ("global read failed: " <> show err)
        Right page
          | Vector.null page -> pure (concat (reverse chunks))
          | otherwise -> go ((Vector.last page).globalPosition) (Vector.toList page : chunks)

positionValue :: GlobalPosition -> Int64
positionValue (GlobalPosition value) = value

missingPositions :: Int64 -> [RecordedEvent] -> [Int64]
missingPositions frontier rows =
  [value | value <- [1 .. frontier], value `Set.notMember` present]
  where
    present = Set.fromList (fmap (positionValue . (.globalPosition)) rows)

runIdempotence :: RunContext -> IO ScenarioReport
runIdempotence context = withKirokuStore context \store -> do
  let eventId1 = EventId (uuid "0199a000-0000-7000-8000-000000000001")
      eventId2 = EventId (uuid "0199a000-0000-7000-8000-000000000002")
      eventId3 = EventId (uuid "0199a000-0000-7000-8000-000000000003")
      event eid = EventData (Just eid) (EventType "Idempotent") (object []) Nothing Nothing Nothing
      original = StreamName "idempotent-original"
      other = StreamName "idempotent-other"
      append name expected events = runStoreIO store (appendToStream name expected events)
      collision = \case Left (DuplicateEvent _) -> True; _ -> False
  initial <- append original NoStream [event eventId1, event eventId2]
  before <- runStoreIO store (readAllForward (GlobalPosition 0) 100)
  retry <- append original AnyVersion [event eventId1, event eventId2]
  crossStream <- append other NoStream [event eventId1]
  larger <- append other AnyVersion [event eventId3, event eventId2]
  after <- runStoreIO store (readAllForward (GlobalPosition 0) 100)
  originalInfo <- runStoreIO store (getStream original)
  otherInfo <- runStoreIO store (getStream other)
  putSummary context Verdicts "idempotent-errors" (object ["retry" .= show retry, "crossStream" .= show crossStream, "largerBatch" .= show larger])
  let cells =
        [ ("first-batch-committed", case initial of Right result -> result.streamVersion == StreamVersion 2; _ -> False),
          ("same-stream-retry-rejected", collision retry),
          ("cross-stream-duplicate-rejected", collision crossStream),
          ("larger-batch-atomic", collision larger),
          ("all-position-unchanged", case (before, after) of (Right a, Right b) -> Vector.length a == 2 && Vector.length b == 2; _ -> False),
          ("original-version-unchanged", case originalInfo of Right (Just info) -> info.version == StreamVersion 2; _ -> False),
          ("other-stream-not-created", otherInfo == Right Nothing)
        ]
  recordCells context "idempotent-event-ids" ["all-position-unchanged"] cells

runMultiStream :: RunContext -> IO ScenarioReport
runMultiStream context = withKirokuStore context \store -> do
  let a = StreamName "multi-atomic-a"
      b = StreamName "multi-atomic-b"
      c = StreamName "multi-atomic-c"
      event = EventData Nothing (EventType "Atomic") (object []) Nothing Nothing Nothing
      one name expectation = (name, expectation, [event])
      append ops = runStoreIO store (appendMultiStream ops)
  empty <- append []
  initial <- append [one a NoStream, one b NoStream]
  before <- runStoreIO store (readAllForward (GlobalPosition 0) 100)
  rejected <- append [one a (ExactVersion (StreamVersion 1)), one b (ExactVersion (StreamVersion 0)), one c NoStream]
  after <- runStoreIO store (readAllForward (GlobalPosition 0) 100)
  cInfo <- runStoreIO store (getStream c)
  aInfo <- runStoreIO store (getStream a)
  bInfo <- runStoreIO store (getStream b)
  reserved <- append [one c NoStream, one (StreamName "$all") AnyVersion]
  perStreamEmpty <- append [(c, NoStream, [])]
  let cells =
        [ ("empty-call-is-empty", empty == Right []),
          ("success-results-input-order", case initial of Right [first, second] -> first.streamVersion == StreamVersion 1 && second.streamVersion == StreamVersion 1 && first.globalPosition < second.globalPosition; _ -> False),
          ("conflict-rejects-whole-call", case rejected of Left (WrongExpectedVersion name _ _) -> name == b; _ -> False),
          ("no-new-stream-after-conflict", cInfo == Right Nothing),
          ("old-stream-versions-unchanged", case (aInfo, bInfo) of (Right (Just ai), Right (Just bi)) -> ai.version == StreamVersion 1 && bi.version == StreamVersion 1; _ -> False),
          ("global-log-unchanged", case (before, after) of (Right prior, Right final) -> Vector.length prior == 2 && Vector.length final == 2; _ -> False),
          ("reserved-name-rejects-whole-call", case reserved of Left (ReservedStreamName _) -> True; _ -> False),
          ("empty-per-stream-batch-rejected", perStreamEmpty == Left (EmptyAppendBatch c))
        ]
  recordCells context "multi-stream-atomicity" [] cells

uuid :: String -> UUID.UUID
uuid value = maybe (error "invalid fixture UUID") id (UUID.fromString value)

recordCells :: RunContext -> Text -> [Text] -> [(Text, Bool)] -> IO ScenarioReport
recordCells context name implementationLabels cells = do
  checkedAt <- getCurrentTime
  mapM_ (writeCell checkedAt) cells
  let labels = [label | (label, False) <- cells, label `notElem` implementationLabels]
      implementationFindings = [label | (label, False) <- cells, label `elem` implementationLabels]
  putSummary context Verdicts name (object ["cells" .= length cells, "failures" .= labels, "implementationFindings" .= implementationFindings])
  pure $ if null labels then passed else failedWith labels (name <> " contract check failed")
  where
    writeCell checkedAt (label, held) = do
      let verdict =
            Verdict
              { checker = name <> "-" <> label,
                invariant = label,
                cls = if label `elem` implementationLabels then Implementation else Contract,
                status = if held then Held else Violated,
                reason = Nothing,
                summary = if held then "Expected result observed" else "Expected result did not match",
                counts = Map.singleton "cells" 1,
                parameters = object [],
                counterExamples = [],
                counterExamplesTruncated = False,
                inputs = [],
                replay = Nothing,
                checkedAt = checkedAt,
                durationMillis = 0
              }
      _ <- writeVerdict (context.outDir </> "verdicts") (RunInfo context.runId context.scenario) verdict
      pure ()
