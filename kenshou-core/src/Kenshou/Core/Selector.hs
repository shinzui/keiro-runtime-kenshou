module Kenshou.Core.Selector
  ( ScenarioSelector,
    parseSelector,
    matchesSelector,
  )
where

import Data.Text (Text)
import Data.Text qualified as Text
import Kenshou.Core.Id (ScenarioId, renderScenarioId)

newtype ScenarioSelector = ScenarioSelector [Text]
  deriving stock (Eq, Show)

parseSelector :: Text -> Either Text ScenarioSelector
parseSelector value
  | null pieces = Left "selector is empty"
  | "**" `elem` initSafe pieces = Left "** is permitted only as the final segment"
  | length pieces < 4 && last pieces /= "**" = Left "short selectors must end in **"
  | length pieces > 4 = Left "selector has more than four segments"
  | any invalid pieces = Left ("invalid selector \"" <> value <> "\"")
  | otherwise = Right (ScenarioSelector pieces)
  where
    pieces = Text.splitOn "/" value
    initSafe [] = []
    initSafe xs = init xs
    invalid piece = Text.null piece || (piece /= "*" && piece /= "**" && Text.any (== '*') piece)

matchesSelector :: ScenarioSelector -> ScenarioId -> Bool
matchesSelector (ScenarioSelector patterns) scenario = go patterns (Text.splitOn "/" (renderScenarioId scenario))
  where
    go ["**"] _ = True
    go [] [] = True
    go (patternPart : restPatterns) (actual : restActual) =
      (patternPart == "*" || patternPart == actual) && go restPatterns restActual
    go _ _ = False
