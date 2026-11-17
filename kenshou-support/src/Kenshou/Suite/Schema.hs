{-# LANGUAGE CPP #-}

module Kenshou.Suite.Schema (kirokuSchema, keiroSchema, pgmqSchema, migrationSets, schemaBundle, kafkaEnvironment) where

import Data.List.NonEmpty (NonEmpty (..))
import Data.Text qualified as Text
import Kenshou.Core.Bundle (LayerBundle (..), mkBundle, requirePgVersionsFor)
import Kenshou.Core.Dimension (PgVersion (..))
import Kenshou.Core.Env (EnvRequirements, MigrationSet (..), MigrationSetName (..), requiresResource)
import Kenshou.Core.Id (mkLayerId)
import Kenshou.Core.Resource.Types (legacyKafkaName)
import Kiroku.Store.Migrations (kirokuMigrations)
import Pgmq.Migration (pgmqMigrations)
#ifdef FULL_RUNTIME_SUITES
import Keiro.Migrations (keiroMigrations)
#endif
kirokuSchema, keiroSchema, pgmqSchema :: MigrationSetName
kirokuSchema = MigrationSetName "kiroku"
keiroSchema = MigrationSetName "keiro"
pgmqSchema = MigrationSetName "pgmq"

migrationSets :: [MigrationSet]
migrationSets = [MigrationSet kirokuSchema [] (mapError kirokuMigrations), MigrationSet pgmqSchema [] (mapError pgmqMigrations)] <> keiroSets

keiroSets :: [MigrationSet]
#ifdef FULL_RUNTIME_SUITES
keiroSets = [MigrationSet keiroSchema [kirokuSchema] (mapError keiroMigrations)]
#else
keiroSets = []
#endif

mapError :: (Show e) => Either e a -> Either Text.Text a
mapError = either (Left . Text.pack . show) Right

kafkaEnvironment :: EnvRequirements
kafkaEnvironment = requiresResource legacyKafkaName

schemaBundle :: LayerBundle
schemaBundle = (mkBundle (either (error . show) id (mkLayerId "runtime-schema")) [] []) {migrations = migrationSets, rules = [requirePgVersionsFor keiroSchema (Pg18 :| [])]}
