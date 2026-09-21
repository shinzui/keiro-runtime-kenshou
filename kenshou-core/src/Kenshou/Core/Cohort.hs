{-# LANGUAGE FieldSelectors #-}

module Kenshou.Core.Cohort
  ( CohortName (..),
    ComponentId (..),
    PlanHash (..),
    CohortDescriptor (..),
    ComponentSpec (..),
    PackagePin (..),
    SourceSpec (..),
    PinException (..),
    loadCohortDescriptor,
    CohortIdentity (..),
    ResolvedComponent (..),
    ResolvedPackage (..),
    PackageSource (..),
    CohortSource (..),
    CohortError (..),
    activeCohortName,
    resolveCohortIdentity,
    identityFromPlan,
    planHash,
    CohortMismatch (..),
    checkCohort,
    renderCohortIdentity,
  )
where

import Control.Exception (IOException, displayException, try)
import Crypto.Hash.SHA256 qualified as SHA256
import Data.Aeson
  ( FromJSON (parseJSON),
    Object,
    ToJSON (toJSON),
    Value (..),
    eitherDecodeStrict',
    object,
    withObject,
    withText,
    (.!=),
    (.:),
    (.:?),
    (.=),
  )
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString (ByteString)
import Data.ByteString qualified as ByteString
import Data.Char (isAlphaNum)
import Data.List (sort, sortOn)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes, fromMaybe)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text.Encoding
import Data.Word (Word8)
import Numeric (showHex)
import System.FilePath ((</>))

newtype CohortName = CohortName {unCohortName :: Text}
  deriving stock (Eq, Ord, Show)

newtype ComponentId = ComponentId {unComponentId :: Text}
  deriving stock (Eq, Ord, Show)

newtype PlanHash = PlanHash {unPlanHash :: Text}
  deriving stock (Eq, Ord, Show)

data SourceSpec
  = HackageSource
  | GitSource Text Text
  deriving stock (Eq, Show)

data PackagePin = PackagePin
  { pinName :: Text,
    pinVersion :: Text,
    pinSubdir :: Maybe Text
  }
  deriving stock (Eq, Show)

data ComponentSpec = ComponentSpec
  { componentId :: ComponentId,
    componentMoriUri :: Text,
    componentSource :: SourceSpec,
    componentPackages :: [PackagePin]
  }
  deriving stock (Eq, Show)

data PinException = PinException
  { exceptionPackage :: Text,
    exceptionSelected :: Text,
    exceptionLatestObserved :: Text,
    exceptionReason :: Text,
    exceptionRecheckAfter :: Text
  }
  deriving stock (Eq, Show)

data CohortDescriptor = CohortDescriptor
  { descriptorSchema :: Text,
    descriptorName :: CohortName,
    descriptorDescription :: Text,
    descriptorVerifiedAt :: Text,
    descriptorCompiler :: Text,
    descriptorIndexState :: Text,
    descriptorProjectFile :: FilePath,
    descriptorComponents :: [ComponentSpec],
    descriptorAllowNewer :: [Text],
    descriptorExceptions :: [PinException]
  }
  deriving stock (Eq, Show)

data PackageSource
  = FromHackage (Maybe Text)
  | FromGit Text Text (Maybe Text)
  | FromBoot
  | FromLocalPath FilePath
  deriving stock (Eq, Show)

data ResolvedPackage = ResolvedPackage
  { resolvedPackageName :: Text,
    resolvedPackageVersion :: Text,
    resolvedPackageSource :: PackageSource
  }
  deriving stock (Eq, Show)

data ResolvedComponent = ResolvedComponent
  { resolvedComponentId :: ComponentId,
    resolvedComponentMoriUri :: Text,
    resolvedComponentPackages :: [ResolvedPackage]
  }
  deriving stock (Eq, Show)

data CohortIdentity = CohortIdentity
  { identityCohort :: CohortName,
    identityCompiler :: Text,
    identityCabalVersion :: Text,
    identityOs :: Text,
    identityArch :: Text,
    identityIndexState :: Maybe Text,
    identityPlanHash :: PlanHash,
    identityDescriptorSha256 :: Text,
    identityComponents :: [ResolvedComponent]
  }
  deriving stock (Eq, Show)

data CohortSource
  = FromProject FilePath (Maybe FilePath) (Maybe FilePath)
  | FromIdentityFile FilePath
  deriving stock (Eq, Show)

