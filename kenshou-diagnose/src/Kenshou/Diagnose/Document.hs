module Kenshou.Diagnose.Document
  ( Diagnosis (..),
    DiagnosisKind (..),
    Generator (..),
    encodeDiagnosis,
    decodeDiagnosis,
    diagnosisKindText,
  )
where

import Data.Aeson
import Data.Aeson.Types (Parser)
import Data.ByteString.Lazy (ByteString)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime)

data DiagnosisKind = LeakDiagnosis | StallDiagnosis | ThreadDumpDiagnosis | ProfileDiagnosis
  deriving stock (Eq, Show)

data Generator = Generator
  { package :: Text,
    version :: Text,
    algorithm :: Text
  }
  deriving stock (Eq, Show)

data Diagnosis = Diagnosis
  { kind :: DiagnosisKind,
    runId :: Text,
    scenario :: Text,
    generatedAt :: UTCTime,
    generator :: Generator,
    body :: Value
  }
  deriving stock (Eq, Show)

diagnosisKindText :: DiagnosisKind -> Text
diagnosisKindText LeakDiagnosis = "leak"
diagnosisKindText StallDiagnosis = "stall"
diagnosisKindText ThreadDumpDiagnosis = "thread-dump"
diagnosisKindText ProfileDiagnosis = "profile"

parseDiagnosisKind :: Text -> Parser DiagnosisKind
parseDiagnosisKind "leak" = pure LeakDiagnosis
parseDiagnosisKind "stall" = pure StallDiagnosis
parseDiagnosisKind "thread-dump" = pure ThreadDumpDiagnosis
parseDiagnosisKind "profile" = pure ProfileDiagnosis
parseDiagnosisKind other = fail ("unknown diagnosis kind " <> Text.unpack other)

instance ToJSON Generator where
  toJSON value = object ["package" .= value.package, "version" .= value.version, "algorithm" .= value.algorithm]

instance FromJSON Generator where
  parseJSON = withObject "Generator" \value -> Generator <$> value .: "package" <*> value .: "version" <*> value .: "algorithm"

instance ToJSON Diagnosis where
  toJSON value =
    object
      [ "schema" .= ("kenshou.diagnosis/v1" :: Text),
        "kind" .= diagnosisKindText value.kind,
        "runId" .= value.runId,
        "scenario" .= value.scenario,
        "generatedAt" .= value.generatedAt,
        "generator" .= value.generator,
        "body" .= value.body
      ]

instance FromJSON Diagnosis where
  parseJSON = withObject "Diagnosis" \value -> do
    schema <- value .: "schema"
    if schema /= ("kenshou.diagnosis/v1" :: Text)
      then fail "unsupported diagnosis schema"
      else Diagnosis <$> (value .: "kind" >>= parseDiagnosisKind) <*> value .: "runId" <*> value .: "scenario" <*> value .: "generatedAt" <*> value .: "generator" <*> value .: "body"

encodeDiagnosis :: Diagnosis -> ByteString
encodeDiagnosis = encode

decodeDiagnosis :: ByteString -> Either String Diagnosis
decodeDiagnosis = eitherDecode
