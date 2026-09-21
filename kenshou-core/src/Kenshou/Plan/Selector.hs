module Kenshou.Plan.Selector
  ( Selector,
    parseSelector,
    renderSelector,
    matches,
  )
where

import Data.Text (Text)
import Kenshou.Core.Id (ScenarioId)
import Kenshou.Core.Selector (ScenarioSelector)
import Kenshou.Core.Selector qualified as Core

type Selector = ScenarioSelector

parseSelector :: Text -> Either Text Selector
parseSelector = Core.parseSelector

renderSelector :: Selector -> Text
renderSelector = Core.renderSelector

matches :: Selector -> ScenarioId -> Bool
matches = Core.matchesSelector
