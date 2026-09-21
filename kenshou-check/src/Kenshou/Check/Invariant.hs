{-# LANGUAGE ExistentialQuantification #-}

module Kenshou.Check.Invariant
  ( CheckResult (..),
    CheckFold (..),
    Checker (..),
    DuplicateBudget (..),
    Deadline (..),
    runCheckers,
    evaluateChecker,
    noLoss,
    duplicatesWithin,
    perKeyOrder,
    globalOrder,
    gaplessPositions,
    exactlyNEffects,
    eventualQuiescence,
    monotonicCheckpoints,
    disjointOwnership,
  )
where

import Data.Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Foldable (foldl')
import Data.Int (Int64)
import Data.List (groupBy, sort, sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (mapMaybe)
import Data.Scientific (toBoundedInteger)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Time (getCurrentTime)
import Kenshou.Check.Fact
import Kenshou.Check.Ledger.Read
import Kenshou.Check.Ledger.Sort
import Kenshou.Check.Scenario
import Kenshou.Check.Verdict
import Kenshou.Check.Window
import System.FilePath ((</>))

data CheckResult = CheckResult
  { status :: !VerdictStatus,
    reason :: !(Maybe Text),
    summary :: !Text,
    counts :: !(Map Text Int64),
    parameters :: !Value,
    counterExamples :: ![Value]
  }
  deriving stock (Eq, Show)

data CheckFold = forall state. CheckFold
  { initial :: state,
    step :: state -> Fact -> state,
    finish :: state -> CheckResult
  }

data Checker = Checker
  { name :: !Text,
    invariant :: !Text,
    cls :: !InvariantClass,
    order :: !SortOrder,
    select :: Fact -> Bool,
    allowEmpty :: !Bool,
    fold :: !CheckFold
  }

data DuplicateBudget = DuplicateBudget
  { maxPerWindow :: !(Maybe Int),
    maxRedeliveryDelayMicros :: !(Maybe Int64)
  }
  deriving stock (Eq, Show)

newtype Deadline = Deadline {micros :: Int64}
  deriving stock (Eq, Ord, Show)

data Running = forall state. Running Checker state Int (state -> Fact -> state) (state -> CheckResult)

runCheckers :: CheckEnv -> LedgerSet -> [Checker] -> IO [Verdict]
runCheckers environment ledger checkers = concat <$> traverse runGroup grouped
  where
    grouped = groupBy (\left right -> left.order == right.order) (sortOn (.order) checkers)
    inputs = [InputRef segment.relativePath segment.sha256 | segment <- ledger.segments]
    runGroup [] = pure []
    runGroup group@(first : _) = do
      let running = fmap startChecker group
          config = defaultSortConfig (environment.ledgerDirectory </> ".sort")
      completed <- sortedFacts config first.order (const True) ledger (drain running)
      now <- getCurrentTime
      pure [toVerdict now inputs checker selected result | (checker, selected, result) <- fmap finishRunning completed]

evaluateChecker :: Checker -> [Fact] -> CheckResult
evaluateChecker checker facts =
  let (_, selected, result) = finishRunning (foldl' feed (startChecker checker) facts)
   in if selected == 0 && not checker.allowEmpty then vacuous else result

startChecker :: Checker -> Running
startChecker checker = case checker.fold of CheckFold initial step finish -> Running checker initial 0 step finish

feed :: Running -> Fact -> Running
feed (Running checker state selected step finish) fact
  | checker.select fact = Running checker (step state fact) (selected + 1) step finish
  | otherwise = Running checker state selected step finish

finishRunning :: Running -> (Checker, Int, CheckResult)
finishRunning (Running checker state selected _ finish) = (checker, selected, if selected == 0 && not checker.allowEmpty then vacuous else finish state)

drain :: [Running] -> FactSource -> IO [Running]
drain running source = source.next >>= \case Nothing -> pure running; Just fact -> drain (fmap (`feed` fact) running) source

toVerdict now inputs checker _selected result =
  Verdict checker.name checker.invariant checker.cls result.status result.reason result.summary result.counts result.parameters (take 20 result.counterExamples) (length result.counterExamples > 20) inputs Nothing now 0

vacuous :: CheckResult
vacuous = CheckResult NotEvaluated (Just "vacuous") "No relevant facts were observed." (Map.fromList [("examined", 0), ("violations", 0)]) Null []

result :: Text -> Int -> Int -> [Value] -> CheckResult
result summary examined violations examples =
  CheckResult
    (if violations == 0 then Held else Violated)
    Nothing
    summary
    (Map.fromList [("examined", fromIntegral examined), ("violations", fromIntegral violations)])
    (object [])
    examples

noLoss :: Text -> InvariantClass -> Text -> Checker
noLoss checkerName cls consumerScope =
  Checker checkerName "no-loss" cls ByKeySeq relevant False (CheckFold (Set.empty, Set.empty, Set.empty) step finish)
  where
    relevant fact = fact.kind `elem` [Intent, Produced, Observed]
    identity :: Fact -> (Text, Int64, Text)
    identity fact = (fact.key, fact.seq, fact.id)
    step (intents, produced, observed) fact = case fact.kind of
      Intent -> (Set.insert (identity fact) intents, produced, observed)
      Produced -> (intents, Set.insert (identity fact) produced, observed)
      Observed | fact.scope == consumerScope -> (intents, produced, Set.insert (identity fact) observed)
      _ -> (intents, produced, observed)
    finish :: (Set (Text, Int64, Text), Set (Text, Int64, Text), Set (Text, Int64, Text)) -> CheckResult
    finish (intents, produced, observed) =
      let missing = Set.toList (produced `Set.difference` observed)
          phantom = Set.toList (observed `Set.difference` intents)
          violations = length missing + length phantom
          examples = fmap (example "missing") missing <> fmap (example "phantom") phantom
       in result "Acknowledged items are observed and observations have intents." (Set.size produced + Set.size observed) violations examples

duplicatesWithin :: Text -> InvariantClass -> Text -> DuplicateBudget -> [DisturbanceWindow] -> Checker
duplicatesWithin checkerName cls consumerScope budget windows =
  Checker checkerName "duplicates-within-windows" cls ByKeySeq relevant False (CheckFold Map.empty step finish)
  where
    relevant fact = fact.kind == Observed && fact.scope == consumerScope
    identity fact = (fact.key, fact.seq, fact.id)
    step observations fact = Map.insertWith (<>) (identity fact) [fact] observations
    finish observations =
      let duplicates = [(key, sortOn (.wall) facts) | (key, facts) <- Map.toList observations, length facts > 1]
          classify (key, first : rest) =
            let extra = length rest
                windowed = any (\window -> first.wall <= maybe maxBound id window.end && any (\fact -> fact.wall >= window.start) rest) windows
                overBudget = maybe False (extra >) budget.maxPerWindow
             in (if windowed && not overBudget then 0 else extra, object ["item" .= showIdentity key, "duplicates" .= extra, "windowed" .= windowed])
          classify _ = (0, Null)
          classified = fmap classify duplicates
          violations = sum (fmap fst classified)
          base = result "Duplicates occur only inside declared disturbance budgets." (sum (fmap (length . snd) duplicates)) violations (fmap snd (filter ((> 0) . fst) classified))
          parameters = object ["maxPerWindow" .= budget.maxPerWindow, "maxRedeliveryDelayMicros" .= budget.maxRedeliveryDelayMicros]
          counts = Map.fromList [("examined", fromIntegral (sum (fmap (length . snd) duplicates))), ("violations", fromIntegral violations), ("duplicates", fromIntegral (sum [length facts - 1 | (_, facts) <- duplicates]))]
       in setCounts counts (setParameters parameters base)

perKeyOrder :: Text -> InvariantClass -> Text -> Checker
perKeyOrder checkerName cls consumerScope = orderChecker checkerName "per-key-order" cls ByScopeKeyArrival (\fact -> fact.scope == consumerScope) (\fact -> (fact.scope, fact.key)) (.seq)

globalOrder :: Text -> InvariantClass -> Text -> Text -> Checker
globalOrder checkerName cls consumerScope attribute = orderCheckerMaybe checkerName "global-order" cls ByScopeArrival (\fact -> fact.scope == consumerScope && fact.kind == Observed) (.scope) (attrInt attribute)

gaplessPositions :: Text -> InvariantClass -> Checker
gaplessPositions checkerName cls =
  Checker checkerName "gapless-positions" cls ByKeySeq (\fact -> fact.kind == Produced) False (CheckFold Set.empty (\seen fact -> Set.insert fact.seq seen) finish)
  where
    finish seen = case (Set.lookupMin seen, Set.lookupMax seen) of
      (Just low, Just high) ->
        let missing = [value | value <- [low .. high], Set.notMember value seen]
         in result "Acknowledged positions form a contiguous range." (Set.size seen) (length missing) (fmap (object . pure . ("missing" .=)) (take 20 missing))
      _ -> vacuous

exactlyNEffects :: Text -> InvariantClass -> Int -> Checker
exactlyNEffects checkerName cls expected =
  Checker checkerName "exactly-n-effects" cls ByKeySeq (\fact -> fact.kind == Effect) False (CheckFold Map.empty (\counts fact -> Map.insertWith (+) fact.id 1 counts) finish)
  where
    finish counts =
      let wrong = [(item, count) | (item, count) <- Map.toList counts, count /= expected]
       in setParameters (object ["expected" .= expected]) (result "Each idempotency key has exactly the expected number of effects." (sum (Map.elems counts)) (length wrong) [object ["id" .= item, "actual" .= count, "expected" .= expected] | (item, count) <- wrong])

eventualQuiescence :: Text -> InvariantClass -> Deadline -> Checker
eventualQuiescence checkerName cls deadline =
  Checker checkerName "eventual-quiescence" cls ByKeySeq (\fact -> fact.kind `elem` [Produced, Terminal]) False (CheckFold (Map.empty, Map.empty) step finish)
  where
    step (produced, terminal) fact = case fact.kind of
      Produced -> (Map.insert fact.id fact.wall produced, terminal)
      Terminal -> (produced, Map.insert fact.id fact.wall terminal)
      _ -> (produced, terminal)
    finish (produced, terminal) =
      let violations = [(item, started, Map.lookup item terminal) | (item, started) <- Map.toList produced, maybe True (> started + deadline.micros) (Map.lookup item terminal)]
       in setParameters (object ["deadlineMicros" .= deadline.micros]) (result "Every acknowledged item reaches a terminal state before its deadline." (Map.size produced) (length violations) [object ["id" .= item, "producedAt" .= started, "terminalAt" .= ended] | (item, started, ended) <- violations])

monotonicCheckpoints :: Text -> InvariantClass -> Checker
monotonicCheckpoints checkerName cls = orderChecker checkerName "monotonic-checkpoints" cls ByScopeArrival (\fact -> fact.kind == Checkpoint) (.key) (.seq)

disjointOwnership :: Text -> InvariantClass -> Checker
disjointOwnership checkerName cls =
  Checker checkerName "disjoint-ownership" cls ByKeyWall relevant False (CheckFold (Map.empty, []) step finish)
  where
    relevant fact = fact.kind `elem` [Acquired, Acted, Released]
    step (owners, violations) fact = case fact.kind of
      Acquired -> (Map.insertWith Set.union fact.key (Set.singleton fact.scope) owners, violations)
      Released -> (Map.adjust (Set.delete fact.scope) fact.key owners, violations)
      Acted ->
        let active = Map.findWithDefault Set.empty fact.key owners
         in if Set.null active || active == Set.singleton fact.scope then (owners, violations) else (owners, fact : violations)
      _ -> (owners, violations)
    finish (_, violations) = result "No owner acts while another owner holds the same lease." (length violations + 1) (length violations) (fmap factExample violations)

orderChecker :: (Ord group) => Text -> Text -> InvariantClass -> SortOrder -> (Fact -> Bool) -> (Fact -> group) -> (Fact -> Int64) -> Checker
orderChecker checkerName invariantName cls order select group value =
  Checker checkerName invariantName cls order select False (CheckFold Map.empty (\groups fact -> Map.insertWith (<>) (group fact) [value fact] groups) finish)
  where
    finish groups =
      let sequences = fmap reverse (Map.elems groups)
          violations = sum (fmap inversions sequences)
       in result ("Observed values are monotonic for " <> invariantName <> ".") (sum (fmap length sequences)) violations []

orderCheckerMaybe :: (Ord group) => Text -> Text -> InvariantClass -> SortOrder -> (Fact -> Bool) -> (Fact -> group) -> (Fact -> Maybe Int64) -> Checker
orderCheckerMaybe checkerName invariantName cls order select group value =
  Checker checkerName invariantName cls order select False (CheckFold Map.empty step finish)
  where
    step groups fact = maybe groups (\item -> Map.insertWith (<>) (group fact) [item] groups) (value fact)
    finish groups =
      let sequences = fmap reverse (Map.elems groups)
          violations = sum (fmap inversions sequences)
       in result ("Observed values are monotonic for " <> invariantName <> ".") (sum (fmap length sequences)) violations []

inversions :: [Int64] -> Int
inversions values = length [() | (left, right) <- zip values (drop 1 values), right < left]

attrInt :: Text -> Fact -> Maybe Int64
attrInt attribute fact = case KeyMap.lookup (Key.fromText attribute) fact.attrs of Just (Number value) -> toBoundedInteger value; _ -> Nothing

factExample :: Fact -> Value
factExample fact = object ["kind" .= fact.kind, "key" .= fact.key, "seq" .= fact.seq, "id" .= fact.id, "scope" .= fact.scope]

example :: Text -> (Text, Int64, Text) -> Value
example label (key, sequenceNumber, item) = object ["type" .= label, "key" .= key, "seq" .= sequenceNumber, "id" .= item]

showIdentity (key, sequenceNumber, item) = object ["key" .= key, "seq" .= sequenceNumber, "id" .= item]

setParameters :: Value -> CheckResult -> CheckResult
setParameters parameters (CheckResult status reason summary counts _ counterExamples) = CheckResult status reason summary counts parameters counterExamples

setCounts :: Map Text Int64 -> CheckResult -> CheckResult
setCounts counts (CheckResult status reason summary _ parameters counterExamples) = CheckResult status reason summary counts parameters counterExamples
