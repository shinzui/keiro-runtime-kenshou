{-# LANGUAGE CPP #-}

module Kenshou.Diagnose.Profile.GhcDebug
  ( withGhcDebugIfRequested,
  )
where

import System.Environment (lookupEnv)

#ifdef WITH_GHC_DEBUG
import Data.Word (Word16)
import GHC.Debug.Stub qualified as GhcDebug
import Text.Read (readMaybe)
#else
import System.IO (hPutStrLn, stderr)
#endif

withGhcDebugIfRequested :: IO value -> IO value
withGhcDebugIfRequested action = do
  socket <- lookupEnv "KENSHOU_GHC_DEBUG_SOCKET"
  tcp <- lookupEnv "KENSHOU_GHC_DEBUG_TCP"
#ifdef WITH_GHC_DEBUG
  case (socket, tcp >>= parseTcp) of
    (Just path, _) -> GhcDebug.withGhcDebugUnix path action
    (Nothing, Just (host, port)) -> GhcDebug.withGhcDebugTCP host port action
    _ -> action
#else
  case socket <> tcp of
    Nothing -> pure ()
    Just _ -> hPutStrLn stderr "kenshou: ghc-debug requested, but the executable was built without -fghc-debug"
  action
#endif

#ifdef WITH_GHC_DEBUG
parseTcp :: String -> Maybe (String, Word16)
parseTcp value = case break (== ':') value of
  (host, ':' : rawPort) -> (host,) <$> readMaybe rawPort
  _ -> Nothing
#endif
