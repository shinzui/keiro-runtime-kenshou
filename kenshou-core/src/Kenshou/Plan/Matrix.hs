{-# LANGUAGE FieldSelectors #-}

module Kenshou.Plan.Matrix
  ( DimensionPolicy (..),
    KnobPolicy (..),
    Config (..),
    MatrixSkip (..),
    expandScenario,
    pairwiseCover,
  )
where

import Data.List (maximumBy, nub, sortOn)
import Data.List.NonEmpty qualified as NonEmpty
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Ord (Down (..), comparing)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Kenshou.Core.Dimension
import Kenshou.Core.Id (Kind (..), ScenarioId (..))
import Kenshou.Core.Knob
import Kenshou.Plan.Catalog (ScenarioInfo (..))
import Kenshou.Plan.Change (Selected (..))
import Kenshou.Plan.Policy

data Config = Config
  { knobs :: Map KnobName KnobValue,
    dimensions :: Map Text Text,
    isDefault :: Bool
  }
  deriving stock (Eq, Show)

data MatrixSkip = MatrixSkip {reason :: Text, detail :: Text}
  deriving stock (Eq, Show)

expandScenario :: PlanPolicy -> Selected -> ([Config], [MatrixSkip])
expandScenario policy selected = case dimensionRows of
  Left problem -> ([], [problem])
  Right rows -> case knobRows of
    Left problem -> ([], [problem])
    Right (defaultKnobs, variants) ->
      ( [Config defaultKnobs row (index == 0) | (index, row) <- zip [0 :: Int ..] rows]
          <> [Config variant (headOrEmpty rows) False | variant <- variants],
        []
      )
  where
    scenario = selected.scenario
    effectivePolicy = max policy.dimensionPolicy (maybe DefaultOnly parseMinimum selected.minPolicy)
    dimensionRows = expandDimensions effectivePolicy policy.pinnedDimensions scenario
    effectiveKnobPolicy = max policy.knobPolicy (maybe KnobDefaults parseMinimumKnob selected.minKnobPolicy)
    knobRows = expandKnobs (policy {knobPolicy = effectiveKnobPolicy}) scenario
    parseMinimum value = maybe DefaultOnly (\policyValue -> policyValue) (parseDimensionPolicy value)
    parseMinimumKnob value = maybe KnobDefaults (\policyValue -> policyValue) (parseKnobPolicy value)
    headOrEmpty [] = Map.empty
    headOrEmpty (first : _) = first

expandDimensions :: DimensionPolicy -> [(Text, Text)] -> ScenarioInfo -> Either MatrixSkip [Map Text Text]
expandDimensions policy pins scenario
  | scenario.id.kind == Benchmark && not durableSupported = Left (MatrixSkip "benchmark-without-durable" "benchmark does not support pg.durability=durable")
  | otherwise = do
      pinned <- traverse validatePin pins
      let valueSets = fmap (applyPin pinned) supported
          effectiveSets = if scenario.id.kind == Benchmark then fmap forceDurable valueSets else valueSets
          defaults = Map.fromList [(name, def) | (name, _, def) <- effectiveSets]
          rows = case policy of
            DefaultOnly -> [defaults]
            TelemetryCorners -> telemetryCorners effectiveSets defaults
            Pairwise -> pairwiseCover [(name, values) | (name, values, _) <- effectiveSets]
            Full -> productRows [(name, values) | (name, values, _) <- effectiveSets]
      pure rows
  where
    supported = supportRows scenario.dimensions
    durableSupported = case scenario.dimensions.pgDurability of
      Supported support -> PgDurable `elem` support.values
      NotApplicable -> False
    validatePin (name, value) = case lookup name [(rowName, values) | (rowName, values, _) <- supported] of
      Nothing -> Left (MatrixSkip "unsupported-dimension" (name <> " is not applicable"))
      Just values | value `elem` values -> Right (name, value)
      Just _ -> Left (MatrixSkip "unsupported-dimension" (name <> "=" <> value <> " is not supported"))
    applyPin pinnedValues row@(name, _, _) = case lookup name pinnedValues of
      Nothing -> row
      Just value -> (name, [value], value)
    forceDurable ("pg.durability", _, _) = ("pg.durability", ["durable"], "durable")
    forceDurable row = row

supportRows :: DimensionSupport -> [(Text, [Text], Text)]
supportRows support =
  concat
    [ supportRow "telemetry.tracing" renderTracing support.tracing,
      supportRow "telemetry.metrics" renderMetrics support.metrics,
      supportRow "pg.durability" renderDurability support.pgDurability,
      supportRow "pg.version" renderVersion support.pgVersion
    ]
  where
    supportRow _ _ NotApplicable = []
    supportRow name render (Supported value) = [(name, fmap render (NonEmpty.toList value.values), render value.def)]

telemetryCorners :: [(Text, [Text], Text)] -> Map Text Text -> [Map Text Text]
telemetryCorners rows defaults = nub [set tracing metrics defaults | tracing <- tracingValues, metrics <- metricsValues]
  where
    values name fallback = maybe fallback (\(items, def) -> nub [def, preferred name items def]) (lookupRow name)
    lookupRow name = case [(items, def) | (rowName, items, def) <- rows, rowName == name] of [] -> Nothing; first : _ -> Just first
    tracingValues = values "telemetry.tracing" [""]
    metricsValues = values "telemetry.metrics" [""]
    preferred "telemetry.tracing" items def = firstSupported ["sdk-inmemory", "sdk-otlp", "noop"] items def
    preferred "telemetry.metrics" items def = firstSupported ["serve-scraped", "serve", "collect"] items def
    preferred _ _ def = def
    firstSupported preferences items def = case filter (`elem` items) preferences of [] -> def; first : _ -> first
    set tracing metrics = setIfPresent "telemetry.metrics" metrics . setIfPresent "telemetry.tracing" tracing
    setIfPresent _ "" valuesMap = valuesMap
    setIfPresent name value valuesMap = Map.insert name value valuesMap

productRows :: [(Text, [Text])] -> [Map Text Text]
productRows = foldr step [Map.empty]
  where
    step (name, values) rows = [Map.insert name value row | value <- values, row <- rows]

pairwiseCover :: [(Text, [Text])] -> [Map Text Text]
pairwiseCover dimensions
  | length dimensions < 2 = take 1 (productRows dimensions)
  | otherwise = go uncovered [] candidates
  where
    candidates = sortOn renderRow (productRows dimensions)
    uncovered = Set.unions (fmap rowPairs candidates)
    go remaining chosen available
      | Set.null remaining = reverse chosen
      | otherwise = case available of
          [] -> reverse chosen
          _ ->
            let best = maximumBy (comparing (\row -> (Set.size (Set.intersection remaining (rowPairs row)), Down (renderRow row)))) available
             in go (remaining `Set.difference` rowPairs best) (best : chosen) (filter (/= best) available)
    rowPairs row =
      Set.fromList
        [ ((leftName, leftValue), (rightName, rightValue))
        | (leftIndex, (leftName, leftValue)) <- zip [0 :: Int ..] (Map.toAscList row),
          (rightIndex, (rightName, rightValue)) <- zip [0 :: Int ..] (Map.toAscList row),
          leftIndex < rightIndex
        ]
    renderRow = Text.pack . show . Map.toAscList

expandKnobs :: PlanPolicy -> ScenarioInfo -> Either MatrixSkip (Map KnobName KnobValue, [Map KnobName KnobValue])
expandKnobs policy scenario = case resolveKnobs scenario.knobs supplied of
  Left problems -> Left (MatrixSkip "unsupported-knob" (Text.intercalate "; " (fmap renderProblem (NonEmpty.toList problems))))
  Right resolved -> Right (base, variants)
    where
      base = resolvedKnobsMap resolved
      variants
        | policy.knobPolicy == KnobDefaults = []
        | otherwise =
            [ Map.insert spec.name value base
            | spec <- scenario.knobs,
              length spec.variants <= 8,
              value <- spec.variants,
              value /= Map.findWithDefault spec.def spec.name base
            ]
  where
    declaredNames = fmap (renderKnobName . (.name)) scenario.knobs
    supplied =
      [ (spec.name, RawText value)
      | (name, value) <- policy.pinnedKnobs,
        name `elem` declaredNames,
        spec <- scenario.knobs,
        renderKnobName spec.name == name
      ]
    renderProblem (KnobError message) = message
