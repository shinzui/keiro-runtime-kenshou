module Kenshou.Check.Ledger.Read
  ( FactSource (..),
    SegmentRef (..),
    LedgerSet (..),
    LedgerReadError (..),
    openSegment,
    discoverLedgers,
    foldFacts,
  )
where

import Control.Exception (Exception, throwIO)
import Control.Monad (foldM)
import Data.Aeson (eitherDecodeStrict')
import Data.ByteString qualified as ByteString
import Data.ByteString.Char8 qualified as ByteString.Char8
import Data.List (sort)
import Data.Text (Text)
import Data.Text qualified as Text
import Kenshou.Check.Fact (Fact)
import Kenshou.Check.Ledger (LedgerHeader)
import Kenshou.Core.Canonical (sha256Hex)
import System.Directory (doesDirectoryExist, doesFileExist, listDirectory)
import System.FilePath (makeRelative, takeExtension, (</>))
import System.IO

newtype FactSource = FactSource {next :: IO (Maybe Fact)}

data SegmentRef = SegmentRef
  { path :: !FilePath,
    relativePath :: !FilePath,
    sha256 :: !Text,
    bytes :: !Integer
  }
  deriving stock (Eq, Show)

newtype LedgerSet = LedgerSet {segments :: [SegmentRef]}
  deriving stock (Eq, Show)

newtype LedgerReadError = LedgerReadError Text deriving stock (Eq, Show)

instance Exception LedgerReadError

openSegment :: FilePath -> IO (LedgerHeader, FactSource)
openSegment path = do
  handle <- openBinaryFile path ReadMode
  hSetBuffering handle (BlockBuffering (Just (64 * 1024)))
  endsWithNewline <- fileEndsWithNewline handle
  headerLine <- ByteString.hGetLine handle
  header <- either (throwIO . LedgerReadError . Text.pack) pure (eitherDecodeStrict' headerLine)
  pure (header, FactSource (readNext handle endsWithNewline))
  where
    readNext handle endsWithNewline = do
      done <- hIsEOF handle
      if done
        then hClose handle >> pure Nothing
        else do
          line <- ByteString.hGetLine handle
          atEnd <- hIsEOF handle
          if atEnd && not endsWithNewline
            then hClose handle >> pure Nothing
            else case eitherDecodeStrict' line of
              Right fact -> pure (Just fact)
              Left err -> hClose handle >> throwIO (LedgerReadError (Text.pack path <> ": " <> Text.pack err))

discoverLedgers :: FilePath -> IO LedgerSet
discoverLedgers root = do
  exists <- doesDirectoryExist root
  if not exists
    then pure (LedgerSet [])
    else do
      names <- sort <$> listDirectory root
      paths <- filterMFile [root </> name | name <- names, takeExtension name == ".jsonl"]
      LedgerSet <$> traverse describe paths
  where
    filterMFile [] = pure []
    filterMFile (path : rest) = do
      file <- doesFileExist path
      others <- filterMFile rest
      pure (if file then path : others else others)
    describe path = do
      contents <- ByteString.readFile path
      pure (SegmentRef path (makeRelative root path) (sha256Hex contents) (fromIntegral (ByteString.length contents)))

foldFacts :: LedgerSet -> state -> (state -> Fact -> IO state) -> IO state
foldFacts ledger initial step = foldM foldSegment initial ledger.segments
  where
    foldSegment state segment = do
      (_, source) <- openSegment segment.path
      go state source
    go state source =
      source.next >>= \case
        Nothing -> pure state
        Just fact -> step state fact >>= (`go` source)

fileEndsWithNewline :: Handle -> IO Bool
fileEndsWithNewline handle = do
  size <- hFileSize handle
  if size == 0
    then pure False
    else do
      hSeek handle SeekFromEnd (-1)
      byte <- ByteString.hGet handle 1
      hSeek handle AbsoluteSeek 0
      pure (byte == ByteString.Char8.pack "\n")
