module Kenshou.Remote.Cell.Parity
  ( ParityOptions (..),
    ParityDifference (..),
    ParityReport (..),
    compareForParity,
  )
where

import Crypto.Hash.SHA256 qualified as SHA256
import Data.Aeson (ToJSON (..), Value (..), eitherDecodeStrict', object, (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString qualified as ByteString
import Data.ByteString.Base16 qualified as Base16
import Data.Foldable (toList)
import Data.List (isPrefixOf, sort)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import System.Directory (doesDirectoryExist, listDirectory)
import System.FilePath (takeExtension, (</>))

newtype ParityOptions = ParityOptions {volatilePaths :: [Text]}
  deriving stock (Eq, Show)

data ParityDifference = ParityDifference
  { path :: !Text,
    localValue :: !(Maybe Value),
    cellValue :: !(Maybe Value)
  }
  deriving stock (Eq, Show)

instance ToJSON ParityDifference where
  toJSON difference =
    object
      [ "path" .= difference.path,
        "local" .= difference.localValue,
        "cell" .= difference.cellValue
      ]

data ParityReport = ParityReport
  { schema :: !Text,
    localRunResultSha256 :: !Text,
    cellRunResultSha256 :: !Text,
    equal :: ![Text],
    intentional :: ![ParityDifference],
    unexpected :: ![ParityDifference]
  }
  deriving stock (Eq, Show)

instance ToJSON ParityReport where
  toJSON report =
    object
      [ "schema" .= report.schema,
        "localRunResultSha256" .= report.localRunResultSha256,
        "cellRunResultSha256" .= report.cellRunResultSha256,
        "equal" .= report.equal,
        "intentional" .= report.intentional,
        "unexpected" .= report.unexpected
      ]

compareForParity :: ParityOptions -> FilePath -> FilePath -> IO ParityReport
compareForParity options localDir cellDir = do
  localBytes <- ByteString.readFile (localDir </> "run-result.json")
  cellBytes <- ByteString.readFile (cellDir </> "run-result.json")
  localResult <- decode "local run-result.json" localBytes
  cellResult <- decode "cell run-result.json" cellBytes
  localSpec <- readJson "local run-spec.json" (localDir </> "run-spec.json")
  cellSpec <- readJson "cell run-spec.json" (cellDir </> "run-spec.json")
  localVerdicts <- readVerdicts localDir
  cellVerdicts <- readVerdicts cellDir
  let comparisons =
        compareJson ["result"] localResult cellResult
          <> compareJson ["spec"] localSpec cellSpec
          <> compareVerdicts localVerdicts cellVerdicts
      allEqual = [renderPath path | (path, Just left, Just right) <- comparisons, left == right]
      differences = [ParityDifference (renderPath path) left right | (path, left, right) <- comparisons, left /= right]
      intentionalDiffs = filter (isIntentional options . (.path)) differences
      unexpectedDiffs = filter (not . isIntentional options . (.path)) differences
  pure
    ParityReport
      { schema = "kenshou.parity-report/v1",
        localRunResultSha256 = digest localBytes,
        cellRunResultSha256 = digest cellBytes,
        equal = allEqual,
        intentional = intentionalDiffs,
        unexpected = unexpectedDiffs
      }

decode :: Text -> ByteString.ByteString -> IO Value
decode label bytes =
  case eitherDecodeStrict' bytes of
    Left problem -> ioError (userError (Text.unpack label <> ": " <> problem))
    Right value -> pure value

readJson :: Text -> FilePath -> IO Value
readJson label path = ByteString.readFile path >>= decode label

readVerdicts :: FilePath -> IO (Map.Map Text Value)
readVerdicts runDir = do
  let verdictDir = runDir </> "verdicts"
  exists <- doesDirectoryExist verdictDir
  if not exists
    then pure Map.empty
    else do
      names <- sort . filter ((== ".json") . takeExtension) <$> listDirectory verdictDir
      Map.fromList
        <$> traverse
          ( \name -> do
              value <- readJson (Text.pack name) (verdictDir </> name)
              pure (Text.pack name, projectVerdict value)
          )
          names

projectVerdict :: Value -> Value
projectVerdict (Object value) =
  Object (KeyMap.filterWithKey (\key _ -> Key.toText key `elem` ["status", "counts"]) value)
projectVerdict value = value

compareVerdicts :: Map.Map Text Value -> Map.Map Text Value -> [([Text], Maybe Value, Maybe Value)]
compareVerdicts localVerdicts cellVerdicts =
  concatMap compareName (Set.toAscList (Map.keysSet localVerdicts `Set.union` Map.keysSet cellVerdicts))
  where
    compareName name =
      case (Map.lookup name localVerdicts, Map.lookup name cellVerdicts) of
        (Just localValue, Just cellValue) -> compareJson ["verdicts", name] localValue cellValue
        (left, right) -> [(["verdicts", name], left, right)]

compareJson :: [Text] -> Value -> Value -> [([Text], Maybe Value, Maybe Value)]
compareJson prefix localValue cellValue =
  [ (path, Map.lookup path localLeaves, Map.lookup path cellLeaves)
  | path <- Set.toAscList (Map.keysSet localLeaves `Set.union` Map.keysSet cellLeaves)
  ]
  where
    localLeaves = Map.fromList (flatten prefix localValue)
    cellLeaves = Map.fromList (flatten prefix cellValue)

flatten :: [Text] -> Value -> [([Text], Value)]
flatten prefix (Object value)
  | not (KeyMap.null value) = concatMap (\(key, child) -> flatten (prefix <> [Key.toText key]) child) (KeyMap.toList value)
flatten prefix (Array value)
  | not (null value) = concatMap (\(index, child) -> flatten (prefix <> [Text.pack (show index)]) child) (zip [0 :: Int ..] (toList value))
flatten prefix value = [(prefix, value)]

renderPath :: [Text] -> Text
renderPath = Text.intercalate "."

isIntentional :: ParityOptions -> Text -> Bool
isIntentional options rendered =
  natural || volatile
  where
    path = Text.splitOn "." rendered
    starts prefix = prefix `isPrefixOf` path
    natural =
      or
        [ starts ["result", "runId"],
          starts ["result", "timings"],
          starts ["result", "compatibility"],
          starts ["result", "invocation"],
          starts ["result", "spec", "sha256"],
          starts ["result", "spec", "path"],
          starts ["result", "cohort", "arch"],
          starts ["result", "cohort", "os"],
          starts ["result", "cohort", "resolver"],
          starts ["result", "cohort", "planHash"],
          starts ["result", "cohort", "cabalVersion"],
          starts ["result", "fingerprint", "cell"],
          starts ["result", "fingerprint", "host"],
          starts ["result", "fingerprint", "runtime"],
          starts ["result", "fingerprint", "machineProfile"],
          starts ["result", "fingerprint", "placement"],
          starts ["result", "fingerprint", "postgres"],
          starts ["result", "fingerprint", "kenshou", "executableSha256"],
          starts ["result", "fingerprint", "kenshou", "revision"],
          starts ["spec", "runId"],
          starts ["spec", "cohortExpectation"],
          starts ["spec", "environment", "placement"],
          starts ["spec", "environment", "machineProfile"],
          starts ["spec", "environment", "postgres"],
          path == ["spec", "labels"],
          starts ["spec", "labels", "postgresPlacement"]
        ]
    volatileScope = starts ["result", "summaries", "verdicts"] || starts ["verdicts"]
    volatile = volatileScope && any (\selected -> selected == rendered || (selected <> ".") `Text.isPrefixOf` rendered) options.volatilePaths

digest :: ByteString.ByteString -> Text
digest bytes = "sha256:" <> TextEncoding.decodeUtf8 (Base16.encode (SHA256.hash bytes))
