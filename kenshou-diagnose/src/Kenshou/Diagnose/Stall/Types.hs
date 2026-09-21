module Kenshou.Diagnose.Stall.Types
  ( StallClass (..),
    OnStall (..),
    SpinEvidence (..),
    StallSnapshot (..),
    StallReport (..),
    stallClassText,
  )
where

import Data.Aeson
import Data.Aeson.Types (Parser)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime)
import Kenshou.Diagnose.LockGraph (LockGraph)
import Kenshou.Diagnose.Pool (PoolStats)
import Kenshou.Diagnose.Postgres (PostgresSnapshot)
import Kenshou.Diagnose.Progress (ProgressSnapshot)
import Kenshou.Diagnose.Threads (ThreadDump)

data StallClass = Deadlock | LockWait | PoolStarvation | BlockedIndefinitely | IdleSpin | Unknown
  deriving stock (Eq, Ord, Show)

data OnStall = CaptureAndContinue | CaptureAndAbort deriving stock (Eq, Show)

data SpinEvidence = SpinEvidence {cpuCores :: !Double, statementCallsPerSecond :: !Double}
  deriving stock (Eq, Show)

data StallSnapshot = StallSnapshot
  { deadlineSeconds :: !Double,
    progress :: ![ProgressSnapshot],
    haskellThreads :: !ThreadDump,
    postgres :: !(Maybe PostgresSnapshot),
    graph :: !LockGraph,
    pools :: ![PoolStats],
    stateProbes :: !Value,
    idleSpin :: !SpinEvidence
  }
  deriving stock (Eq, Show)

data StallReport = StallReport
  { detectedAt :: !UTCTime,
    captureNumber :: !Int,
    classification :: !StallClass,
    secondary :: ![StallClass],
    reasons :: ![Text],
    snapshot :: !StallSnapshot
  }
  deriving stock (Eq, Show)

stallClassText :: StallClass -> Text
stallClassText Deadlock = "deadlock"
stallClassText LockWait = "lock-wait"
stallClassText PoolStarvation = "pool-starvation"
stallClassText BlockedIndefinitely = "blocked-indefinitely"
stallClassText IdleSpin = "idle-spin"
stallClassText Unknown = "unknown"

parseStallClass :: Text -> Parser StallClass
parseStallClass value = maybe (fail ("unknown stall class " <> Text.unpack value)) pure (lookup value [(stallClassText class_, class_) | class_ <- [Deadlock, LockWait, PoolStarvation, BlockedIndefinitely, IdleSpin, Unknown]])

instance ToJSON StallClass where toJSON = String . stallClassText

instance FromJSON StallClass where parseJSON = withText "StallClass" parseStallClass

instance ToJSON SpinEvidence where toJSON value = object ["cpuCores" .= value.cpuCores, "statementCallsPerSecond" .= value.statementCallsPerSecond]

instance FromJSON SpinEvidence where parseJSON = withObject "SpinEvidence" \value -> SpinEvidence <$> value .:? "cpuCores" .!= 0 <*> value .:? "statementCallsPerSecond" .!= 0

instance ToJSON StallSnapshot where toJSON value = object ["deadlineSeconds" .= value.deadlineSeconds, "progress" .= value.progress, "haskellThreads" .= value.haskellThreads, "postgres" .= value.postgres, "graph" .= value.graph, "pools" .= value.pools, "stateProbes" .= value.stateProbes, "idleSpin" .= value.idleSpin]

instance FromJSON StallSnapshot where parseJSON = withObject "StallSnapshot" \value -> StallSnapshot <$> value .: "deadlineSeconds" <*> value .:? "progress" .!= [] <*> value .: "haskellThreads" <*> value .:? "postgres" <*> value .: "graph" <*> value .:? "pools" .!= [] <*> value .:? "stateProbes" .!= Null <*> value .:? "idleSpin" .!= SpinEvidence 0 0

instance ToJSON StallReport where toJSON value = object ["detectedAt" .= value.detectedAt, "captureNumber" .= value.captureNumber, "classification" .= value.classification, "secondary" .= value.secondary, "reasons" .= value.reasons, "snapshot" .= value.snapshot]

instance FromJSON StallReport where parseJSON = withObject "StallReport" \value -> StallReport <$> value .: "detectedAt" <*> value .: "captureNumber" <*> value .: "classification" <*> value .:? "secondary" .!= [] <*> value .:? "reasons" .!= [] <*> value .: "snapshot"
