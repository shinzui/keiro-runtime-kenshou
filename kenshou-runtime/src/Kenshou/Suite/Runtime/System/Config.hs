module Kenshou.Suite.Runtime.System.Config
  ( SystemConfig (..),
    TtlProfile (..),
    InboxMode (..),
    TransientPolicy (..),
    PublishMode (..),
    WakeMode (..),
    Timeouts (..),
    timeoutsFor,
    customerCount,
    skuCount,
  )
where

import Data.Aeson (FromJSON, ToJSON)
import Data.Text (Text)
import GHC.Generics (Generic)

data TtlProfile = ShortTtl | ProductionTtl
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

data InboxMode = InboxTable | InboxDelegated
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

data TransientPolicy = CrashOnly | AckRetryPolicy
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

data PublishMode = SyncPerRecord | BatchEnqueue
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

data WakeMode = WakePush | WakePoll
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

-- | Every role receives the whole system description, so one worker process
-- can be started for any role without consulting the harness again.
data SystemConfig = SystemConfig
  { shopDatabase :: !Text,
    warehouseDatabase :: !Text,
    brokers :: ![Text],
    topicPrefix :: !Text,
    shopTopic :: !Text,
    warehouseTopic :: !Text,
    shopConsumerGroup :: !Text,
    warehouseConsumerGroup :: !Text,
    orders :: !Int,
    durationSeconds :: !Int,
    ratePerSecond :: !Int,
    refuseFraction :: !Double,
    expireFraction :: !Double,
    routerFanout :: !Int,
    coolingOffMillis :: !Int,
    fulfilmentDeadlineSeconds :: !Int,
    ttlProfile :: !TtlProfile,
    inboxMode :: !InboxMode,
    transientPolicy :: !TransientPolicy,
    publishMode :: !PublishMode,
    poolSize :: !Int,
    shardCount :: !Int,
    outboxBatchSize :: !Int,
    wakeMode :: !WakeMode,
    maxConcurrentAdvances :: !Int,
    queueBatchSize :: !Int,
    orderingPolicy :: !Text,
    processesPerRole :: !Int,
    -- | Every driver submits every order instead of its own share.
    replicatedDrivers :: !Bool,
    -- | How many times each driver submits its sequence.
    submissionRounds :: !Int,
    -- | A trace-continuity sabotage control; @none@ outside those runs.
    traceSabotage :: !Text
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

-- | Lease and timeout values selected by @runtime.ttl-profile@. The runtime
-- has no clock abstraction, so crash recovery waits for these leases.
data Timeouts = Timeouts
  { workflowLeaseSeconds :: !Double,
    shardLeaseSeconds :: !Double,
    shardRenewSeconds :: !Double,
    publishingTimeoutSeconds :: !Double,
    timerRequeueSeconds :: !Double,
    jobVisibilitySeconds :: !Int
  }
  deriving stock (Eq, Show)

timeoutsFor :: TtlProfile -> Timeouts
timeoutsFor = \case
  ShortTtl -> Timeouts 10 6 2 15 10 10
  ProductionTtl -> Timeouts 60 30 10 300 300 30

-- | The seeded population is fixed so that funds and stock always suffice;
-- no business outcome depends on a ledger rejection.
customerCount :: Int
customerCount = 50

skuCount :: Int
skuCount = 20
