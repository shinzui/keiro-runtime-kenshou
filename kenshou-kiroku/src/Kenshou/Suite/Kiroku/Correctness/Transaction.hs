module Kenshou.Suite.Kiroku.Correctness.Transaction (scenarios) where

import Data.Aeson (object, (.=))
import Data.Int (Int64)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Vector qualified as Vector
import Effectful (runEff)
import Effectful.Error.Static (runErrorNoCallStack)
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Statement qualified as Statement
import Hasql.Transaction qualified as Tx
import Kenshou.Core.Context (RunContext)
import Kenshou.Core.Dimension
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Scenario
import Kenshou.Suite.Kiroku.Correctness.Append (recordCells)
import Kenshou.Suite.Kiroku.Fixture.Store (withKirokuStore, withKirokuStoreWithEnricher)
import Kenshou.Suite.Kiroku.Knobs (storeKnobs)
import Kiroku.Store hiding (id, withKirokuStore)

scenarios :: [Scenario]
scenarios = [appendWithContinuation]

appendWithContinuation :: Scenario
appendWithContinuation =
  Scenario
    { id = either (error . show) id (parseScenarioId "kiroku/transaction/correctness/append-with-continuation"),
      revision = 1,
      summary = "Checks an event append and caller SQL commit or roll back together.",
      tier = TierSmoke,
      placement = PlaceEither,
      knobs = storeKnobs,
      dimensions =
        DimensionSupport
          { tracing = Supported (Support (TracingOff :| []) TracingOff),
            metrics = Supported (Support (MetricsOff :| []) MetricsOff),
            pgDurability = Supported (Support (PgFsyncOff :| [PgDurable]) PgFsyncOff),
            pgVersion = Supported (Support (Pg18 :| [Pg17]) Pg18)
          },
      phases = zeroPhases,
      requires = noEnvironment {postgres = Just (PostgresRequirement [SchemaKiroku] [] False)},
      knownDefect = Nothing,
      run = runTransactionChecks
    }

runTransactionChecks :: RunContext -> IO ScenarioReport
runTransactionChecks context = withKirokuStore context \store -> do
  let committed = StreamName "tx-committed"
      rolledBack = StreamName "tx-rolled-back"
      event = EventData Nothing (EventType "Transaction") (object []) Nothing Nothing Nothing
      countRows = runStoreIO store (runTransaction (Tx.statement () countStatement))
  created <- runStoreIO store (runTransaction (Tx.sql "create schema if not exists kenshou_kiroku; create table if not exists kenshou_kiroku.tx_probe (tag text not null)"))
  before <- countRows
  commit <- runStoreIO store (runTransactionAppending committed NoStream [event] (\_ -> Tx.sql "insert into kenshou_kiroku.tx_probe (tag) values ('commit')"))
  committedInfo <- runStoreIO store (getStream committed)
  afterCommit <- countRows
  rollback <- runStoreIO store (runTransactionAppending rolledBack NoStream [event] (\_ -> Tx.sql "insert into kenshou_kiroku.tx_probe (tag) values ('rollback')" >> Tx.condemn))
  rolledBackInfo <- runStoreIO store (getStream rolledBack)
  afterRollback <- countRows
  conflict <- runStoreIO store (runTransactionAppending committed (ExactVersion (StreamVersion 0)) [event] (\_ -> Tx.sql "insert into kenshou_kiroku.tx_probe (tag) values ('conflict')"))
  afterConflict <- countRows
  finalInfo <- runStoreIO store (getStream committed)
  (bareAppend, resourceAppend, bareRows, resourceRows) <-
    withKirokuStoreWithEnricher context (Just (\(EventData eventId eventType payload _ causationId correlationId) -> pure (EventData eventId eventType payload (Just (object ["enriched" .= True])) causationId correlationId))) \hookStore -> do
      let bareName = StreamName "tx-hook-bare"
          resourceName = StreamName "tx-hook-resource"
          append name = runTransactionAppending name NoStream [event] (\_ -> pure ())
      bare <- runStoreIO hookStore (append bareName)
      resource <- runEff $ runErrorNoCallStack @StoreError $ runKirokuStoreWith hookStore $ runStorePool hookStore (runTransactionAppendingResource resourceName NoStream [event] (\_ -> pure ()))
      bareRead <- runStoreIO hookStore (readStreamForward bareName (StreamVersion 0) 10)
      resourceRead <- runStoreIO hookStore (readStreamForward resourceName (StreamVersion 0) 10)
      pure (bare, resource, bareRead, resourceRead)
  let cells =
        [ ("probe-table-created", created == Right ()),
          ("probe-starts-empty", before == Right (0 :: Int64)),
          ("append-and-continuation-return", commit == Right (Right ())),
          ("append-and-continuation-commit", case committedInfo of Right (Just info) -> info.version == StreamVersion 1 && afterCommit == Right 1; _ -> False),
          ("condemned-transaction-return", rollback == Right (Right ())),
          ("condemned-transaction-rolls-back", rolledBackInfo == Right Nothing && afterRollback == Right 1),
          ("conflict-reported", case conflict of Right (Left (WrongExpectedVersion name _ _)) -> name == committed; _ -> False),
          ("conflict-skips-continuation", afterConflict == Right 1 && case finalInfo of Right (Just info) -> info.version == StreamVersion 1; _ -> False),
          ("bare-append-commits-without-enrichment", bareAppend == Right (Right ()) && case bareRows of Right rows -> fmap (.metadata) (Vector.toList rows) == [Nothing]; _ -> False),
          ("resource-append-applies-enrichment", resourceAppend == Right (Right ()) && case resourceRows of Right rows -> fmap (.metadata) (Vector.toList rows) == [Just (object ["enriched" .= True])]; _ -> False)
        ]
  recordCells context "append-with-continuation" [] cells

countStatement :: Statement.Statement () Int64
countStatement =
  Statement.preparable
    "select count(*) from kenshou_kiroku.tx_probe"
    Encoders.noParams
    (Decoders.singleRow (Decoders.column (Decoders.nonNullable Decoders.int8)))
