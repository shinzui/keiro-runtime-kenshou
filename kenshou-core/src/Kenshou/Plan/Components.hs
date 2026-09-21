{-# LANGUAGE FieldSelectors #-}
{-# LANGUAGE TemplateHaskell #-}

module Kenshou.Plan.Components
  ( ComponentId (..),
    SubId (..),
    ComponentRef (..),
    EdgeKind (..),
    ComponentKind (..),
    ChangeImplies (..),
    Subcomponent (..),
    DependencyEdge (..),
    Component (..),
    PathEffect (..),
    RepositoryPathRule (..),
    ComponentGraph (..),
    Affected (..),
    GraphProblem (..),
    GraphError (..),
    embeddedGraph,
    embeddedGraphBytes,
    loadGraphFile,
    decodeGraph,
    validateGraph,
    parseRef,
    renderRef,
    dependents,
    graphDigest,
    componentById,
    selectorsForRef,
    minPolicyForRef,
  )
where

import Data.Aeson
import Data.Aeson.Types (Parser)
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.FileEmbed (embedFile)
import Data.Graph (SCC (..), stronglyConnComp)
import Data.List (group, nub, sort, sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Sequence (Seq (..), (|>))
import Data.Sequence qualified as Seq
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Kenshou.Core.Canonical (canonicalEncode, sha256Hex)
import Kenshou.Plan.Selector (Selector, parseSelector, renderSelector)

newtype ComponentId = ComponentId {unComponentId :: Text}
  deriving stock (Eq, Ord, Show)

newtype SubId = SubId {unSubId :: Text}
  deriving stock (Eq, Ord, Show)

data ComponentRef = ComponentRef {component :: ComponentId, sub :: Maybe SubId}
  deriving stock (Eq, Ord, Show)

data EdgeKind = Build | Runtime deriving stock (Eq, Ord, Show)

data ComponentKind = Library | Migrations | Service | Harness | Assembly
  deriving stock (Eq, Ord, Show)

newtype ChangeImplies = ChangeImplies {minDimensionPolicy :: Text}
  deriving stock (Eq, Show)

data Subcomponent = Subcomponent
  { id :: SubId,
    pathPrefixes :: [FilePath],
    selectors :: [Selector],
    uses :: [SubId],
    changeImplies :: Maybe ChangeImplies
  }
  deriving stock (Eq, Show)

data DependencyEdge = DependencyEdge
  { to :: ComponentId,
    kind :: EdgeKind,
    toSubs :: [SubId],
    fromSubs :: [SubId]
  }
  deriving stock (Eq, Show)

data Component = Component
  { id :: ComponentId,
    kind :: ComponentKind,
    uri :: Maybe Text,
    repository :: Text,
    sourceRoots :: [FilePath],
    packages :: [Text],
    selectors :: [Selector],
    changeImplies :: Maybe ChangeImplies,
    verifiedAgainst :: Text,
    subcomponents :: [Subcomponent],
    dependsOn :: [DependencyEdge]
  }
  deriving stock (Eq, Show)

data PathEffect = PathAll | PathNothing | PathCohort | PathSelectors [Selector]
  deriving stock (Eq, Show)

data RepositoryPathRule = RepositoryPathRule {prefix :: FilePath, effect :: PathEffect}
  deriving stock (Eq, Show)

data ComponentGraph = ComponentGraph
  { schema :: Text,
    ignoredPackages :: [Text],
    components :: [Component],
    repositoryPaths :: [RepositoryPathRule]
  }
  deriving stock (Eq, Show)

data Affected = Affected
  { ref :: ComponentRef,
    origin :: ComponentRef,
    path :: [ComponentRef],
    distance :: Int
  }
  deriving stock (Eq, Show)

newtype GraphProblem = GraphProblem {problemText :: Text}
  deriving stock (Eq, Ord, Show)

newtype GraphError = GraphError {errorText :: Text}
  deriving stock (Eq, Show)

embeddedGraphBytes :: ByteString
embeddedGraphBytes = $(embedFile "data/components.json")

embeddedGraph :: Either GraphError ComponentGraph
embeddedGraph = decodeGraph embeddedGraphBytes

loadGraphFile :: FilePath -> IO (Either GraphError ComponentGraph)
loadGraphFile path = decodeGraph <$> ByteString.readFile path

decodeGraph :: ByteString -> Either GraphError ComponentGraph
decodeGraph bytes = case eitherDecodeStrict' bytes of
  Left err -> Left (GraphError (Text.pack err))
  Right graph -> case validateGraph graph of
    [] -> Right graph
    problems -> Left (GraphError (Text.intercalate "; " (fmap (.problemText) problems)))

validateGraph :: ComponentGraph -> [GraphProblem]
validateGraph graph =
  schemaProblems
    <> duplicateComponentProblems
    <> duplicatePackageProblems
    <> concatMap validateComponent graph.components
    <> cycleProblems
  where
    componentIds = Set.fromList (fmap (.id) graph.components)
    schemaProblems = [GraphProblem ("unsupported component graph schema " <> graph.schema) | graph.schema /= "kenshou.component-graph/v1"]
    duplicateComponentProblems = duplicateProblems "component" (fmap (unComponentId . (.id)) graph.components)
    duplicatePackageProblems = duplicateProblems "package" (concatMap (.packages) graph.components)
    validateComponent componentValue =
      duplicateProblems ("subcomponent of " <> unComponentId componentValue.id) (fmap (unSubId . (.id)) componentValue.subcomponents)
        <> concatMap (validateEdge componentValue) componentValue.dependsOn
        <> concatMap (validateSub componentValue) componentValue.subcomponents
    validateEdge componentValue edge =
      [GraphProblem (unComponentId componentValue.id <> ": unknown dependency " <> unComponentId edge.to) | edge.to `Set.notMember` componentIds]
        <> case componentById graph edge.to of
          Nothing -> []
          Just target ->
            [ GraphProblem (unComponentId componentValue.id <> ": unknown target subcomponent " <> unSubId subId)
            | subId <- edge.toSubs,
              subId `notElem` fmap (.id) target.subcomponents
            ]
        <> [ GraphProblem (unComponentId componentValue.id <> ": unknown source subcomponent " <> unSubId subId)
           | subId <- edge.fromSubs,
             subId `notElem` fmap (.id) componentValue.subcomponents
           ]
    validateSub componentValue subcomponentValue =
      [ GraphProblem (unComponentId componentValue.id <> ": " <> unSubId subcomponentValue.id <> " uses unknown subcomponent " <> unSubId used)
      | used <- subcomponentValue.uses,
        used `notElem` fmap (.id) componentValue.subcomponents
      ]
    cycleProblems =
      [ GraphProblem ("component dependency cycle: " <> Text.intercalate " -> " (sort (fmap (unComponentId . (.id)) members)))
      | CyclicSCC members <- stronglyConnComp [(componentValue, componentValue.id, fmap (.to) componentValue.dependsOn) | componentValue <- graph.components]
      ]

duplicateProblems :: Text -> [Text] -> [GraphProblem]
duplicateProblems label values =
  [GraphProblem ("duplicate " <> label <> " " <> value) | entries@(value : _) <- group (sort values), length entries > 1]

componentById :: ComponentGraph -> ComponentId -> Maybe Component
componentById graph wanted = Map.lookup wanted (Map.fromList [(componentValue.id, componentValue) | componentValue <- graph.components])

parseRef :: ComponentGraph -> Text -> Either Text ComponentRef
parseRef graph raw = case Text.splitOn ":" raw of
  [componentText] -> do
    let componentId = ComponentId componentText
    case componentById graph componentId of
      Nothing -> Left ("unknown component " <> raw)
      Just _ -> Right (ComponentRef componentId Nothing)
  [componentText, subText] -> do
    let componentId = ComponentId componentText
        subId = SubId subText
    componentValue <- maybe (Left ("unknown component " <> componentText)) Right (componentById graph componentId)
    if subId `elem` fmap (.id) componentValue.subcomponents
      then Right (ComponentRef componentId (Just subId))
      else Left ("unknown subcomponent " <> raw)
  _ -> Left ("invalid component reference " <> raw)

renderRef :: ComponentRef -> Text
renderRef reference = unComponentId reference.component <> maybe "" ((":" <>) . unSubId) reference.sub

dependents :: ComponentGraph -> Set ComponentRef -> Map ComponentRef Affected
dependents graph origins = go initialQueue initialMap
  where
    seeded = concatMap expandOrigin (Set.toAscList origins)
    expandOrigin originRef@(ComponentRef componentId Nothing) =
      (originRef, Affected originRef originRef [originRef] 0)
        : case componentById graph componentId of
          Nothing -> []
          Just componentValue ->
            [ let subRef = ComponentRef componentId (Just subcomponentValue.id)
               in (subRef, Affected subRef originRef [originRef, subRef] 0)
            | subcomponentValue <- componentValue.subcomponents
            ]
    expandOrigin originRef = [(originRef, Affected originRef originRef [originRef] 0)]
    initialMap = Map.fromListWith chooseShorter seeded
    initialQueue = Seq.fromList (Map.keys initialMap)
    go Empty results = results
    go (current :<| rest) results =
      let currentAffected = results Map.! current
          candidates = fmap (mkAffected currentAffected) (neighbors current)
          (results', queue') = foldl insertCandidate (results, rest) candidates
       in go queue' results'
    mkAffected previous next =
      Affected next previous.origin (previous.path <> [next]) (previous.distance + if next.component == previous.ref.component then 0 else 1)
    insertCandidate (results, queue) candidate = case Map.lookup candidate.ref results of
      Just existing | existing.distance <= candidate.distance -> (results, queue)
      _ -> (Map.insert candidate.ref candidate results, queue |> candidate.ref)
    chooseShorter left right = if left.distance <= right.distance then left else right
    neighbors target = nub (siblingUsers target <> edgeUsers target)
    siblingUsers (ComponentRef componentId (Just subId)) = case componentById graph componentId of
      Nothing -> []
      Just componentValue -> [ComponentRef componentId (Just sibling.id) | sibling <- componentValue.subcomponents, subId `elem` sibling.uses]
    siblingUsers _ = []
    edgeUsers target = concatMap (sourceFor target) graph.components
    sourceFor target source = concatMap (edgeSource target source) source.dependsOn
    edgeSource target source edge
      | edge.to /= target.component = []
      | not (targetMatches target edge) = []
      | null edge.fromSubs = [ComponentRef source.id Nothing]
      | otherwise = fmap (ComponentRef source.id . Just) edge.fromSubs
    targetMatches (ComponentRef _ Nothing) _ = True
    targetMatches (ComponentRef _ (Just subId)) edge = null edge.toSubs || subId `elem` edge.toSubs

selectorsForRef :: ComponentGraph -> ComponentRef -> [Selector]
selectorsForRef graph (ComponentRef componentId Nothing) = maybe [] (.selectors) (componentById graph componentId)
selectorsForRef graph (ComponentRef componentId (Just subId)) = do
  componentValue <- maybe [] pure (componentById graph componentId)
  subcomponentValue <- filter ((== subId) . (.id)) componentValue.subcomponents
  subcomponentValue.selectors

minPolicyForRef :: ComponentGraph -> ComponentRef -> Maybe Text
minPolicyForRef graph (ComponentRef componentId Nothing) = do
  componentValue <- componentById graph componentId
  implies <- componentValue.changeImplies
  pure implies.minDimensionPolicy
minPolicyForRef graph (ComponentRef componentId (Just subId)) = do
  componentValue <- componentById graph componentId
  subcomponentValue <- case filter ((== subId) . (.id)) componentValue.subcomponents of [] -> Nothing; value : _ -> Just value
  implies <- subcomponentValue.changeImplies
  pure implies.minDimensionPolicy

graphDigest :: ComponentGraph -> Text
graphDigest = sha256Hex . canonicalEncode . toJSON

instance FromJSON ComponentGraph where
  parseJSON = withObject "ComponentGraph" \value -> ComponentGraph <$> value .: "schema" <*> value .:? "ignoredPackages" .!= [] <*> value .: "components" <*> value .: "repositoryPaths"

instance ToJSON ComponentGraph where
  toJSON graph = object ["schema" .= graph.schema, "ignoredPackages" .= graph.ignoredPackages, "components" .= graph.components, "repositoryPaths" .= graph.repositoryPaths]

instance FromJSON Component where
  parseJSON = withObject "Component" \value ->
    Component <$> value .: "id" <*> value .: "kind" <*> value .:? "uri" <*> value .: "repository" <*> value .:? "sourceRoots" .!= [] <*> value .:? "packages" .!= [] <*> parseSelectors value <*> value .:? "changeImplies" <*> value .:? "verifiedAgainst" .!= "" <*> value .:? "subcomponents" .!= [] <*> value .:? "dependsOn" .!= []

instance ToJSON Component where
  toJSON componentValue = object ["id" .= componentValue.id, "kind" .= componentValue.kind, "uri" .= componentValue.uri, "repository" .= componentValue.repository, "sourceRoots" .= componentValue.sourceRoots, "packages" .= componentValue.packages, "selectors" .= fmap renderSelector componentValue.selectors, "changeImplies" .= componentValue.changeImplies, "verifiedAgainst" .= componentValue.verifiedAgainst, "subcomponents" .= componentValue.subcomponents, "dependsOn" .= componentValue.dependsOn]

instance FromJSON Subcomponent where
  parseJSON = withObject "Subcomponent" \value -> Subcomponent <$> value .: "id" <*> value .:? "pathPrefixes" .!= [] <*> parseSelectors value <*> value .:? "uses" .!= [] <*> value .:? "changeImplies"

instance ToJSON Subcomponent where
  toJSON subcomponentValue = object ["id" .= subcomponentValue.id, "pathPrefixes" .= subcomponentValue.pathPrefixes, "selectors" .= fmap renderSelector subcomponentValue.selectors, "uses" .= subcomponentValue.uses, "changeImplies" .= subcomponentValue.changeImplies]

parseSelectors :: Object -> Parser [Selector]
parseSelectors value = do
  raw <- value .:? "selectors" .!= []
  traverse (either (fail . Text.unpack) pure . parseSelector) raw

instance FromJSON DependencyEdge where
  parseJSON = withObject "DependencyEdge" \value -> DependencyEdge <$> value .: "to" <*> value .: "kind" <*> value .:? "toSubs" .!= [] <*> value .:? "fromSubs" .!= []

instance ToJSON DependencyEdge where
  toJSON edge = object ["to" .= edge.to, "kind" .= edge.kind, "toSubs" .= edge.toSubs, "fromSubs" .= edge.fromSubs]

instance FromJSON RepositoryPathRule where
  parseJSON = withObject "RepositoryPathRule" \value -> RepositoryPathRule <$> value .: "prefix" <*> value .: "effect"

instance ToJSON RepositoryPathRule where toJSON rule = object ["prefix" .= rule.prefix, "effect" .= rule.effect]

instance FromJSON PathEffect where
  parseJSON = withObject "PathEffect" \value ->
    value .: "kind" >>= \case
      ("all" :: Text) -> pure PathAll
      "nothing" -> pure PathNothing
      "cohort" -> pure PathCohort
      "selectors" -> PathSelectors <$> parseSelectors value
      other -> fail ("unknown path effect " <> Text.unpack other)

instance ToJSON PathEffect where
  toJSON PathAll = object ["kind" .= ("all" :: Text)]
  toJSON PathNothing = object ["kind" .= ("nothing" :: Text)]
  toJSON PathCohort = object ["kind" .= ("cohort" :: Text)]
  toJSON (PathSelectors selectors) = object ["kind" .= ("selectors" :: Text), "selectors" .= fmap renderSelector selectors]

instance FromJSON ChangeImplies where parseJSON = withObject "ChangeImplies" \value -> ChangeImplies <$> value .: "minDimensionPolicy"

instance ToJSON ChangeImplies where toJSON value = object ["minDimensionPolicy" .= value.minDimensionPolicy]

instance FromJSON ComponentId where parseJSON = withText "ComponentId" (pure . ComponentId)

instance ToJSON ComponentId where toJSON = toJSON . unComponentId

instance FromJSON SubId where parseJSON = withText "SubId" (pure . SubId)

instance ToJSON SubId where toJSON = toJSON . unSubId

instance FromJSON EdgeKind where parseJSON = withText "EdgeKind" \case "build" -> pure Build; "runtime" -> pure Runtime; other -> fail ("unknown edge kind " <> Text.unpack other)

instance ToJSON EdgeKind where toJSON Build = String "build"; toJSON Runtime = String "runtime"

instance FromJSON ComponentKind where parseJSON = withText "ComponentKind" \case "library" -> pure Library; "migrations" -> pure Migrations; "service" -> pure Service; "harness" -> pure Harness; "assembly" -> pure Assembly; other -> fail ("unknown component kind " <> Text.unpack other)

instance ToJSON ComponentKind where toJSON Library = String "library"; toJSON Migrations = String "migrations"; toJSON Service = String "service"; toJSON Harness = String "harness"; toJSON Assembly = String "assembly"
