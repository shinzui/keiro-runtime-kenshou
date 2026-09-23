module Kenshou.Suite.Shibuya.Cohort
  ( CoreLine (..),
    coreLine,
    knownOnReleasedCore,
    rev,
  )
where

import Data.Either (isLeft)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text qualified as Text
import Kenshou.Core.Scenario (CohortScope (..), KnownDefect (..), PackageCondition (..))
import Shibuya.Policy (Concurrency (..), OrderingPolicy (..), validatePolicy)

data CoreLine = CoreReleased0903 | CoreLifecycleRemediated
  deriving stock (Eq, Show)

-- The pinned released core accepts Async 0; the pinned head rejects it.
coreLine :: CoreLine
coreLine
  | isLeft (validatePolicy Unordered (Async 0)) = CoreLifecycleRemediated
  | otherwise = CoreReleased0903

knownOnReleasedCore :: KnownDefect -> Maybe KnownDefect
knownOnReleasedCore defect = case coreLine of
  CoreReleased0903 -> Just defect
  CoreLifecycleRemediated -> Nothing

rev :: Int -> Text -> KnownDefect
rev review finding =
  KnownDefect
    { reference = "mori://shinzui/shibuya/okf/reviews/concepts/REV-" <> Text.pack (show review),
      summary = finding,
      expectedFailures = [finding],
      appliesTo = OnlyWhen (ResolvedFromHackage "shibuya-core" :| [])
    }
