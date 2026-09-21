{-# LANGUAGE FieldSelectors #-}

module Kenshou.Cli.Cohort
  ( runCohortCommand,
  )
where

import Control.Applicative ((<|>))
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy.Char8 qualified as LazyByteString
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as Text.IO
import Kenshou.Cli.Options (CohortCommand (..))
import Kenshou.Core.Cohort
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO (stderr)

runCohortCommand :: CohortCommand -> IO ExitCode
runCohortCommand (CohortShow json projectDir planJson identityOption) = do
  identityEnvironment <- lookupEnv "KENSHOU_COHORT_IDENTITY"
  let source =
        maybe
          (FromProject projectDir planJson Nothing)
          FromIdentityFile
          (identityOption <|> identityEnvironment)
  result <- resolveCohortIdentity source
  case result of
    Left err -> reportError err
    Right identity -> do
      if json
        then LazyByteString.putStrLn (Aeson.encode identity)
        else Text.IO.putStr (renderCohortIdentity identity)
      pure ExitSuccess
runCohortCommand (CohortCheck projectDir planJson descriptorOverride) = do
  descriptorResult <- loadActiveDescriptor projectDir descriptorOverride
  identityResult <- resolveCohortIdentity (FromProject projectDir planJson descriptorOverride)
  case (descriptorResult, identityResult) of
    (Left err, _) -> reportError err
    (_, Left err) -> reportError err
    (Right descriptor, Right identity) ->
      case checkCohort descriptor identity of
        [] -> pure ExitSuccess
        mismatches -> do
          mapM_ (Text.IO.hPutStrLn stderr . renderMismatch) mismatches
          pure (ExitFailure 1)

loadActiveDescriptor :: FilePath -> Maybe FilePath -> IO (Either CohortError CohortDescriptor)
loadActiveDescriptor _ (Just path) = loadCohortDescriptor path
loadActiveDescriptor projectDir Nothing = do
  nameResult <- activeCohortName projectDir
  case nameResult of
    Left err -> pure (Left err)
    Right (CohortName name) -> loadCohortDescriptor (projectDir </> "cohort" </> Text.unpack name <> ".json")

reportError :: CohortError -> IO ExitCode
reportError err = do
  Text.IO.hPutStrLn stderr (renderError err)
  pure (ExitFailure 4)

renderError :: CohortError -> Text
renderError (CohortIoError message)
  | "dist-newstyle/cache/plan.json" `Text.isInfixOf` message = "no dist-newstyle/cache/plan.json; run cabal build all first"
  | otherwise = message
renderError (CohortDecodeError message) = message
renderError (CohortPlanError message) = message
renderError (CohortInvalidActive message) = message

renderMismatch :: CohortMismatch -> Text
renderMismatch (MissingPackage packageName) = "missing package: " <> packageName
renderMismatch (VersionMismatch packageName expected actual) =
  packageName <> ": expected version " <> expected <> ", resolved " <> actual
renderMismatch (SourceMismatch packageName expected actual) =
  packageName <> ": expected source " <> Text.pack (show expected) <> ", resolved " <> Text.pack (show actual)
renderMismatch (LocalPathSource packageName path) = packageName <> ": resolved from forbidden local path " <> Text.pack path
