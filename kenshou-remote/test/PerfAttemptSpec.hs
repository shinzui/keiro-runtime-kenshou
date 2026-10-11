module PerfAttemptSpec (spec) where

import Data.Aeson
import Data.ByteString qualified as Bytes
import Data.IORef
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Kenshou.Core.Id (mkSeed, newRunId, renderRunId)
import Kenshou.Measure.Compare.Compatibility (VaryingAxis (..))
import Kenshou.Measure.Compare.Ordering (PairedOrdering (..))
import Kenshou.Measure.Compare.Policy qualified as Policy
import Kenshou.Perf.Plan
import Kenshou.Perf.Result
import Kenshou.Plan.RunPlan (PlannedRun (runId), RunPlan (..))
import Kenshou.Remote.Cell.WorkJson (decodeWorkPlan)
import Kenshou.Remote.Pair
import Kenshou.Remote.Perf.Attempt
import Kenshou.Remote.Perf.Journal
import Kenshou.Remote.Perf.Runner
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

spec :: Spec
spec = describe "performance paired attempts" do
  it "bounds replacements and reuses retained invalid paths without resubmitting trials" $ withSystemTempDirectory "perf-attempt" \directory -> do
    (entry, schedule, policy) <- fixture
    identifier <- newRunId
    calls <- newIORef (0 :: Int)
    replacements <- newIORef (0 :: Int)
    let lease = LeaseIdentity "alpha" identifier
        callbacks = ComparisonHooks (modifyIORef' replacements (+ 1)) (\_ -> pure ())
        execute run = do
          modifyIORef' calls (+ 1)
          let path = directory </> "retained" </> Text.unpack (renderRunId run.runId)
          createDirectoryIfMissing True path
          encodeFile (path </> "run-result.json") (object [])
          encodeFile (path </> "run-spec.json") (object [])
          pure (Right path)
    result <- executeAttempt lease entry schedule policy (VaryControl :| []) directory callbacks execute
    result.infrastructureState `shouldBe` "failed"
    result.validPairs `shouldBe` 0
    readIORef calls `shouldReturn` 14
    readIORef replacements `shouldReturn` 2
    _ <- executeAttempt lease entry schedule policy (VaryControl :| []) directory callbacks execute
    readIORef calls `shouldReturn` 14
    another <- newRunId
    executeAttempt (LeaseIdentity "alpha" another) entry schedule policy (VaryControl :| []) directory callbacks execute `shouldThrow` anyIOException
  it "rejects an incomplete schedule and a forged retained path before dispatch" $ withSystemTempDirectory "perf-attempt-rejection" \directory -> do
    (entry, schedule, policy) <- fixture
    identifier <- newRunId
    let callbacks = ComparisonHooks (pure ()) (\_ -> pure ())
        execute _ = expectationFailure "must not dispatch an invalid attempt" >> pure (Left "invalid")
    executeAttempt (LeaseIdentity "alpha" identifier) entry schedule {runs = drop 1 schedule.runs} policy (VaryControl :| []) (directory </> "incomplete") callbacks execute `shouldThrow` anyIOException
    createDirectoryIfMissing True (directory </> "forged")
    encodeFile (directory </> "forged/trial-paths.json") (Map.singleton ("unplanned" :: Text.Text) ("../escape" :: FilePath))
    executeAttempt (LeaseIdentity "alpha" identifier) entry schedule policy (VaryControl :| []) (directory </> "forged") callbacks execute `shouldThrow` anyIOException

fixture :: IO (PlannedProfile, RunPlan, Policy.Policy)
fixture = do
  plan <- eitherDecodeFileStrict' "../kenshou-core/test/golden/perf-plan.json" >>= either fail pure
  entry <- case (plan :: PerfPlan).selected of value : _ -> pure value; _ -> fail "empty profile fixture"
  identifier <- newRunId
  seed <- either (fail . show) pure (mkSeed 37)
  source <-
    either
      (fail . show)
      pure
      ( decodeWorkPlan
          ( object
              [ "schema" .= ("kenshou.run-plan/v1" :: Text.Text),
                "planId" .= identifier,
                "runs"
                  .= [ object
                         [ "ordinal" .= (0 :: Int),
                           "runId" .= identifier,
                           "estimateMinutes" .= (1 :: Int),
                           "spec"
                             .= object
                               [ "schema" .= ("kenshou.run-spec/v1" :: Text.Text),
                                 "runId" .= identifier,
                                 "scenario" .= entry.profile.scenario,
                                 "scenarioRevision" .= entry.profile.scenarioRevision,
                                 "knobs" .= entry.profile.knobs,
                                 "dimensions" .= entry.profile.dimensions,
                                 "seed" .= seed
                               ]
                         ]
                     ]
              ]
          )
      )
  schedule <- either (fail . show) pure (pairPlan (PairRequest "candidate" "baseline" 5 ABBA 37 2) source)
  policy <- Bytes.readFile "../policies/default.json" >>= either (fail . show) pure . Policy.decodePolicy
  pure (entry, schedule, policy)
