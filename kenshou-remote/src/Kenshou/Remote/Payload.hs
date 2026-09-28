module Kenshou.Remote.Payload
  ( Bundle (..),
    CellPayload (..),
    Harness (..),
    CohortCheck (..),
    PayloadDescriptor (..),
  )
where

import Control.Monad (unless)
import Data.Aeson (FromJSON (..), ToJSON (..), object, withObject, (.:), (.=))
import Data.Int (Int64)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime)
import Kenshou.Core.Cohort (CohortIdentity (..), CohortName (..))

data Bundle = Bundle
  { uri :: !Text,
    sha256 :: !Text,
    bytes :: !Int64
  }
  deriving stock (Eq, Show)

data CellPayload = CellPayload
  { bundle :: !Bundle,
    storePath :: !Text,
    narHash :: !Text,
    closurePaths :: ![Text],
    system :: !Text,
    command :: ![Text]
  }
  deriving stock (Eq, Show)

data Harness = Harness
  { revision :: !Text,
    dirty :: !Bool
  }
  deriving stock (Eq, Show)

data CohortCheck = CohortCheck
  { packagesChecked :: !Int
  }
  deriving stock (Eq, Show)

data PayloadDescriptor = PayloadDescriptor
  { cohort :: !Text,
    variant :: !Text,
    flakeAttr :: !Text,
    harness :: !Harness,
    cohortIdentity :: !CohortIdentity,
    cohortCheck :: !CohortCheck,
    cell :: !CellPayload,
    createdAt :: !UTCTime
  }
  deriving stock (Eq, Show)

instance ToJSON Bundle where
  toJSON bundle = object ["uri" .= bundle.uri, "sha256" .= bundle.sha256, "bytes" .= bundle.bytes]

instance FromJSON Bundle where
  parseJSON = withObject "cell payload bundle" \value -> do
    bundle <- Bundle <$> value .: "uri" <*> value .: "sha256" <*> value .: "bytes"
    unless (bundle.bytes > 0 && validSha256 bundle.sha256 && Text.isSuffixOf ("/payloads/sha256/" <> bundle.sha256 <> ".nar.zst") bundle.uri && "gs://" `Text.isPrefixOf` bundle.uri) (fail "invalid content-addressed cell bundle")
    pure bundle

instance ToJSON CellPayload where
  toJSON payload =
    object
      [ "schema" .= ("cell.payload/v1" :: Text),
        "kind" .= ("nix-nar-bundle" :: Text),
        "bundle" .= payload.bundle,
        "storePath" .= payload.storePath,
        "narHash" .= payload.narHash,
        "closurePaths" .= payload.closurePaths,
        "system" .= payload.system,
        "command" .= payload.command
      ]

instance FromJSON CellPayload where
  parseJSON = withObject "cell payload" \value -> do
    schema <- value .: "schema"
    kind <- value .: "kind"
    unless (schema == ("cell.payload/v1" :: Text) && kind == ("nix-nar-bundle" :: Text)) (fail "unsupported cell payload")
    payload <- CellPayload <$> value .: "bundle" <*> value .: "storePath" <*> value .: "narHash" <*> value .: "closurePaths" <*> value .: "system" <*> value .: "command"
    unless (payload.system == "x86_64-linux" && payload.storePath `elem` payload.closurePaths && payload.command == ["bin/kenshou", "cell", "exec"] && validStorePath payload.storePath && all validStorePath payload.closurePaths) (fail "invalid Kenshou cell payload")
    pure payload

instance ToJSON Harness where
  toJSON harness = object ["revision" .= harness.revision, "dirty" .= harness.dirty]

instance FromJSON Harness where
  parseJSON = withObject "payload harness" \value -> do
    harness <- Harness <$> value .: "revision" <*> value .: "dirty"
    unless (Text.length harness.revision == 40 && Text.all isHex harness.revision) (fail "invalid harness revision")
    pure harness

instance ToJSON CohortCheck where
  toJSON check = object ["status" .= ("consistent" :: Text), "packagesChecked" .= check.packagesChecked]

instance FromJSON CohortCheck where
  parseJSON = withObject "payload cohort check" \value -> do
    status <- value .: "status"
    unless (status == ("consistent" :: Text)) (fail "payload cohort check is not consistent")
    count <- value .: "packagesChecked"
    unless (count >= (0 :: Int)) (fail "negative checked package count")
    pure (CohortCheck count)

instance ToJSON PayloadDescriptor where
  toJSON descriptor =
    object
      [ "schema" .= ("kenshou.payload/v1" :: Text),
        "cohort" .= descriptor.cohort,
        "variant" .= descriptor.variant,
        "flakeAttr" .= descriptor.flakeAttr,
        "harness" .= descriptor.harness,
        "cohortIdentity" .= descriptor.cohortIdentity,
        "cohortCheck" .= descriptor.cohortCheck,
        "cell" .= descriptor.cell,
        "createdAt" .= descriptor.createdAt
      ]

instance FromJSON PayloadDescriptor where
  parseJSON = withObject "Kenshou payload" \value -> do
    schema <- value .: "schema"
    unless (schema == ("kenshou.payload/v1" :: Text)) (fail "unsupported Kenshou payload schema")
    descriptor <- PayloadDescriptor <$> value .: "cohort" <*> value .: "variant" <*> value .: "flakeAttr" <*> value .: "harness" <*> value .: "cohortIdentity" <*> value .: "cohortCheck" <*> value .: "cell" <*> value .: "createdAt"
    let expectedAttr =
          "packages.x86_64-linux.kenshou-" <> descriptor.cohort <> case descriptor.variant of
            "default" -> ""
            "info-table" -> "-info-table"
            "profiled" -> "-profiled"
            _ -> "-invalid"
    unless (descriptor.variant `elem` ["default", "info-table", "profiled"] && descriptor.cohort == unCohortName descriptor.cohortIdentity.identityCohort && descriptor.flakeAttr == expectedAttr && descriptor.cohortIdentity.identityResolver == Just "nix") (fail "inconsistent Kenshou payload identity")
    pure descriptor

validSha256 :: Text -> Bool
validSha256 digest = Text.length digest == 64 && Text.all isHex digest

isHex :: Char -> Bool
isHex character = character `elem` ['0' .. '9'] || character `elem` ['a' .. 'f']

validStorePath :: Text -> Bool
validStorePath path = case Text.stripPrefix "/nix/store/" path of
  Just suffix ->
    let (digest, name) = Text.breakOn "-" suffix
     in Text.length digest == 32 && Text.all validNixBase32 digest && not (Text.null (Text.drop 1 name)) && not (Text.any (== '/') name)
  Nothing -> False
  where
    validNixBase32 character = character `elem` ("0123456789abcdfghijklmnpqrsvwxyz" :: String)
