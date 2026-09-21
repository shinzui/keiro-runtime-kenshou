{-# LANGUAGE FieldSelectors #-}

module Kenshou.Plan.Components.Check
  ( PackageName (..),
    EdgeDrift (..),
    LintFinding (..),
    checkAgainstPlanJson,
    lintAgainstCatalog,
    isDriftError,
    isLintError,
  )
where

import Data.Aeson
import Data.ByteString qualified as ByteString
import Data.List (nub, sort)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Kenshou.Core.Id (Layer (Selftest), ScenarioId (..), renderScenarioId)
import Kenshou.Plan.Catalog (ScenarioInfo (..))
import Kenshou.Plan.Components
import Kenshou.Plan.Selector (Selector, matches, renderSelector)

newtype PackageName = PackageName Text
  deriving stock (Eq, Ord, Show)

data EdgeDrift
  = MissingEdge ComponentId ComponentId [PackageName]
  | ExtraEdge ComponentId ComponentId
  | NotInBuildPlan PackageName
  deriving stock (Eq, Ord, Show)

data LintFinding
  = OrphanScenario ScenarioId
  | DeadSelector ComponentRef Selector
  deriving stock (Eq, Show)

data PlanUnit = PlanUnit {unitId :: Text, package :: PackageName, componentName :: Maybe Text, dependencies :: [Text]}

newtype CabalPlan = CabalPlan {units :: [PlanUnit]}

instance FromJSON CabalPlan where parseJSON = withObject "CabalPlan" \value -> CabalPlan <$> value .: "install-plan"

instance FromJSON PlanUnit where
  parseJSON = withObject "PlanUnit" \value ->
    PlanUnit <$> value .: "id" <*> (PackageName <$> value .: "pkg-name") <*> value .:? "component-name" <*> value .:? "depends" .!= []

checkAgainstPlanJson :: ComponentGraph -> FilePath -> IO (Either Text [EdgeDrift])
checkAgainstPlanJson graph path = do
  bytes <- ByteString.readFile path
  pure case eitherDecodeStrict' bytes of
    Left err -> Left (Text.pack err)
    Right plan -> Right (compareEdges graph plan)

compareEdges :: ComponentGraph -> CabalPlan -> [EdgeDrift]
compareEdges graph plan =
  fmap (uncurry missingEdgeWithPackages) missing
    <> fmap (uncurry ExtraEdge) extra
    <> fmap (NotInBuildPlan . PackageName) absentPackages
  where
    libraryUnits = filter ((== Just "lib") . (.componentName)) plan.units
    idToPackage = Map.fromList [(unit.unitId, unit.package) | unit <- plan.units]
    packageToComponent = Map.fromList [(PackageName package, componentValue.id) | componentValue <- graph.components, package <- componentValue.packages]
    presentPackages = Set.fromList (fmap (.package) libraryUnits)
    presentComponents = Set.fromList (Map.elems (Map.restrictKeys packageToComponent presentPackages))
    observed = Set.fromList do
      unit <- libraryUnits
      source <- maybe [] pure (Map.lookup unit.package packageToComponent)
      dependencyId <- unit.dependencies
      dependencyPackage <- maybe [] pure (Map.lookup dependencyId idToPackage)
      target <- maybe [] pure (Map.lookup dependencyPackage packageToComponent)
      if source == target then [] else pure (source, target)
    declared = Set.fromList [(componentValue.id, edge.to) | componentValue <- graph.components, edge <- componentValue.dependsOn, edge.kind == Build, componentValue.id `Set.member` presentComponents, edge.to `Set.member` presentComponents]
    missing = Set.toAscList (observed `Set.difference` declared)
    extra = Set.toAscList (declared `Set.difference` observed)
    absentPackages = sort [package | componentValue <- graph.components, package <- componentValue.packages, PackageName package `Set.notMember` presentPackages]
    directPackages source target =
      nub
        [ dependencyPackage
        | unit <- libraryUnits,
          Map.lookup unit.package packageToComponent == Just source,
          dependencyId <- unit.dependencies,
          Just dependencyPackage <- [Map.lookup dependencyId idToPackage],
          Map.lookup dependencyPackage packageToComponent == Just target
        ]
    missingEdgeWithPackages source target = MissingEdge source target (directPackages source target)

lintAgainstCatalog :: ComponentGraph -> [ScenarioInfo] -> [LintFinding]
lintAgainstCatalog graph catalog = orphaned <> dead
  where
    references =
      [ComponentRef componentValue.id Nothing | componentValue <- graph.components]
        <> [ComponentRef componentValue.id (Just subcomponentValue.id) | componentValue <- graph.components, subcomponentValue <- componentValue.subcomponents]
    selectorPairs = [(reference, selector) | reference <- references, selector <- selectorsForRef graph reference]
    orphaned =
      [ OrphanScenario scenario.id
      | scenario <- catalog,
        scenario.id.layer /= Selftest,
        not (any ((`matches` scenario.id) . snd) selectorPairs)
      ]
    dead =
      [ DeadSelector reference selector
      | (reference, selector) <- selectorPairs,
        selectorHasRegisteredLayer selector,
        not (any (matches selector . (.id)) catalog)
      ]
    selectorHasRegisteredLayer selector =
      let prefix = Text.takeWhile (/= '/') (renderSelector selector)
       in prefix == "*" || any ((== prefix) . Text.takeWhile (/= '/') . renderScenarioId . (.id)) catalog

isDriftError :: EdgeDrift -> Bool
isDriftError NotInBuildPlan {} = False
isDriftError _ = True

isLintError :: LintFinding -> Bool
isLintError OrphanScenario {} = True
isLintError DeadSelector {} = False
