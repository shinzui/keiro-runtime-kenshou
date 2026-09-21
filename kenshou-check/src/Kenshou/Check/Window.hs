module Kenshou.Check.Window
  ( DisturbanceWindow (..),
    SkewBound (..),
    loadWindows,
    windowContains,
  )
where

import Data.Aeson (Value (..))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Int (Int64)
import Data.List (sortOn)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Kenshou.Check.Fact
import Kenshou.Check.Ledger.Read

data DisturbanceWindow = DisturbanceWindow
  { label :: !Text,
    target :: !Text,
    start :: !Int64,
    end :: !(Maybe Int64)
  }
  deriving stock (Eq, Show)

newtype SkewBound = SkewBound {micros :: Int64}
  deriving stock (Eq, Ord, Show)

loadWindows :: LedgerSet -> IO [DisturbanceWindow]
loadWindows ledger = do
  facts <- foldFacts ledger [] (\items fact -> pure (if fact.kind `elem` [DisturbanceStart, DisturbanceEnd] then fact : items else items))
  pure (assemble (sortOn (\fact -> (fact.wall, fact.n)) facts))
  where
    assemble = finish . foldl step (Map.empty, [])
    step (open, closed) fact =
      let label = attrText "label" fact.attrs fact.id
          target = attrText "target" fact.attrs fact.key
          key = (label, target)
       in case fact.kind of
            DisturbanceStart -> (Map.insert key fact.wall open, closed)
            DisturbanceEnd -> case Map.lookup key open of
              Nothing -> (open, closed)
              Just started -> (Map.delete key open, DisturbanceWindow label target started (Just fact.wall) : closed)
            _ -> (open, closed)
    finish (open, closed) = reverse closed <> [DisturbanceWindow label target started Nothing | ((label, target), started) <- Map.toAscList open]

windowContains :: SkewBound -> Int64 -> DisturbanceWindow -> Bool
windowContains (SkewBound skew) instant window = instant >= window.start - skew && maybe True (instant <=) ((+ skew) <$> window.end)

attrText :: Text -> KeyMap.KeyMap Value -> Text -> Text
attrText key attrs fallback = case KeyMap.lookup (Key.fromText key) attrs of Just (String value) -> value; _ -> fallback
