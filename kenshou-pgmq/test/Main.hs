module Main (main) where

import Data.List (isInfixOf)
import Data.Map.Strict qualified as Map
import Data.Text qualified as Text
import Data.Time (UTCTime (..), addUTCTime, fromGregorian, secondsToDiffTime)
import Kenshou.Core.Bundle (LayerBundle (..), mkRegistry)
import Kenshou.Core.Context (Environment (..), RunContext (..))
import Kenshou.Core.Dimension (emptyDimensions)
import Kenshou.Core.Id (Kind (..), ScenarioId (..), mkSeed, parseRunId, parseScenarioId, renderScenarioId)
import Kenshou.Core.Knob qualified as CoreKnob
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Scenario (Scenario (..))
import Kenshou.Suite.Pgmq (bundle)
import Kenshou.Suite.Pgmq.Client (Layer (..), parseLayer)
import Kenshou.Suite.Pgmq.Facts
import Kenshou.Suite.Pgmq.Harness (scenarioQueueName)
import Kenshou.Suite.Pgmq.Knobs qualified as PgmqKnobs
import Kenshou.Suite.Pgmq.Oracle
import Kenshou.Suite.Pgmq.TopicModel (matches)
import Pgmq.Types (parseRoutingKey, parseTopicPattern, queueNameToText)
import System.Directory (doesFileExist, getCurrentDirectory)
import System.FilePath (takeDirectory, (</>))
import Test.Hspec

main :: IO ()
main = hspec do
  describe "pgmq bundle" do
    it "is registry-valid and contains the planned scenario counts" do
      case mkRegistry [bundle] of
        Left errors -> expectationFailure (show errors)
        Right _ -> pure ()
      length bundle.scenarios `shouldBe` 49
      length (filter isCorrectness bundle.scenarios) `shouldBe` 18

    it "documents every registered scenario" do
      root <- findRepositoryRoot =<< getCurrentDirectory
      guide <- readFile (root </> "docs/layers/pgmq.md")
      mapM_ (\scenario -> guide `shouldSatisfy` isInfixOf (Text.unpack (renderScenarioId scenario.id))) bundle.scenarios

  describe "lease oracle" do
    it "accepts consecutive leases after visibility expiry" do
      checkLeaseIntervals [lease 1 1 at0 at2, lease 1 2 at2 at4] `shouldBe` []

    it "detects overlapping lease intervals" do
      checkLeaseIntervals [lease 1 1 at0 at2, lease 1 2 at1 at4]
        `shouldBe` [OverlappingLease 1 at2 at1]

    it "accepts a lease made visible early by an explicit release" do
      checkLeaseIntervals [lease 1 1 at0 at4, Released 1 at1, lease 1 2 at1 at4] `shouldBe` []

    it "detects duplicate read counts" do
      checkLeaseIntervals [lease 1 1 at0 at2, lease 1 1 at2 at4]
        `shouldBe` [DuplicateReadCount 1 1]

    it "detects delivery before the scheduled due time" do
      checkNotBeforeDue [Sent "k" 1 Nothing Nothing (Just at2), lease 1 1 at1 at4]
        `shouldBe` [EarlyDelivery "k" at2 at1]

  describe "knobs and queue identity" do
    it "resolves the common defaults" do
      let resolved = resolvedOrFail (CoreKnob.resolveKnobs PgmqKnobs.commonKnobs [])
      PgmqKnobs.resolveKnobs (contextWith resolved) `shouldSatisfy` either (const False) ((== PgmqKnobs.Standard) . (.queueKind))

    it "rejects long polling with pop" do
      let assignments = map (resolvedOrFail . CoreKnob.parseAssignment) ["pgmq.read-strategy=pop", "pgmq.poll.max-seconds=2"]
          resolved = resolvedOrFail (CoreKnob.resolveKnobs PgmqKnobs.commonKnobs assignments)
      PgmqKnobs.resolveKnobs (contextWith resolved) `shouldBe` Left "pgmq.read-strategy=pop cannot be combined with long polling"

    it "derives a lower-case per-run queue name" do
      queueNameToText (scenarioQueueName (contextWith CoreKnob.emptyKnobs) "My Tag") `shouldBe` "kn01a0c69b_my_tag"

    it "selects three distinct benchmark client layers" do
      traverse parseLayer ["raw-sql", "hasql", "effectful"] `shouldBe` Right [RawSql, HasqlLayer, EffectfulLayer]

  describe "topic matcher" do
    it "implements one-segment and tail wildcards" do
      let patternOne = parsed parseTopicPattern "orders.*.created"
          patternTail = parsed parseTopicPattern "orders.#"
          matching = parsed parseRoutingKey "orders.us.created"
          short = parsed parseRoutingKey "orders"
      matches patternOne matching `shouldBe` True
      matches patternOne short `shouldBe` False
      matches patternTail matching `shouldBe` True
      matches patternTail short `shouldBe` True

at0, at1, at2, at4 :: UTCTime
at0 = UTCTime (fromGregorian 2026 9 21) (secondsToDiffTime 0)
at1 = addUTCTime 1 at0
at2 = addUTCTime 2 at0
at4 = addUTCTime 4 at0

lease :: Int -> Int -> UTCTime -> UTCTime -> PgmqFact
lease messageId readCount readAt visibleAt = Leased "k" (fromIntegral messageId) (fromIntegral readCount) readAt visibleAt Nothing

parsed :: (Text.Text -> Either error value) -> Text.Text -> value
parsed parser value = either (const (error "test parser rejected fixture")) id (parser value)

resolvedOrFail :: (Show error) => Either error value -> value
resolvedOrFail = either (error . show) id

isCorrectness :: Scenario -> Bool
isCorrectness scenario = case scenario.id of ScenarioId _ _ kind _ -> kind == Correctness

contextWith :: CoreKnob.ResolvedKnobs -> RunContext
contextWith knobs =
  RunContext
    { runId = parsed parseRunId "01a0c69b-e3c5-72ab-ac24-1fdc6004ae05",
      scenario = parsed parseScenarioId "pgmq/queue/correctness/lifecycle-by-kind",
      knobs,
      dimensions = emptyDimensions,
      seed = either (error . Text.unpack) id (mkSeed 1),
      phases = zeroPhases,
      env = Environment Nothing Map.empty,
      environmentSpec = error "environmentSpec not used by this unit test",
      comparison = Nothing,
      outDir = ".",
      logger = error "logger not used by this unit test",
      state = error "state not used by this unit test"
    }

findRepositoryRoot :: FilePath -> IO FilePath
findRepositoryRoot directory = do
  let marker = directory </> "docs/layers/pgmq.md"
  exists <- doesFileExist marker
  if exists
    then pure directory
    else
      let parent = takeDirectory directory
       in if parent == directory then ioError (userError "could not locate repository root") else findRepositoryRoot parent
