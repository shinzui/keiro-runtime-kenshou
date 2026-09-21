module Kenshou.Check.Fault.Time
  ( BackdateTarget (..),
    newVirtualNow,
    backdateRows,
  )
where

import Data.IORef
import Data.Int (Int64)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time
import Kenshou.Core.Env.Postgres (PostgresEnv (..))
import System.Exit (ExitCode (..))
import System.Process (readProcessWithExitCode)

data BackdateTarget = BackdateTarget
  { table :: !Text,
    column :: !Text,
    predicate :: !Text
  }
  deriving stock (Eq, Show)

newVirtualNow :: IO (IO UTCTime, NominalDiffTime -> IO ())
newVirtualNow = do
  origin <- getCurrentTime
  offset <- newIORef 0
  pure ((addUTCTime <$> readIORef offset <*> pure origin), \delta -> modifyIORef' offset (+ delta))

backdateRows :: PostgresEnv -> BackdateTarget -> NominalDiffTime -> IO Int64
backdateRows postgres target amount = do
  let sql = "UPDATE " <> target.table <> " SET " <> target.column <> " = " <> target.column <> " - interval '" <> Text.pack (show (realToFrac amount :: Double)) <> " seconds' WHERE " <> target.predicate <> " RETURNING 1"
  (code, output, err) <- readProcessWithExitCode "psql" ["-d", Text.unpack postgres.adminConnectionString, "-Atqc", Text.unpack sql] ""
  case code of
    ExitSuccess -> pure (fromIntegral (length (lines output)))
    ExitFailure _ -> ioError (userError err)
