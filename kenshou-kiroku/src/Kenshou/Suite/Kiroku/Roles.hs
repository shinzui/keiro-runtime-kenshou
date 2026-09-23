module Kenshou.Suite.Kiroku.Roles (roles, appenderRoleName) where

import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (SomeException, try)
import Control.Monad (forM_, replicateM)
import Data.Aeson (Value, object, withObject, (.:), (.=))
import Data.Aeson.Types (Parser, parseMaybe)
import Data.Text (Text)
import Data.UUID qualified as UUID
import Kenshou.Core.Role (ControlMessage (..), PostgresConnInfo (..), RoleContext (..), RoleName, WorkerInit (..), WorkerMessage (..), WorkerRole (..), mkRoleName)
import Kiroku.Store hiding (id)

roles :: [WorkerRole]
roles = [WorkerRole appenderRoleName "Races expected-version appends from a separate process." runAppender]

appenderRoleName :: RoleName
appenderRoleName = either (error . show) id (mkRoleName "kiroku/appender")

runAppender :: RoleContext -> IO ()
runAppender context = case context.init.postgres of
  Nothing -> context.send (WrkError "appender requires PostgreSQL")
  Just postgres -> withStore (defaultConnectionSettings postgres.connectionString) \store -> do
    context.send WrkReady
    loop store
  where
    loop store =
      context.receive >>= \case
        Just CtlStart -> loop store
        Just (CtlCustom "race" payload) -> case parseMaybe parseRace payload of
          Nothing -> context.send (WrkError "invalid race request") >> loop store
          Just (stream, version, writers) -> do
            replies <- newEmptyMVar
            forM_ [1 .. writers] \index -> do
              _ <- forkIO do
                let event = EventData Nothing (EventType "Race") (object ["writer" .= (index :: Int)]) Nothing Nothing Nothing
                outcome <- try @SomeException (runStoreIO store (appendToStream (StreamName stream) (ExactVersion (StreamVersion (fromIntegral version))) [event]))
                putMVar replies $ case outcome of
                  Right (Right _) -> "success" :: Text
                  Right (Left (WrongExpectedVersion _ _ _)) -> "conflict"
                  Right (Left _) -> "store-error"
                  Left _ -> "exception"
              pure ()
            outcomes <- replicateM writers (takeMVar replies)
            context.send (WrkCustom "race" (object ["successes" .= length (filter (== "success") outcomes), "conflicts" .= length (filter (== "conflict") outcomes), "errors" .= length (filter (`elem` ["store-error", "exception"]) outcomes)]))
            loop store
        Just (CtlCustom "duplicate" payload) -> case parseMaybe parseDuplicate payload of
          Nothing -> context.send (WrkError "invalid duplicate request") >> loop store
          Just (stream, rawIds, mode, version) -> case traverse UUID.fromText rawIds of
            Nothing -> context.send (WrkError "invalid caller event ID") >> loop store
            Just identifiers -> do
              let expected = if mode == "exact" then ExactVersion (StreamVersion (fromIntegral version)) else AnyVersion
                  events = [EventData (Just (EventId uuid)) (EventType "DuplicateRace") (object []) Nothing Nothing Nothing | uuid <- identifiers]
              outcome <- try @SomeException (runStoreIO store (appendToStream (StreamName stream) expected events))
              let (status, finalVersion) = case outcome of
                    Right (Right result) -> ("success" :: Text, Just (case result.streamVersion of StreamVersion value -> value))
                    Right (Left (DuplicateEvent _)) -> ("duplicate", Nothing)
                    Right (Left (WrongExpectedVersion _ _ _)) -> ("version", Nothing)
                    _ -> ("error", Nothing)
              context.send (WrkCustom "duplicate" (object ["status" .= status, "version" .= finalVersion]))
              loop store
        Just (CtlStop _) -> pure ()
        Just _ -> loop store
        Nothing -> pure ()

parseRace :: Value -> Parser (Text, Int, Int)
parseRace = withObject "race request" \value -> (,,) <$> value .: "stream" <*> value .: "version" <*> value .: "writers"

parseDuplicate :: Value -> Parser (Text, [Text], Text, Int)
parseDuplicate = withObject "duplicate request" \value -> (,,,) <$> value .: "stream" <*> value .: "eventIds" <*> value .: "mode" <*> value .: "version"
