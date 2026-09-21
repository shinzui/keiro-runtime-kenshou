module Kenshou.Core.Env.Migration
  ( MigrationSetupError (..),
    composePlan,
    migrateDatabase,
  )
where

import Data.List (nub, sort)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Text (Text)
import Data.Text qualified as Text
import Database.PostgreSQL.Migrate (MigrationPlan, defaultRunOptions, migrationPlan, runMigrationPlan)
import Hasql.Connection.Settings qualified as Settings
import Keiro.Migrations (keiroMigrations)
import Kenshou.Core.Env (SchemaComponent (..))
import Kiroku.Store.Migrations (kirokuMigrations)
import Pgmq.Migration (pgmqMigrations)

newtype MigrationSetupError = MigrationSetupError Text deriving stock (Eq, Show)

composePlan :: [SchemaComponent] -> Either MigrationSetupError MigrationPlan
composePlan requested = do
  let components = sort . nub $ requested <> [SchemaKiroku | SchemaKeiro `elem` requested]
  migrations <- traverse component components
  case migrations of
    [] -> Left (MigrationSetupError "cannot compose an empty migration plan")
    first : rest -> mapError (migrationPlan (first :| rest))
  where
    component SchemaKiroku = mapError kirokuMigrations
    component SchemaKeiro = mapError keiroMigrations
    component SchemaPgmq = mapError pgmqMigrations
    mapError :: (Show problem) => Either problem value -> Either MigrationSetupError value
    mapError = either (Left . MigrationSetupError . Text.pack . show) Right

migrateDatabase :: Text -> MigrationPlan -> IO (Either MigrationSetupError ())
migrateDatabase connectionString plan = do
  result <- runMigrationPlan defaultRunOptions (Settings.connectionString connectionString) plan
  pure (either (Left . MigrationSetupError . Text.pack . show) (const (Right ())) result)
