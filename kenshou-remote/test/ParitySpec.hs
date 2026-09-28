module ParitySpec (spec) where

import Data.Aeson (Value, encode, object, (.=))
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text qualified as Text
import Kenshou.Remote.Cell.Parity (ParityDifference (..), ParityOptions (..), ParityReport (..), compareForParity)
import System.Directory (createDirectoryIfMissing)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

spec :: Spec
spec = describe "local and cell parity" do
  it "names placement differences while preserving scenario and verdict equality" $ withSystemTempDirectory "kenshou-parity" \root -> do
    let localDir = root </> "local"
        cellDir = root </> "cell"
    writeRun localDir (result "local" "passed" 7) (runSpec "local" 7)
    writeRun cellDir (result "cell" "passed" 7) (runSpec "cell" 7)
    report <- compareForParity (ParityOptions []) localDir cellDir
    report.unexpected `shouldBe` []
    let intentionalPaths = fmap (.path) report.intentional
    mapM_ (\path -> intentionalPaths `shouldContain` [path]) ["result.fingerprint.placement", "spec.environment.placement"]
    mapM_ (\path -> report.equal `shouldContain` [path]) ["result.outcome", "spec.seed"]
    report.localRunResultSha256 `shouldNotBe` report.cellRunResultSha256

  it "rejects changed outcomes, seeds and verdict counts" $ withSystemTempDirectory "kenshou-parity" \root -> do
    let localDir = root </> "local"
        cellDir = root </> "cell"
    writeRun localDir (result "local" "passed" 7) (runSpec "local" 7)
    writeRun cellDir (result "cell" "failed" 8) (runSpec "cell" 8)
    writeVerdict localDir 3
    writeVerdict cellDir 2
    report <- compareForParity (ParityOptions []) localDir cellDir
    let unexpectedPaths = fmap (.path) report.unexpected
    mapM_ (\path -> unexpectedPaths `shouldContain` [path]) ["result.outcome", "spec.seed", "verdicts.ledger.json.counts.checked"]

  it "allows only a named volatile verdict field" $ withSystemTempDirectory "kenshou-parity" \root -> do
    let localDir = root </> "local"
        cellDir = root </> "cell"
    writeRun localDir (result "local" "passed" 7) (runSpec "local" 7)
    writeRun cellDir (result "cell" "passed" 7) (runSpec "cell" 7)
    writeVerdict localDir 3
    writeVerdict cellDir 2
    report <- compareForParity (ParityOptions ["verdicts.ledger.json.counts.checked"]) localDir cellDir
    report.unexpected `shouldBe` []
    fmap (.path) report.intentional `shouldContain` ["verdicts.ledger.json.counts.checked"]

writeRun :: FilePath -> Value -> Value -> IO ()
writeRun directory runResult specValue = do
  createDirectoryIfMissing True directory
  LazyByteString.writeFile (directory </> "run-result.json") (encode runResult)
  LazyByteString.writeFile (directory </> "run-spec.json") (encode specValue)

writeVerdict :: FilePath -> Int -> IO ()
writeVerdict directory count = do
  let verdictDir = directory </> "verdicts"
  createDirectoryIfMissing True verdictDir
  LazyByteString.writeFile (verdictDir </> "ledger.json") (encode (object ["status" .= ("passed" :: Text.Text), "counts" .= object ["checked" .= count]]))

result :: Text.Text -> Text.Text -> Int -> Value
result placement outcome seed =
  object
    [ "schema" .= ("kenshou.run-result/v1" :: Text.Text),
      "runId" .= placement,
      "scenario" .= ("selftest/kernel/correctness/postgres-roundtrip" :: Text.Text),
      "outcome" .= outcome,
      "seed" .= seed,
      "cohort" .= object ["components" .= [object ["name" .= ("kiroku-store" :: Text.Text), "version" .= ("0.8.0.1" :: Text.Text)]], "os" .= placement],
      "fingerprint" .= object ["placement" .= placement]
    ]

runSpec :: Text.Text -> Int -> Value
runSpec placement seed =
  object
    [ "runId" .= placement,
      "scenario" .= ("selftest/kernel/correctness/postgres-roundtrip" :: Text.Text),
      "seed" .= seed,
      "knobs" .= object ["selftest.events" .= (3 :: Int)],
      "dimensions" .= object ["pg.version" .= ("18" :: Text.Text)],
      "environment" .= object ["placement" .= placement],
      "labels" .= (if placement == "cell" then object ["postgresPlacement" .= ("cell-server" :: Text.Text)] else object [])
    ]
