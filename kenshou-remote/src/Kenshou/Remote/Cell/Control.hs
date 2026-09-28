module Kenshou.Remote.Cell.Control
  ( CellSnapshot (..),
    readCellSnapshot,
  )
where

import Data.Aeson (FromJSON, eitherDecode)
import Data.Text (Text)
import Data.Text qualified as Text
import Kenshou.Remote.Cell.Docs (CellBuckets (..), CellDescriptor (..))
import Kenshou.Remote.Cell.Lease (CellRef (..), Lease (..), Quarantine (..))
import Kenshou.Remote.Store (Bucket (..), ObjectName (..), ObjectStore (..))

data CellSnapshot = CellSnapshot
  { descriptor :: !CellDescriptor,
    lease :: !(Maybe Lease),
    quarantine :: !(Maybe Quarantine)
  }
  deriving stock (Eq, Show)

-- Read the same control objects as the cell owner. A descriptor is mandatory
-- before any client action so a bucket or project mismatch cannot be ignored.
readCellSnapshot :: ObjectStore -> CellRef -> [Text] -> IO (Either Text CellSnapshot)
readCellSnapshot store ref allowedProjects = do
  descriptor <- readDocument store ref "descriptor.json"
  case descriptor of
    Left problem -> pure (Left problem)
    Right Nothing -> pure (Left "cell descriptor is missing")
    Right (Just current)
      | current.name /= ref.cellName -> pure (Left "cell descriptor names another cell")
      | current.buckets.control /= ref.controlBucket.unBucket -> pure (Left "cell descriptor control bucket differs from selected bucket")
      | current.project `notElem` allowedProjects -> pure (Left ("cell project is outside KENSHOU_GCP_ALLOWED_PROJECTS: " <> current.project))
      | otherwise -> do
          lease <- readDocument store ref "lease.json"
          quarantine <- readDocument store ref "quarantine.json"
          pure do
            observedLease <- lease
            observedQuarantine <- quarantine
            case observedLease of
              Just record | record.cell /= ref.cellName -> Left "cell lease names another cell"
              _ -> pure ()
            case observedQuarantine of
              Just record | record.cell /= ref.cellName -> Left "cell quarantine names another cell"
              _ -> pure ()
            pure (CellSnapshot current observedLease observedQuarantine)

readDocument :: (FromJSON document) => ObjectStore -> CellRef -> Text -> IO (Either Text (Maybe document))
readDocument store ref name = do
  let object = ObjectName ("cells/" <> ref.cellName <> "/" <> name)
  stored <- store.getObject ref.controlBucket object
  pure case stored of
    Nothing -> Right Nothing
    Just (bytes, _) -> case eitherDecode bytes of
      Left failure -> Left ("invalid " <> name <> ": " <> Text.pack failure)
      Right document -> Right (Just document)
