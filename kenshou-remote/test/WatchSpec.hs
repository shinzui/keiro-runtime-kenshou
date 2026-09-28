module WatchSpec (spec) where

import Data.Aeson (eitherDecode, encode)
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)
import Kenshou.Core.Id (RunId, newRunId, renderRunId)
import Kenshou.Remote.Cell.Docs (CellPhase (..), CellStatus (..), LogChunks (..), Rejected (..))
import Kenshou.Remote.Cell.Lease (CellRef (..))
import Kenshou.Remote.Cell.Watch (WatchEvent (..), WatchSnapshot (..), WatchTerminal (..), newWatchCursor, pollCellRun)
import Kenshou.Remote.Store (Bucket (..), ObjectName (..), ObjectStore (..), Precondition (..))
import Kenshou.Remote.Store.File (newFileStore)
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

spec :: Spec
spec = describe "cell status and log watcher" do
  it "waits for a status and then emits each phase and chunk exactly once" $ withSystemTempDirectory "kenshou-watch" \root -> do
    store <- newFileStore root
    identifier <- newRunId
    pollCellRun store cellRef identifier newWatchCursor `shouldReturn` WatchSnapshot newWatchCursor [] Nothing
    fixture <- statusFixture identifier
    let running = fixture {phase = Running, logChunks = LogChunks 1 1, outcome = Nothing, manifestSha256 = Nothing}
    put store identifier "log/stdout.0" "first out\n"
    put store identifier "log/stderr.0" "first err\n"
    put store identifier "status.json" (encode running)
    first <- pollCellRun store cellRef identifier newWatchCursor
    first.events `shouldBe` [PhaseChanged Running, StdoutChunk "first out\n", StderrChunk "first err\n"]
    first.terminal `shouldBe` Nothing
    unchanged <- pollCellRun store cellRef identifier first.cursor
    unchanged.events `shouldBe` []
    put store identifier "log/stdout.1" "second out\n"
    put store identifier "status.json" (encode fixture {logChunks = LogChunks 2 1})
    sealed <- pollCellRun store cellRef identifier unchanged.cursor
    sealed.events `shouldBe` [PhaseChanged Sealed, StdoutChunk "second out\n"]
    sealed.terminal `shouldBe` Just (RunSealed fixture {logChunks = LogChunks 2 1})

  it "gives rejection priority over status and checks the run identity" $ withSystemTempDirectory "kenshou-watch" \root -> do
    store <- newFileStore root
    identifier <- newRunId
    fixture <- statusFixture identifier
    rejected <- rejectedFixture identifier
    put store identifier "status.json" (encode fixture)
    put store identifier "rejected.json" (encode rejected)
    result <- pollCellRun store cellRef identifier newWatchCursor
    result.events `shouldBe` []
    result.terminal `shouldBe` Just (RunRejected rejected)
    other <- newRunId
    wrong <- rejectedFixture other
    put store identifier "rejected.json" (encode wrong)
    pollCellRun store cellRef identifier newWatchCursor `shouldThrow` anyIOException

  it "refuses missing chunks and a backwards chunk count" $ withSystemTempDirectory "kenshou-watch" \root -> do
    store <- newFileStore root
    identifier <- newRunId
    fixture <- statusFixture identifier
    let running = fixture {phase = Running, logChunks = LogChunks 1 0, outcome = Nothing, manifestSha256 = Nothing}
    put store identifier "status.json" (encode running)
    pollCellRun store cellRef identifier newWatchCursor `shouldThrow` anyIOException
    put store identifier "log/stdout.0" "first out\n"
    first <- pollCellRun store cellRef identifier newWatchCursor
    put store identifier "status.json" (encode running {logChunks = LogChunks 0 0})
    pollCellRun store cellRef identifier first.cursor `shouldThrow` anyIOException

statusFixture :: RunId -> IO CellStatus
statusFixture identifier = do
  bytes <- LazyByteString.readFile "test/golden/cell/cell.status.v1.json"
  fixture <- either (ioError . userError) pure (eitherDecode bytes :: Either String CellStatus)
  pure (CellStatus identifier fixture.phase fixture.leaseSequence fixture.updatedAt fixture.phaseStartedAt fixture.logChunks fixture.outcome fixture.manifestSha256 fixture.reasons)

rejectedFixture :: RunId -> IO Rejected
rejectedFixture identifier = do
  bytes <- LazyByteString.readFile "test/golden/cell/cell.rejected.v1.json"
  fixture <- either (ioError . userError) pure (eitherDecode bytes :: Either String Rejected)
  pure (Rejected identifier fixture.reason fixture.at)

put :: ObjectStore -> RunId -> Text -> LazyByteString.ByteString -> IO ()
put store identifier suffix bytes = do
  let name = ObjectName ("cells/alpha/submissions/" <> renderRunId identifier <> "/" <> suffix)
  _ <- store.putObject cellRef.controlBucket name "application/json" NoPrecondition bytes
  pure ()

cellRef :: CellRef
cellRef = CellRef "alpha" (Bucket "control")
