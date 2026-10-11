module PerfConditionsSpec (spec) where

import Data.Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Either (isLeft)
import Data.Text (Text)
import Kenshou.Core.Id (newRunId)
import Kenshou.Remote.Perf.Conditions
import Test.Hspec

spec :: Spec
spec = describe "performance cell conditions" do
  it "requires all five passing gates for each machine and a verified cold reset" do
    identifier <- newRunId
    let health = report identifier (concatMap gates machines)
        reset = resetReport identifier
    validateCellConditions identifier "alpha" machines health reset `shouldBe` Right ()
    validateCellConditions identifier "alpha" machines (report identifier []) reset `shouldSatisfy` isLeft
    validateCellConditions identifier "alpha" machines (report identifier (concatMap gates (drop 1 machines))) reset `shouldSatisfy` isLeft
    validateCellConditions identifier "alpha" machines (report identifier (concatMap gates machines <> gates "driver")) reset `shouldSatisfy` isLeft
  it "rejects a lying passed flag, tripped gate and pressure beyond the reported threshold" do
    identifier <- newRunId
    let health values = report identifier (values <> concatMap gates (drop 1 machines))
        reset = resetReport identifier
        entries = gates "driver"
        tripped = map (change "status" (String "tripped")) entries
        overloaded = case entries of
          first : load : rest -> first : change "observed" (object ["settleCpuPercent" .= (95 :: Int), "runStealCpuPercent" .= (0 :: Int)]) load : rest
          _ -> entries
    validateCellConditions identifier "alpha" machines (health tripped) reset `shouldSatisfy` isLeft
    validateCellConditions identifier "alpha" machines (health overloaded) reset `shouldSatisfy` isLeft
    validateCellConditions identifier "alpha" machines (change "passed" (Bool False) (health entries)) reset `shouldSatisfy` isLeft
  it "rejects wrong run identity, warm reset, failed reset and inverted windows" do
    identifier <- newRunId
    other <- newRunId
    let health = report identifier (concatMap gates machines)
        reset = resetReport identifier
    validateCellConditions other "alpha" machines health reset `shouldSatisfy` isLeft
    mapM_
      (\changed -> validateCellConditions identifier "alpha" machines health changed `shouldSatisfy` isLeft)
      [change "cachePolicy" (String "warm") reset, change "verified" (Bool False) reset, change "finishedAt" (String "2026-10-10T23:00:00Z") reset]

machines :: [Text]
machines = ["driver", "postgres", "monitoring"]

report :: (ToJSON a) => a -> [Value] -> Value
report identifier entries =
  object
    [ "schema" .= ("cell.health/v1" :: Text),
      "runId" .= identifier,
      "passed" .= True,
      "windowStart" .= ("2026-10-11T00:00:00Z" :: Text),
      "windowEnd" .= ("2026-10-11T00:01:00Z" :: Text),
      "gates" .= entries
    ]

gates :: Text -> [Value]
gates machine =
  [ gate "host-maintenance" (String "NONE") (String "NONE"),
    gate "background-load" (object ["settleCpuPercent" .= (1 :: Int), "runStealCpuPercent" .= (0 :: Int)]) (object ["settleCpuMaxPercent" .= (5 :: Int), "runStealCpuMaxPercent" .= (5 :: Int)]),
    gate "storage-pressure" (object ["startFreePercent" .= (80 :: Int), "runFreePercent" .= (75 :: Int), "outputExceeded" .= False]) (object ["startFreeMinPercent" .= (20 :: Int), "runFreeMinPercent" .= (10 :: Int), "outputExceeded" .= False]),
    gate "incomplete-reset" (Bool True) (Bool True),
    gate "version-mismatch" (Bool True) (Bool True)
  ]
  where
    gate name observed threshold = object ["name" .= (name :: Text), "machine" .= machine, "status" .= ("ok" :: Text), "at" .= ("2026-10-11T00:00:30Z" :: Text), "observed" .= observed, "threshold" .= threshold]

resetReport :: (ToJSON a) => a -> Value
resetReport identifier =
  object
    [ "schema" .= ("cell.reset-evidence/v1" :: Text),
      "runId" .= identifier,
      "cell" .= ("alpha" :: Text),
      "cachePolicy" .= ("cold" :: Text),
      "verified" .= True,
      "startedAt" .= start,
      "finishedAt" .= end,
      "steps" .= [object ["name" .= ("stop-driver-processes" :: Text), "status" .= ("ok" :: Text), "startedAt" .= start, "finishedAt" .= end]]
    ]
  where
    start = "2026-10-11T00:00:00Z" :: Text
    end = "2026-10-11T00:00:05Z" :: Text

change :: Key -> Value -> Value -> Value
change key value (Object fields) = Object (KeyMap.insert key value fields)
change _ _ value = value
