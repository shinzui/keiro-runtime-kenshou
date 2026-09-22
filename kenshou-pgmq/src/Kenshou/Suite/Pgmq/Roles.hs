module Kenshou.Suite.Pgmq.Roles (CrashPoint (..), roles) where

import Kenshou.Core.Role

data CrashPoint = AfterRead | AfterHandled | MidBatchAck deriving stock (Eq, Ord, Show)

roles :: [WorkerRole]
roles = fmap role ["pgmq-producer", "pgmq-consumer", "pgmq-reconciler"]
  where
    role name = WorkerRole (roleName ("pgmq/" <> name)) ("Runs the " <> name <> " scenario role.") runLoop
    runLoop :: RoleContext -> IO ()
    runLoop context = context.send WrkReady >> loop context
    loop :: RoleContext -> IO ()
    loop context =
      context.receive >>= \case
        Just CtlStart -> context.send (WrkDone Nothing) >> loop context
        Just (CtlStop _) -> pure ()
        Just _ -> loop context
        Nothing -> pure ()
    roleName = either (error . show) id . mkRoleName
