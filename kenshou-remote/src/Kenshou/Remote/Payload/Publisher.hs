module Kenshou.Remote.Payload.Publisher
  ( PublishOptions (..),
    PublishError (..),
    PublisherDeps (..),
    publishPayload,
    publishPayloadWith,
    validateCohortIdentity,
  )
where

import Control.Exception (IOException, displayException, finally, try)
import Crypto.Hash.SHA256 qualified as SHA256
import Data.Aeson (eitherDecodeStrict', encode)
import Data.ByteString qualified as ByteString
import Data.ByteString.Base16 qualified as Base16
import Data.ByteString.Lazy qualified as LazyByteString
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TextEncoding
import Data.Time (getCurrentTime)
import Kenshou.Core.Cohort (CohortDescriptor (..), CohortIdentity (..), CohortName (..), ComponentSpec (..), checkCohort)
import Kenshou.Remote.Payload (Bundle (..), CellPayload (..), CohortCheck (..), Harness (..), PayloadDescriptor (..))
import Kenshou.Remote.Payload.Nix (BundleInfo (..), ClosureInfo (..), NixError (..), exportBundle, nixBuild, nixEvalJson)
import Kenshou.Remote.Payload.Publish (BundlePublishError, publishBundle)
import Kenshou.Remote.Store (Bucket (..), ObjectStore)
import System.Directory (createDirectoryIfMissing, doesFileExist, removeFile, renameFile)
import System.Exit (ExitCode (..))
import System.FilePath (takeDirectory, (</>))
import System.IO (hClose, openBinaryTempFile)
import System.Process (readProcessWithExitCode)

data PublishOptions = PublishOptions
  { root :: !FilePath,
    cohort :: !Text,
    variant :: !Text,
    bucket :: !Bucket,
    out :: !FilePath,
    allowDirty :: !Bool
  }
  deriving stock (Eq, Show)

data PublishError
  = PublishInvalidSelection !Text
  | PublishDirtyWorktree
  | PublishDescriptorError !Text
  | PublishCohortMismatch !Text
  | PublishNixError !NixError
  | PublishBundleError !BundlePublishError
  | PublishIoError !Text
  deriving stock (Eq, Show)

data PublisherDeps = PublisherDeps
  { readHarness :: FilePath -> IO (Either PublishError Harness),
    evalIdentity :: String -> IO (Either NixError CohortIdentity),
    build :: String -> IO (Either NixError FilePath),
    export :: FilePath -> FilePath -> IO (Either NixError BundleInfo)
  }

defaultDeps :: PublisherDeps
defaultDeps = PublisherDeps gitHarness nixEvalJson nixBuild exportBundle

publishPayload :: ObjectStore -> PublishOptions -> IO (Either PublishError PayloadDescriptor)
publishPayload = publishPayloadWith defaultDeps

publishPayloadWith :: PublisherDeps -> ObjectStore -> PublishOptions -> IO (Either PublishError PayloadDescriptor)
publishPayloadWith deps store options = case flakeAttribute options.cohort options.variant of
  Left problem -> pure (Left (PublishInvalidSelection problem))
  Right attribute -> do
    harnessResult <- deps.readHarness options.root
    case harnessResult of
      Left problem -> pure (Left problem)
      Right harness
        | harness.dirty && not options.allowDirty -> pure (Left PublishDirtyWorktree)
        | otherwise -> do
            descriptorResult <- readDescriptor (options.root </> "cohort" </> Text.unpack options.cohort <> ".json")
            case descriptorResult of
              Left problem -> pure (Left problem)
              Right (descriptor, _) | descriptor.descriptorName /= CohortName options.cohort -> pure (Left (PublishDescriptorError "selected descriptor names another cohort"))
              Right (descriptor, descriptorSha) -> do
                let flake = options.root <> "#" <> Text.unpack attribute
                identityResult <- deps.evalIdentity (flake <> ".cohortIdentity")
                case identityResult of
                  Left problem -> pure (Left (PublishNixError problem))
                  Right identity -> case validateCohortIdentity descriptor descriptorSha identity of
                    Left problem -> pure (Left (PublishCohortMismatch problem))
                    Right checked -> do
                      built <- deps.build flake
                      case built of
                        Left problem -> pure (Left (PublishNixError problem))
                        Right storePath -> withBundleFile options.out \bundlePath -> do
                          exported <- deps.export storePath bundlePath
                          case exported of
                            Left problem -> pure (Left (PublishNixError problem))
                            Right bundle | bundle.closure.storePath /= storePath -> pure (Left (PublishNixError (NixInvalidOutput "exported closure root differs from the built store path")))
                            Right bundle -> do
                              now <- getCurrentTime
                              let digest = bundle.sha256
                                  object = "payloads/sha256/" <> digest <> ".nar.zst"
                                  payload =
                                    PayloadDescriptor
                                      options.cohort
                                      options.variant
                                      attribute
                                      harness
                                      identity
                                      (CohortCheck checked)
                                      ( CellPayload
                                          (Bundle ("gs://" <> options.bucket.unBucket <> "/" <> object) digest bundle.bytes)
                                          (Text.pack storePath)
                                          bundle.closure.narHash
                                          (map Text.pack bundle.closure.closurePaths)
                                          "x86_64-linux"
                                          ["bin/kenshou", "cell", "exec"]
                                      )
                                      now
                              uploaded <- publishBundle store options.bucket payload bundle.file
                              case uploaded of
                                Left problem -> pure (Left (PublishBundleError problem))
                                Right published -> do
                                  written <- writeDescriptor options.out published
                                  pure (published <$ written)

validateCohortIdentity :: CohortDescriptor -> Text -> CohortIdentity -> Either Text Int
validateCohortIdentity descriptor descriptorSha identity
  | identity.identityDescriptorSha256 /= descriptorSha = Left "Nix identity descriptor digest differs from the selected descriptor"
  | identity.identityResolver /= Just "nix" = Left "payload identity must use the Nix resolver"
  | identity.identityOs /= "linux" || identity.identityArch /= "x86_64" = Left "payload identity must target x86_64-linux"
  | identity.identityIndexState /= Just descriptor.descriptorIndexState = Left "Nix identity index state differs from the selected descriptor"
  | not (null mismatches) = Left (Text.pack (show mismatches))
  | otherwise = Right (sum (map (length . (.componentPackages)) descriptor.descriptorComponents))
  where
    mismatches = checkCohort descriptor identity

flakeAttribute :: Text -> Text -> Either Text Text
flakeAttribute cohort variant
  | cohort `notElem` ["released", "head"] = Left "--cohort must be released or head"
  | variant `notElem` ["default", "info-table", "profiled"] = Left "--variant must be default, info-table or profiled"
  | otherwise = Right ("packages.x86_64-linux.kenshou-" <> cohort <> if variant == "default" then "" else "-" <> variant)

readDescriptor :: FilePath -> IO (Either PublishError (CohortDescriptor, Text))
readDescriptor path = do
  contents <- try @IOException (ByteString.readFile path)
  pure case contents of
    Left problem -> Left (PublishIoError (Text.pack (displayException problem)))
    Right bytes -> case eitherDecodeStrict' bytes of
      Left problem -> Left (PublishDescriptorError (Text.pack problem))
      Right descriptor -> Right (descriptor, TextEncoding.decodeUtf8 (Base16.encode (SHA256.hash bytes)))

gitHarness :: FilePath -> IO (Either PublishError Harness)
gitHarness path = do
  revision <- git ["-C", path, "rev-parse", "HEAD"]
  status <- git ["-C", path, "status", "--porcelain"]
  pure do
    full <- Text.strip <$> revision
    changed <- status
    if Text.length full /= 40 || not (Text.all isHex full)
      then Left (PublishDescriptorError "git did not return a full commit revision")
      else Right (Harness full (not (Text.null changed)))
  where
    isHex character = character `elem` ['0' .. '9'] || character `elem` ['a' .. 'f']

git :: [String] -> IO (Either PublishError Text)
git arguments = do
  result <- try @IOException (readProcessWithExitCode "git" arguments "")
  pure case result of
    Left problem -> Left (PublishIoError (Text.pack (displayException problem)))
    Right (ExitSuccess, output, _) -> Right (Text.pack output)
    Right (_, _, errors) -> Left (PublishIoError (Text.pack errors))

withBundleFile :: FilePath -> (FilePath -> IO result) -> IO result
withBundleFile destination operation = do
  let directory = takeDirectory destination
  createDirectoryIfMissing True directory
  (temporary, handle) <- openBinaryTempFile directory ".kenshou-export-"
  hClose handle
  operation temporary `finally` removeIfPresent temporary

writeDescriptor :: FilePath -> PayloadDescriptor -> IO (Either PublishError ())
writeDescriptor destination descriptor = do
  let directory = takeDirectory destination
  createDirectoryIfMissing True directory
  (temporary, handle) <- openBinaryTempFile directory ".kenshou-descriptor-"
  result <- try @IOException do
    LazyByteString.hPut handle (encode descriptor) `finally` hClose handle
    renameFile temporary destination
  case result of
    Left problem -> do
      removeIfPresent temporary
      pure (Left (PublishIoError (Text.pack (displayException problem))))
    Right () -> pure (Right ())

removeIfPresent :: FilePath -> IO ()
removeIfPresent path = do
  exists <- doesFileExist path
  if exists then removeFile path else pure ()
