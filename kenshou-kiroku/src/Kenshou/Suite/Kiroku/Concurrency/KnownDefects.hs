module Kenshou.Suite.Kiroku.Concurrency.KnownDefects (scenarios) where

import Control.Exception (SomeException, try)
import Data.Aeson (object, (.=))
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Data.Int (Int32)
import Data.List.NonEmpty (NonEmpty (..))
import Kenshou.Core.Context (RunContext, SummarySection (..), putSummary)
import Kenshou.Core.Dimension
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Scenario
import Kenshou.Suite.Kiroku.Correctness.Append (recordCells)
import Kenshou.Suite.Kiroku.Fixture.Store (withKirokuStore)
import Kenshou.Suite.Kiroku.Knobs (storeKnobs)
import Kiroku.Store hiding (id, withKirokuStore)
import System.Timeout (timeout)

scenarios :: [Scenario]
scenarios = [batchSizeValidation]

batchSizeValidation :: Scenario
batchSizeValidation =
  Scenario
    { id = either (error . show) id (parseScenarioId "kiroku/subscription/correctness/batch-size-validation"),
      revision = 1,
      summary = "Expects zero and negative subscription batch sizes to be rejected promptly.",
      tier = TierStandard,
      placement = PlaceEither,
      knobs = storeKnobs,
      dimensions =
        DimensionSupport
          { tracing = Supported (Support (TracingOff :| []) TracingOff),
            metrics = Supported (Support (MetricsOff :| []) MetricsOff),
            pgDurability = Supported (Support (PgDurable :| []) PgDurable),
            pgVersion = Supported (Support (Pg18 :| [Pg17]) Pg18)
          },
      phases = zeroPhases,
      requires = noEnvironment {postgres = Just (PostgresRequirement [SchemaKiroku] [] False)},
      knownDefect = Just (KnownDefect "mori://shinzui/kiroku/plans/82-repair-live-reconnect-and-validate-subscription-identity-and-batch-size" "Subscription accepts invalid batch sizes" ["zero-refused", "negative-refused"] AllCohorts),
      run = runBatchSizeValidation
    }

runBatchSizeValidation :: RunContext -> IO ScenarioReport
runBatchSizeValidation context = withKirokuStore context \store -> do
  let event = EventData Nothing (EventType "InvalidBatch") (object []) Nothing Nothing Nothing
  seeded <- runStoreIO store (appendToStream (StreamName "invalid-batch-events") NoStream [event])
  (zeroRefused, zeroCalls) <- probe store (SubscriptionName "invalid-batch-zero") 0
  (negativeRefused, negativeCalls) <- probe store (SubscriptionName "invalid-batch-negative") (-1)
  putSummary context Measurements "batch-size-validation" (object ["zeroRefused" .= zeroRefused, "zeroHandlerCalls" .= zeroCalls, "negativeRefused" .= negativeRefused, "negativeHandlerCalls" .= negativeCalls])
  recordCells
    context
    "batch-size-validation"
    []
    [ ("seeded-event", case seeded of Right _ -> True; _ -> False),
      ("zero-refused", zeroRefused && zeroCalls == 0),
      ("negative-refused", negativeRefused && negativeCalls == 0)
    ]

probe :: KirokuStore -> SubscriptionName -> Int32 -> IO (Bool, Int)
probe store name size = do
  calls <- newIORef (0 :: Int)
  let handler _ = atomicModifyIORef' calls (\count -> (count + 1, ())) >> pure Continue
      config = (defaultSubscriptionConfig name AllStreams handler) {batchSize = size}
  started <- try @SomeException (subscribe store config)
  refused <- case started of
    Left _ -> pure True
    Right handle -> do
      outcome <- timeout 5000000 (wait handle)
      handle.cancel
      pure (case outcome of Just (Left _) -> True; _ -> False)
  delivered <- readIORef calls
  pure (refused, delivered)
