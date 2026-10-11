module PerfJournalSpec (spec) where

import Data.Aeson
import Data.Aeson.KeyMap qualified as MapKey
import Data.Either (isLeft)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Time (UTCTime (..), addUTCTime, fromGregorian, secondsToDiffTime)
import Kenshou.Core.Id (newRunId)
import Kenshou.Perf.Plan
import Kenshou.Perf.Request qualified as Request
import Kenshou.Perf.Result (ConfigurationResult (..))
import Kenshou.Remote.Perf.Journal
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

spec :: Spec
spec = describe "performance session budgets" do
  it "replays the synthetic interruption fixture without extending its deadline" do
    session <- eitherDecodeFileStrict' "test/golden/perf-session.fixture.json" >>= either fail pure
    state <- right (journalState session)
    state.executionDeadline `shouldBe` Just (time 1810)
    state.admissionSpentSeconds `shouldBe` 30
  it "retains proposed claims and anchors confirmation or owned release to their original time" do
    session <- fixture
    profile <- firstProfile session
    identifier <- newRunId
    other <- newRunId
    let identity = LeaseIdentity "alpha" identifier
    proposed <- apply 10 (LeaseClaimProposed profile identity) session
    restored <- right (eitherDecode (encode proposed) :: Either String PerfSession)
    state <- right (journalState restored)
    state.pendingClaim `shouldBe` Just (profile, identity, time 10)
    appendEvent (SessionEvent (time 11) (LeaseClaimProposed profile identity)) restored `shouldSatisfy` isLeft
    appendEvent (SessionEvent (time 11) (LeaseAcquired (LeaseIdentity "alpha" other))) restored `shouldSatisfy` isLeft
    confirmed <- apply 20 (LeaseAcquired identity) restored >>= right . journalState
    confirmed.executionDeadline `shouldBe` Just (time 1810)
    confirmed.pendingClaim `shouldBe` Nothing
    withdrawn <- apply 21 LeaseClaimWithdrawn restored >>= right . journalState
    withdrawn.executionDeadline `shouldBe` Nothing
    released <- apply 21 LeaseClaimReleased restored
    next <- apply 30 (LeaseAcquired (LeaseIdentity "alpha" other)) released >>= right . journalState
    next.executionDeadline `shouldBe` Just (time 1810)
    appendEvent (SessionEvent (time 1811) (LeaseAcquired identity)) restored `shouldSatisfy` isLeft
  it "keeps spent admission allowance through serialization and repeated interruption" do
    session <- fixture
    waited <- apply 1 (AdmissionReserved 60) session
    restored <- right (eitherDecode (encode waited) :: Either String PerfSession)
    appendEvent (SessionEvent (time 2) (AdmissionReserved 31)) restored `shouldSatisfy` isLeft
    final <- apply 2 (AdmissionReserved 30) restored >>= right . journalState
    final.admissionSpentSeconds `shouldBe` 90
  it "retains its first deadline and refuses a fresh near-deadline comparison after lease loss" do
    session <- fixture
    firstLease <- newRunId
    nextLease <- newRunId
    acquired <- apply 10 (LeaseAcquired (LeaseIdentity "alpha" firstLease)) session
    name <- firstProfile acquired
    started <- apply 11 (ComparisonStarted name 0) acquired
    lost <- apply 1790 (LeaseLost "client lease expired") started
    restored <- right (eitherDecode (encode lost) :: Either String PerfSession)
    reacquired <- apply 1791 (LeaseAcquired (LeaseIdentity "alpha" nextLease)) restored
    state <- right (journalState reacquired)
    state.executionDeadline `shouldBe` Just (time 1810)
    state.cleanupDeadline `shouldBe` Just (time 1870)
    appendEvent (SessionEvent (time 1792) (ComparisonStarted name 1)) reacquired `shouldSatisfy` isLeft
    appendEvent (SessionEvent (time 1810) (ReplacementReserved name)) reacquired `shouldSatisfy` isLeft
  it "starts a separate attempt after loss and preserves replacement counts and runtime blockers" do
    session <- fixture
    lease <- newRunId
    acquired <- apply 1 (LeaseAcquired (LeaseIdentity "alpha" lease)) session
    name <- firstProfile acquired
    started <- apply 2 (ComparisonStarted name 0) acquired
    invalid <- apply 3 (ReplacementReserved name) started
    blocked <- apply 4 (RuntimeBlocked name "known defect reproduced with exit zero") invalid
    lost <- apply 5 (LeaseLost "reset health failure") blocked
    nextLease <- newRunId
    continued <- apply 6 (LeaseAcquired (LeaseIdentity "alpha" nextLease)) lost >>= apply 7 (ComparisonStarted name 1)
    state <- right (journalState continued)
    Map.lookup name state.attempts `shouldBe` Just 2
    Map.lookup name state.replacements `shouldBe` Just 1
    state.activeComparison `shouldBe` Just (name, 1)
    twice <- apply 8 (ReplacementReserved name) continued
    appendEvent (SessionEvent (time 9) (ReplacementReserved name)) twice `shouldSatisfy` isLeft
    entry <- selectedProfile twice
    let comparison = object ["schema" .= ("kenshou.comparison/v1" :: Text), "verdict" .= ("pass" :: Text), "pairCount" .= (5 :: Int)]
        result = ConfigurationResult name entry.workloadSha256 "pass" "healthy" [] 5 5 [] (Just comparison)
    finished <- apply 10 (ComparisonCompleted result) twice
    final <- right (journalState finished)
    fmap (.runtimeFailures) (Map.lookup name final.completed) `shouldBe` Just ["known defect reproduced with exit zero"]
    appendEvent (SessionEvent (time 11) (ComparisonStarted name 2)) finished `shouldSatisfy` isLeft
  it "rejects overlapping leases, backward clocks, unknown profiles and reset deadlines" do
    session <- fixture
    lease <- newRunId
    acquired <- apply 10 (LeaseAcquired (LeaseIdentity "alpha" lease)) session
    appendEvent (SessionEvent (time 11) (LeaseAcquired (LeaseIdentity "alpha" lease))) acquired `shouldSatisfy` isLeft
    appendEvent (SessionEvent (time 9) LeaseReleased) acquired `shouldSatisfy` isLeft
    appendEvent (SessionEvent (time 11) (ComparisonStarted "unselected" 0)) acquired `shouldSatisfy` isLeft
    appendEvent (SessionEvent (time 11) (AdmissionReserved 1)) acquired `shouldSatisfy` isLeft
  it "recovers a sealed blocker after lease loss or comparison completion without duplicating it" do
    session <- fixture
    name <- firstProfile session
    appendEvent (SessionEvent (time 1) (RuntimeBlocked name "sealed defect")) session `shouldSatisfy` isLeft
    identifier <- newRunId
    acquired <- apply 1 (LeaseAcquired (LeaseIdentity "alpha" identifier)) session
    started <- apply 2 (ComparisonStarted name 0) acquired
    lost <- apply 3 (LeaseLost "interrupted before runtime checkpoint") started
    recovered <- apply 4 (RuntimeBlocked name "sealed defect") lost
    state <- right (journalState recovered)
    Map.lookup name state.runtimeBlockers `shouldBe` Just ["sealed defect"]
    entry <- selectedProfile started
    let comparison = object ["schema" .= ("kenshou.comparison/v1" :: Text), "verdict" .= ("pass" :: Text), "pairCount" .= (5 :: Int)]
        result = ConfigurationResult name entry.workloadSha256 "pass" "healthy" [] 5 5 [] (Just comparison)
    finished <- apply 3 (ComparisonCompleted result) started
    late <- apply 4 (RuntimeBlocked name "sealed defect") finished >>= apply 5 (RuntimeBlocked name "sealed defect")
    final <- right (journalState late)
    fmap (.runtimeFailures) (Map.lookup name final.completed) `shouldBe` Just ["sealed defect"]
  it "persists the transition journal atomically and refuses changed request purpose" $ withSystemTempDirectory "perf-journal" \directory -> do
    session <- fixture
    writePerfSession (directory </> "session.json") session
    readPerfSession (directory </> "session.json") `shouldReturn` Right session
    changed <- apply 1 (AdmissionReserved 10) session
    writePerfSession (directory </> "session.json") changed
    writePerfSession (directory </> "session.json") session `shouldThrow` anyIOException
    writePerfSession (directory </> "session.json") changed {evidenceBaseUri = "gs://different-evidence/performance"} `shouldThrow` anyIOException
    let mutate (Object document) = Object (MapKey.insert "schema" (String "unknown") document)
        mutate value = value
    (eitherDecode (encode (mutate (toJSON session))) :: Either String PerfSession) `shouldSatisfy` isLeft
    let pinned = session.plan
    (eitherDecode (encode session {plan = pinned {request = pinned.request {Request.purpose = "gating"}}}) :: Either String PerfSession) `shouldSatisfy` isLeft

fixture :: IO PerfSession
fixture = do
  plan <- eitherDecodeFileStrict' "../kenshou-core/test/golden/perf-plan.json" >>= either fail pure
  identifier <- newRunId
  right (initialSession identifier ("sha256:" <> "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa") plan "gs://fixture-evidence/performance" (time 0))

time :: Integer -> UTCTime
time seconds = addUTCTime (fromInteger seconds) (UTCTime (fromGregorian 2026 10 11) (secondsToDiffTime 0))

apply :: Integer -> SessionAction -> PerfSession -> IO PerfSession
apply seconds action = right . appendEvent (SessionEvent (time seconds) action)

selectedProfile :: PerfSession -> IO PlannedProfile
selectedProfile session = case session.plan.selected of
  entry : _ -> pure entry
  [] -> fail "fixture must select a profile"

firstProfile :: PerfSession -> IO Text
firstProfile session = (.name) . (.profile) <$> selectedProfile session

right :: (Show e) => Either e a -> IO a
right = either (fail . show) pure
