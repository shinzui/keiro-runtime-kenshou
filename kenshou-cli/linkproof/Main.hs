{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeApplications #-}

module Main (main) where

import Control.Exception (bracket)
import Data.Aeson (Value (String), object)
import Data.Text (Text)
import Data.Vector qualified as Vector
import Effectful (runEff)
import Effectful.Error.Static (runErrorNoCallStack)
import Hasql.Connection.Settings qualified as Connection
import Hasql.Decoders qualified as Decoders
import Hasql.Encoders qualified as Encoders
import Hasql.Pool (Pool)
import Hasql.Pool qualified as Pool
import Hasql.Pool.Config qualified as Pool.Config
import Hasql.Session qualified as Session
import Hasql.Statement qualified as Statement
import Kafka.Effectful (BrokerAddress (..), KafkaError, flushProducer, runKafkaProducer)
import Kafka.Effectful.Producer qualified as Kafka
import Keiro.Test.Postgres qualified as Postgres
import Kiroku.Store qualified as Store
import LinkProof.Imports ()
import Pgmq.Effectful
  ( Message (..),
    MessageBody (..),
    PgmqRuntimeError,
    ReadMessage (..),
    SendMessage (..),
    createQueue,
    parseQueueName,
    readMessage,
    runPgmq,
    sendMessage,
  )
import Pgmq.Migration qualified as Pgmq
import Test.Hspec

main :: IO ()
main = do
  pgmq <- either (fail . show) pure Pgmq.pgmqMigrations
  Postgres.withMigratedSuiteWith [pgmq] \fixture ->
    hspec $
      describe "runtime cohort link-proof" $
        around (Postgres.withFreshDatabase fixture) spec

spec :: SpecWith Text
spec = do
  it "holds kiroku, keiro and pgmq in one pg-migrate ledger" $ \connStr ->
    withPool connStr $ \pool -> do
      result <- Pool.use pool ledgerComponents
      result `shouldBe` Right ["keiro", "kiroku", "pgmq"]

  it "appends one kiroku event and reads it back" $ \connStr ->
    Store.withStore (Store.defaultConnectionSettings connStr) $ \store -> do
      result <- Store.runStoreIO store $ do
        _ <-
          Store.appendToStream
            (Store.StreamName "linkproof-1")
            Store.NoStream
            [ Store.EventData
                { eventId = Nothing,
                  eventType = Store.EventType "LinkProved",
                  payload = object [],
                  metadata = Nothing,
                  causationId = Nothing,
                  correlationId = Nothing
                }
            ]
        Store.readStreamForward (Store.StreamName "linkproof-1") (Store.StreamVersion 0) 10
      case result of
        Left err -> expectationFailure (show err)
        Right events ->
          fmap (.eventType) (Vector.toList events)
            `shouldBe` [Store.EventType "LinkProved"]

  it "sends and reads one PGMQ message" $ \connStr ->
    withPool connStr $ \pool -> do
      queue <- either (fail . show) pure (parseQueueName "kenshou_linkproof")
      result <- runEff . runErrorNoCallStack @PgmqRuntimeError . runPgmq pool $ do
        createQueue queue
        _ <-
          sendMessage
            SendMessage
              { queueName = queue,
                messageBody = MessageBody (String "ping"),
                delay = Nothing
              }
        readMessage
          ReadMessage
            { queueName = queue,
              delay = 30,
              batchSize = Just 1,
              conditional = Nothing
            }
      case result of
        Left err -> expectationFailure (show err)
        Right messages ->
          fmap (.body) (Vector.toList messages)
            `shouldBe` [MessageBody (String "ping")]

  it "creates and closes a librdkafka producer without a broker" $ \_ -> do
    result <-
      runEff
        . runErrorNoCallStack @KafkaError
        . runKafkaProducer (Kafka.brokersList [BrokerAddress "127.0.0.1:1"])
        $ flushProducer
    result `shouldBe` Right ()

withPool :: Text -> (Pool -> IO a) -> IO a
withPool connStr =
  bracket
    ( Pool.acquire $
        Pool.Config.settings
          [Pool.Config.staticConnectionSettings (Connection.connectionString connStr)]
    )
    Pool.release

ledgerComponents :: Session.Session [Text]
ledgerComponents =
  Session.statement () $
    Statement.preparable
      "SELECT DISTINCT component FROM pgmigrate.migrations WHERE status = 'applied' ORDER BY 1"
      Encoders.noParams
      (Decoders.rowList (Decoders.column (Decoders.nonNullable Decoders.text)))
