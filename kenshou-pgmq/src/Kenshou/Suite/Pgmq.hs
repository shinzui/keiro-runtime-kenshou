module Kenshou.Suite.Pgmq (bundle) where

import Kenshou.Core.Bundle (LayerBundle (..))
import Kenshou.Core.Id (Layer (Pgmq))
import Kenshou.Suite.Pgmq.Bench.Backlog qualified as BenchBacklog
import Kenshou.Suite.Pgmq.Bench.Fifo qualified as BenchFifo
import Kenshou.Suite.Pgmq.Bench.Ladder qualified as BenchLadder
import Kenshou.Suite.Pgmq.Bench.Notify qualified as BenchNotify
import Kenshou.Suite.Pgmq.Bench.Overhead qualified as BenchOverhead
import Kenshou.Suite.Pgmq.Bench.ProduceConsume qualified as BenchProduceConsume
import Kenshou.Suite.Pgmq.Bench.ReadAck qualified as BenchReadAck
import Kenshou.Suite.Pgmq.Bench.Send qualified as BenchSend
import Kenshou.Suite.Pgmq.Concurrency.Config qualified as ConcurrentConfig
import Kenshou.Suite.Pgmq.Concurrency.Crash qualified as ConcurrentCrash
import Kenshou.Suite.Pgmq.Concurrency.Fifo qualified as ConcurrentFifo
import Kenshou.Suite.Pgmq.Concurrency.Lease qualified as ConcurrentLease
import Kenshou.Suite.Pgmq.Concurrency.Notify qualified as ConcurrentNotify
import Kenshou.Suite.Pgmq.Concurrency.Outage qualified as ConcurrentOutage
import Kenshou.Suite.Pgmq.Concurrency.Pool qualified as ConcurrentPool
import Kenshou.Suite.Pgmq.Concurrency.Retention qualified as ConcurrentRetention
import Kenshou.Suite.Pgmq.Correctness.Ack qualified as CorrectnessAck
import Kenshou.Suite.Pgmq.Correctness.Config qualified as CorrectnessConfig
import Kenshou.Suite.Pgmq.Correctness.Effectful qualified as CorrectnessEffectful
import Kenshou.Suite.Pgmq.Correctness.Fifo qualified as CorrectnessFifo
import Kenshou.Suite.Pgmq.Correctness.Notify qualified as CorrectnessNotify
import Kenshou.Suite.Pgmq.Correctness.Queue qualified as CorrectnessQueue
import Kenshou.Suite.Pgmq.Correctness.Read qualified as CorrectnessRead
import Kenshou.Suite.Pgmq.Correctness.Send qualified as CorrectnessSend
import Kenshou.Suite.Pgmq.Correctness.Topics qualified as CorrectnessTopics
import Kenshou.Suite.Pgmq.Correctness.Vt qualified as CorrectnessVt
import Kenshou.Suite.Pgmq.Roles qualified as Roles
import Kenshou.Suite.Pgmq.Soak.SteadyState qualified as SteadyState

bundle :: LayerBundle
bundle = LayerBundle Pgmq scenarios Roles.roles
  where
    scenarios =
      concat
        [ CorrectnessQueue.scenarios,
          CorrectnessSend.scenarios,
          CorrectnessRead.scenarios,
          CorrectnessAck.scenarios,
          CorrectnessVt.scenarios,
          CorrectnessFifo.scenarios,
          CorrectnessTopics.scenarios,
          CorrectnessNotify.scenarios,
          CorrectnessConfig.scenarios,
          CorrectnessEffectful.scenarios,
          ConcurrentLease.scenarios,
          ConcurrentCrash.scenarios,
          ConcurrentPool.scenarios,
          ConcurrentOutage.scenarios,
          ConcurrentFifo.scenarios,
          ConcurrentNotify.scenarios,
          ConcurrentRetention.scenarios,
          ConcurrentConfig.scenarios,
          BenchLadder.scenarios,
          BenchSend.scenarios,
          BenchReadAck.scenarios,
          BenchProduceConsume.scenarios,
          BenchBacklog.scenarios,
          BenchFifo.scenarios,
          BenchNotify.scenarios,
          BenchOverhead.scenarios,
          SteadyState.scenarios
        ]
