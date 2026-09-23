module Kenshou.Cli.Registry (bundles, commands, topics) where

import Kenshou.Check.Selftest qualified as CheckSelftest
import Kenshou.Cli.Command.Cohort (cohortCommand)
import Kenshou.Cli.Command.Execute (executeCommand)
import Kenshou.Cli.Command.List (listCommand)
import Kenshou.Cli.Command.Overhead (overheadCommand)
import Kenshou.Cli.Command.Plan (planCommand)
import Kenshou.Cli.Command.Run (runCommand)
import Kenshou.Cli.Command.Worker (workerCommand)
import Kenshou.Cli.Completions (completionsCommand)
import Kenshou.Cli.Diagnose qualified as Diagnose
import Kenshou.Cli.Help qualified as Help
import Kenshou.Core.Bundle (LayerBundle)
import Kenshou.Core.Cli (CliCommand, HelpTopic)
import Kenshou.Core.Selftest qualified as Selftest
import Kenshou.Diagnose.SelfTest qualified as DiagnoseSelftest
import Kenshou.Measure.Cli qualified as Measure
import Kenshou.Measure.Selftest qualified as MeasureSelftest
import Kenshou.Suite.Kiroku qualified as Kiroku
import Kenshou.Suite.Pgmq qualified as Pgmq
import Kenshou.Suite.Shibuya qualified as Shibuya
import Kenshou.Telemetry.SelfTest qualified as TelemetrySelftest

-- Extension contract: coverage plans add one imported bundle and one list element;
-- tool plans add command and topic values here without changing a central sum type.
bundles :: [LayerBundle]
bundles = [Selftest.bundle, MeasureSelftest.bundle, CheckSelftest.bundle, DiagnoseSelftest.bundle, TelemetrySelftest.selfTestBundle, Pgmq.bundle, Kiroku.bundle, Shibuya.bundle]

commands :: [CliCommand]
commands = [listCommand, planCommand, Help.helpCommand, runCommand, executeCommand, overheadCommand, Measure.summarizeCommand, Measure.compareCommand, Diagnose.diagnoseCommand, workerCommand, cohortCommand, completionsCommand]

topics :: [HelpTopic]
topics = Help.topics
