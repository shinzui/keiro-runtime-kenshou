module Kenshou.Cli.Command.Cell (cellCommand) where

import Control.Exception (SomeAsyncException, SomeException, displayException, fromException, throwIO, try)
import Data.List.NonEmpty qualified as NonEmpty
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as TextIO
import Kenshou.Core.Cli (CliCommand (..), CliEnv, CliGroup (..))
import Kenshou.Core.Id (RunId, parseRunId, renderRunId)
import Kenshou.Remote.Cell.Docs (CellManifest (..))
import Kenshou.Remote.Cell.Fetch (FetchError (..), fetchCellRun, verifyCellRun)
import Kenshou.Remote.Cell.Index (deriveCellRunIndex, writeCellRunIndex)
import Kenshou.Remote.Store (Bucket (..), ObjectStore)
import Kenshou.Remote.Store.File (newFileStore)
import Kenshou.Remote.Store.Gcs (newGcsStore, newTokenProvider)
import Options.Applicative
import System.Directory (doesDirectoryExist)
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO (stderr)
import System.IO.Temp (withSystemTempDirectory)

data CellAction
  = Fetch !Text !Text !FilePath
  | Verify !FilePath

cellCommand :: CliCommand
cellCommand = CliCommand "cell" "Run and inspect leased verification cells" Execution False (runCell <$> cellParser)

cellParser :: Parser CellAction
cellParser =
  hsubparser $
    command "fetch" (info (fetchParser <**> helper) (progDesc "Fetch and verify one sealed cell run"))
      <> command "verify" (info (verifyParser <**> helper) (progDesc "Verify a fetched tree or a sealed GCS run"))

fetchParser :: Parser CellAction
fetchParser =
  Fetch
    <$> strOption (long "results-bucket" <> metavar "BUCKET" <> help "Results bucket containing the sealed run")
    <*> strArgument (metavar "CELL_RUN_ID")
    <*> strOption (long "out" <> metavar "DIR" <> help "Directory for the fetched cell run")

verifyParser :: Parser CellAction
verifyParser = Verify <$> strArgument (metavar "DIR_OR_GS_URI")

runCell :: CellAction -> CliEnv -> IO ExitCode
runCell selected _ = case selected of
  Fetch bucket identifier outDir -> case (validateBucket bucket, parseRunId identifier) of
    (Left problem, _) -> usage problem
    (_, Left problem) -> usage problem
    (Right resultsBucket, Right cellRun) -> guardIO $ do
      store <- openStore resultsBucket
      fetched <- fetchCellRun store resultsBucket cellRun outDir
      case fetched of
        Left problem -> fetchFailure problem
        Right tree -> do
          indexed <- deriveCellRunIndex resultsBucket Nothing tree
          case indexed of
            Left problems -> failVerification (Text.pack (show (NonEmpty.toList problems)))
            Right index -> do
              path <- writeCellRunIndex tree index
              TextIO.putStrLn (Text.pack path)
              pure ExitSuccess
  Verify location -> case Text.stripPrefix "gs://" (Text.pack location) of
    Nothing -> guardIO $ do
      let nested = location </> "tree"
      isRunDirectory <- doesDirectoryExist nested
      exists <- doesDirectoryExist location
      if exists then verifyTree (if isRunDirectory then nested else location) else unavailable "verification directory does not exist"
    Just suffix -> case parseResultsUri suffix of
      Left problem -> usage problem
      Right (bucket, identifier) -> guardIO $
        withSystemTempDirectory "kenshou-cell-verify" \temporary -> do
          store <- openStore bucket
          fetched <- fetchCellRun store bucket identifier temporary
          case fetched of
            Left problem -> fetchFailure problem
            Right tree -> verifyTree tree

verifyTree :: FilePath -> IO ExitCode
verifyTree tree = do
  verified <- verifyCellRun tree
  case verified of
    Left problems -> failVerification (Text.pack (show (NonEmpty.toList problems)))
    Right manifest -> TextIO.putStrLn ("verified " <> renderRunId manifest.runId) >> pure ExitSuccess

openStore :: Bucket -> IO ObjectStore
openStore bucket = do
  selected <- lookupEnv "KENSHOU_CELL_STORE"
  case selected of
    Nothing -> newTokenProvider bucket >>= newGcsStore
    Just setting -> case Text.stripPrefix "file:" (Text.pack setting) of
      Just root | not (Text.null root) -> newFileStore (Text.unpack root)
      _ -> ioError (userError "KENSHOU_CELL_STORE must be file:<dir> or unset for GCS")

parseResultsUri :: Text -> Either Text (Bucket, RunId)
parseResultsUri suffix = case Text.splitOn "/" suffix of
  [bucket, "runs", identifier] -> do
    checked <- validateBucket bucket
    parsed <- parseRunId identifier
    pure (checked, parsed)
  _ -> Left "expected gs://BUCKET/runs/CELL_RUN_ID"

validateBucket :: Text -> Either Text Bucket
validateBucket bucket
  | Text.null bucket || Text.any (\character -> not (character `elem` (['a' .. 'z'] <> ['A' .. 'Z'] <> ['0' .. '9'] <> "-_."))) bucket = Left "invalid results bucket"
  | otherwise = Right (Bucket bucket)

guardIO :: IO ExitCode -> IO ExitCode
guardIO operation = do
  result <- try operation :: IO (Either SomeException ExitCode)
  case result of
    Left failure | Just async <- (fromException failure :: Maybe SomeAsyncException) -> throwIO async
    Left failure -> unavailable (Text.pack (displayException failure))
    Right code -> pure code

fetchFailure :: FetchError -> IO ExitCode
fetchFailure problem = case problem of
  Unsealed -> unavailable "cell run is not sealed"
  ObjectChanged _ -> unavailable (Text.pack (show problem))
  _ -> failVerification (Text.pack (show problem))

unavailable :: Text -> IO ExitCode
unavailable problem = TextIO.hPutStrLn stderr ("kenshou cell: " <> problem) >> pure (ExitFailure 4)

failVerification :: Text -> IO ExitCode
failVerification problem = TextIO.hPutStrLn stderr ("kenshou cell: " <> problem) >> pure (ExitFailure 1)

usage :: Text -> IO ExitCode
usage problem = TextIO.hPutStrLn stderr ("kenshou cell: " <> problem) >> pure (ExitFailure 2)
