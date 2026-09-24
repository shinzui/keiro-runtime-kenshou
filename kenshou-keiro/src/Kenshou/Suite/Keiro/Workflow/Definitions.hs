module Kenshou.Suite.Keiro.Workflow.Definitions
  ( DefinitionParams (..),
    defaultDefinitionParams,
    linearName,
    linearRegistry,
    linearWorkflow,
    expectedLinearSteps,
    expectedLinearResult,
    sleeperName,
    ordinalSleeperName,
    rotatedSleeperName,
    sleeperWorkflow,
    sleeperWorkflowWithDelay,
    rotatedSleeperWorkflow,
    sleeperRegistry,
    approvalName,
    approvalWorkflow,
    approvalRegistry,
    rotatingApprovalName,
    rotatingApprovalWorkflow,
    patchedName,
    patchedWorkflow,
    childName,
    parentName,
    childWorkflow,
    parentWorkflow,
    childRegistry,
    rotatedParentName,
    rotatedParentWorkflow,
    discoveryParentName,
    discoveryParentWorkflow,
    flakyName,
    flakyWorkflow,
    flakyRegistry,
  )
where

import Control.Exception (throwIO)
import Control.Monad (forM)
import Data.Aeson (object, (.=))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (NominalDiffTime)
import Effectful (Eff, IOE, liftIO, (:>))
import Effectful.Error.Static (Error)
import Keiro.Workflow (PatchId (..), StepName (..), Workflow, WorkflowId (..), WorkflowName, continueAsNew, mkWorkflowName, patch, restoreSeed, step)
import Keiro.Workflow.Awakeable (awakeableIdText, awakeableNamed)
import Keiro.Workflow.Child (awaitChild, spawnChild)
import Keiro.Workflow.Resume (WorkflowDef (..), WorkflowRegistry)
import Keiro.Workflow.Sleep (sleep, sleepNamed)
import Kenshou.Suite.Keiro.Workflow.Effects (BoundaryPoint (..), EffectFact (..), EffectSink (..))
import Kiroku.Store (Store)
import Kiroku.Store.Error (StoreError)

data DefinitionParams = DefinitionParams
  { seed :: !Int,
    steps :: !Int
  }
  deriving stock (Eq, Show)

defaultDefinitionParams :: DefinitionParams
defaultDefinitionParams = DefinitionParams 1 8

linearName :: WorkflowName
linearName = either (error . show) id (mkWorkflowName "kenshouLinear")

-- | The expected result is independent of execution order and survives a replay.
expectedLinearResult :: DefinitionParams -> WorkflowId -> Int
expectedLinearResult params wid = sum [linearValue params wid n | n <- [0 .. params.steps - 1]]

expectedLinearSteps :: DefinitionParams -> [Text]
expectedLinearSteps params = ["s" <> Text.pack (show n) | n <- [0 .. params.steps - 1]]

linearValue :: DefinitionParams -> WorkflowId -> Int -> Int
linearValue params (WorkflowId wid) n = params.seed + Text.length wid * 31 + n

linearWorkflow :: (IOE :> es) => EffectSink -> DefinitionParams -> WorkflowId -> Eff (Workflow : es) Int
linearWorkflow sink params wid = do
  results <- forM (zip [0 ..] (expectedLinearSteps params)) \(index, name) ->
    step (StepName name) do
      let value = linearValue params wid index
      liftIO $ sink.recordEffect (EffectFact "step" (unWorkflowId wid <> "/0/" <> name) "workflow" (object ["result" .= value]))
      liftIO $ sink.boundary (AfterStepAction name)
      pure value
  pure (sum results)

linearRegistry :: EffectSink -> DefinitionParams -> WorkflowRegistry '[Store, Error StoreError, IOE]
linearRegistry sink params = Map.singleton linearName (WorkflowDef (linearWorkflow sink params))

sleeperName :: WorkflowName
sleeperName = either (error . show) id (mkWorkflowName "kenshouSleeper")

ordinalSleeperName :: WorkflowName
ordinalSleeperName = either (error . show) id (mkWorkflowName "kenshouOrdinalSleeper")

rotatedSleeperName :: WorkflowName
rotatedSleeperName = either (error . show) id (mkWorkflowName "kenshouRotatedSleeper")

