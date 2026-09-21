module Kenshou.Cli.Registry (bundles, commands, topics) where

import Kenshou.Cli.Command.Cohort (cohortCommand)
import Kenshou.Cli.Command.Execute (executeCommand)
import Kenshou.Cli.Command.List (listCommand)
import Kenshou.Cli.Command.Plan (planCommand)
import Kenshou.Cli.Command.Run (runCommand)
import Kenshou.Cli.Command.Worker (workerCommand)
import Kenshou.Cli.Completions (completionsCommand)
import Kenshou.Cli.Help qualified as Help
import Kenshou.Core.Bundle (LayerBundle)
import Kenshou.Core.Cli (CliCommand, HelpTopic)
import Kenshou.Core.Selftest qualified as Selftest
import Kenshou.Measure.Selftest qualified as MeasureSelftest

-- Extension contract: coverage plans add one imported bundle and one list element;
-- tool plans add command and topic values here without changing a central sum type.
bundles :: [LayerBundle]
bundles = [Selftest.bundle, MeasureSelftest.bundle]

commands :: [CliCommand]
commands = [listCommand, planCommand, Help.helpCommand, runCommand, executeCommand, workerCommand, cohortCommand, completionsCommand]

topics :: [HelpTopic]
topics = Help.topics
