module Kenshou.Measure.Compare.Compatibility
  ( VaryingAxis (..),
    parseVaryingAxis,
    compatibilityInputs,
    environmentFingerprint,
    compatibleExcept,
    varyingValue,
  )
where

import Data.Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.List.NonEmpty (NonEmpty)
import Data.List.NonEmpty qualified as NonEmpty
import Data.Text (Text)
import Data.Text qualified as Text

data VaryingAxis = VaryControl | VaryCohort | VaryDimension Text | VaryKnob Text deriving stock (Eq, Ord, Show)

instance ToJSON VaryingAxis where
  toJSON VaryControl = String "control"
  toJSON VaryCohort = String "cohort"
  toJSON (VaryDimension name) = String ("dim:" <> name)
  toJSON (VaryKnob name) = String ("knob:" <> name)

parseVaryingAxis :: Text -> Either Text VaryingAxis
parseVaryingAxis "control" = Right VaryControl
parseVaryingAxis "cohort" = Right VaryCohort
parseVaryingAxis value | Just name <- Text.stripPrefix "dim:" value, not (Text.null name) = Right (VaryDimension name)
parseVaryingAxis value | Just name <- Text.stripPrefix "knob:" value, not (Text.null name) = Right (VaryKnob name)
parseVaryingAxis value = Left ("invalid varying axis " <> value)

compatibilityInputs :: Value -> Maybe Value
compatibilityInputs (Object root) = do
  Object compatibility <- KeyMap.lookup "compatibility" root
  KeyMap.lookup "inputs" compatibility
compatibilityInputs _ = Nothing

environmentFingerprint :: Value -> Maybe Value
environmentFingerprint (Object root) = do
  Object fingerprint <- KeyMap.lookup "fingerprint" root
  pure (Object (KeyMap.filterWithKey (\key _ -> Key.toText key `elem` ["host", "runtime", "postgres", "placement", "machineProfile"]) fingerprint))
environmentFingerprint _ = Nothing

compatibleExcept :: NonEmpty VaryingAxis -> Value -> Value -> Either Text ()
compatibleExcept axes left right =
  let normalized value = foldr removeAxis value (NonEmpty.toList axes)
   in if normalized left == normalized right
        then Right ()
        else Left "run compatibility inputs differ outside the declared varying axes"
  where
    removeAxis axis value = case value of
      Object objectValue -> Object case axis of
        VaryControl -> objectValue
        VaryCohort -> KeyMap.delete "cohortPlanHash" objectValue
        VaryDimension name -> updateNested "dimensions" name objectValue
        VaryKnob name -> updateNested "knobs" name objectValue
      other -> other
    deleteNested name (Object objectValue) = Object (KeyMap.delete (Key.fromText name) objectValue)
    deleteNested _ other = other
    updateNested parent name objectValue = case KeyMap.lookup parent objectValue of
      Nothing -> objectValue
      Just nested -> KeyMap.insert parent (deleteNested name nested) objectValue

varyingValue :: VaryingAxis -> Value -> Maybe Value
varyingValue axis (Object inputs) = case axis of
  VaryControl -> Just (Object inputs)
  VaryCohort -> KeyMap.lookup "cohortPlanHash" inputs
  VaryDimension name -> nested "dimensions" name
  VaryKnob name -> nested "knobs" name
  where
    nested parent name = do Object values <- KeyMap.lookup parent inputs; KeyMap.lookup (Key.fromText name) values
varyingValue _ _ = Nothing
