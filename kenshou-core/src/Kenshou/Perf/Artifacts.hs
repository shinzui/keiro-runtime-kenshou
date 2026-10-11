{-# LANGUAGE FieldSelectors #-}

module Kenshou.Perf.Artifacts (verifyPerfManifest, sealPerfDirectory) where

import Control.Exception (IOException, displayException, try)
import Control.Monad (unless)
import Data.Aeson (eitherDecodeFileStrict', encodeFile)
import Data.ByteString qualified as ByteString
import Data.List (nub, sort)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Kenshou.Core.Canonical (sha256Hex)
import Kenshou.Core.Id (newRunId)
import Kenshou.Core.Manifest (Manifest (..), ManifestFile (..), writeManifest)
import System.Directory (doesDirectoryExist, listDirectory, pathIsSymbolicLink)
import System.FilePath (isAbsolute, makeRelative, splitDirectories, (</>))

-- Performance documents are replayed after retrieval. Reject links, escaping
-- paths, omitted files and duplicate entries before opening any manifest path.
verifyPerfManifest :: FilePath -> IO (Either Text ())
verifyPerfManifest root = ioResult do
  decoded <- eitherDecodeFileStrict' (root </> "manifest.json")
  case decoded of
    Left problem -> pure (Left (Text.pack problem))
    Right manifest -> do
      paths <- regularFiles root
      let listed = map (.path) (manifest :: Manifest).files
      if any (not . safePath) listed || nub listed /= listed || sort listed /= filter (/= "manifest.json") paths
        then pure (Left "performance manifest file inventory is unsafe or incomplete")
        else do
          problems <- traverse verifyFile manifest.files
          pure (sequence_ problems)
  where
    verifyFile file = do
      bytes <- ByteString.readFile (root </> file.path)
      pure do
        unless (sha256Hex bytes == file.sha256) (Left (Text.pack file.path <> ": digest mismatch"))
        unless (fromIntegral (ByteString.length bytes) == file.bytes) (Left (Text.pack file.path <> ": byte count mismatch"))

sealPerfDirectory :: FilePath -> IO (Either Text ())
sealPerfDirectory root = ioResult do
  _ <- regularFiles root
  identifier <- newRunId
  manifest <- writeManifest root identifier Map.empty
  encodeFile (root </> "manifest.json") manifest
  pure (Right ())

regularFiles :: FilePath -> IO [FilePath]
regularFiles root = sort <$> visit root
  where
    visit path = do
      link <- pathIsSymbolicLink path
      if link then ioError (userError "performance evidence may not contain symbolic links") else pure ()
      directory <- doesDirectoryExist path
      if directory then listDirectory path >>= fmap concat . traverse (visit . (path </>)) else pure [makeRelative root path]

safePath :: FilePath -> Bool
safePath path = not (null path) && not (isAbsolute path) && all (`notElem` ["", ".", ".."]) (splitDirectories path) && '\\' `notElem` path

ioResult :: IO (Either Text a) -> IO (Either Text a)
ioResult action = do
  result <- try @IOException action
  pure (either (Left . Text.pack . displayException) id result)
