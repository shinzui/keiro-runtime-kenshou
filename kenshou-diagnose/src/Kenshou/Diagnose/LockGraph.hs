module Kenshou.Diagnose.LockGraph
  ( GraphNode (..),
    GraphEdge (..),
    LockGraph (..),
    buildGraph,
    renderDot,
    renderText,
  )
where

import Data.Aeson (FromJSON (..), ToJSON (..), object, withObject, (.!=), (.:), (.:?), (.=))
import Data.Graph (SCC (..), stronglyConnComp)
import Data.List (sort)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Kenshou.Diagnose.Postgres

data GraphNode = GraphNode {pid :: !Int, applicationName :: !Text, state :: !Text, waitEvent :: !(Maybe Text), transactionAgeSeconds :: !(Maybe Double), query :: !Text}
  deriving stock (Eq, Show)

data GraphEdge = GraphEdge {waiter :: !Int, blocker :: !Int, label :: !Text}
  deriving stock (Eq, Ord, Show)

data LockGraph = LockGraph {nodes :: ![GraphNode], edges :: ![GraphEdge], cycles :: ![[Int]], roots :: ![Int]}
  deriving stock (Eq, Show)

buildGraph :: [ActivityRow] -> [LockRow] -> LockGraph
buildGraph activity _locks = LockGraph nodes edges foundCycles foundRoots
  where
    nodes = [GraphNode row.pid row.applicationName row.state row.waitEvent row.transactionAgeSeconds row.query | row <- activity]
    edges = [GraphEdge row.pid blocker (maybe "lock" id row.waitEvent) | row <- activity, blocker <- row.blockedBy]
    foundCycles = cycleComponents activity
    waiters = Set.fromList (fmap (.waiter) edges)
    blockers = Set.fromList (fmap (.blocker) edges)
    foundRoots = sort (Set.toList (blockers `Set.difference` waiters))

cycleComponents :: [ActivityRow] -> [[Int]]
cycleComponents rows = sort [sort component | CyclicSCC component <- stronglyConnComp [(row.pid, row.pid, row.blockedBy) | row <- rows]]

renderDot :: LockGraph -> Text
renderDot graph = "digraph waits {\n" <> Text.concat (fmap nodeLine graph.nodes) <> Text.concat (fmap edgeLine graph.edges) <> "}\n"
  where
    nodeLine node = "  " <> shown node.pid <> " [label=\"" <> shown node.pid <> " " <> escape node.applicationName <> " " <> escape node.state <> "\"];\n"
    edgeLine edge = "  " <> shown edge.waiter <> " -> " <> shown edge.blocker <> " [label=\"" <> escape edge.label <> "\"];\n"
    shown = Text.pack . show
    escape = Text.replace "\"" "\\\""

renderText :: LockGraph -> Text
renderText graph = Text.unlines (fmap cycleLine graph.cycles <> fmap edgeLine graph.edges)
  where
    cycleLine pids = "cycle: " <> Text.intercalate " -> " (fmap (Text.pack . show) (pids <> take 1 pids))
    edgeLine edge = Text.pack (show edge.waiter) <> " waits for " <> Text.pack (show edge.blocker) <> " (" <> edge.label <> ")"

instance ToJSON GraphNode where toJSON node = object ["pid" .= node.pid, "applicationName" .= node.applicationName, "state" .= node.state, "waitEvent" .= node.waitEvent, "transactionAgeSeconds" .= node.transactionAgeSeconds, "query" .= node.query]

instance FromJSON GraphNode where parseJSON = withObject "GraphNode" \value -> GraphNode <$> value .: "pid" <*> value .:? "applicationName" .!= "" <*> value .:? "state" .!= "" <*> value .:? "waitEvent" <*> value .:? "transactionAgeSeconds" <*> value .:? "query" .!= ""

instance ToJSON GraphEdge where toJSON edge = object ["waiter" .= edge.waiter, "blocker" .= edge.blocker, "label" .= edge.label]

instance FromJSON GraphEdge where parseJSON = withObject "GraphEdge" \value -> GraphEdge <$> value .: "waiter" <*> value .: "blocker" <*> value .:? "label" .!= "lock"

instance ToJSON LockGraph where toJSON graph = object ["nodes" .= graph.nodes, "edges" .= graph.edges, "cycles" .= graph.cycles, "roots" .= graph.roots, "dot" .= renderDot graph]

instance FromJSON LockGraph where parseJSON = withObject "LockGraph" \value -> LockGraph <$> value .:? "nodes" .!= [] <*> value .:? "edges" .!= [] <*> value .:? "cycles" .!= [] <*> value .:? "roots" .!= []
