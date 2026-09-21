module Kenshou.Measure.Cli
  ( compareCommand,
    summarizeCommand,
  )
where

import Data.Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy qualified as LazyByteString
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as Text
import Kenshou.Core.Cli
import Kenshou.Measure.Compare
import Kenshou.Measure.Compare.Compatibility
import Kenshou.Measure.Compare.Policy
import Kenshou.Measure.Metrics
import Kenshou.Measure.Stats
import Kenshou.Measure.Summary
import Options.Applicative
import System.Exit (ExitCode (..))
import System.IO (stderr)

data SummarizeOptions = SummarizeOptions {runDir :: FilePath, json :: Bool, verify :: Bool}

data CompareOptions = CompareOptions
  { baselines :: [FilePath],
    candidates :: [FilePath],
    policySource :: InputSource,
    vary :: [Text],
    output :: Maybe FilePath,
    json :: Bool
  }

summarizeCommand :: CliCommand
summarizeCommand = CliCommand "summarize" "Recompute and verify run measurements" Analysis False (runSummarize <$> summarizeParser)

compareCommand :: CliCommand
compareCommand = CliCommand "compare" "Compare paired baseline and candidate runs" Analysis False (runCompare <$> compareParser)

summarizeParser :: Parser SummarizeOptions
summarizeParser =
  SummarizeOptions
    <$> strArgument (metavar "RUN_DIR" <> help "Completed run directory")
    <*> switch (long "json" <> help "Write JSON to standard output")
    <*> switch (long "verify" <> help "Compare recomputed figures with run-result.json")

compareParser :: Parser CompareOptions
compareParser =
  CompareOptions
    <$> some (strOption (long "baseline" <> metavar "DIR" <> help "Baseline run directory; repeat once per pair"))
    <*> some (strOption (long "candidate" <> metavar "DIR" <> help "Candidate run directory; repeat once per pair"))
    <*> (parseInputSource <$> strOption (long "policy" <> metavar "FILE" <> help "Comparison policy file, or - for stdin"))
    <*> many (Text.pack <$> strOption (long "vary" <> metavar "AXIS" <> help "Allowed varying axis: cohort, dim:NAME, or knob:NAME"))
    <*> optional (strOption (long "out" <> metavar "FILE" <> help "Write the comparison JSON document"))
    <*> switch (long "json" <> help "Write JSON to standard output")

runSummarize :: SummarizeOptions -> CliEnv -> IO ExitCode
runSummarize options _ = do
  result <- summarizeRunDir options.runDir
  case result of
    Left (SummaryError message) -> Text.hPutStrLn stderr ("kenshou summarize: " <> message) >> pure (ExitFailure 4)
    Right summary -> do
      let document = toJSON summary
      if options.json then LazyByteString.putStr (encode document <> "\n") else renderSummary summary
      if not options.verify then pure ExitSuccess else verifyStored options.runDir document

verifyStored :: FilePath -> Value -> IO ExitCode
verifyStored runDir recomputed = do
  decoded <- eitherDecodeFileStrict' (runDir <> "/run-result.json") :: IO (Either String Value)
  case decoded of
    Left message -> Text.hPutStrLn stderr ("kenshou summarize: " <> Text.pack message) >> pure (ExitFailure 4)
    Right result -> case storedMeasurements result of
      Nothing -> Text.hPutStrLn stderr "kenshou summarize: run-result.json has no stored measurements" >> pure (ExitFailure 1)
      Just stored | stored == recomputed -> pure ExitSuccess
      Just _ -> Text.hPutStrLn stderr "kenshou summarize: stored measurements differ from recomputed measurements" >> pure (ExitFailure 1)

storedMeasurements :: Value -> Maybe Value
storedMeasurements (Object root) = do
  Object summaries <- KeyMap.lookup "summaries" root
  Object measurements <- KeyMap.lookup "measurements" summaries
  KeyMap.lookup "measurements" measurements
storedMeasurements _ = Nothing

runCompare :: CompareOptions -> CliEnv -> IO ExitCode
runCompare options _ = do
  policyBytes <- readInputSource options.policySource
  case decodePolicy policyBytes of
    Left message -> Text.hPutStrLn stderr ("kenshou compare: " <> message) >> pure (ExitFailure 2)
    Right policy -> case traverse parseVaryingAxis (if null options.vary then ["cohort"] else options.vary) of
      Left message -> Text.hPutStrLn stderr ("kenshou compare: " <> message) >> pure (ExitFailure 2)
      Right [] -> pure (ExitFailure 2)
      Right (axis : axes) -> do
        result <- compareRuns policy (axis :| axes) options.baselines options.candidates
        case result of
          Left (CompareError message) -> Text.hPutStrLn stderr ("kenshou compare: " <> message) >> pure (ExitFailure 2)
          Right comparison -> do
            let bytes = encode comparison
            maybe (pure ()) (\path -> LazyByteString.writeFile path (bytes <> "\n")) options.output
            if options.json then LazyByteString.putStr (bytes <> "\n") else renderComparison comparison
            pure case verdictExitCode comparison.verdict of 0 -> ExitSuccess; code -> ExitFailure code

renderSummary :: MeasurementSummary -> IO ()
renderSummary summary = do
  Text.putStrLn ("grade: " <> summary.grade)
  mapM_ (\(name, metric) -> Text.putStrLn (name <> ": " <> Text.pack (show metric.value) <> " " <> metric.unit)) (toList summary.metrics)

renderComparison :: Comparison -> IO ()
renderComparison comparison = do
  Text.putStrLn ("comparison " <> comparison.comparisonId <> "  verdict: " <> verdictName comparison.verdict)
  mapM_ (\(_, metric) -> Text.putStrLn (metric.metric <> "  " <> statusName metric.status <> "  ratio=" <> Text.pack (show metric.ratio.estimate))) (toList comparison.metrics)
  mapM_ (Text.putStrLn . ("reason: " <>)) comparison.reasons

verdictName :: Verdict -> Text
verdictName VerdictPass = "pass"
verdictName VerdictRegression = "regression"
verdictName VerdictInconclusive = "inconclusive"
verdictName VerdictInfrastructureFailure = "infrastructure-failure"

statusName :: MetricStatus -> Text
statusName MetricPass = "pass"
statusName MetricRegression = "regression"
statusName MetricInconclusive = "inconclusive"

toList :: Map key value -> [(key, value)]
toList = Map.toList
