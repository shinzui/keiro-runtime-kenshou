module Kenshou.Cli.Command.Cohort (cohortCommand) where

import Kenshou.Cli.Cohort (runCohortCommand)
import Kenshou.Cli.Options (cohortCommandParser)
import Kenshou.Core.Cli (CliCommand (..), CliGroup (..))

cohortCommand :: CliCommand
cohortCommand =
  CliCommand
    { name = "cohort",
      description = "Inspect the pinned runtime cohort",
      group = Maintenance,
      hidden = False,
      parser = (\command _ -> runCohortCommand command) <$> cohortCommandParser
    }
