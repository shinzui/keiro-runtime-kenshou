module Kenshou.Core.Cohort
  ( CohortName (..),
  )
where

import Data.Text (Text)

newtype CohortName = CohortName Text
  deriving stock (Eq, Show)
