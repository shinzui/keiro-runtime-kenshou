module Kenshou.Check.Fault.Cell (cellFault) where

import Data.Aeson (Value, encode, object, (.=))
import Data.ByteString.Lazy.Char8 qualified as LazyByteString
import Data.Text (Text)
import Data.Text qualified as Text
import Kenshou.Check.Fault
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..))
import System.Process (readProcessWithExitCode)

cellFault :: Text -> Value -> Fault
cellFault name parameters =
  Fault
    { name = "cell-" <> name,
      target = "cell",
      availability = maybe (Unavailable "KENSHOU_CELL_FAULT_HOOK is unset") (const Available) <$> lookupEnv "KENSHOU_CELL_FAULT_HOOK",
      inject = do
        hook <- lookupEnv "KENSHOU_CELL_FAULT_HOOK" >>= maybe (ioError (userError "KENSHOU_CELL_FAULT_HOOK is unset")) pure
        (code, token, err) <- readProcessWithExitCode hook ["inject", Text.unpack name, LazyByteString.unpack (encode parameters)] ""
        case code of
          ExitFailure _ -> ioError (userError err)
          ExitSuccess -> do
            let cleanToken = Text.strip (Text.pack token)
            pure (FaultHandle (healHook hook cleanToken) (object ["fault" .= name, "token" .= cleanToken]))
    }

healHook :: FilePath -> Text -> IO ()
healHook hook token = do
  (code, _, err) <- readProcessWithExitCode hook ["heal", Text.unpack token] ""
  case code of ExitSuccess -> pure (); ExitFailure _ -> ioError (userError err)
