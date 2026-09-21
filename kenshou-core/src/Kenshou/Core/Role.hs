module Kenshou.Core.Role
  ( RoleName,
    WorkerRole (..),
    RoleContext (..),
    mkRoleName,
    renderRoleName,
  )
where

import Data.Text (Text)
import Data.Text qualified as Text

newtype RoleName = RoleName Text deriving stock (Eq, Ord, Show)

data RoleContext = RoleContext

data WorkerRole = WorkerRole
  { name :: RoleName,
    summary :: Text,
    run :: RoleContext -> IO ()
  }

mkRoleName :: Text -> Either Text RoleName
mkRoleName value = case Text.splitOn "/" value of
  [layer, role] | not (Text.null layer) && not (Text.null role) -> Right (RoleName value)
  _ -> Left "role name must be <layer>/<name>"

renderRoleName :: RoleName -> Text
renderRoleName (RoleName value) = value
