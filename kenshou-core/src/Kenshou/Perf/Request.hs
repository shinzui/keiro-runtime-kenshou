{-# LANGUAGE FieldSelectors #-}

module Kenshou.Perf.Request
  ( PerfRequest (..),
    validateRequest,
    requestDigest,
    immutableRevision,
    canonicalProject,
    strictObject,
  )
where

import Control.Monad (unless)
import Data.Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (Parser)
import Data.Char (isAsciiLower, isDigit)
import Data.List (nub, sort)
import Data.Text (Text)
import Data.Text qualified as Text
import Kenshou.Core.Canonical (canonicalEncode, sha256Hex)

-- Lists are sets on the wire; encoding sorts them to give equivalent requests
-- the same identity. Duplicates are rejected rather than silently discarded.
data PerfRequest = PerfRequest
  { project :: Text,
    baselineRevision :: Text,
    candidateRevision :: Text,
    cohortTemplate :: FilePath,
    targetComponents :: [Text],
    suite :: Text,
    coverageMode :: Text,
    purpose :: Text,
    control :: Text,
    profiles :: [Text],
    seed :: Integer,
    cells :: [Text],
    waitSeconds :: Int,
    budgetMinutes :: Int
  }
  deriving stock (Eq, Show)

immutableRevision :: Text -> Bool
immutableRevision revision = Text.length revision == 40 && Text.all (\c -> c `elem` ['0' .. '9'] || c `elem` ['a' .. 'f']) revision

canonicalProject :: Text -> Bool
canonicalProject uri = case Text.splitOn "/" <$> Text.stripPrefix "mori://" uri of
  Just [namespace, projectName] -> valid namespace && valid projectName
  _ -> False
  where
    valid part = not (Text.null part) && Text.all (\c -> isAsciiLower c || isDigit c || c `elem` ("-_" :: String)) part

validateRequest :: PerfRequest -> Either Text ()
validateRequest request = do
  require (canonicalProject request.project) "project must be a canonical mori://namespace/project URI"
  require (all immutableRevision [request.baselineRevision, request.candidateRevision]) "revisions must be full lowercase 40-character Git commits"
  require (not (null request.cohortTemplate)) "cohortTemplate must be nonempty"
  require (request.suite == "change-performance") "unsupported performance suite"
  require (request.coverageMode `elem` ["affected", "selected-profiles"]) "unknown coverageMode"
  require (request.purpose `elem` ["gating", "calibration"]) "unknown purpose"
  require (request.control `elem` ["none", "aa"]) "unknown control"
  require (request.control /= "aa" || request.baselineRevision == request.candidateRevision) "A/A control requires identical revisions"
  require (request.control /= "aa" || not (null request.profiles)) "A/A control requires explicit profiles"
  require (request.coverageMode /= "selected-profiles" || not (null request.profiles)) "selected-profiles requires explicit profiles"
  require (request.seed >= 0 && request.seed <= 9007199254740991) "seed must be an exactly representable nonnegative JSON integer"
  require (request.waitSeconds >= 0 && request.budgetMinutes > 0) "waitSeconds must be nonnegative and budgetMinutes positive"
  require (not (null request.targetComponents) && not (null request.cells)) "targetComponents and cells must be nonempty"
  mapM_ validateSet [request.targetComponents, request.profiles, request.cells]
  where
    require condition message = unless condition (Left message)
    validateSet values = do
      require (all (\v -> not (Text.null v) && Text.strip v == v) values) "set entries must be nonempty and have no surrounding whitespace"
      require (nub values == values) "duplicate set entry"

requestDigest :: PerfRequest -> Text
requestDigest = sha256Hex . canonicalEncode . toJSON

strictObject :: [Text] -> Object -> Parser ()
strictObject allowed value = unless (null unknown) (fail ("unknown fields: " <> show unknown))
  where
    unknown = filter (`notElem` allowed) (map Key.toText (KeyMap.keys value))

instance ToJSON PerfRequest where
  toJSON request =
    object
      [ "schema" .= ("kenshou.perf-request/v1" :: Text),
        "project" .= request.project,
        "baselineRevision" .= request.baselineRevision,
        "candidateRevision" .= request.candidateRevision,
        "cohortTemplate" .= request.cohortTemplate,
        "targetComponents" .= sort request.targetComponents,
        "suite" .= request.suite,
        "coverageMode" .= request.coverageMode,
        "purpose" .= request.purpose,
        "control" .= request.control,
        "profiles" .= sort request.profiles,
        "seed" .= request.seed,
        "cells" .= sort request.cells,
        "waitSeconds" .= request.waitSeconds,
        "budgetMinutes" .= request.budgetMinutes
      ]

instance FromJSON PerfRequest where
  parseJSON = withObject "PerfRequest" \value -> do
    strictObject ["schema", "project", "baselineRevision", "candidateRevision", "cohortTemplate", "targetComponents", "suite", "coverageMode", "purpose", "control", "profiles", "seed", "cells", "waitSeconds", "budgetMinutes"] value
    schema <- value .: "schema"
    unless (schema == ("kenshou.perf-request/v1" :: Text)) (fail "unsupported performance request schema")
    request <-
      PerfRequest
        <$> value .: "project"
        <*> value .: "baselineRevision"
        <*> value .: "candidateRevision"
        <*> value .: "cohortTemplate"
        <*> value .: "targetComponents"
        <*> value .:? "suite" .!= "change-performance"
        <*> value .:? "coverageMode" .!= "affected"
        <*> value .:? "purpose" .!= "gating"
        <*> value .:? "control" .!= "none"
        <*> value .:? "profiles" .!= []
        <*> value .: "seed"
        <*> value .: "cells"
        <*> value .:? "waitSeconds" .!= 90
        <*> value .:? "budgetMinutes" .!= 30
    either (fail . Text.unpack) pure (validateRequest request)
    pure request {targetComponents = sort request.targetComponents, profiles = sort request.profiles, cells = sort request.cells}
