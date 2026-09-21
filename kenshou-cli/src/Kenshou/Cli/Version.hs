{-# LANGUAGE CPP #-}
{-# LANGUAGE TemplateHaskell #-}

module Kenshou.Cli.Version
  ( appVersion,
    appVersionWithGit,
    gitCommitShort,
  )
where

import Data.Text (Text)
import Data.Text qualified as Text
import Data.Version (showVersion)
import GitHash (GitInfo, giHash, tGitInfoCwdTry)
import Paths_kenshou_cli (version)

appVersion :: Text
appVersion = Text.pack (showVersion version)

gitInfo :: Either String GitInfo
gitInfo = $$tGitInfoCwdTry

nixGitHash :: Maybe Text
#ifdef GIT_HASH
nixGitHash = Just GIT_HASH
#else
nixGitHash = Nothing
#endif

gitCommitShort :: Maybe Text
gitCommitShort = case gitInfo of
  Right info -> Just (Text.pack (take 7 (giHash info)))
  Left _ -> nixGitHash

appVersionWithGit :: Text
appVersionWithGit = "kenshou v" <> appVersion <> maybe "" (\commit -> " (" <> commit <> ")") gitCommitShort
