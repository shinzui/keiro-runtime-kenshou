module Kenshou.Cli.Registry (bundles, commands, topics) where

import Kenshou.Cli.Command.Cohort (cohortCommand)
import Kenshou.Cli.Command.List (listCommand)
import Kenshou.Cli.Completions (completionsCommand)
import Kenshou.Cli.Help qualified as Help
import Kenshou.Core.Bundle (LayerBundle)
import Kenshou.Core.Cli (CliCommand, HelpTopic)
import Kenshou.Core.Selftest qualified as Selftest

-- Extension contract: coverage plans add one imported bundle and one list element;
-- tool plans add command and topic values here without changing a central sum type.
bundles :: [LayerBundle]
bundles = [Selftest.bundle]

commands :: [CliCommand]
commands = [listCommand, Help.helpCommand, cohortCommand, completionsCommand]

topics :: [HelpTopic]
topics = Help.topics
