module Kenshou.Evidence.Bundle
  ( BundleWriteError (..),
    BundleWriteResult (..),
    runRecordPath,
    writeRunRecord,
    writeRunRecordWith,
  )
where

import Control.Exception (IOException, try)
import Data.ByteString qualified as ByteString
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.Text.IO qualified as Text.IO
import Data.Time (UTCTime, defaultTimeLocale, formatTime, parseTimeM)
import Kenshou.Core.Id (ScenarioId (..), parseRunId, renderLayer, renderScenarioId)
import Kenshou.Core.Outcome (renderOutcome)
import Kenshou.Evidence.Frontmatter (EvidenceRecord (..), recordToDocument)
import Okf.Bundle (walkBundle, walkBundleInventory, walkLogs)
import Okf.Document (OKFDocument (..), parseDocument, removeField, serializeDocument)
import Okf.Index (readBundleVersion, writeBundleIndexes)
import Okf.Log (Log (..), LogEntry (..), appendLogEntry, parseLog, serializeLog)
import Okf.Profile (compileProfile, loadProfileFile, validateProfileWith)
import Okf.Validation (ValidationProfile (StrictAuthoring), validateBundle, validateBundleLogs)
import System.Directory (createDirectoryIfMissing, doesFileExist, removeFile)
import System.FilePath (takeDirectory, (</>))
import System.IO (hFlush)
import System.IO.Error (isAlreadyExistsError)
import System.IO.Temp (withTempFile)
import System.Posix.Files (createLink)

data BundleWriteError
  = InvalidRecordIdentity !Text
  | RecordConflict !FilePath
  | BundleInvalid !Text
  | BundleIo !Text
  deriving stock (Eq, Show)

data BundleWriteResult = RecordCreated !FilePath | RecordPresent !FilePath
  deriving stock (Eq, Show)

runRecordPath :: EvidenceRecord -> Either BundleWriteError FilePath
runRecordPath record = do
  case parseRunId record.runId of
    Left reason -> Left (InvalidRecordIdentity reason)
    Right _ -> Right ()
  started <- maybe (Left (InvalidRecordIdentity "startedAt must be an RFC 3339 UTC timestamp")) Right (parseUtc record.startedAt)
  pure $ "runs" </> Text.unpack (renderLayer record.scenario.layer) </> formatTime defaultTimeLocale "%Y" started </> formatTime defaultTimeLocale "%m" started </> Text.unpack record.runId <> ".md"

writeRunRecord :: FilePath -> EvidenceRecord -> IO (Either BundleWriteError BundleWriteResult)
writeRunRecord = writeRunRecordWith validateEvidenceBundle

writeRunRecordWith :: (FilePath -> IO (Either BundleWriteError ())) -> FilePath -> EvidenceRecord -> IO (Either BundleWriteError BundleWriteResult)
writeRunRecordWith validate root record = case runRecordPath record of
  Left err -> pure (Left err)
  Right relative -> do
    completed <- try (write validate root relative record) :: IO (Either IOException (Either BundleWriteError BundleWriteResult))
    pure $ either (Left . BundleIo . Text.pack . show) id completed

write :: (FilePath -> IO (Either BundleWriteError ())) -> FilePath -> FilePath -> EvidenceRecord -> IO (Either BundleWriteError BundleWriteResult)
write validate root relative record = do
  let target = root </> relative
      parent = takeDirectory target
      logPath = parent </> "log.md"
  createDirectoryIfMissing True parent
  oldLog <- do
    exists <- doesFileExist logPath
    if exists then Just <$> Text.IO.readFile logPath else pure Nothing
  let document = recordToDocument record
      rendered = serializeDocument document
  published <- withTempFile parent ".kenshou-record-" $ \temporary handle -> do
    ByteString.hPut handle (Text.encodeUtf8 rendered)
    hFlush handle
    result <- try (createLink temporary target)
    pure case result of
      Right () -> Right True
      Left err
        | isAlreadyExistsError err -> Right False
        | otherwise -> Left (BundleIo (Text.pack (show (err :: IOException))))
  case published of
    Left err -> pure (Left err)
    Right False -> do
      existing <- Text.IO.readFile target
      pure $ case parseDocument existing of
        Right old | sameFact old document -> Right (RecordPresent relative)
        _ -> Left (RecordConflict relative)
    Right True -> do
      result <- try (finish validate root relative logPath oldLog record) :: IO (Either IOException (Either BundleWriteError ()))
      let rollback err = do
            removeFile target
            restoreLog logPath oldLog
            _ <- writeBundleIndexes root
            pure (Left err)
      case result of
        Right (Right ()) -> pure (Right (RecordCreated relative))
        Left err -> rollback (BundleIo (Text.pack (show err)))
        Right (Left err) -> rollback err

finish :: (FilePath -> IO (Either BundleWriteError ())) -> FilePath -> FilePath -> FilePath -> Maybe Text -> EvidenceRecord -> IO (Either BundleWriteError ())
finish validate root relative logPath oldLog record = case parseUtc record.generatedAt of
  Nothing -> pure (Left (InvalidRecordIdentity "generatedAt must be an RFC 3339 UTC timestamp"))
  Just generated -> do
    let logTitle = Text.pack (takeDirectory relative) <> " Update Log"
        current = maybe (Log logTitle []) parseLog oldLog
        message = "Recorded run " <> record.runId <> " (" <> renderScenarioId record.scenario <> ", " <> renderOutcome record.outcome <> ")."
        updated = appendLogEntry (Text.pack (formatTime defaultTimeLocale "%Y-%m-%d" generated)) (LogEntry (Just "Addition") message) current
    Text.IO.writeFile logPath (serializeLog updated)
    indexed <- writeBundleIndexes root
    case indexed of
      Left err -> pure (Left (BundleInvalid (Text.pack (show err))))
      Right () -> validate root

restoreLog :: FilePath -> Maybe Text -> IO ()
restoreLog path = \case
  Just previous -> Text.IO.writeFile path previous
  Nothing -> do
    exists <- doesFileExist path
    if exists then removeFile path else pure ()

sameFact :: OKFDocument -> OKFDocument -> Bool
sameFact left right =
  strip left.frontmatter == strip right.frontmatter && left.body == right.body
  where
    strip = removeField "verified" . removeField "generated"

validateEvidenceBundle :: FilePath -> IO (Either BundleWriteError ())
validateEvidenceBundle root = do
  loaded <- loadProfileFile (root </> "profile.dhall")
  case loaded of
    Left err -> pure (Left (BundleInvalid err))
    Right profile -> case compileProfile profile of
      Left errors -> pure (Left (BundleInvalid (Text.pack (show errors))))
      Right compiled -> do
        concepts <- walkBundle root
        inventory <- walkBundleInventory root
        declaration <- readBundleVersion root
        logs <- walkLogs root
        pure $ do
          found <- either (Left . BundleInvalid . Text.pack . show) Right concepts
          files <- either (Left . BundleInvalid . Text.pack . show) Right inventory
          version <- either (Left . BundleInvalid . Text.pack . show) Right declaration
          parsedLogs <- either (Left . BundleInvalid . Text.pack . show) Right logs
          let errors =
                map show (validateBundle StrictAuthoring version files found)
                  <> map show (validateProfileWith files StrictAuthoring compiled found)
                  <> map show (validateBundleLogs parsedLogs)
          if null errors then Right () else Left (BundleInvalid (Text.intercalate "; " (Text.pack <$> errors)))

parseUtc :: Text -> Maybe UTCTime
parseUtc = parseTimeM True defaultTimeLocale "%Y-%m-%dT%H:%M:%S%QZ" . Text.unpack