-- | The named form is safe across a code reorder; the ordinal form exposes
-- its positional step key for the corresponding compatibility probe.
sleeperWorkflow :: (IOE :> es, Store :> es) => EffectSink -> Bool -> WorkflowId -> Eff (Workflow : es) Int
sleeperWorkflow sink named = sleeperWorkflowWithDelay sink named 0.2

sleeperWorkflowWithDelay :: (IOE :> es, Store :> es) => EffectSink -> Bool -> NominalDiffTime -> WorkflowId -> Eff (Workflow : es) Int
sleeperWorkflowWithDelay sink named delay wid = do
  before <- step (StepName "before") $ do
    liftIO $ sink.recordEffect (EffectFact "step" (unWorkflowId wid <> "/0/before") "workflow" (object []))
    pure (1 :: Int)
  if named then sleepNamed (StepName "nap") delay else sleep delay
  after <- step (StepName "after") $ do
    liftIO $ sink.recordEffect (EffectFact "step" (unWorkflowId wid <> "/0/after") "workflow" (object []))
    pure (2 :: Int)
  pure (before + after)

rotatedSleeperWorkflow :: (IOE :> es, Store :> es) => WorkflowId -> Eff (Workflow : es) Int
rotatedSleeperWorkflow _ = do
  generation <- restoreSeed (0 :: Int)
  if generation == 0
    then continueAsNew (1 :: Int)
    else sleepNamed (StepName "nap") 0.2 >> pure generation

sleeperRegistry :: EffectSink -> WorkflowRegistry '[Store, Error StoreError, IOE]
sleeperRegistry sink =
  Map.fromList
    [ (sleeperName, WorkflowDef (sleeperWorkflow sink True)),
      (ordinalSleeperName, WorkflowDef (sleeperWorkflow sink False))
    ]

approvalName :: WorkflowName
approvalName = either (error . show) id (mkWorkflowName "kenshouApproval")

-- | Publish the journaled opaque id as its own step, then wait for a durable
-- signal. The effect ledger is the external recipient in this fixture.
approvalWorkflow :: (IOE :> es, Store :> es) => EffectSink -> WorkflowId -> Eff (Workflow : es) Text
approvalWorkflow sink wid = do
  (aid, await) <- awakeableNamed (StepName "approval")
  _ <- step (StepName "publish") do
    liftIO $ sink.recordEffect (EffectFact "arm" (unWorkflowId wid <> "/approval") "workflow" (object ["awakeableId" .= aid]))
    pure ()
  answer <- await
  step (StepName "accepted") do
    liftIO $ sink.recordEffect (EffectFact "step" (unWorkflowId wid <> "/accepted") "workflow" (object ["awakeableId" .= awakeableIdText aid]))
    pure answer

approvalRegistry :: EffectSink -> WorkflowRegistry '[Store, Error StoreError, IOE]
approvalRegistry sink = Map.singleton approvalName (WorkflowDef (approvalWorkflow sink))

rotatingApprovalName :: WorkflowName
rotatingApprovalName = either (error . show) id (mkWorkflowName "kenshouRotatingApproval")

-- | Generation zero publishes an id and rotates without awaiting it. The
-- next generation must allocate a different id under the same label.
rotatingApprovalWorkflow :: (IOE :> es, Store :> es) => EffectSink -> WorkflowId -> Eff (Workflow : es) Text
rotatingApprovalWorkflow sink wid = do
  generation <- restoreSeed (0 :: Int)
  (aid, await) <- awakeableNamed (StepName "approval")
  _ <- step (StepName "publish") do
    liftIO $ sink.recordEffect (EffectFact "arm" (unWorkflowId wid <> "/" <> Text.pack (show generation) <> "/approval") "workflow" (object ["awakeableId" .= aid, "generation" .= generation]))
    pure ()
  if generation == 0
    then continueAsNew (1 :: Int)
    else await

patchedName :: WorkflowName
patchedName = either (error . show) id (mkWorkflowName "kenshouPatched")

