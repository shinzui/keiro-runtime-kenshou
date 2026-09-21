module Kenshou.Check.Oracle
  ( OracleQuery (..),
    OracleResult (..),
    ItemRef (..),
    QuiescenceResult (..),
    runOracle,
    sampleOracle,
    reconcile,
    awaitQuiescence,
  )
where

import Control.Concurrent (threadDelay)
import Data.Aeson
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Int (Int64)
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (getCurrentTime)
import Kenshou.Check.Fact
import Kenshou.Check.Invariant
import Kenshou.Check.Ledger
import Kenshou.Check.Ledger.Sort (SortOrder (ByKeySeq))
import Kenshou.Check.Verdict
import Kenshou.Core.Env.Postgres (PostgresEnv (..))
import System.Directory (createDirectoryIfMissing)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.Process (readProcessWithExitCode)

data OracleQuery value = OracleQuery
  { name :: !Text,
    sql :: !Text,
    decode :: Text -> Either Text value
  }

data OracleResult value = OracleResult
  { query :: !Text,
    rows :: !value,
    path :: !FilePath
  }
  deriving stock (Eq, Show)

data ItemRef = ItemRef {key :: !Text, seq :: !Int64, id :: !Text}
  deriving stock (Eq, Ord, Show)

data QuiescenceResult = Quiescent | QuiescenceTimedOut Int64
  deriving stock (Eq, Show)

runOracle :: (ToJSON value) => FilePath -> PostgresEnv -> OracleQuery value -> IO (Either Text (OracleResult value))
runOracle verdictDirectory postgres query = do
  (code, output, err) <- readProcessWithExitCode "psql" ["-d", Text.unpack postgres.connectionString, "-Atqc", Text.unpack query.sql] ""
  case code of
    ExitFailure _ -> pure (Left (Text.strip (Text.pack err)))
    ExitSuccess -> case query.decode (Text.strip (Text.pack output)) of
      Left problem -> pure (Left problem)
      Right rows -> do
        let directory = verdictDirectory </> "oracle"
            path = directory </> Text.unpack query.name <> ".json"
        createDirectoryIfMissing True directory
        now <- getCurrentTime
        LazyByteString.writeFile path (encode (object ["schema" .= ("kenshou.oracle/v1" :: Text), "query" .= query.name, "capturedAt" .= now, "rows" .= rows]) <> "\n")
        pure (Right (OracleResult query.name rows path))

sampleOracle :: (ToJSON value) => FilePath -> LedgerWriter -> PostgresEnv -> OracleQuery value -> IO (Either Text (OracleResult value))
sampleOracle verdictDirectory _writer postgres query = runOracle verdictDirectory postgres query

reconcile :: Text -> InvariantClass -> [ItemRef] -> Checker
reconcile checkerName cls durableRows =
  let durable = Map.fromList [((row.key, row.seq, row.id), ()) | row <- durableRows]
      step (examined, missing) fact =
        let identity = (fact.key, fact.seq, fact.id)
         in (examined + 1, if Map.member identity durable then missing else fact : missing)
      finish (examined, missing) = CheckResult (if null missing then Held else Violated) Nothing "Acknowledged facts exist in durable storage." (Map.fromList [("examined", fromIntegral examined), ("violations", fromIntegral (length missing))]) Null (fmap toJSON (take 20 missing))
   in Checker checkerName "ledger-versus-oracle" cls ByKeySeq (\fact -> fact.kind == Produced) False (CheckFold (0 :: Int, []) step finish)

awaitQuiescence :: PostgresEnv -> OracleQuery Int64 -> Int64 -> IO QuiescenceResult
awaitQuiescence postgres query deadlineMicros = loop 0
  where
    interval = 100000 :: Int64
    loop waited
      | waited >= deadlineMicros = pure (QuiescenceTimedOut waited)
      | otherwise = do
          result <- runOracle "/tmp/kenshou-oracle" postgres query
          case result of
            Right oracle | oracle.rows == 0 -> pure Quiescent
            _ -> threadDelay (fromIntegral interval) >> loop (waited + interval)

instance ToJSON ItemRef where toJSON value = object ["key" .= value.key, "seq" .= value.seq, "id" .= value.id]
