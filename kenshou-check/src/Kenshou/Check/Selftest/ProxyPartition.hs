module Kenshou.Check.Selftest.ProxyPartition (proxyPartitionScenario) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async
import Data.Aeson (object, (.=))
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (diffUTCTime, getCurrentTime)
import Kenshou.Check.Fault.Network
import Kenshou.Check.Scenario
import Kenshou.Check.Verdict
import Kenshou.Core.Context (RunContext (..), requirePostgres)
import Kenshou.Core.Dimension
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..))
import Kenshou.Core.Env.Postgres (PostgresEnv (..))
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Scenario
import System.Exit (ExitCode (..))
import System.Process (readProcessWithExitCode)
import System.Timeout (timeout)

proxyPartitionScenario :: Scenario
proxyPartitionScenario =
  Scenario
    { id = either (error . show) id (parseScenarioId "selftest/check/concurrency/proxy-partition"),
      revision = 1,
      summary = "Routes PostgreSQL through the fault proxy and observes latency, stall, reset, and recovery.",
      tier = TierSmoke,
      placement = PlaceEither,
      knobs = [],
      dimensions = postgresDimensions (PgFsyncOff :| [PgDurable]) (Pg18 :| [Pg17]) telemetryOff,
      phases = zeroPhases,
      requires = EnvRequirements (Just (PostgresRequirement [] [] False)) [] False,
      knownDefect = Nothing,
      run = runProxyPartition
    }

runProxyPartition :: RunContext -> IO ScenarioReport
runProxyPartition context = withCheck context \environment -> do
  let postgres = requirePostgres context
      endpoint = maybe (error "PostgreSQL TCP endpoint unavailable") (\(host, port) -> pure (Text.unpack host, fromIntegral port)) postgres.tcpEndpoint
  withTcpProxy endpoint \proxy -> do
    let connection = proxiedConnectionString postgres proxy
    baseline <- psql connection "select 1"
    setProxyMode proxy (Latency 40)
    started <- getCurrentTime
    delayed <- psql connection "select 1"
    ended <- getCurrentTime
    setProxyMode proxy Stall
    stalled <- async (psql connection "select pg_sleep(0.05)")
    threadDelay 150000
    wasStalled <- isNothing <$> poll stalled
    setProxyMode proxy Forward
    stallResult <- wait stalled
    setProxyMode proxy Blackhole
    blackholeResult <- timeout 500000 (psql connection "select 1")
    let wasBlackholed = isNothing blackholeResult
    resetCount <- resetConnections proxy
    setProxyMode proxy Forward
    recovered <- psql connection "select 1"
    let delayMillis = floor (diffUTCTime ended started * 1000) :: Int
        held = baseline == Right "1" && delayed == Right "1" && delayMillis >= 40 && wasStalled && stallResult == Right "" && wasBlackholed && resetCount > 0 && recovered == Right "1"
    now <- getCurrentTime
    let verdict = Verdict "proxy-effects" "network-faults-are-observable" Contract (if held then Held else Violated) Nothing "The proxy delayed, stalled, blackholed, reset, and then recovered a real PostgreSQL connection." (Map.fromList [("examined", 5), ("violations", if held then 0 else 1)]) (object ["delayMillis" .= delayMillis, "stalled" .= wasStalled, "blackholed" .= wasBlackholed, "resetConnections" .= resetCount]) [] False [] Nothing now 0
    finishWithVerdicts environment [verdict]

psql :: Text -> Text -> IO (Either Text Text)
psql connection statement = do
  (code, output, err) <- readProcessWithExitCode "psql" ["-d", Text.unpack connection, "-Atqc", Text.unpack statement] ""
  pure case code of ExitSuccess -> Right (Text.strip (Text.pack output)); ExitFailure _ -> Left (Text.strip (Text.pack err))

isNothing :: Maybe value -> Bool
isNothing Nothing = True
isNothing (Just _) = False

telemetryOff :: DimensionSupport
telemetryOff = DimensionSupport (Supported (Support (TracingOff :| []) TracingOff)) (Supported (Support (MetricsOff :| []) MetricsOff)) NotApplicable NotApplicable
