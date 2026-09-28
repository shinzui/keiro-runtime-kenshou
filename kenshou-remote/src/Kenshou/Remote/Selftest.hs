module Kenshou.Remote.Selftest (bundle) where

import Control.Exception (SomeAsyncException, SomeException, bracket, fromException, throwIO, try)
import Data.Aeson (object, (.=))
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Kenshou.Core.Bundle (LayerBundle (..))
import Kenshou.Core.Context (RunContext (..), SummarySection (..), putSummary, requirePostgres)
import Kenshou.Core.Dimension (Dimensions (..), PgDurability (..), PgVersion (..), noDimensions, postgresDimensions)
import Kenshou.Core.Env (PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Env qualified as Env
import Kenshou.Core.Env.Postgres (PgSettingsSnapshot (..), PostgresEnv (..), PostgresMode (..))
import Kenshou.Core.Id (Layer (..), parseScenarioId)
import Kenshou.Core.Knob (Allowed (..), KnobName, KnobSpec (..), KnobType (..), KnobValue (..), knobText, mkKnobName)
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.RunSpec (EnvironmentSpec (..), SpecPlacement (..))
import Kenshou.Core.Scenario (Placement (..), Scenario (..), ScenarioReport, Tier (..), failedWith, passed)
import Network.HTTP.Client (Request (..), RequestBody (..), httpLbs, newManager, parseRequest, responseStatus, responseTimeoutMicro)
import Network.HTTP.Client.TLS (tlsManagerSettings)
import Network.HTTP.Types.Status (statusCode)
import Network.Socket (SocketType (Stream), addrAddress, addrFamily, addrSocketType, close, connect, defaultHints, defaultProtocol, getAddrInfo, socket)
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..))
import System.Process (readProcessWithExitCode)
import System.Timeout (timeout)

bundle :: LayerBundle
bundle = LayerBundle Selftest [cellEnvironment] []

cellEnvironment :: Scenario
cellEnvironment =
  Scenario
    { id = either (error . show) id (parseScenarioId "selftest/remote/correctness/cell-environment"),
      revision = 1,
      summary = "Checks the environment supplied to a local or cell run.",
      tier = TierSmoke,
      placement = PlaceEither,
      knobs =
        [ KnobSpec expectPlacement "Expected execution placement" KnobText (VText "any") (OneOf (VText "any" :| [VText "local", VText "cell"])) [],
          KnobSpec otlpEndpoint "Optional OTLP HTTP endpoint to check" KnobText (VText "") AnyValue [],
          KnobSpec kafkaBootstrap "Optional Kafka bootstrap address to check" KnobText (VText "") AnyValue []
        ],
      dimensions = postgresDimensions (PgFsyncOff :| [PgDurable]) (Pg18 :| [Pg17]) noDimensions,
      phases = zeroPhases,
      requires = noEnvironment {Env.postgres = Just (PostgresRequirement [SchemaKiroku] [] False)},
      knownDefect = Nothing,
      run = runCellEnvironment
    }

runCellEnvironment :: RunContext -> IO ScenarioReport
runCellEnvironment context = do
  cellId <- lookupEnv "CELL_RUN_ID"
  let postgres = requirePostgres context
      cell = context.environmentSpec.placement == RunOnCell
      requestedPlacement = knobText context.knobs expectPlacement
      placementOk = (requestedPlacement == "any" || requestedPlacement == if cell then "cell" else "local") && (cell == maybe False (not . null) cellId)
      modeOk = postgres.mode == if cell then PgExternal else PgEphemeral
      major = postgres.snapshot.serverVersionNum `div` 10000
      versionOk = major == case context.dimensions.pgVersion of Just Pg17 -> 17; Just Pg18 -> 18; Nothing -> 0
      durabilityOk = Map.lookup "fsync" postgres.snapshot.settings == Just (if context.dimensions.pgDurability == Just PgDurable then "on" else "off")
  fresh <- (== Right "0") <$> psql postgres.connectionString "SELECT count(*) FROM kiroku.events"
  otlp <- reachableOtlp (knobText context.knobs otlpEndpoint)
  kafka <- reachableKafka (knobText context.knobs kafkaBootstrap)
  let checks =
        [ ("placement-as-expected", placementOk),
          ("postgres-mode-as-expected", modeOk),
          ("pg-version-honoured", versionOk),
          ("pg-durability-honoured", durabilityOk),
          ("database-is-fresh", fresh),
          ("otlp-reachable", otlp),
          ("kafka-reachable", kafka)
        ]
      failures = [label | (label, False) <- checks]
  putSummary context Verdicts "cell-environment" (object ["checks" .= Map.fromList checks])
  pure (if null failures then passed else failedWith failures "cell environment differs from the declared run specification")

psql :: Text -> Text -> IO (Either Text Text)
psql connection query = do
  (code, output, errors) <- readProcessWithExitCode "psql" ["-d", Text.unpack connection, "-Atqc", Text.unpack query] ""
  pure case code of
    ExitSuccess -> Right (Text.strip (Text.pack output))
    _ -> Left (Text.strip (Text.pack errors))

reachableOtlp :: Text -> IO Bool
reachableOtlp endpoint
  | Text.null endpoint = pure True
  | otherwise = do
      result <- try @SomeException do
        request <- parseRequest (Text.unpack (Text.dropWhileEnd (== '/') endpoint <> "/v1/traces"))
        manager <- newManager tlsManagerSettings
        response <-
          httpLbs
            request
              { method = "POST",
                requestHeaders = [("Content-Type", "application/json")],
                requestBody = RequestBodyLBS "{\"resourceSpans\":[]}",
                responseTimeout = responseTimeoutMicro 2000000
              }
            manager
        pure (statusCode (responseStatus response) `elem` [200, 202, 204])
      recovered result

reachableKafka :: Text -> IO Bool
reachableKafka bootstrap
  | Text.null bootstrap = pure True
  | otherwise = do
      let firstAddress = Text.takeWhile (/= ',') bootstrap
          (host, colonPort) = Text.breakOnEnd ":" firstAddress
      if Text.null host || Text.null colonPort
        then pure False
        else do
          result <- try @SomeException $ timeout 2000000 do
            addresses <- getAddrInfo (Just defaultHints {addrSocketType = Stream}) (Just (Text.unpack (Text.dropEnd 1 host))) (Just (Text.unpack colonPort))
            case addresses of
              [] -> pure False
              address : _ -> bracket (socket (addrFamily address) Stream defaultProtocol) close (\connection -> connect connection (addrAddress address) >> pure True)
          recovered (fmap (maybe False id) result)

recovered :: Either SomeException Bool -> IO Bool
recovered (Right available) = pure available
recovered (Left failure)
  | Just asynchronous <- fromException failure :: Maybe SomeAsyncException = throwIO asynchronous
  | otherwise = pure False

expectPlacement, otlpEndpoint, kafkaBootstrap :: KnobName
expectPlacement = knobName "remote.expect-placement"
otlpEndpoint = knobName "remote.otlp-endpoint"
kafkaBootstrap = knobName "remote.kafka-bootstrap"

knobName :: Text -> KnobName
knobName = either (error . show) id . mkKnobName
