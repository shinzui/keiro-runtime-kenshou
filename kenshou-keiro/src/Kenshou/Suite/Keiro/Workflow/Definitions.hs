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
    rotatedSleeperWorkflow,
    sleeperRegistry,
  )
where

import Control.Monad (forM)
import Data.Aeson (object, (.=))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Effectful (Eff, IOE, liftIO, (:>))
import Effectful.Error.Static (Error)
import Keiro.Workflow (StepName (..), Workflow, WorkflowId (..), WorkflowName, continueAsNew, mkWorkflowName, restoreSeed, step)
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
sleeperWorkflow sink named wid = do
  before <- step (StepName "before") $ do
    liftIO $ sink.recordEffect (EffectFact "step" (unWorkflowId wid <> "/0/before") "workflow" (object []))
    pure (1 :: Int)
  if named then sleepNamed (StepName "nap") 0.2 else sleep 0.2
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
