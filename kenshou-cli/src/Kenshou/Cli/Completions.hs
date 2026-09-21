module Kenshou.Cli.Completions (completionsCommand) where

import Data.Text (Text)
import Data.Text.IO qualified as Text.IO
import Kenshou.Core.Cli (CliCommand (..), CliGroup (..))
import Options.Applicative
import System.Exit (ExitCode (..))

data Shell = Bash | Zsh | Fish

completionsCommand :: CliCommand
completionsCommand =
  CliCommand
    { name = "completions",
      description = "Generate parser-derived shell completions",
      group = Maintenance,
      hidden = False,
      parser = (\shell _ -> Text.IO.putStr (script shell) >> pure ExitSuccess) <$> shellParser
    }

shellParser :: Parser Shell
shellParser = argument (eitherReader parseShell) (metavar "bash|zsh|fish" <> help "Target shell")
  where
    parseShell "bash" = Right Bash
    parseShell "zsh" = Right Zsh
    parseShell "fish" = Right Fish
    parseShell value = Left ("unsupported shell " <> show value)

script :: Shell -> Text
script Bash = "_kenshou_completions() {\n  local CMDLINE=(--bash-completion-index $COMP_CWORD)\n  for arg in ${COMP_WORDS[@]}; do CMDLINE+=(--bash-completion-word \"$arg\"); done\n  COMPREPLY=( $(kenshou \"${CMDLINE[@]}\" 2>/dev/null) )\n}\ncomplete -o filenames -F _kenshou_completions kenshou\n"
script Zsh = "#compdef kenshou\n_kenshou() {\n  local -a completions\n  local CMDLINE=(--bash-completion-enriched --bash-completion-index $((CURRENT - 1)))\n  for arg in ${words[@]}; do CMDLINE+=(--bash-completion-word \"$arg\"); done\n  completions=(\"${(@f)$(kenshou $CMDLINE 2>/dev/null)}\")\n  _describe kenshou completions\n}\n_kenshou\n"
script Fish = "complete -c kenshou -f\nfunction __kenshou_complete\n  set -l tokens (commandline -cop)\n  set -l args --bash-completion-enriched --bash-completion-index (count $tokens)\n  for token in $tokens; set args $args --bash-completion-word $token; end\n  kenshou $args 2>/dev/null\nend\ncomplete -c kenshou -a '(__kenshou_complete)'\n"
