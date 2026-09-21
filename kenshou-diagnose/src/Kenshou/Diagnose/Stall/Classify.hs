module Kenshou.Diagnose.Stall.Classify
  ( classify,
  )
where

import Data.List (find)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Kenshou.Diagnose.LockGraph (LockGraph (..))
import Kenshou.Diagnose.Pool (PoolStats (..))
import Kenshou.Diagnose.Postgres (ActivityRow (..), PostgresSnapshot (..))
import Kenshou.Diagnose.Stall.Types
import Kenshou.Diagnose.Threads (ThreadDump (..), ThreadEntry (..))

classify :: StallSnapshot -> (StallClass, [StallClass], [Text])
classify snapshot = (fromMaybe Unknown (fst <$> find snd checks), [class_ | (class_, True) <- checks], reasons)
  where
    checks =
      [ (Deadlock, not (null snapshot.graph.cycles)),
        (LockWait, lockWait),
        (PoolStarvation, poolStarvation),
        (IdleSpin, idleSpin),
        (BlockedIndefinitely, blockedIndefinitely)
      ]
    activity = maybe [] (.activity) snapshot.postgres
    lockWait = null snapshot.graph.cycles && any longLock activity
    longLock row = row.waitEventType == Just "Lock" && fromMaybe 0 row.queryAgeSeconds >= snapshot.deadlineSeconds / 2
    saturated = [pool | pool <- snapshot.pools, pool.saturatedSeconds >= snapshot.deadlineSeconds / 2 && pool.inUse >= pool.size]
    blockedOnStm = any ((== Just "BlockedOnSTM") . (.blockReason)) (nonHarness snapshot.haskellThreads.entries)
    poolStarvation = not lockWait && not (null saturated) && blockedOnStm
    idleSpin = snapshot.idleSpin.cpuCores >= 0.5 || snapshot.idleSpin.statementCallsPerSecond >= 100
    nonHarness = filter (maybe True (not . Text.isPrefixOf "kenshou:diagnose") . (.label))
    quietThread entry = entry.status `elem` ["finished", "died"] || entry.blockReason `elem` [Just "BlockedOnMVar", Just "BlockedOnSTM"]
    allDatabaseIdle = maybe False (\database -> database.available && not (null database.activity) && all ((== "idle") . (.state)) database.activity) snapshot.postgres
    blockedIndefinitely = not idleSpin && all quietThread (nonHarness snapshot.haskellThreads.entries) && allDatabaseIdle
    reasons =
      ["wait-for graph contains a cycle" | not (null snapshot.graph.cycles)]
        <> ["sessions have waited on locks for at least half the watchdog deadline" | lockWait]
        <> ["pool " <> pool.name <> " is saturated" | pool <- saturated]
        <> ["CPU or database statement rate is high while progress is zero" | idleSpin]
        <> ["all non-harness threads are finished or indefinitely blocked" | blockedIndefinitely]
