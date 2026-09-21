module Kenshou.Measure.Sampler.Csv
  ( CsvWriter,
    openCsv,
    appendCsv,
    closeCsv,
    timestampColumns,
  )
where

import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as Text
import Data.Time.Clock.POSIX (getPOSIXTime)
import Data.Word (Word64)
import Kenshou.Measure.Clock
import Kenshou.Measure.Phase
import System.Directory (createDirectoryIfMissing)
import System.FilePath (takeDirectory)
import System.IO

newtype CsvWriter = CsvWriter Handle

openCsv :: FilePath -> [Text] -> IO CsvWriter
openCsv path columns = do
  createDirectoryIfMissing True (takeDirectory path)
  handle <- openFile path WriteMode
  hSetBuffering handle LineBuffering
  let writer = CsvWriter handle
  appendCsv writer columns
  pure writer

appendCsv :: CsvWriter -> [Text] -> IO ()
appendCsv (CsvWriter handle) fields = Text.hPutStrLn handle (Text.intercalate "," (fmap quote fields))
  where
    quote value
      | Text.any (`elem` [',', '"', '\r', '\n']) value = "\"" <> Text.replace "\"" "\"\"" value <> "\""
      | otherwise = value

closeCsv :: CsvWriter -> IO ()
closeCsv (CsvWriter handle) = hClose handle

timestampColumns :: Origin -> PhaseClock -> IO (Word64, [Text])
timestampColumns origin phaseClock = do
  mono <- nowNs
  wall <- getPOSIXTime
  phase <- currentPhase phaseClock
  pure
    ( mono,
      [ Text.pack (show (mono - min mono origin.monoNs)),
        Text.pack (show (floor (wall * 1_000) :: Integer)),
        renderPhase phase
      ]
    )
