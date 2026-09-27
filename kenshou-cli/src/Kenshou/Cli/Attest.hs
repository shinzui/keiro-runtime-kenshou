module Kenshou.Cli.Attest (measurementRecomputer, pairedComparisonRecomputer) where

import Control.Monad (forM)
import Data.Aeson (Result (..), Value (..), eitherDecodeFileStrict', fromJSON, toJSON)
import Data.Aeson.KeyMap qualified as KeyMap
import Data.List.NonEmpty qualified as NonEmpty
import Data.Text (Text)
import Data.Text qualified as Text
import Kenshou.Evidence.Attest (Recomputation (..), Recomputer (..))
import Kenshou.Measure.Compare (CompareError (..), compareRuns)
import Kenshou.Measure.Compare.Compatibility (VaryingAxis, parseVaryingAxis)
import Kenshou.Measure.Compare.Policy (Policy)
import Kenshou.Measure.Summary (SummaryError (..), summarizeRunDir)
import System.FilePath ((</>))

measurementRecomputer :: Recomputer
measurementRecomputer = Recomputer "kenshou-summary" 1 $ \root -> do
  measured <- summarizeRunDir root
  case measured of
    Left (SummaryError message) -> pure (Left message)
    Right summary -> do
      stored <- eitherDecodeFileStrict' (root </> "run-result.json") :: IO (Either String Value)
      pure case stored of
        Left message -> Left (Text.pack message)
        Right document ->
          Right
            Recomputation
              { agreesWithDocuments = storedMeasurements document == Just (toJSON summary),
                outcome = Nothing,
                comparisonVerdict = Nothing,
                detail = "recomputed kenshou.measurements/v1 from the sealed samples and series"
              }

storedMeasurements :: Value -> Maybe Value
storedMeasurements (Object result) = do
  Object summaries <- KeyMap.lookup "summaries" result
  Object measurements <- KeyMap.lookup "measurements" summaries
  KeyMap.lookup "measurements" measurements
storedMeasurements _ = Nothing

pairedComparisonRecomputer :: Recomputer
pairedComparisonRecomputer = Recomputer "paired-bootstrap-t-envelope" 1 $ \root -> do
  stored <- eitherDecodeFileStrict' (root </> "comparison.json") :: IO (Either String Value)
  case stored of
    Left message -> pure (Left (Text.pack message))
    Right document -> case comparisonInputs document of
      Left message -> pure (Left message)
      Right (policy, axes, pairs) -> do
        let baselines = [root </> "baseline" </> show index | index <- [0 .. pairs - 1]]
            candidates = [root </> "candidate" </> show index | index <- [0 .. pairs - 1]]
        verified <- forM (baselines <> candidates) $ \path -> do
          measured <- summarizeRunDir path
          result <- eitherDecodeFileStrict' (path </> "run-result.json") :: IO (Either String Value)
          pure case (measured, result) of
            (Right summary, Right value) | storedMeasurements value == Just (toJSON summary) -> Right ()
            (Left (SummaryError message), _) -> Left message
            (_, Left message) -> Left (Text.pack message)
            _ -> Left "arm measurements differ from the sealed samples and series"
        case sequence verified of
          Left message -> pure (Left message)
          Right _ -> do
            replayed <- compareRuns policy axes baselines candidates
            pure case replayed of
              Left (CompareError message) -> Left message
              Right comparison ->
                let actual = toJSON comparison
                    stableKeys = ["design", "baselineRuns", "candidateRuns", "algorithm", "policy", "variedFactors", "pairCount", "metrics", "reasons", "verdict", "exitCode"]
                    agrees = all (\key -> field key actual == field key document) stableKeys
                 in Right
                      Recomputation
                        { agreesWithDocuments = agrees,
                          outcome = Nothing,
                          comparisonVerdict = case field "verdict" actual of Just (String verdict) -> Just verdict; _ -> Nothing,
                          detail = "recomputed arm summaries and the paired comparison from sealed data"
                        }
  where
    field name (Object value) = KeyMap.lookup name value
    field _ _ = Nothing

comparisonInputs :: Value -> Either Text (Policy, NonEmpty.NonEmpty VaryingAxis, Int)
comparisonInputs (Object document) = do
  rawPolicy <- maybe (Left "comparison has no policy") Right (KeyMap.lookup "policy" document)
  policy <- case fromJSON rawPolicy of
    Error message -> Left (Text.pack message)
    Success value -> Right value
  rawAxes <- maybe (Left "comparison has no varied factors") Right (KeyMap.lookup "variedFactors" document)
  axisNames <- case fromJSON rawAxes of
    Error message -> Left (Text.pack message)
    Success value -> Right value
  axes <- traverse parseVaryingAxis axisNames >>= maybe (Left "comparison has no varied factors") Right . NonEmpty.nonEmpty
  rawPairs <- maybe (Left "comparison has no pair count") Right (KeyMap.lookup "pairCount" document)
  pairs <- case fromJSON rawPairs of
    Error message -> Left (Text.pack message)
    Success value -> Right value
  if pairs > 0 then Right (policy, axes, pairs) else Left "comparison pair count must be positive"
comparisonInputs _ = Left "comparison document is not an object"
