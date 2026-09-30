module Kenshou.Suite.Keiro.Messaging.RelationGrowth
  ( RelationGrowth (..),
    readRelationGrowth,
    bytesPerInsertedRow,
    sizeBounded,
    deadTuplesBounded,
  )
where

import Data.List (sort)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as TextIO
import Kenshou.Core.Context (RunContext (..))
import System.FilePath ((</>))
import Text.Read (readMaybe)

data RelationGrowth = RelationGrowth
  { earlyBytes :: !Integer,
    lateBytes :: !Integer,
    earlyDeadTuples :: !Integer,
    lateDeadTuples :: !Integer,
    earlyInserts :: !Integer,
    lateInserts :: !Integer
  }
  deriving stock (Eq, Show)

-- Compare median samples in the middle and final quarters of steady state.
-- The first half is excluded so relation creation and initial growth do not
-- masquerade as an unbounded steady-state slope.
readRelationGrowth :: RunContext -> Text -> IO (Maybe RelationGrowth)
readRelationGrowth context relation = do
  content <- TextIO.readFile (context.outDir </> "series" </> "pg-relations.csv")
  let samples =
        [ (bytes, dead, inserts)
        | line <- drop 1 (Text.lines content),
          let columns = Text.splitOn "," line,
          length columns >= 10,
          columns !! 2 == "steady",
          columns !! 3 == relation,
          Just bytes <- [readMaybe (Text.unpack (columns !! 6))],
          Just dead <- [readMaybe (Text.unpack (columns !! 8))],
          Just inserts <- [readMaybe (Text.unpack (columns !! 9))]
        ]
      count = length samples
      quarter = count `div` 4
      median values = sort values !! (length values `div` 2)
      early = take quarter (drop (count `div` 2) samples)
      late = drop (count - quarter) samples
  pure $
    if quarter < 10
      then Nothing
      else
        Just
          RelationGrowth
            { earlyBytes = median [bytes | (bytes, _, _) <- early],
              lateBytes = median [bytes | (bytes, _, _) <- late],
              earlyDeadTuples = median [dead | (_, dead, _) <- early],
              lateDeadTuples = median [dead | (_, dead, _) <- late],
              earlyInserts = median [inserts | (_, _, inserts) <- early],
              lateInserts = median [inserts | (_, _, inserts) <- late]
            }

bytesPerInsertedRow :: RelationGrowth -> Maybe Double
bytesPerInsertedRow growth
  | growth.lateInserts > growth.earlyInserts = Just (fromIntegral (growth.lateBytes - growth.earlyBytes) / fromIntegral (growth.lateInserts - growth.earlyInserts))
  | otherwise = Nothing

sizeBounded :: Integer -> RelationGrowth -> Bool
sizeBounded tolerance growth = growth.lateBytes <= growth.earlyBytes + tolerance

deadTuplesBounded :: Integer -> RelationGrowth -> Bool
deadTuplesBounded tolerance growth = growth.lateDeadTuples <= growth.earlyDeadTuples + tolerance
