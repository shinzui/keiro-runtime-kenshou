module Kenshou.Core.Selftest (bundle) where

import Data.Text (Text)
import Kenshou.Core.Bundle (LayerBundle (..))
import Kenshou.Core.Context (RunContext)
import Kenshou.Core.Dimension (noDimensions)
import Kenshou.Core.Env (noEnvironment)
import Kenshou.Core.Id (Layer (..), parseScenarioId)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Scenario

bundle :: LayerBundle
bundle = LayerBundle Selftest [alwaysFail, alwaysPass, errors] []

alwaysPass, alwaysFail, errors :: Scenario
alwaysPass = scenario "selftest/kernel/correctness/always-pass" "Always reports passed." (const (pure passed))
alwaysFail = scenario "selftest/kernel/correctness/always-fail" "Always reports failed." (const (pure (failedWith ["seeded-failure"] "this scenario always fails")))
errors = scenario "selftest/kernel/correctness/errors" "Always throws." (const (ioError (userError "seeded self-test error")))

scenario :: Text -> Text -> (RunContext -> IO ScenarioReport) -> Scenario
scenario identifier summary action =
  Scenario
    { id = either (error . show) id (parseScenarioId identifier),
      revision = 1,
      summary,
      tier = TierSmoke,
      placement = PlaceEither,
      knobs = [],
      dimensions = noDimensions,
      phases = zeroPhases,
      requires = noEnvironment,
      knownDefect = Nothing,
      run = action
    }
