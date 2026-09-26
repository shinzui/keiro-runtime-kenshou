module Kenshou.Evidence.Types
  ( Sha256 (..),
    Revision (..),
    mkSha256,
    sha256Bytes,
    mkRevision,
    RecordKind (..),
    Purpose (..),
    DataKind (..),
    DataLink (..),
    ComponentSource (..),
    ComponentRef (..),
    SubjectKind (..),
  )
where

import Data.ByteString (ByteString)
import Data.Text (Text)
import Data.Text qualified as Text
import Kenshou.Core.Canonical (sha256Hex)
import Numeric.Natural (Natural)

newtype Sha256 = Sha256 Text deriving stock (Eq, Ord, Show)

newtype Revision = Revision Text deriving stock (Eq, Ord, Show)

mkSha256 :: Text -> Either Text Sha256
mkSha256 value
  | Text.length value == 64 && Text.all lowerHex value = Right (Sha256 value)
  | otherwise = Left "SHA-256 must be exactly 64 lowercase hexadecimal characters"

-- The kernel uses a sha256: prefix in its JSON documents; OKF evidence stores
-- bare hexadecimal digests. Keep that conversion at the boundary.
sha256Bytes :: ByteString -> Sha256
sha256Bytes = Sha256 . Text.drop 7 . sha256Hex

mkRevision :: Text -> Either Text Revision
mkRevision value
  | Text.length value == 40 && Text.all lowerHex value = Right (Revision value)
  | otherwise = Left "revision must be exactly 40 lowercase hexadecimal characters"

lowerHex :: Char -> Bool
lowerHex char = char >= '0' && char <= '9' || char >= 'a' && char <= 'f'

data RecordKind = RunRecord | ComparisonRecord deriving stock (Eq, Ord, Show)

data Purpose = Nightly | Release | Baseline | Investigation deriving stock (Eq, Ord, Show)

data DataKind
  = RunSpecData
  | RunResultData
  | ManifestData
  | CellManifestData
  | SamplesData
  | SeriesData
  | VerdictsData
  | DiagnosisData
  | LogsData
  | ComparisonData
  deriving stock (Eq, Ord, Show)

data DataLink = DataLink
  { kind :: !DataKind,
    uri :: !Text,
    digest :: !Sha256,
    mediaType :: !Text,
    bytes :: !Natural
  }
  deriving stock (Eq, Show)

data ComponentSource = FromHackage | FromGit deriving stock (Eq, Ord, Show)

data ComponentRef = ComponentRef
  { project :: !Text,
    package :: !Text,
    version :: !Text,
    source :: !ComponentSource,
    revision :: !(Maybe Revision)
  }
  deriving stock (Eq, Show)

data SubjectKind = SubjectProject | SubjectPackage deriving stock (Eq, Ord, Show)
