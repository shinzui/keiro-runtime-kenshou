module Kenshou.Cli.Help.Width (renderForWidth, resolveWidth) where

import Data.Text (Text)
import Data.Text qualified as Text
import System.Console.Terminal.Size qualified as Terminal
import System.IO (hIsTerminalDevice, stdout)

resolveWidth :: Maybe Int -> IO (Maybe Int)
resolveWidth (Just width) = pure (Just (max 1 width))
resolveWidth Nothing = do
  terminal <- hIsTerminalDevice stdout
  if not terminal
    then pure Nothing
    else do
      window <- Terminal.size
      pure (min 140 . Terminal.width <$> window)

renderForWidth :: Maybe Int -> Text -> Text
renderForWidth Nothing body = body
renderForWidth (Just width) body = Text.intercalate "\n\n" (fmap renderParagraph (splitParagraphs body))
  where
    renderParagraph paragraph
      | all (Text.isPrefixOf "  ") (filter (not . Text.null . Text.strip) (Text.lines paragraph)) = paragraph
      | otherwise = Text.intercalate "\n" (packWords (Text.words paragraph))
    packWords [] = []
    packWords (firstWord : rest) = go firstWord rest
    go current [] = [current]
    go current (word : rest)
      | Text.length current + 1 + Text.length word <= width = go (current <> " " <> word) rest
      | otherwise = current : go word rest

splitParagraphs :: Text -> [Text]
splitParagraphs body = go [] [] (Text.lines body)
  where
    go result current [] = reverse (flush result current)
    go result current (line : rest)
      | Text.null (Text.strip line) = go (flush result current) [] rest
      | otherwise = go result (line : current) rest
    flush result [] = result
    flush result current = Text.intercalate "\n" (reverse current) : result