data CohortError
  = CohortIoError Text
  | CohortDecodeError Text
  | CohortPlanError Text
  | CohortInvalidActive Text
  deriving stock (Eq, Show)

data CohortMismatch
  = MissingPackage Text
  | VersionMismatch Text Text Text
  | SourceMismatch Text SourceSpec PackageSource
  | LocalPathSource Text FilePath
  deriving stock (Eq, Show)

instance ToJSON CohortName where
  toJSON = toJSON . unCohortName

instance FromJSON CohortName where
  parseJSON = withText "CohortName" (pure . CohortName)

instance ToJSON ComponentId where
  toJSON = toJSON . unComponentId

instance FromJSON ComponentId where
  parseJSON = withText "ComponentId" (pure . ComponentId)

instance ToJSON PlanHash where
  toJSON = toJSON . unPlanHash

instance FromJSON PlanHash where
  parseJSON = withText "PlanHash" (pure . PlanHash)

instance ToJSON SourceSpec where
  toJSON HackageSource = object ["type" .= ("hackage" :: Text)]
  toJSON (GitSource gitLocation gitRevision) =
    object ["type" .= ("git" :: Text), "location" .= gitLocation, "rev" .= gitRevision]

instance FromJSON SourceSpec where
  parseJSON = withObject "SourceSpec" \value -> do
    sourceType <- value .: "type"
    case (sourceType :: Text) of
      "hackage" -> pure HackageSource
      "git" -> GitSource <$> value .: "location" <*> value .: "rev"
      other -> fail ("unknown cohort source type: " <> Text.unpack other)

instance ToJSON PackagePin where
  toJSON PackagePin {pinName, pinVersion, pinSubdir} =
    object (["name" .= pinName, "version" .= pinVersion] <> maybe [] (pure . ("subdir" .=)) pinSubdir)

instance FromJSON PackagePin where
  parseJSON = withObject "PackagePin" \value ->
    PackagePin <$> value .: "name" <*> value .: "version" <*> value .:? "subdir"

instance ToJSON ComponentSpec where
  toJSON ComponentSpec {componentId, componentMoriUri, componentSource, componentPackages} =
    object
      [ "id" .= componentId,
        "moriUri" .= componentMoriUri,
        "source" .= componentSource,
        "packages" .= componentPackages
      ]

instance FromJSON ComponentSpec where
  parseJSON = withObject "ComponentSpec" \value ->
    ComponentSpec
      <$> value .: "id"
      <*> value .: "moriUri"
      <*> value .: "source"
      <*> value .: "packages"

instance ToJSON PinException where
  toJSON PinException {exceptionPackage, exceptionSelected, exceptionLatestObserved, exceptionReason, exceptionRecheckAfter} =
    object
      [ "package" .= exceptionPackage,
        "selected" .= exceptionSelected,
        "latestObserved" .= exceptionLatestObserved,
        "reason" .= exceptionReason,
        "recheckAfter" .= exceptionRecheckAfter
      ]

instance FromJSON PinException where
  parseJSON = withObject "PinException" \value ->
    PinException
      <$> value .: "package"
      <*> value .: "selected"
      <*> value .: "latestObserved"
      <*> value .: "reason"
      <*> value .: "recheckAfter"

instance ToJSON CohortDescriptor where
  toJSON CohortDescriptor {descriptorSchema, descriptorName, descriptorDescription, descriptorVerifiedAt, descriptorCompiler, descriptorIndexState, descriptorProjectFile, descriptorComponents, descriptorAllowNewer, descriptorExceptions} =
    object
      [ "schema" .= descriptorSchema,
        "name" .= descriptorName,
        "description" .= descriptorDescription,
        "verifiedAt" .= descriptorVerifiedAt,
        "compiler" .= descriptorCompiler,
        "indexState" .= descriptorIndexState,
        "projectFile" .= descriptorProjectFile,
        "components" .= descriptorComponents,
        "allowNewer" .= descriptorAllowNewer,
        "exceptions" .= descriptorExceptions
      ]

