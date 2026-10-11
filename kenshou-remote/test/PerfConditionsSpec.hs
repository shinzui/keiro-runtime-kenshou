module PerfConditionsSpec (spec) where

import Data.Aeson
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Either (isLeft)
import Data.Text (Text)
import Data.Time (UTCTime, addUTCTime)
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
  it "reconstructs health from sealed raw samples and rejects scalar laundering" do
    identifier <- newRunId
    let health = rawReport identifier
        windows = rawWindows
        check = validateCellObservations identifier "0.1.0" policy health (executionWindow identifier)
    check windows `shouldBe` Right ()
    let rounded = case windows of (role, machine, image, value) : rest -> (role, machine, image, change "from" (toJSON (addUTCTime (-0.0005) (at 0))) (change "to" (toJSON (addUTCTime (-0.0005) (at 60))) value)) : rest; [] -> []
    -- Role HTTP requests retain millisecond bounds, while the driver has the
    -- original timestamp. Samples must still fall inside the retained window.
    check (case rounded of (role, machine, image, value) : rest -> (role, machine, image, change "samples" (toJSON (map healthSample [0 .. 59])) value) : rest; [] -> []) `shouldBe` Right ()
    check [] `shouldSatisfy` isLeft
    check (drop 1 windows) `shouldSatisfy` isLeft
    let corrupt update = case windows of (role, machine, image, value) : rest -> (role, machine, image, update value) : rest; [] -> []
    check (corrupt (change "image" (String "different-image"))) `shouldSatisfy` isLeft
    check (corrupt (change "agentVersion" (String "stale-agent"))) `shouldSatisfy` isLeft
    check (corrupt (change "maintenanceEvents" (toJSON [object ["at" .= at 20, "value" .= ("maintenance" :: Text)]]))) `shouldSatisfy` isLeft
    check (corrupt (change "samples" (toJSON (filter (\i -> i < 20 || i > 25) [0 .. 60 :: Int] >>= \i -> [healthSample i])))) `shouldSatisfy` isLeft
    check (corrupt (change "samples" (toJSON [change "cpuIdleTicks" (toJSON (900 + i * 50)) (healthSample i) | i <- [0 .. 60 :: Int]]))) `shouldSatisfy` isLeft
    let alteredGates = [change "threshold" (object ["settleCpuMaxPercent" .= (100 :: Int), "runStealCpuMaxPercent" .= (100 :: Int)]) g | g <- gates "driver"] <> concatMap gates (drop 1 machines)
    validateCellObservations identifier "0.1.0" policy (report identifier alteredGates) (executionWindow identifier) windows `shouldSatisfy` isLeft
  it "rejects missing windows, stale sampling, counter reversals and changed execution intervals" do
    identifier <- newRunId
    let check interval windows = validateCellObservations identifier "0.1.0" policy (rawReport identifier) interval windows
        corrupt samples = case rawWindows of (role, machine, image, value) : rest -> (role, machine, image, change "samples" (toJSON samples) value) : rest; [] -> []
    check (executionWindow identifier) (corrupt ([] :: [Value])) `shouldSatisfy` isLeft
    check (executionWindow identifier) (corrupt (map healthSample [1 .. 59])) `shouldBe` Right ()
    check (executionWindow identifier) (corrupt (map healthSample [5 .. 55])) `shouldSatisfy` isLeft
    check (executionWindow identifier) (corrupt (map healthSample [0 .. 30] <> map healthSample [29 .. 60])) `shouldSatisfy` isLeft
    check (change "runFinished" (toJSON (at 59)) (executionWindow identifier)) rawWindows `shouldSatisfy` isLeft

policy :: Value
policy = object ["schema" .= ("cell.policy/v1" :: Text), "health" .= object ["settleCpuMaxPercent" .= (5 :: Int), "runStealCpuMaxPercent" .= (5 :: Int), "startFreeDiskMinPercent" .= (20 :: Int), "runFreeDiskMinPercent" .= (10 :: Int)]]

at :: Int -> UTCTime
at seconds = addUTCTime (fromIntegral seconds) (read "2026-10-11 00:00:00 UTC")

executionWindow :: (ToJSON a) => a -> Value
executionWindow identifier = object ["schema" .= ("cell.execution-window/v1" :: Text), "runId" .= identifier, "resetStarted" .= at 0, "runStarted" .= at 10, "runFinished" .= at 60]

rawReport :: (ToJSON a) => a -> Value
rawReport identifier = report identifier [change "at" (toJSON (at 60)) (if machine == "monitoring" && jsonName gate == Just (String "background-load") then change "observed" (object ["settleCpuPercent" .= (0 :: Int), "runStealCpuPercent" .= (0 :: Int)]) gate else gate) | machine <- machines, gate <- gates machine]
  where
    jsonName (Object value) = KeyMap.lookup "name" value
    jsonName _ = Nothing

rawWindows :: [(Text, Text, Text, Value)]
rawWindows = [(role, role, "image-" <> role, object ["schema" .= ("cell.observations/v1" :: Text), "machine" .= role, "image" .= ("image-" <> role), "agentVersion" .= ("0.1.0" :: Text), "systemClosure" .= ("/nix/store/synthetic-system-identity" :: Text), "from" .= at 0, "to" .= at 60, "samples" .= map healthSample [0 .. 60], "maintenanceEvents" .= ([] :: [Value]), "samplingErrors" .= ([] :: [Value])]) | role <- machines]

healthSample :: Int -> Value
healthSample i = object ["at" .= at i, "cpuTotalTicks" .= (1000 + i * 100), "cpuIdleTicks" .= (990 + i * 99), "cpuStealTicks" .= (0 :: Int), "diskFreePercent" .= (if i <= 10 then 80 else 75 :: Int)]

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
