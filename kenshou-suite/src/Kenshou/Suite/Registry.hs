{-# LANGUAGE CPP #-}
{-# LANGUAGE TemplateHaskell #-}

module Kenshou.Suite.Registry (program, runWithArgs) where

import Data.FileEmbed (embedFile, embedStringFile)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.IO qualified as Text.IO
import Kenshou.Cli (Program (..), runWithArgsWith, selfTestAssembly, standardCommands)
import Kenshou.Core.Bundle (LayerBundle (..))
import Kenshou.Core.Cohort (CohortDescriptor (..), ComponentId (..), ComponentSpec (..))
import Kenshou.Core.Knob (mkKnobName)
import Kenshou.Perf.Contracts (PerfContracts (..), noPerfContracts)
import Kenshou.Suite.Attest (measurementRecomputer, pairedComparisonRecomputer, runOutcomeRecomputer)
import Kenshou.Suite.Schema (schemaBundle)
import Kenshou.Suite.Version (appVersionWithGit)
import System.Exit (ExitCode (..))
#ifdef FULL_RUNTIME_SUITES
import Kenshou.Suite.Kafka qualified as Kafka
import Kenshou.Suite.Keiro qualified as Keiro
import Kenshou.Suite.Kiroku qualified as Kiroku
import Kenshou.Suite.Pgmq qualified as Pgmq
import Kenshou.Suite.Runtime qualified as Runtime
#endif
import Kenshou.Suite.Shibuya qualified as Shibuya

program :: Program
program =
  selfTestAssembly
    { bundles = map (\bundle -> bundle {evidenceSubject = Just "mori://shinzui/keiro-runtime-kenshou"}) selfTestAssembly.bundles <> [schemaBundle] <> layerBundles,
      commands = standardCommands [runOutcomeRecomputer, measurementRecomputer, pairedComparisonRecomputer],
      componentGraph = $(embedFile "data/components.json"),
      perf =
        noPerfContracts
          { reviewedPhaseContracts = [("shibuya/core-ordering/benchmark/concurrency-sweep", 2), ("shibuya/pgmq-adapter/benchmark/end-to-end-throughput-latency", 1)],
            steadyCountKnob = Just (either (error . show) id (mkKnobName "shibuya.messages")),
            laneStanzas = \descriptor -> harnessStanzas <> if isolatedShibuya descriptor then ["package kenshou-suite", "  flags: -runtime-suites", "package kenshou-support", "  flags: -keiro-schema"] else [],
            lanePackages = \descriptor paths -> if isolatedShibuya descriptor then filter (\path -> path `elem` ["kenshou-suite", "kenshou-support", "kenshou-shibuya"]) paths else paths
          }
    }

layerBundles :: [LayerBundle]
#ifdef FULL_RUNTIME_SUITES
layerBundles = [Pgmq.bundle, Kiroku.bundle, Keiro.bundle, Shibuya.bundle, Kafka.bundle, Runtime.bundle]
#else
layerBundles = [Shibuya.bundle]
#endif
runWithArgs :: [String] -> IO ExitCode
runWithArgs ["--version"] = Text.IO.putStrLn appVersionWithGit >> pure ExitSuccess
runWithArgs arguments = runWithArgsWith program arguments

harnessStanzas :: [Text]
harnessStanzas = Text.lines (Text.pack $(embedStringFile "data/kenshou.project"))

isolatedShibuya :: CohortDescriptor -> Bool
isolatedShibuya descriptor = "shibuya" `elem` names && all (`elem` ["shibuya", "shibuya-pgmq-adapter", "pgmq-hs", "kiroku"]) names
  where
    names = map (unComponentId . (.componentId)) descriptor.descriptorComponents
