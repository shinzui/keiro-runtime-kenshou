module Kenshou.Suite.Kiroku.Fixture.Model
  ( ModelStream (..),
    Model (..),
    Cmd (..),
    StoreErrorTag (..),
    Outcome (..),
    stepModel,
  )
where

import Data.ByteString qualified as ByteString
import Data.Foldable (toList)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Sequence (Seq)
import Data.Sequence qualified as Seq
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text.Encoding qualified as TextEncoding
import Data.UUID (UUID)
import Kiroku.Store (ExpectedVersion (..), StreamVersion (..))

data ModelStream = ModelStream
  { version :: Int,
    deleted :: Bool,
    eventIds :: Seq UUID
  }
  deriving stock (Eq, Show)

newtype Model = Model (Map Text ModelStream)
  deriving stock (Eq, Show)

data Cmd
  = CmdAppend Text ExpectedVersion [UUID]
  | CmdGetStream Text
  | CmdSoftDelete Text
  | CmdUndelete Text
  | CmdReadForward Text Int Int
  deriving stock (Eq, Show)

data StoreErrorTag
  = EmptyBatch
  | ReservedName
  | NameTooLong
  | AlreadyExists
  | NotFound
  | WrongVersion
  | DuplicateId
  deriving stock (Eq, Show)

data Outcome
  = Appended Int
  | Rejected StoreErrorTag
  | StreamIs (Maybe (Int, Bool))
  | Events [UUID]
  | Done Bool
  deriving stock (Eq, Show)

stepModel :: Model -> Cmd -> (Model, Outcome)
stepModel model@(Model streams) = \case
  CmdAppend name expected identifiers ->
    case appendError of
      Just tag -> (model, Rejected tag)
      Nothing ->
        let old = Map.findWithDefault (ModelStream 0 False Seq.empty) name streams
            next = old {version = old.version + length identifiers, eventIds = old.eventIds <> Seq.fromList identifiers}
         in (Model (Map.insert name next streams), Appended next.version)
    where
      current = Map.lookup name streams
      existingIds = Set.fromList [identifier | entry <- Map.elems streams, identifier <- toList entry.eventIds]
      appendError
        | name == "$all" = Just ReservedName
        | ByteString.length (TextEncoding.encodeUtf8 name) > 512 = Just NameTooLong
        | null identifiers = Just EmptyBatch
        | otherwise = case expected of
            NoStream | current /= Nothing -> Just AlreadyExists
            NoStream -> duplicate
            StreamExists -> case current of
              Just entry | not entry.deleted -> duplicate
              _ -> Just NotFound
            ExactVersion (StreamVersion requested) -> case current of
              Just entry | not entry.deleted && fromIntegral entry.version == requested -> duplicate
              _ -> Just WrongVersion
            AnyVersion -> case current of
              Just entry | entry.deleted -> Just NotFound
              _ -> duplicate
      duplicate = if any (`Set.member` existingIds) identifiers || length identifiers /= Set.size (Set.fromList identifiers) then Just DuplicateId else Nothing
  CmdGetStream name -> (model, StreamIs ((\entry -> (entry.version, entry.deleted)) <$> Map.lookup name streams))
  CmdSoftDelete name -> changeDeleted name False True
  CmdUndelete name -> changeDeleted name True False
  CmdReadForward name cursor limit ->
    let values = case Map.lookup name streams of
          Just entry | not entry.deleted -> toList entry.eventIds
          _ -> []
     in (model, Events (take (max 0 limit) (drop (max 0 cursor) values)))
  where
    changeDeleted name from to = case Map.lookup name streams of
      Just entry | entry.deleted == from -> (Model (Map.insert name (entry {deleted = to}) streams), Done True)
      _ -> (model, Done False)
