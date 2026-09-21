module Kenshou.Core.Id
  ( Layer (..),
    Kind (..),
    Segment,
    ScenarioId (..),
    RunId,
    Seed,
    renderLayer,
    parseLayer,
    renderKind,
    parseKind,
    mkSegment,
    unSegment,
    parseScenarioId,
    renderScenarioId,
    newRunId,
    parseRunId,
    renderRunId,
    mkSeed,
    unSeed,
    deriveGen,
  )
where

import Data.Aeson (FromJSON (..), ToJSON (..), withText)
import Data.Bits (xor)
import Data.ByteString qualified as ByteString
import Data.Char (isAsciiLower, isDigit)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Data.UUID (UUID)
import Data.UUID qualified as UUID
import Data.UUID.V7 qualified as UUID.V7
import Data.Word (Word64)
import System.Random.SplitMix (SMGen, mkSMGen)

data Layer = Selftest | Pgmq | Kiroku | Shibuya | Kafka | Keiro | Runtime
  deriving stock (Eq, Ord, Show, Enum, Bounded)

data Kind = Correctness | Concurrency | Soak | Benchmark
  deriving stock (Eq, Ord, Show, Enum, Bounded)

newtype Segment = Segment Text
  deriving stock (Eq, Ord, Show)

data ScenarioId = ScenarioId
  { layer :: Layer,
    component :: Segment,
    kind :: Kind,
    name :: Segment
  }
  deriving stock (Eq, Ord, Show)

newtype RunId = RunId UUID
  deriving stock (Eq, Ord, Show)

newtype Seed = Seed Word64
  deriving stock (Eq, Ord, Show)

renderLayer :: Layer -> Text
renderLayer Selftest = "selftest"
renderLayer Pgmq = "pgmq"
renderLayer Kiroku = "kiroku"
renderLayer Shibuya = "shibuya"
renderLayer Kafka = "kafka"
renderLayer Keiro = "keiro"
renderLayer Runtime = "runtime"

parseLayer :: Text -> Either Text Layer
parseLayer value = maybe (Left ("unknown layer \"" <> value <> "\"")) Right (lookup value pairs)
  where
    pairs = [(renderLayer item, item) | item <- [minBound .. maxBound]]

renderKind :: Kind -> Text
renderKind Correctness = "correctness"
renderKind Concurrency = "concurrency"
renderKind Soak = "soak"
renderKind Benchmark = "benchmark"

parseKind :: Text -> Either Text Kind
parseKind value = maybe (Left ("unknown kind \"" <> value <> "\"")) Right (lookup value pairs)
  where
    pairs = [(renderKind item, item) | item <- [minBound .. maxBound]]

mkSegment :: Text -> Either Text Segment
mkSegment value
  | Text.length value > 48 = Left "segment is longer than 48 characters"
  | Text.null value = Left "segment is empty"
  | valid = Right (Segment value)
  | otherwise = Left ("invalid segment \"" <> value <> "\"")
  where
    chunks = Text.splitOn "-" value
    validChunk chunk =
      not (Text.null chunk)
        && isAsciiLower (Text.head chunk)
        && Text.all (\c -> isAsciiLower c || isDigit c) chunk
    valid = all validChunk chunks

unSegment :: Segment -> Text
unSegment (Segment value) = value

parseScenarioId :: Text -> Either Text ScenarioId
parseScenarioId value = case Text.splitOn "/" value of
  [layerText, componentText, kindText, nameText] ->
    ScenarioId
      <$> parseLayer layerText
      <*> mkSegment componentText
      <*> parseKind kindText
      <*> mkSegment nameText
  _ -> Left ("scenario identifier must have four segments: \"" <> value <> "\"")

renderScenarioId :: ScenarioId -> Text
renderScenarioId value =
  Text.intercalate
    "/"
    [renderLayer value.layer, unSegment value.component, renderKind value.kind, unSegment value.name]

newRunId :: IO RunId
newRunId = RunId <$> UUID.V7.genUUID

parseRunId :: Text -> Either Text RunId
parseRunId value = case UUID.fromText value of
  Nothing -> Left ("invalid UUIDv7 \"" <> value <> "\"")
  Just uuid
    | UUID.toText uuid /= value -> Left "run id must use canonical lowercase UUID text"
    | Text.index value 14 /= '7' -> Left "run id must be UUIDv7"
    | otherwise -> Right (RunId uuid)

renderRunId :: RunId -> Text
renderRunId (RunId uuid) = UUID.toText uuid

mkSeed :: Word64 -> Either Text Seed
mkSeed value
  | value <= 9007199254740991 = Right (Seed value)
  | otherwise = Left "seed must be between 0 and 9007199254740991"

unSeed :: Seed -> Word64
unSeed (Seed value) = value

deriveGen :: Seed -> Text -> SMGen
deriveGen (Seed seed) label = mkSMGen (seed `xor` fnv1a64 (Text.encodeUtf8 label))

fnv1a64 :: ByteString.ByteString -> Word64
fnv1a64 = ByteString.foldl' step 14695981039346656037
  where
    step hash byte = (hash `xor` fromIntegral byte) * 1099511628211

instance ToJSON Layer where toJSON = toJSON . renderLayer

instance FromJSON Layer where parseJSON = withText "Layer" (either (fail . Text.unpack) pure . parseLayer)

instance ToJSON Kind where toJSON = toJSON . renderKind

instance FromJSON Kind where parseJSON = withText "Kind" (either (fail . Text.unpack) pure . parseKind)

instance ToJSON Segment where toJSON = toJSON . unSegment

instance FromJSON Segment where parseJSON = withText "Segment" (either (fail . Text.unpack) pure . mkSegment)

instance ToJSON ScenarioId where toJSON = toJSON . renderScenarioId

instance FromJSON ScenarioId where parseJSON = withText "ScenarioId" (either (fail . Text.unpack) pure . parseScenarioId)

instance ToJSON RunId where toJSON = toJSON . renderRunId

instance FromJSON RunId where parseJSON = withText "RunId" (either (fail . Text.unpack) pure . parseRunId)

instance ToJSON Seed where toJSON = toJSON . unSeed

instance FromJSON Seed where parseJSON value = parseJSON value >>= either (fail . Text.unpack) pure . mkSeed
