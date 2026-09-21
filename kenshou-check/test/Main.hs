module Main (main) where

import Control.Monad (forM_)
import Data.Aeson (Object, Value (Number), decode, encode)
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.IORef
import Data.Int (Int64)
import Data.List (sortOn)
import Data.Text qualified as Text
import Kenshou.Check.Fact
import Kenshou.Check.Invariant
import Kenshou.Check.Ledger
import Kenshou.Check.Ledger.Read
import Kenshou.Check.Ledger.Sort
import Kenshou.Check.Model.Linearizability
import Kenshou.Check.Verdict
import System.Directory (listDirectory)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

main :: IO ()
main = hspec do
  describe "Fact" do
    it "round-trips through JSON" do
      let fact = Fact Produced "stream" 3 "event" "writer/0" (ProcId "writer" 0 0) 1 2 3 KeyMap.empty
      decode (encode fact) `shouldBe` Just fact

  describe "Ledger" do
    it "rotates immutable segments and reads every fact" $ withSystemTempDirectory "kenshou-ledger" \directory -> do
      let config = LedgerConfig directory (ProcId "writer" 0 0) "run" 1024 (ClockInfo SameHost 1000)
      withLedger config \writer -> forM_ [1 .. 200 :: Int64] \number -> record writer Produced "key" number (Text.pack (show number)) KeyMap.empty
      files <- listDirectory directory
      length files `shouldSatisfy` (> 1)
      ledger <- discoverLedgers directory
      count <- foldFacts ledger (0 :: Int) (\value _ -> pure (value + 1))
      count `shouldBe` 200

    it "drops a torn final fact line" $ withSystemTempDirectory "kenshou-torn" \directory -> do
      let config = LedgerConfig directory (ProcId "writer" 0 0) "run" 1000000 (ClockInfo SameHost 1000)
      withLedger config \writer -> record writer Produced "key" 1 "one" KeyMap.empty
      [path] <- fmap (directory </>) <$> listDirectory directory
      appendFile path "{\"schema\":\"kenshou.ledger-fact/v1\""
      ledger <- discoverLedgers directory
      count <- foldFacts ledger (0 :: Int) (\value _ -> pure (value + 1))
      count `shouldBe` 1

  describe "external sort" do
    it "matches an in-memory sort across many runs" $ withSystemTempDirectory "kenshou-sort" \directory -> do
      let ledgerDir = directory </> "ledger"
          config = LedgerConfig ledgerDir (ProcId "writer" 0 0) "run" 10000000 (ClockInfo SameHost 1000)
          facts = [1000, 999 .. 1 :: Int64]
      withLedger config \writer -> forM_ facts \number -> record writer Produced (Text.pack (show (number `mod` 13))) number (Text.pack (show number)) KeyMap.empty
      ledger <- discoverLedgers ledgerDir
      collected <- newIORef []
      sortedFacts (SortConfig (ledgerDir </> ".sort") 17 8) ByKeySeq (const True) ledger \source -> drain source collected
      actual <- readIORef collected
      fmap (\fact -> (fact.key, fact.seq)) actual `shouldBe` sortOn id [(Text.pack (show (number `mod` 13)), number) | number <- facts]

  describe "invariant checkers" do
    let cases =
          [ ("no-loss", noLoss "no-loss" Contract "consumer", cleanDelivery, [fact Produced "producer" 1 1 mempty]),
            ("duplicates", duplicatesWithin "duplicates" Contract "consumer" (DuplicateBudget (Just 0) Nothing) [], [fact Observed "consumer" 1 1 mempty], [fact Observed "consumer" 1 1 mempty, fact Observed "consumer" 2 1 mempty]),
            ("per-key-order", perKeyOrder "per-key-order" Contract "consumer", [fact Observed "consumer" 1 1 mempty, fact Observed "consumer" 2 2 mempty], [fact Observed "consumer" 1 2 mempty, fact Observed "consumer" 2 1 mempty]),
            ("global-order", globalOrder "global-order" Contract "consumer" "gp", [fact Observed "consumer" 1 1 (gp 1), fact Observed "consumer" 2 2 (gp 2)], [fact Observed "consumer" 1 1 (gp 2), fact Observed "consumer" 2 2 (gp 1)]),
            ("gapless", gaplessPositions "gapless" Implementation, [fact Produced "producer" 1 1 mempty, fact Produced "producer" 2 2 mempty], [fact Produced "producer" 1 1 mempty, fact Produced "producer" 2 3 mempty]),
            ("effects", exactlyNEffects "effects" Contract 1, [fact Effect "consumer" 1 1 mempty], [fact Effect "consumer" 1 1 mempty, fact Effect "consumer" 2 1 mempty]),
            ("quiescence", eventualQuiescence "quiescence" Contract (Deadline 1000), [fact Produced "producer" 1 1 mempty, fact Terminal "consumer" 2 1 mempty], [fact Produced "producer" 1 1 mempty]),
            ("checkpoint", monotonicCheckpoints "checkpoint" Contract, [fact Checkpoint "consumer" 1 1 mempty, fact Checkpoint "consumer" 2 2 mempty], [fact Checkpoint "consumer" 1 2 mempty, fact Checkpoint "consumer" 2 1 mempty]),
            ("ownership", disjointOwnership "ownership" Contract, [fact Acquired "owner-a" 1 1 mempty, fact Acted "owner-a" 2 1 mempty, fact Released "owner-a" 3 1 mempty], [fact Acquired "owner-a" 1 1 mempty, fact Acquired "owner-b" 2 1 mempty, fact Acted "owner-a" 3 1 mempty])
          ]
    forM_ cases \(label, checker, heldFacts, violatedFacts) -> do
      it (label <> " holds for valid facts") $ (evaluateChecker checker heldFacts).status `shouldBe` Held
      it (label <> " rejects a targeted mutation") $ (evaluateChecker checker violatedFacts).status `shouldBe` Violated
      it (label <> " refuses a vacuous pass") $ (evaluateChecker checker []).status `shouldBe` NotEvaluated

  describe "linearizability" do
    it "accepts and rejects register histories" do
      let valid = [Operation "p1" "register" (WriteRegister 1) 0 (Just 1) (Returned Written), Operation "p2" "register" ReadRegister 2 (Just 3) (Returned (ReadValue (Just 1)))]
          invalid = [Operation "p1" "register" (WriteRegister 1) 0 (Just 1) (Returned Written), Operation "p2" "register" ReadRegister 2 (Just 3) (Returned (ReadValue Nothing))]
      checkLinearizable defaultLinConfig registerModel valid `shouldBe` Linearizable
      checkLinearizable defaultLinConfig registerModel invalid `shouldSatisfy` isRejected

    it "accepts and rejects append-log histories" do
      let valid = [Operation "p1" "log" (Append "a") 0 (Just 1) (Returned (Appended 0)), Operation "p2" "log" ReadLog 2 (Just 3) (Returned (LogContents ["a"]))]
          invalid = [Operation "p1" "log" (Append "a") 0 (Just 1) (Returned (Appended 0)), Operation "p2" "log" ReadLog 2 (Just 3) (Returned (LogContents []))]
      checkLinearizable defaultLinConfig appendLogModel valid `shouldBe` Linearizable
      checkLinearizable defaultLinConfig appendLogModel invalid `shouldSatisfy` isRejected

drain :: FactSource -> IORef [Fact] -> IO ()
drain source output =
  source.next >>= \case
    Nothing -> pure ()
    Just fact -> modifyIORef' output (<> [fact]) >> drain source output

fact :: FactKind -> Text.Text -> Word -> Int64 -> Object -> Fact
fact kind scope n sequenceNumber attrs = Fact kind "key" sequenceNumber "item" scope (ProcId scope 0 0) (fromIntegral n) (fromIntegral n) (fromIntegral n * 100) attrs

gp :: Int64 -> Object
gp value = KeyMap.singleton (Key.fromText "gp") (Number (fromIntegral value))

cleanDelivery :: [Fact]
cleanDelivery = [fact Intent "producer" 1 1 mempty, fact Produced "producer" 2 1 mempty, fact Observed "consumer" 3 1 mempty]

isRejected :: LinResult -> Bool
isRejected (NotLinearizable _) = True
isRejected _ = False