instance FromJSON CohortDescriptor where
  parseJSON = withObject "CohortDescriptor" \value -> do
    descriptorSchema <- value .: "schema"
    if descriptorSchema /= ("kenshou.cohort/v1" :: Text)
      then fail ("unsupported cohort descriptor schema: " <> Text.unpack descriptorSchema)
      else
        CohortDescriptor descriptorSchema
          <$> value .: "name"
          <*> value .: "description"
          <*> value .: "verifiedAt"
          <*> value .: "compiler"
          <*> value .: "indexState"
          <*> value .: "projectFile"
          <*> value .: "components"
          <*> value .:? "allowNewer" .!= []
          <*> value .:? "exceptions" .!= []

instance ToJSON PackageSource where
  toJSON (FromHackage packageSha256) = object ["type" .= ("hackage" :: Text), "sha256" .= packageSha256]
  toJSON (FromGit packageLocation packageRevision packageSubdir) =
    object
      [ "type" .= ("git" :: Text),
        "location" .= packageLocation,
        "rev" .= packageRevision,
        "subdir" .= packageSubdir
      ]
  toJSON FromBoot = object ["type" .= ("boot" :: Text)]
  toJSON (FromLocalPath path) = object ["type" .= ("local" :: Text), "path" .= path]

instance FromJSON PackageSource where
  parseJSON = withObject "PackageSource" \value -> do
    sourceType <- value .: "type"
    case (sourceType :: Text) of
      "hackage" -> FromHackage <$> value .:? "sha256"
      "git" -> FromGit <$> value .: "location" <*> value .: "rev" <*> value .:? "subdir"
      "boot" -> pure FromBoot
      "local" -> FromLocalPath <$> value .: "path"
      other -> fail ("unknown resolved package source type: " <> Text.unpack other)

instance ToJSON ResolvedPackage where
  toJSON ResolvedPackage {resolvedPackageName, resolvedPackageVersion, resolvedPackageSource} =
    object ["name" .= resolvedPackageName, "version" .= resolvedPackageVersion, "source" .= resolvedPackageSource]

instance FromJSON ResolvedPackage where
  parseJSON = withObject "ResolvedPackage" \value ->
    ResolvedPackage <$> value .: "name" <*> value .: "version" <*> value .: "source"

instance ToJSON ResolvedComponent where
  toJSON ResolvedComponent {resolvedComponentId, resolvedComponentMoriUri, resolvedComponentPackages} =
    object ["id" .= resolvedComponentId, "moriUri" .= resolvedComponentMoriUri, "packages" .= resolvedComponentPackages]

instance FromJSON ResolvedComponent where
  parseJSON = withObject "ResolvedComponent" \value ->
    ResolvedComponent <$> value .: "id" <*> value .: "moriUri" <*> value .: "packages"

instance ToJSON CohortIdentity where
  toJSON CohortIdentity {identityCohort, identityCompiler, identityCabalVersion, identityOs, identityArch, identityIndexState, identityPlanHash, identityDescriptorSha256, identityComponents} =
    object
      [ "schema" .= ("kenshou.cohort-identity/v1" :: Text),
        "cohort" .= identityCohort,
        "compiler" .= identityCompiler,
        "cabalVersion" .= identityCabalVersion,
        "os" .= identityOs,
        "arch" .= identityArch,
        "indexState" .= identityIndexState,
        "planHash" .= identityPlanHash,
        "descriptorSha256" .= identityDescriptorSha256,
        "components" .= identityComponents
      ]

instance FromJSON CohortIdentity where
  parseJSON = withObject "CohortIdentity" \value -> do
    schema <- value .: "schema"
    if schema /= ("kenshou.cohort-identity/v1" :: Text)
      then fail ("unsupported cohort identity schema: " <> Text.unpack schema)
      else
        CohortIdentity
          <$> value .: "cohort"
          <*> value .: "compiler"
          <*> value .: "cabalVersion"
          <*> value .: "os"
          <*> value .: "arch"
          <*> value .:? "indexState"
          <*> value .: "planHash"
          <*> value .: "descriptorSha256"
          <*> value .: "components"

loadCohortDescriptor :: FilePath -> IO (Either CohortError CohortDescriptor)
loadCohortDescriptor path = do
  bytesResult <- readBytes path
  pure (bytesResult >>= decodeBytes path)