-- | A gate lets one generation begin before a patch is deployed. A fresh
-- instance can omit it so competing deployments race on the first decision.
patchedWorkflow :: (IOE :> es, Store :> es) => EffectSink -> Bool -> WorkflowId -> Eff (Workflow : es) Text
patchedWorkflow sink gated wid = do
  _ <- step (StepName "start") (pure ())
  if gated
    then do
      (aid, await) <- awakeableNamed (StepName "gate")
      _ <- step (StepName "publishGate") do
        liftIO $ sink.recordEffect (EffectFact "arm" (unWorkflowId wid <> "/gate") "workflow" (object ["awakeableId" .= aid]))
        pure ()
      (_ :: Text) <- await
      pure ()
    else pure ()
  enabled <- patch (PatchId "p1")
  let branch = if enabled then "new" else "old"
  step (StepName branch) do
    liftIO $ sink.recordEffect (EffectFact "step" (unWorkflowId wid <> "/" <> branch) "workflow" (object []))
    pure branch

childName :: WorkflowName
childName = either (error . show) id (mkWorkflowName "kenshouChild")

parentName :: WorkflowName
parentName = either (error . show) id (mkWorkflowName "kenshouParent")

childWorkflow :: (IOE :> es) => EffectSink -> WorkflowId -> Eff (Workflow : es) Int
childWorkflow sink wid = step (StepName "work") do
  liftIO $ sink.recordEffect (EffectFact "step" (unWorkflowId wid <> "/work") "workflow" (object []))
  if "child-fail" `Text.isPrefixOf` unWorkflowId wid
    then liftIO (throwIO (userError "deliberate child failure"))
    else pure ()
  pure 42

parentWorkflow :: (IOE :> es, Store :> es) => EffectSink -> WorkflowId -> Eff (Workflow : es) Int
parentWorkflow sink wid = do
  let childId = WorkflowId (unWorkflowId wid <> "-child")
  handle <- spawnChild childName childId (childWorkflow sink childId)
  answer <- awaitChild handle
  step (StepName "after") do
    liftIO $ sink.recordEffect (EffectFact "step" (unWorkflowId wid <> "/after") "workflow" (object []))
    pure (answer + 1)

childRegistry :: EffectSink -> WorkflowRegistry '[Store, Error StoreError, IOE]
childRegistry sink =
  Map.fromList
    [ (childName, WorkflowDef (childWorkflow sink)),
      (parentName, WorkflowDef (parentWorkflow sink))
    ]

rotatedParentName :: WorkflowName
rotatedParentName = either (error . show) id (mkWorkflowName "kenshouRotatedParent")

-- | Generation zero registers the child before rotating. Completion then
-- lands on generation one, where spawning the same id reattaches to it.
rotatedParentWorkflow :: (IOE :> es, Store :> es) => EffectSink -> WorkflowId -> Eff (Workflow : es) Int
rotatedParentWorkflow sink wid = do
  generation <- restoreSeed (0 :: Int)
  let childId = WorkflowId (unWorkflowId wid <> "-child")
  handle <- spawnChild childName childId (childWorkflow sink childId)
  if generation == 0
    then continueAsNew (1 :: Int)
    else (+ 1) <$> awaitChild handle

discoveryParentName :: WorkflowName
discoveryParentName = either (error . show) id (mkWorkflowName "kenshouDiscoveryParent")

discoveryParentWorkflow :: (IOE :> es, Store :> es) => EffectSink -> WorkflowId -> Eff (Workflow : es) Int
discoveryParentWorkflow sink wid = do
  let childId = WorkflowId (unWorkflowId wid <> "-child")
  handle <- spawnChild sleeperName childId (sleeperWorkflowWithDelay sink True 60 childId)
  awaitChild handle

flakyName :: WorkflowName
flakyName = either (error . show) id (mkWorkflowName "kenshouFlaky")

flakyWorkflow :: (IOE :> es) => EffectSink -> Bool -> WorkflowId -> Eff (Workflow : es) Int
flakyWorkflow sink repaired wid = step (StepName "boom") do
  liftIO $ sink.recordEffect (EffectFact "flaky" (unWorkflowId wid <> "/0/boom") "workflow" (object []))
  if repaired
    then pure 42
    else liftIO (throwIO (userError "deliberate flaky step failure"))

flakyRegistry :: EffectSink -> Bool -> WorkflowRegistry '[Store, Error StoreError, IOE]
flakyRegistry sink repaired = Map.singleton flakyName (WorkflowDef (flakyWorkflow sink repaired))
