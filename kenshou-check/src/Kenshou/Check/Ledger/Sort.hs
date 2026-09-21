module Kenshou.Check.Ledger.Sort
  ( SortOrder (..),
    SortConfig (..),
    defaultSortConfig,
    sortedFacts,
  )
where

import Control.Exception (bracket)
import Control.Monad (foldM, unless)
import Data.Aeson (eitherDecodeStrict', encode)
import Data.ByteString.Char8 qualified as ByteString
import Data.ByteString.Lazy.Char8 qualified as LazyByteString
import Data.IORef
import Data.List (minimumBy, sortBy)
import Data.Ord (comparing)
import Kenshou.Check.Fact
import Kenshou.Check.Ledger.Read
import System.Directory (createDirectoryIfMissing, listDirectory, removeFile)
import System.FilePath ((</>))
import System.IO

data SortOrder = ByKeySeq | ByScopeKeyArrival | ByScopeArrival | ByKeyWall
  deriving stock (Eq, Ord, Show)

data SortConfig = SortConfig
  { directory :: !FilePath,
    runRecords :: !Int,
    mergeFanIn :: !Int
  }
  deriving stock (Eq, Show)

defaultSortConfig :: FilePath -> SortConfig
defaultSortConfig directory = SortConfig directory 200000 64

sortedFacts :: SortConfig -> SortOrder -> (Fact -> Bool) -> LedgerSet -> (FactSource -> IO value) -> IO value
sortedFacts config order select ledger action = bracket prepare cleanup (action <=< sourceFor)
  where
    prepare = do
      createDirectoryIfMissing True config.directory
      counter <- newIORef (0 :: Int)
      chunks <- buildRuns counter [] [] 0 ledger.segments
      collapse counter chunks
    cleanup finalPath = do
      names <- listDirectory config.directory
      mapM_ (removeFile . (config.directory </>)) names
      unless (null finalPath) (pure ())
    sourceFor "" = pure (FactSource (pure Nothing))
    sourceFor path = openRun path

    buildRuns counter paths chunk size [] = flushChunk counter paths chunk size
    buildRuns counter paths chunk size (segment : rest) = do
      (_, source) <- openSegment segment.path
      (paths', chunk', size') <- consume counter paths chunk size source
      buildRuns counter paths' chunk' size' rest

    consume counter paths chunk size source =
      source.next >>= \case
        Nothing -> pure (paths, chunk, size)
        Just fact
          | not (select fact) -> consume counter paths chunk size source
          | size + 1 >= max 1 config.runRecords -> do
              paths' <- flushChunk counter paths (fact : chunk) (size + 1)
              consume counter paths' [] 0 source
          | otherwise -> consume counter paths (fact : chunk) (size + 1) source

    flushChunk _ paths [] _ = pure paths
    flushChunk counter paths chunk _ = do
      path <- freshPath counter
      writeFacts path (sortBy (compareFact order) chunk)
      pure (paths <> [path])

    collapse _ [] = pure ""
    collapse _ [path] = pure path
    collapse counter paths = do
      merged <- traverse (mergeGroup counter) (chunksOf (max 2 config.mergeFanIn) paths)
      mapM_ removeFile paths
      collapse counter merged

    mergeGroup counter paths = do
      target <- freshPath counter
      sources <- traverse openRun paths
      mergeSources order target sources
      pure target

    freshPath counter = do
      number <- atomicModifyIORef' counter (\value -> (value + 1, value + 1))
      pure (config.directory </> ("run-" <> pad6 number <> ".jsonl"))

    pad6 number = replicate (max 0 (6 - length rendered)) '0' <> rendered where rendered = show number

compareFact :: SortOrder -> Fact -> Fact -> Ordering
compareFact ByKeySeq = comparing (\fact -> (fact.key, fact.seq, fact.kind, fact.wall, fact.n))
compareFact ByScopeKeyArrival = comparing (\fact -> (fact.scope, fact.key, fact.proc.incarnation, fact.n))
compareFact ByScopeArrival = comparing (\fact -> (fact.scope, fact.proc.incarnation, fact.n))
compareFact ByKeyWall = comparing (\fact -> (fact.key, fact.wall, fact.scope, fact.n))

writeFacts :: FilePath -> [Fact] -> IO ()
writeFacts path facts = withBinaryFile path WriteMode \handle -> mapM_ (LazyByteString.hPutStrLn handle . encode) facts

openRun :: FilePath -> IO FactSource
openRun path = do
  handle <- openBinaryFile path ReadMode
  pure (FactSource (nextFact handle))
  where
    nextFact handle = do
      done <- hIsEOF handle
      if done
        then hClose handle >> pure Nothing
        else do
          line <- ByteString.hGetLine handle
          either (ioError . userError) (pure . Just) (eitherDecodeStrict' line)

mergeSources :: SortOrder -> FilePath -> [FactSource] -> IO ()
mergeSources order path sources = withBinaryFile path WriteMode \handle -> do
  heads <- traverse (\source -> (source,) <$> source.next) sources
  go handle heads
  where
    go _ heads | all (maybe True (const False) . snd) heads = pure ()
    go handle heads = do
      let candidates = [(index, source, fact) | (index, (source, Just fact)) <- zip [0 :: Int ..] heads]
          (chosenIndex, chosenSource, chosenFact) = minimumBy (\(_, _, left) (_, _, right) -> compareFact order left right) candidates
      LazyByteString.hPutStrLn handle (encode chosenFact)
      replacement <- chosenSource.next
      go handle [if index == chosenIndex then (source, replacement) else pair | (index, pair@(source, _)) <- zip [0 :: Int ..] heads]

chunksOf :: Int -> [value] -> [[value]]
chunksOf _ [] = []
chunksOf size values = first : chunksOf size rest where (first, rest) = splitAt size values

(<=<) :: (b -> IO c) -> (a -> IO b) -> a -> IO c
(<=<) left right value = right value >>= left