activeCohortName :: FilePath -> IO (Either CohortError CohortName)
activeCohortName projectDir = do
  bytesResult <- readBytes (projectDir </> "cohort" </> "active.project")
  pure do
    bytes <- bytesResult
    text <- either (Left . CohortDecodeError . Text.pack . displayException) Right (Text.Encoding.decodeUtf8' bytes)
    case Text.lines text of
      [line]
        | Just project <- Text.stripPrefix "import: " line,
          Just name <- Text.stripSuffix ".project" project,
          not (Text.null name),
          Text.all validNameCharacter name ->
            Right (CohortName name)
      _ -> Left (CohortInvalidActive "cohort/active.project must contain exactly one line: import: <name>.project")
  where
    validNameCharacter character = isAlphaNum character || character == '-'

resolveCohortIdentity :: CohortSource -> IO (Either CohortError CohortIdentity)
resolveCohortIdentity (FromIdentityFile path) = do
  bytesResult <- readBytes path
  pure (bytesResult >>= decodeBytes path)
resolveCohortIdentity (FromProject sourceProjectDir sourcePlanJson sourceDescriptor) = do
  nameResult <- activeCohortName sourceProjectDir
  case nameResult of
    Left err -> pure (Left err)
    Right cohortName@(CohortName name) -> do
      let descriptorPath = fromMaybe (sourceProjectDir </> "cohort" </> Text.unpack name <> ".json") sourceDescriptor
          planPath = fromMaybe (sourceProjectDir </> "dist-newstyle" </> "cache" </> "plan.json") sourcePlanJson
      descriptorBytesResult <- readBytes descriptorPath
      planBytesResult <- readBytes planPath
      pure do
        descriptorBytes <- descriptorBytesResult
        planBytes <- planBytesResult
        descriptor <- decodeBytes descriptorPath descriptorBytes
        if descriptorName descriptor /= cohortName
          then Left (CohortDecodeError "active cohort name does not match descriptor name")
          else do
            planValue <- decodeBytes planPath planBytes
            identityFromPlan descriptor (sha256Hex descriptorBytes) planValue

identityFromPlan :: CohortDescriptor -> Text -> Value -> Either CohortError CohortIdentity
identityFromPlan descriptor descriptorSha value = do
  plan <- parsePlan value
  identityPlanHash <- planHash value
  let unitsByName = Map.fromListWith preferRuntimeUnit [(planUnitName unit, unit) | unit <- planUnits plan]
  identityComponents <- traverse (resolveComponent unitsByName) (descriptorComponents descriptor)
  pure
    CohortIdentity
      { identityCohort = descriptorName descriptor,
        identityCompiler = planCompiler plan,
        identityCabalVersion = planCabalVersion plan,
        identityOs = planOs plan,
        identityArch = planArch plan,
        identityIndexState = Just (descriptorIndexState descriptor),
        identityPlanHash,
        identityDescriptorSha256 = descriptorSha,
        identityComponents
      }
  where
    preferRuntimeUnit left right
      | planUnitStyle left == Just "local" = right
      | otherwise = left

planHash :: Value -> Either CohortError PlanHash
planHash value = do
  plan <- parsePlan value
  renderedUnits <- traverse renderPlanUnit (filter ((/= Just "local") . planUnitStyle) (planUnits plan))
  let material = Text.intercalate "\n" ("compiler " <> planCompiler plan : sort (Set.toList (Set.fromList renderedUnits)))
  pure (PlanHash ("sha256:" <> sha256Hex (Text.Encoding.encodeUtf8 material)))

checkCohort :: CohortDescriptor -> CohortIdentity -> [CohortMismatch]
checkCohort descriptor identity = concatMap checkComponent (descriptorComponents descriptor)
  where
    resolvedByName =
      Map.fromList
        [ (resolvedPackageName package, package)
        | component <- identityComponents identity,
          package <- resolvedComponentPackages component
        ]

    checkComponent component = concatMap (checkPackage (componentSource component)) (componentPackages component)

    checkPackage expectedSource pin =
      case Map.lookup (pinName pin) resolvedByName of
        Nothing -> [MissingPackage (pinName pin)]
        Just actual -> versionMismatch pin actual <> sourceMismatch expectedSource pin actual

    versionMismatch pin actual
      | pinVersion pin == resolvedPackageVersion actual = []
      | otherwise = [VersionMismatch (pinName pin) (pinVersion pin) (resolvedPackageVersion actual)]

    sourceMismatch _ pin ResolvedPackage {resolvedPackageSource = FromLocalPath path} = [LocalPathSource (pinName pin) path]
    sourceMismatch HackageSource _ ResolvedPackage {resolvedPackageSource = FromHackage _} = []
    sourceMismatch expected@HackageSource pin ResolvedPackage {resolvedPackageSource = actual} = [SourceMismatch (pinName pin) expected actual]
    sourceMismatch expected@(GitSource gitLocation gitRevision) pin ResolvedPackage {resolvedPackageSource = actual@(FromGit packageLocation packageRevision _)}
      | normaliseGitLocation gitLocation == normaliseGitLocation packageLocation,
        gitRevision == packageRevision =
          []
      | otherwise = [SourceMismatch (pinName pin) expected actual]
    sourceMismatch expected@(GitSource _ _) pin ResolvedPackage {resolvedPackageSource = actual} = [SourceMismatch (pinName pin) expected actual]

renderCohortIdentity :: CohortIdentity -> Text
renderCohortIdentity identity =
  Text.unlines
    ( [ "cohort     " <> unCohortName (identityCohort identity),
        "compiler   " <> identityCompiler identity <> "   cabal " <> identityCabalVersion identity <> "   " <> identityOs identity <> "/" <> identityArch identity,
        "index      " <> fromMaybe "-" (identityIndexState identity),
        "plan       " <> unPlanHash (identityPlanHash identity)
      ]
        <> map renderComponent (identityComponents identity)
    )
  where
    renderComponent component =
      Text.justifyLeft 22 ' ' (unComponentId (resolvedComponentId component))
        <> Text.intercalate ", " (map renderPackage (resolvedComponentPackages component))
    renderPackage package =
      resolvedPackageName package
        <> " "
        <> resolvedPackageVersion package
        <> " ["
        <> renderSource (resolvedPackageSource package)
        <> "]"
    renderSource (FromHackage _) = "hackage"
    renderSource (FromGit _ packageRevision _) = "git " <> Text.take 12 packageRevision
    renderSource FromBoot = "boot"
    renderSource FromLocalPath {} = "local"

data Plan = Plan
  { planCompiler :: Text,
    planCabalVersion :: Text,
    planOs :: Text,
    planArch :: Text,
    planUnits :: [PlanUnit]
  }

data PlanUnit = PlanUnit
  { planUnitType :: Text,
    planUnitStyle :: Maybe Text,
    planUnitName :: Text,
    planUnitVersion :: Text,
    planUnitSource :: Maybe Object,
    planUnitSha256 :: Maybe Text,
    planUnitFlags :: Map Text Bool
  }

parsePlan :: Value -> Either CohortError Plan
parsePlan (Object root) = do
  planCompiler <- requiredText "compiler-id" root
  planCabalVersion <- requiredText "cabal-version" root
  planOs <- requiredText "os" root
  planArch <- requiredText "arch" root
  unitValues <- requiredArray "install-plan" root
  planUnits <- traverse parseUnit unitValues
  pure Plan {planCompiler, planCabalVersion, planOs, planArch, planUnits}
parsePlan _ = Left (CohortPlanError "plan.json root must be an object")

parseUnit :: Value -> Either CohortError PlanUnit
parseUnit (Object unit) = do
  planUnitType <- requiredText "type" unit
  planUnitName <- requiredText "pkg-name" unit
  planUnitVersion <- requiredText "pkg-version" unit
  let planUnitStyle = optionalText "style" unit
      planUnitSource = optionalObject "pkg-src" unit
      planUnitSha256 = optionalText "pkg-src-sha256" unit
      planUnitFlags = fromMaybe Map.empty (optionalFlags "flags" unit)
  pure PlanUnit {planUnitType, planUnitStyle, planUnitName, planUnitVersion, planUnitSource, planUnitSha256, planUnitFlags}
parseUnit _ = Left (CohortPlanError "install-plan entries must be objects")

resolveComponent :: Map Text PlanUnit -> ComponentSpec -> Either CohortError ResolvedComponent
resolveComponent units component = do
  resolvedComponentPackages <- catMaybes <$> traverse resolvePackage (componentPackages component)
  pure
    ResolvedComponent
      { resolvedComponentId = componentId component,
        resolvedComponentMoriUri = componentMoriUri component,
        resolvedComponentPackages
      }
  where
    resolvePackage pin = case Map.lookup (pinName pin) units of
      Nothing -> pure Nothing
      Just unit -> Just . ResolvedPackage (planUnitName unit) (planUnitVersion unit) <$> packageSource unit

renderPlanUnit :: PlanUnit -> Either CohortError Text
renderPlanUnit unit = do
  source <- packageSource unit
  let flags =
        if Map.null (planUnitFlags unit)
          then "-"
          else
            Text.intercalate
              ","
              [ (if enabled then "+" else "-") <> name
              | (name, enabled) <- sortOn fst (Map.toList (planUnitFlags unit))
              ]
  pure (planUnitName unit <> " " <> planUnitVersion unit <> " " <> renderPlanSource source <> " " <> flags)

packageSource :: PlanUnit -> Either CohortError PackageSource
packageSource PlanUnit {planUnitType = "pre-existing"} = Right FromBoot
packageSource PlanUnit {planUnitSource = Nothing} = Right FromBoot
packageSource PlanUnit {planUnitSource = Just source, planUnitSha256} = do
  sourceType <- requiredText "type" source
  case sourceType of
    "repo-tar" -> Right (FromHackage planUnitSha256)
    "local" -> FromLocalPath . Text.unpack <$> requiredText "path" source
    "source-repo" -> parseSourceRepo source
    other -> Left (CohortPlanError ("unsupported plan package source: " <> other))

parseSourceRepo :: Object -> Either CohortError PackageSource
parseSourceRepo source = do
  let repo = fromMaybe source (optionalObject "source-repo" source)
  packageLocation <- requiredText "location" repo
  packageRevision <- requiredText "tag" repo
  let packageSubdir = optionalText "subdir" repo
  pure (FromGit packageLocation packageRevision packageSubdir)

renderPlanSource :: PackageSource -> Text
renderPlanSource (FromHackage packageSha256) = "hackage:" <> fromMaybe "-" packageSha256
renderPlanSource (FromGit packageLocation packageRevision packageSubdir) =
  "git:" <> packageLocation <> "@" <> packageRevision <> "#" <> fromMaybe "-" packageSubdir
renderPlanSource FromBoot = "boot"
renderPlanSource (FromLocalPath path) = "local:" <> Text.pack path

requiredText :: Text -> Object -> Either CohortError Text
requiredText key objectValue = case KeyMap.lookup (Key.fromText key) objectValue of
  Just (String value) -> Right value
  _ -> Left (CohortPlanError ("plan field " <> key <> " must be text"))

optionalText :: Text -> Object -> Maybe Text
optionalText key objectValue = case KeyMap.lookup (Key.fromText key) objectValue of
  Just (String value) -> Just value
  _ -> Nothing

optionalObject :: Text -> Object -> Maybe Object
optionalObject key objectValue = case KeyMap.lookup (Key.fromText key) objectValue of
  Just (Object value) -> Just value
  _ -> Nothing

requiredArray :: Text -> Object -> Either CohortError [Value]
requiredArray key objectValue = case KeyMap.lookup (Key.fromText key) objectValue of
  Just (Array values) -> Right (foldr (:) [] values)
  _ -> Left (CohortPlanError ("plan field " <> key <> " must be an array"))

optionalFlags :: Text -> Object -> Maybe (Map Text Bool)
optionalFlags key objectValue = do
  flags <- optionalObject key objectValue
  traverse valueToBool (Map.fromList [(Key.toText name, value) | (name, value) <- KeyMap.toList flags])
  where
    valueToBool (Bool value) = Just value
    valueToBool _ = Nothing

readBytes :: FilePath -> IO (Either CohortError ByteString)
readBytes path = do
  result <- try @IOException (ByteString.readFile path)
  pure (either (\err -> Left (CohortIoError (Text.pack (path <> ": " <> displayException err)))) Right result)

decodeBytes :: (FromJSON value) => FilePath -> ByteString -> Either CohortError value
decodeBytes path bytes =
  either (\err -> Left (CohortDecodeError (Text.pack (path <> ": " <> err)))) Right (eitherDecodeStrict' bytes)

sha256Hex :: ByteString -> Text
sha256Hex = Text.pack . concatMap renderByte . ByteString.unpack . SHA256.hash
  where
    renderByte :: Word8 -> String
    renderByte byte = case showHex byte "" of
      [digit] -> ['0', digit]
      digits -> digits

normaliseGitLocation :: Text -> Text
normaliseGitLocation location =
  let withoutSlash = Text.dropWhileEnd (== '/') location
   in fromMaybe withoutSlash (Text.stripSuffix ".git" withoutSlash)
