module Kenshou.Suite.Keiro.Workflow.Definitions
  ( DefinitionParams (..),
    defaultDefinitionParams,
    linearName,
    linearRegistry,
    linearWorkflow,
    expectedLinearSteps,
    expectedLinearResult,
  )
where

import Control.Monad (forM)
import Data.Aeson (object, (.=))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Effectful (Eff, IOE, liftIO, (:>))
import Effectful.Error.Static (Error)
import Keiro.Workflow (StepName (..), Workflow, WorkflowId (..), WorkflowName, mkWorkflowName, step)
import Keiro.Workflow.Resume (WorkflowDef (..), WorkflowRegistry)
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
