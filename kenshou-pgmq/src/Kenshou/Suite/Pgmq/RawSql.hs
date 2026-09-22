module Kenshou.Suite.Pgmq.RawSql (rawSqlAvailable) where

-- The benchmark client keeps this capability marker separate so the raw-SQL
-- rung can grow statements without leaking them into scenario modules.
rawSqlAvailable :: Bool
rawSqlAvailable = True
