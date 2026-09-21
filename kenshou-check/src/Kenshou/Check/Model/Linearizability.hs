module Kenshou.Check.Model.Linearizability
  ( Completion (..),
    Operation (..),
    SeqModel (..),
    LinConfig (..),
    LinResult (..),
    RegisterOp (..),
    RegisterResult (..),
    LogOp (..),
    LogResult (..),
    defaultLinConfig,
    checkLinearizable,
    registerModel,
    appendLogModel,
    linearizability,
  )
where

import Data.Aeson (object, (.=))
import Data.Int (Int64)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Kenshou.Check.Fact (Fact)
import Kenshou.Check.Invariant
import Kenshou.Check.Ledger.Sort (SortOrder (ByKeyWall))
import Kenshou.Check.Verdict

data Completion output = Returned output | Failed | Indeterminate
  deriving stock (Eq, Ord, Show)

data Operation input output = Operation
  { process :: !Text,
    key :: !Text,
    input :: !input,
    invoked :: !Int64,
    completed :: !(Maybe Int64),
    completion :: !(Completion output)
  }
  deriving stock (Eq, Ord, Show)

data SeqModel state input output = SeqModel
  { initial :: !state,
    apply :: state -> input -> (output, state),
    agrees :: output -> output -> Bool
  }

newtype LinConfig = LinConfig {maxSteps :: Int}
  deriving stock (Eq, Ord, Show)

data LinResult = Linearizable | NotLinearizable [Text] | Undecided
  deriving stock (Eq, Show)

data RegisterOp = ReadRegister | WriteRegister Int64 | CompareAndSet (Maybe Int64) Int64
  deriving stock (Eq, Ord, Show)

data RegisterResult = ReadValue (Maybe Int64) | Written | Compared Bool
  deriving stock (Eq, Ord, Show)

data LogOp = Append Text | ReadLog
  deriving stock (Eq, Ord, Show)

data LogResult = Appended Int | LogContents [Text]
  deriving stock (Eq, Ord, Show)

defaultLinConfig :: LinConfig
defaultLinConfig = LinConfig 5000000

checkLinearizable :: (Ord state) => LinConfig -> SeqModel state input output -> [Operation input output] -> LinResult
checkLinearizable config model operations =
  case search 0 Set.empty model.initial indexed of
    SearchYes -> Linearizable
    SearchBudget -> Undecided
    SearchNo -> NotLinearizable ["No legal sequential history agrees with the completed operations."]
  where
    indexed = [(index, operation) | (index, operation) <- zip [0 :: Int ..] operations, isPending operation]
    isPending operation = case operation.completion of Failed -> False; _ -> True

    search steps visited state pending
      | steps >= config.maxSteps = SearchBudget
      | null pending = SearchYes
      | Set.member (Set.fromList (fmap fst pending), state) visited = SearchNo
      | otherwise =
          let visited' = Set.insert (Set.fromList (fmap fst pending), state) visited
              choices = filter (eligible . snd) pending
              outcomes = concatMap (advance (steps + 1) visited' state pending) choices
           in combine outcomes
      where
        eligible candidate = all (not . happensBefore candidate . snd) pending

    happensBefore candidate other = case other.completed of
      Just ended -> ended < candidate.invoked
      Nothing -> False

    advance steps visited state pending selected@(index, operation) =
      let remaining = filter ((/= index) . fst) pending
          (expected, nextState) = model.apply state operation.input
          applied = search steps visited nextState remaining
       in case operation.completion of
            Returned actual | model.agrees expected actual -> [applied]
            Returned _ -> []
            Failed -> [search steps visited state remaining]
            Indeterminate -> [search steps visited state remaining, applied]

    combine outcomes
      | SearchYes `elem` outcomes = SearchYes
      | SearchBudget `elem` outcomes = SearchBudget
      | otherwise = SearchNo

registerModel :: SeqModel (Maybe Int64) RegisterOp RegisterResult
registerModel = SeqModel Nothing applyRegister (==)
  where
    applyRegister state ReadRegister = (ReadValue state, state)
    applyRegister _ (WriteRegister value) = (Written, Just value)
    applyRegister state (CompareAndSet expected replacement)
      | state == expected = (Compared True, Just replacement)
      | otherwise = (Compared False, state)

appendLogModel :: SeqModel [Text] LogOp LogResult
appendLogModel = SeqModel [] applyLog (==)
  where
    applyLog state (Append value) = (Appended (length state), state <> [value])
    applyLog state ReadLog = (LogContents state, state)

linearizability :: (Ord state) => Text -> InvariantClass -> SeqModel state input output -> (Fact -> Maybe (Operation input output)) -> Checker
linearizability checkerName cls model decode =
  Checker checkerName "linearizability" cls ByKeyWall (maybe False (const True) . decode) False (CheckFold [] step finish)
  where
    step operations fact = maybe operations (: operations) (decode fact)
    finish reversed =
      let operations = reverse reversed
          byKey = Map.elems (Map.fromListWith (<>) [(operation.key, [operation]) | operation <- operations])
          results = fmap (checkLinearizable defaultLinConfig model) byKey
          violations = length [() | NotLinearizable _ <- results]
          undecided = any (== Undecided) results
          status | undecided = NotEvaluated | violations > 0 = Violated | otherwise = Held
          reason = if undecided then Just "search-budget-exhausted" else Nothing
       in CheckResult
            status
            reason
            "Completed operations admit a legal sequential history per key."
            (Map.fromList [("examined", fromIntegral (length operations)), ("violations", fromIntegral violations)])
            (object ["maxSteps" .= defaultLinConfig.maxSteps])
            [object ["reason" .= reasons] | NotLinearizable reasons <- results]

data SearchResult = SearchYes | SearchNo | SearchBudget
  deriving stock (Eq, Show)
