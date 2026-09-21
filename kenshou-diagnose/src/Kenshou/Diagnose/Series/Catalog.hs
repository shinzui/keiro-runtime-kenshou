module Kenshou.Diagnose.Series.Catalog
  ( defaultCatalog,
    discoverProcesses,
  )
where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Kenshou.Diagnose.Series
import System.Directory (doesDirectoryExist, listDirectory)
import System.FilePath (dropExtension, takeExtension, takeFileName, (</>))

defaultCatalog :: Map Text SeriesBinding
defaultCatalog =
  Map.fromList
    [ ("heap.live-bytes", wide "rts.csv" "live_bytes_last_gc"),
      ("runtime.mem-in-use-bytes", wide "rts.csv" "mem_in_use_bytes"),
      ("process.rss-bytes", wide "proc.csv" "rss_bytes"),
      ("haskell.threads", wide "rts.csv" "haskell_threads"),
      ("os.threads", wide "proc.csv" "os_threads"),
      ("os.fds", wide "proc.csv" "open_fds"),
      ("pg.connections", long "pg-activity.csv" "connections"),
      ("pg.relation-bytes", long "pg-relations.csv" "total_bytes"),
      ("pg.dead-tuples", long "pg-relations.csv" "dead_tuples")
    ]
  where
    wide file value = SeriesBinding file "t_mono_ns" value (Map.singleton "phase" "steady")
    long file value = SeriesBinding file "t_mono_ns" value Map.empty

discoverProcesses :: FilePath -> IO [(Text, FilePath)]
discoverProcesses runDirectory = do
  let series = runDirectory </> "series"
  exists <- doesDirectoryExist series
  if not exists
    then pure []
    else do
      names <- listDirectory series
      pure (("main", series </> "rts.csv") : [(suffix name, series </> name) | name <- names, isWorkerRts name])
  where
    isWorkerRts name = takeExtension name == ".csv" && "rts-" `Text.isPrefixOf` Text.pack (takeFileName name)
    suffix name = Text.drop 4 (Text.pack (dropExtension (takeFileName name)))
