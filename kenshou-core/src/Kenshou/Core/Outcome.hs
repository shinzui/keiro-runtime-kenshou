module Kenshou.Core.Outcome
  ( Outcome (..),
    renderOutcome,
    parseOutcome,
    outcomeExitCode,
    usageExitCode,
    worstOutcome,
  )
where

import Data.Aeson (FromJSON (..), ToJSON (..), withText)
import Data.List (maximumBy)
import Data.List.NonEmpty (NonEmpty)
import Data.List.NonEmpty qualified as NonEmpty
import Data.Text (Text)
import Data.Text qualified as Text

data Outcome = Passed | Failed | Errored | Inconclusive | InfrastructureFailure
  deriving stock (Eq, Show, Enum, Bounded)

renderOutcome :: Outcome -> Text
renderOutcome Passed = "passed"
renderOutcome Failed = "failed"
renderOutcome Errored = "errored"
renderOutcome Inconclusive = "inconclusive"
renderOutcome InfrastructureFailure = "infrastructure-failure"

parseOutcome :: Text -> Either Text Outcome
parseOutcome value = maybe (Left ("unknown outcome \"" <> value <> "\"")) Right (lookup value pairs)
  where
    pairs = [(renderOutcome item, item) | item <- [minBound .. maxBound]]

outcomeExitCode :: Outcome -> Int
outcomeExitCode Passed = 0
outcomeExitCode Failed = 1
outcomeExitCode Inconclusive = 3
outcomeExitCode Errored = 4
outcomeExitCode InfrastructureFailure = 4

usageExitCode :: Int
usageExitCode = 2

worstOutcome :: NonEmpty Outcome -> Outcome
worstOutcome = maximumBy (compare `onRank` rank) . NonEmpty.toList
  where
    onRank comparator project left right = comparator (project left) (project right)
    rank Passed = 0 :: Int
    rank Inconclusive = 1
    rank InfrastructureFailure = 2
    rank Errored = 3
    rank Failed = 4

instance ToJSON Outcome where toJSON = toJSON . renderOutcome

instance FromJSON Outcome where parseJSON = withText "Outcome" (either (fail . Text.unpack) pure . parseOutcome)
