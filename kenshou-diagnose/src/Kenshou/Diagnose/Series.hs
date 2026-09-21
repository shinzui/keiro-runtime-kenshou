module Kenshou.Diagnose.Series
  ( DiagnoseError (..),
    SeriesBinding (..),
    readWide,
    readLong,
    readBinding,
  )
where

import Control.Exception (IOException, try)
import Data.List (elemIndex)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as Text
import Data.Vector (Vector)
import Data.Vector qualified as Vector
import System.IO (Handle, IOMode (ReadMode), hIsEOF, withFile)
import Text.Read (readMaybe)

data DiagnoseError
  = MissingSeries FilePath
  | MissingColumn FilePath Text
  | InvalidSeriesValue FilePath Int Text
  | CannotReadSeries FilePath Text
  | InvalidRunDirectory FilePath Text
  deriving stock (Eq, Show)

data SeriesBinding = SeriesBinding
  { file :: FilePath,
    timeColumn :: Text,
    valueColumn :: Text,
    filters :: Map Text Text
  }
  deriving stock (Eq, Show)

readWide :: FilePath -> Text -> Text -> IO (Either DiagnoseError (Vector (Double, Double)))
readWide path timeColumn valueColumn = readBinding path (SeriesBinding path timeColumn valueColumn Map.empty)

readLong :: FilePath -> Text -> Text -> Map Text Text -> IO (Either DiagnoseError (Vector (Double, Double)))
readLong path timeColumn valueColumn filters = readBinding path (SeriesBinding path timeColumn valueColumn filters)

readBinding :: FilePath -> SeriesBinding -> IO (Either DiagnoseError (Vector (Double, Double)))
readBinding path binding = do
  result <- try @IOException (withFile path ReadMode (readRows path binding))
  pure case result of
    Left err -> Left (CannotReadSeries path (Text.pack (show err)))
    Right value -> value

readRows :: FilePath -> SeriesBinding -> Handle -> IO (Either DiagnoseError (Vector (Double, Double)))
readRows path binding handle = do
  exhausted <- hIsEOF handle
  if exhausted
    then pure (Left (MissingSeries path))
    else do
      header <- splitCsv <$> Text.hGetLine handle
      case resolveColumns path binding header of
        Left err -> pure (Left err)
        Right columns -> go columns 2 []
  where
    go columns lineNumber accumulated = do
      exhausted <- hIsEOF handle
      if exhausted
        then pure (Right (Vector.fromList (reverse accumulated)))
        else do
          fields <- splitCsv <$> Text.hGetLine handle
          case parseRow path binding columns lineNumber fields of
            Left err -> pure (Left err)
            Right Nothing -> go columns (lineNumber + 1) accumulated
            Right (Just point) -> go columns (lineNumber + 1) (point : accumulated)

data Columns = Columns Int Int [(Int, Text)]

resolveColumns :: FilePath -> SeriesBinding -> [Text] -> Either DiagnoseError Columns
resolveColumns path binding header = do
  timeIndex <- index binding.timeColumn
  valueIndex <- index binding.valueColumn
  filterColumns <- traverse (\(name, expected) -> (,expected) <$> index name) (Map.toList binding.filters)
  pure (Columns timeIndex valueIndex filterColumns)
  where
    index name = maybe (Left (MissingColumn path name)) Right (elemIndex name header)

parseRow :: FilePath -> SeriesBinding -> Columns -> Int -> [Text] -> Either DiagnoseError (Maybe (Double, Double))
parseRow path binding (Columns timeIndex valueIndex filterColumns) lineNumber fields
  | not (all matches filterColumns) = Right Nothing
  | Text.null valueText = Right Nothing
  | otherwise = case (readMaybe (Text.unpack timeText), readMaybe (Text.unpack valueText)) of
      (Just timeValue, Just value) -> Right (Just (normaliseTime binding.timeColumn timeValue, value))
      _ -> Left (InvalidSeriesValue path lineNumber (timeText <> "," <> valueText))
  where
    at index = if index < length fields then fields !! index else ""
    timeText = at timeIndex
    valueText = at valueIndex
    matches (index, expected) = at index == expected

normaliseTime :: Text -> Double -> Double
normaliseTime column value
  | Text.isSuffixOf "_ns" column = value / 1_000_000_000
  | Text.isSuffixOf "_ms" column = value / 1_000
  | otherwise = value

-- Kenshou-owned sampler files contain numeric cells and optional RFC 4180
-- quoting for labels. This small parser handles escaped quotes without loading
-- a 24-hour series into memory.
splitCsv :: Text -> [Text]
splitCsv = fmap Text.pack . go False [] [] . Text.unpack
  where
    go _ field fields [] = reverse (reverse field : fields)
    go True field fields ('"' : '"' : rest) = go True ('"' : field) fields rest
    go quoted field fields ('"' : rest) = go (not quoted) field fields rest
    go False field fields (',' : rest) = go False [] (reverse field : fields) rest
    go quoted field fields (character : rest) = go quoted (character : field) fields rest
