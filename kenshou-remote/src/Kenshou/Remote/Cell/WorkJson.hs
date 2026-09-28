module Kenshou.Remote.Cell.WorkJson (decodeWorkPlan, renderPreparedWork) where

import Data.Aeson (FromJSON, Value (..))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Foldable (toList)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import Kenshou.Core.Id (RunId, mkSeed)
import Kenshou.Core.RunSpec (RunSpec (..))
import Kenshou.Plan.Change (Change (..), ChangeSource (..), Reason (..))
import Kenshou.Plan.Components (ComponentId (..), ComponentRef (..))
import Kenshou.Plan.Policy (defaultPlanPolicy)
import Kenshou.Plan.RunPlan (PlanContext (..), PlanInputs (..), PlannedRun (..), RunPlan (..), TrialInfo (..))
import Kenshou.Plan.Selector (parseSelector)
import Kenshou.Remote.Cell.Prepare (PreparedRun (..))

data SourceRun = SourceRun
  { ordinal :: !Int,
    runId :: !RunId,
    estimateMinutes :: !Int,
    trial :: !(Maybe TrialInfo),
    spec :: !RunSpec,
    json :: !Value
  }

-- The public plan format is write-only for its provenance members. The typed
-- projection carries only fields used by cell preparation; work rendering
-- copies the original document and replaces selected specs.
decodeWorkPlan :: Value -> Either Text RunPlan
decodeWorkPlan work = do
  (_, entries, planId) <- parseWork work
  selector <- parseSelector "**"
  seed <- mkSeed 1
  let placeholder = Reason (Change (ComponentRef (ComponentId "cell-work") Nothing) Named "internal preparation placeholder") [] selector 0
      planned = [PlannedRun entry.ordinal entry.runId entry.estimateMinutes (placeholder :| []) entry.trial entry.spec | entry <- entries]
      context = PlanContext Nothing "" "" "" (PlanInputs Null) [] []
  pure (RunPlan planId (posixSecondsToUTCTime 0) context (defaultPlanPolicy seed) planned [] (sum (fmap (.estimateMinutes) planned)))

renderPreparedWork :: Value -> [PreparedRun] -> Either Text Value
renderPreparedWork work selected = do
  (fields, entries, _) <- parseWork work
  if unique (fmap (.runId) selected) && unique (fmap (.ordinal) selected)
    then pure ()
    else Left "prepared work contains duplicate run IDs or ordinals"
  let originals = Map.fromList [(entry.runId, entry) | entry <- entries]
  rendered <- traverse (renderEntry originals) selected
  let rows = fmap fst rendered
      minutes = sum (fmap snd rendered)
  pure (Object (KeyMap.insert "runs" (Aeson.toJSON rows) (KeyMap.insert "estimateMinutes" (Aeson.toJSON minutes) fields)))

parseWork :: Value -> Either Text (Aeson.Object, [SourceRun], RunId)
parseWork work = do
  fields <- case work of Object members -> Right members; _ -> Left "run plan is not a JSON object"
  case KeyMap.lookup "schema" fields of
    Just (String "kenshou.run-plan/v1") -> pure ()
    _ -> Left "run plan has an unsupported schema"
  planId <- required "planId" fields
  raw <- case KeyMap.lookup "runs" fields of
    Just (Array rows) -> Right (toList rows)
    _ -> Left "run plan has no runs array"
  entries <- traverse parseEntry raw
  if unique (fmap (.runId) entries) && unique (fmap (.ordinal) entries)
    then Right (fields, entries, planId)
    else Left "run plan contains duplicate run IDs or ordinals"

parseEntry :: Value -> Either Text SourceRun
parseEntry value = case value of
  Object fields -> do
    ordinal <- required "ordinal" fields
    runId <- required "runId" fields
    estimate <- required "estimateMinutes" fields
    spec <- required "spec" fields
    trial <- case KeyMap.lookup "trial" fields of
      Nothing -> Right Nothing
      Just Null -> Right Nothing
      Just (Object members) -> Just <$> (TrialInfo <$> required "group" members <*> required "arm" members <*> required "index" members <*> required "of" members)
      _ -> Left "planned run trial is not an object"
    if ordinal < 0 || estimate <= 0 || maybe False (/= runId) spec.runId
      then Left "planned run has an invalid ordinal, estimate or spec run ID"
      else Right (SourceRun ordinal runId estimate trial spec value)
  _ -> Left "planned run is not an object"

renderEntry :: Map.Map RunId SourceRun -> PreparedRun -> Either Text (Value, Int)
renderEntry originals prepared = case Map.lookup prepared.runId originals of
  Just source
    | source.ordinal /= prepared.ordinal -> Left "prepared run ordinal differs from the source plan"
    | source.spec.scenario /= prepared.spec.scenario -> Left "prepared run scenario differs from the source plan"
    | maybe False (/= prepared.runId) prepared.spec.runId -> Left "prepared spec run ID differs from the source plan"
    | otherwise -> case source.json of
        Object original -> Right (Object (KeyMap.insert "spec" (Aeson.toJSON prepared.spec) original), source.estimateMinutes)
        _ -> Left "prepared run is not an object"
  _ -> Left "prepared run is absent from the source plan"

required :: (FromJSON document) => Text -> Aeson.Object -> Either Text document
required name fields = case KeyMap.lookup (Key.fromText name) fields of
  Nothing -> Left ("run plan is missing " <> name)
  Just value -> case Aeson.fromJSON value of
    Aeson.Error failure -> Left (name <> ": " <> Text.pack failure)
    Aeson.Success result -> Right result

unique :: (Eq value) => [value] -> Bool
unique [] = True
unique (first : rest) = first `notElem` rest && unique rest
