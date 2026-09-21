{-# LANGUAGE FieldSelectors #-}

module Kenshou.Plan.Change
  ( ChangeSource (..),
    Change (..),
    Warning (..),
    Reason (..),
    Selected (..),
    selectScenarios,
    selectAll,
    selectBySelectors,
    applySelectors,
  )
where

import Data.List (sortOn)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Maybe (mapMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Kenshou.Plan.Catalog (ScenarioInfo (..))
import Kenshou.Plan.Components
import Kenshou.Plan.Selector

data ChangeSource = Named | CohortDiff | Since | UpstreamDiff | Everything
  deriving stock (Eq, Ord, Show)

data Change = Change
  { ref :: ComponentRef,
    source :: ChangeSource,
    detail :: Text
  }
  deriving stock (Eq, Show)

data Warning = Warning {code :: Text, message :: Text}
  deriving stock (Eq, Show)

data Reason = Reason
  { change :: Change,
    via :: [ComponentRef],
    selector :: Selector,
    distance :: Int
  }
  deriving stock (Eq, Show)

data Selected = Selected
  { scenario :: ScenarioInfo,
    reasons :: NonEmpty Reason,
    minPolicy :: Maybe Text
  }
  deriving stock (Eq, Show)

selectScenarios :: ComponentGraph -> [ScenarioInfo] -> [Change] -> [Selected]
selectScenarios graph catalog changes
  | any ((== Everything) . (.source)) changes = selectAll catalog
  | otherwise = sortOn (scenarioKey . (.scenario)) (mapMaybe selected catalog)
  where
    affectedByChange changeValue = dependents graph (Set.singleton changeValue.ref)
    closure = [(changeValue, affectedByChange changeValue) | changeValue <- changes]
    selected scenario = case sortOn reasonKey (concatMap (reasonsFor scenario) closure) of
      [] -> Nothing
      first : rest ->
        Just
          Selected
            { scenario,
              reasons = first :| rest,
              minPolicy = maximumPolicy [minPolicyForRef graph changeValue.ref | changeValue <- changes, any ((== changeValue) . (.change)) (first : rest)]
            }
    reasonsFor scenario (changeValue, affected) = do
      affectedValue <- Map.elems affected
      selector <- selectorsForRef graph affectedValue.ref
      if matches selector scenario.id
        then pure (Reason changeValue affectedValue.path selector affectedValue.distance)
        else []
    reasonKey reason = (reason.distance, renderRef reason.change.ref, renderSelector reason.selector)
    scenarioKey = show . (.id)

selectAll :: [ScenarioInfo] -> [Selected]
selectAll catalog = case parseSelector "**" of
  Left _ -> []
  Right selector ->
    [ Selected scenario (Reason change [change.ref] selector 0 :| []) Nothing
    | scenario <- catalog
    ]
  where
    change = Change (ComponentRef (ComponentId "all") Nothing) Everything "all scenarios"

selectBySelectors :: ChangeSource -> Text -> [Selector] -> [ScenarioInfo] -> [Selected]
selectBySelectors source detail selectors catalog =
  [ Selected scenario (Reason change [change.ref] selector 0 :| []) Nothing
  | scenario <- catalog,
    selector <- take 1 (filter (`matches` scenario.id) selectors)
  ]
  where
    change = Change (ComponentRef (ComponentId "repository-path") Nothing) source detail

applySelectors :: [Selector] -> [Selector] -> [Selected] -> [Selected]
applySelectors includes excludes = filter keep
  where
    keep selectedValue =
      (null includes || any (`matches` selectedValue.scenario.id) includes)
        && not (any (`matches` selectedValue.scenario.id) excludes)

maximumPolicy :: [Maybe Text] -> Maybe Text
maximumPolicy policies = case mapMaybe (\value -> value) policies of
  [] -> Nothing
  values -> Just (maximumByRank values)
  where
    maximumByRank = foldl1 (\left right -> if rank left >= rank right then left else right)
    rank "default-only" = (0 :: Int)
    rank "telemetry-corners" = 1
    rank "pairwise" = 2
    rank "full" = 3
    rank _ = 0
