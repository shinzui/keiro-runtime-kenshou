module Kenshou.Remote.Cell.RouteJson (RouteDocuments (..), routeWorkJson) where

import Data.Aeson (FromJSON, Value (..), object, (.=))
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Foldable (toList)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time.Clock.POSIX (posixSecondsToUTCTime)
import Kenshou.Core.Bundle (Registry)
import Kenshou.Core.Id (RunId, mkSeed)
import Kenshou.Core.RunSpec (RunSpec (..))
import Kenshou.Plan.Change (Change (..), ChangeSource (..), Reason (..))
import Kenshou.Plan.Components (ComponentId (..), ComponentRef (..))
import Kenshou.Plan.Policy (defaultPlanPolicy)
import Kenshou.Plan.RunPlan (PlanContext (..), PlanInputs (..), PlannedRun (..), RunPlan (..), TrialInfo (..))
import Kenshou.Plan.Selector (parseSelector)
import Kenshou.Remote.Cell.Docs (CellDescriptor)
import Kenshou.Remote.Cell.Prepare (PrepareOptions, Routed (..), routePlan, routePlanWithoutPayload)
import Kenshou.Remote.Cell.RouteRules (CellCapabilities, RoutingRule)
import Kenshou.Remote.Payload (PayloadDescriptor)

data RouteDocuments = RouteDocuments
  { perCell :: !(Map Text Value),
    local :: !(Maybe Value),
    report :: !Value,
    routeComplete :: !Bool
  }
  deriving stock (Eq, Show)

-- Route the public JSON plan without decoding and re-encoding its provenance
-- types. The typed plan below carries only the fields used by preparation; the
-- output copies each original entry and replaces its prepared spec.
routeWorkJson :: Registry -> NonEmpty (CellDescriptor, Maybe CellCapabilities) -> [RoutingRule] -> Maybe (Map Text PayloadDescriptor) -> PrepareOptions -> Value -> Either Text RouteDocuments
routeWorkJson registry cells rules payloads options work = do
  fields <- case work of Object value -> Right value; _ -> Left "run plan is not a JSON object"
  case KeyMap.lookup "schema" fields of
    Just (String "kenshou.run-plan/v1") -> pure ()
    _ -> Left "run plan has an unsupported schema"
  planId <- required "planId" fields
  rawRuns <- case KeyMap.lookup "runs" fields of
    Just (Array entries) -> Right (toList entries)
    _ -> Left "run plan has no runs array"
  entries <- traverse parseEntry rawRuns
  let identifiers = fmap (\(entry, _) -> entry.runId) entries
      ordinals = fmap (\(entry, _) -> entry.ordinal) entries
  if unique identifiers && unique ordinals then pure () else Left "run plan contains duplicate run IDs or ordinals"
  selector <- parseSelector "**"
  seed <- mkSeed 1
  let placeholder = Reason (Change (ComponentRef (ComponentId "cell-route") Nothing) Named "internal routing placeholder") [] selector 0
      planned = fmap (toPlanned placeholder . fst) entries
      context = PlanContext Nothing "" "" "" (PlanInputs Null) [] []
      typed = RunPlan planId (posixSecondsToUTCTime 0) context (defaultPlanPolicy seed) planned [] (sum (fmap (.estimateMinutes) planned))
      routed = case payloads of
        Just selected -> routePlan registry cells rules selected options typed
        Nothing -> routePlanWithoutPayload registry cells rules options typed
      originals = Map.fromList [(entry.runId, value) | (entry, value) <- entries]
  cellDocs <- traverse (renderPlan fields originals True) routed.perCell
  localDoc <- traverse (renderPlan fields originals False) routed.local
  let routeReport =
        object
          [ "schema" .= ("kenshou.cell-route/v1" :: Text),
            "planId" .= planId,
            "perCell" .= Map.map (fmap (.runId) . (.runs)) routed.perCell,
            "localRunIds" .= maybe [] (fmap (.runId) . (.runs)) routed.local,
            "unroutable" .= [object ["runId" .= entry.runId, "reason" .= Text.pack (show reason)] | (entry, reason) <- routed.unroutable],
            "warnings" .= routed.warnings
          ]
  pure (RouteDocuments cellDocs localDoc routeReport (null routed.unroutable))
  where
    required :: (FromJSON document) => Text -> Aeson.Object -> Either Text document
    required name fields = case KeyMap.lookup (Key.fromText name) fields of
      Nothing -> Left ("run plan is missing " <> name)
      Just value -> decode name value

    decode :: (FromJSON document) => Text -> Value -> Either Text document
    decode label value = case Aeson.fromJSON value of
      Aeson.Error failure -> Left (label <> ": " <> Text.pack failure)
      Aeson.Success result -> Right result

    parseEntry value = case value of
      Object fields -> do
        ordinal <- required "ordinal" fields
        runId <- required "runId" fields
        estimate <- required "estimateMinutes" fields
        spec <- required "spec" fields
        trial <- case KeyMap.lookup "trial" fields of
          Nothing -> Right Nothing
          Just Null -> Right Nothing
          Just (Object trialFields) -> Just <$> (TrialInfo <$> required "group" trialFields <*> required "arm" trialFields <*> required "index" trialFields <*> required "of" trialFields)
          _ -> Left "planned run trial is not an object"
        if ordinal < 0 || estimate <= 0 || maybe False (/= runId) spec.runId
          then Left "planned run has an invalid ordinal, estimate or spec run ID"
          else Right (RouteEntry ordinal runId estimate trial spec, value)
      _ -> Left "planned run is not an object"

    toPlanned placeholder entry = PlannedRun entry.ordinal entry.runId entry.estimateMinutes (placeholder :| []) entry.trial entry.spec

    renderPlan fields originals prepared plan = do
      rows <- traverse (renderEntry originals prepared) plan.runs
      let changed = KeyMap.insert "runs" (Aeson.toJSON rows) (KeyMap.insert "estimateMinutes" (Aeson.toJSON plan.estimateMinutes) fields)
      pure (Object changed)

    renderEntry originals prepared entry = case Map.lookup entry.runId originals of
      Just (Object original) ->
        Right (Object (if prepared then KeyMap.insert "spec" (Aeson.toJSON entry.spec) original else original))
      _ -> Left "routed run is absent from the input plan"

data RouteEntry = RouteEntry
  { ordinal :: !Int,
    runId :: !RunId,
    estimateMinutes :: !Int,
    trial :: !(Maybe TrialInfo),
    spec :: !RunSpec
  }

unique :: (Eq value) => [value] -> Bool
unique [] = True
unique (first : rest) = first `notElem` rest && unique rest
