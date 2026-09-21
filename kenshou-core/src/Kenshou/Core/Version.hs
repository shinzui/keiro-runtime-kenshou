module Kenshou.Core.Version (suiteVersion) where

import Data.Text (Text)
import Data.Text qualified as Text
import Data.Version (showVersion)
import Paths_kenshou_core (version)

suiteVersion :: Text
suiteVersion = Text.pack (showVersion version)
