module Kenshou.Cli.Attest (measurementRecomputer) where

import Data.Aeson (Value (..), eitherDecodeFileStrict', toJSON)
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Text qualified as Text
import Kenshou.Evidence.Attest (Recomputation (..), Recomputer (..))
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
