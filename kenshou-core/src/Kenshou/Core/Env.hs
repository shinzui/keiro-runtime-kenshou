module Kenshou.Core.Env
  ( SchemaComponent (..),
    PostgresRequirement (..),
    EnvRequirements (..),
    noEnvironment,
  )
where

import Data.Text (Text)

data SchemaComponent = SchemaKiroku | SchemaKeiro | SchemaPgmq deriving stock (Eq, Ord, Show)

data PostgresRequirement = PostgresRequirement
  { schemas :: [SchemaComponent],
    settings :: [(Text, Text)],
    needsServerControl :: Bool
  }
  deriving stock (Eq, Show)

data EnvRequirements = EnvRequirements
  { postgres :: Maybe PostgresRequirement,
    extraPostgres :: [(Text, PostgresRequirement)],
    kafka :: Bool
  }
  deriving stock (Eq, Show)

noEnvironment :: EnvRequirements
noEnvironment = EnvRequirements Nothing [] False
