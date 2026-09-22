module Kenshou.Suite.Kiroku.Correctness.Read (scenarios) where

import Control.Monad (forM)
import Data.Aeson (object)
import Data.List (nub, sort)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Vector (Vector)
import Data.Vector qualified as Vector
import Kenshou.Core.Context (RunContext (..))
import Kenshou.Core.Dimension
import Kenshou.Core.Env (EnvRequirements (..), PostgresRequirement (..), SchemaComponent (..), noEnvironment)
import Kenshou.Core.Id (parseScenarioId)
import Kenshou.Core.Knob
import Kenshou.Core.Phase (zeroPhases)
import Kenshou.Core.Scenario
import Kenshou.Suite.Kiroku.Correctness.Append (recordCells)
import Kenshou.Suite.Kiroku.Fixture.Store (withKirokuStore)
import Kenshou.Suite.Kiroku.Knobs (storeKnobs)
import Kiroku.Store hiding (id, withKirokuStore)
import Streamly.Data.Stream qualified as Stream

scenarios :: [Scenario]
scenarios = [cursorSemantics]

cursorSemantics :: Scenario
cursorSemantics =
  Scenario
    { id = either (error . show) id (parseScenarioId "kiroku/read/correctness/cursor-semantics"),
      revision = 1,
      summary = "Checks exclusive forward and backward cursors, categories, and stream name lookup.",
      tier = TierStandard,
      placement = PlaceEither,
      knobs = storeKnobs <> [pageSizeKnob],
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
      run = runCursorSemantics
    }

pageSizeKnob :: KnobSpec
pageSizeKnob =
  KnobSpec
    (knobName "kiroku.read.page-size")
    "Events per read page"
    KnobInt
    (VInt 256)
    (IntRange 1 1000)
    [VInt 1, VInt 7, VInt 256, VInt 1000]

knobName :: Text -> KnobName
knobName = either (error . show) id . mkKnobName

runCursorSemantics :: RunContext -> IO ScenarioReport
runCursorSemantics context = withKirokuStore context \store -> do
  let pageSize = fromIntegral (knobInt context.knobs (knobName "kiroku.read.page-size"))
      event = EventData Nothing (EventType "Cursor") (object []) Nothing Nothing Nothing
      streamName :: Int -> StreamName
      streamName i = StreamName ("c" <> Text.pack (show (i `mod` 8)) <> "-" <> Text.pack (show i))
      category i = CategoryName ("c" <> Text.pack (show i))
      appendBatch batch = do
        let i = batch `mod` 16
        result <- runStoreIO store (appendToStream (streamName i) (if batch < 16 then NoStream else AnyVersion) (replicate 100 event))
        case result of
          Left err -> fail ("kiroku prepopulation failed: " <> show err)
          Right appended -> pure (i, appended.streamId)
  mappings <- Map.fromList <$> forM [0 .. 99] appendBatch
  globalForward <- requireRead =<< collectPages (GlobalPosition 0) (\cursor -> runStoreIO store (readAllForward cursor pageSize)) (.globalPosition)
  globalBackward <- requireRead =<< collectPages (GlobalPosition 0) (\cursor -> runStoreIO store (readAllBackward cursor pageSize)) (.globalPosition)
  streamCells <- forM [0 .. 15] \i -> do
    let streamId = mappings Map.! i
        expected = filter ((== streamId) . (.originalStreamId)) globalForward
        name = streamName i
    forward <- requireRead =<< collectPages (StreamVersion 0) (\cursor -> runStoreIO store (readStreamForward name cursor pageSize)) (.streamVersion)
    backward <- requireRead =<< collectPages (StreamVersion 0) (\cursor -> runStoreIO store (readStreamBackward name cursor pageSize)) (.streamVersion)
    streamed <- runStoreIO store (Stream.toList (readStreamForwardStream name (StreamVersion 0) pageSize)) >>= requireRead
    let sameIds values = fmap (.eventId) values == fmap (.eventId) expected
        versions = fmap (.streamVersion) forward
    pure
      [ ("stream-" <> Text.pack (show i) <> "-forward", sameIds forward),
        ("stream-" <> Text.pack (show i) <> "-backward", sameIds (reverse backward)),
        ("stream-" <> Text.pack (show i) <> "-streamly", sameIds streamed),
        ("stream-" <> Text.pack (show i) <> "-versions", versions == fmap (StreamVersion . fromIntegral) [1 .. length forward])
      ]
  categoryCells <- forM [0 .. 7] \i -> do
    let ids = [streamId | (streamIndex, streamId) <- Map.toList mappings, streamIndex `mod` 8 == i]
        expected = filter (\item -> item.originalStreamId `elem` ids) globalForward
    actual <- requireRead =<< collectPages (GlobalPosition 0) (\cursor -> runStoreIO store (readCategory (category i) cursor pageSize)) (.globalPosition)
    pure ("category-" <> Text.pack (show i), actual == expected)
  resolved <- runStoreIO store (lookupStreamNames (Map.elems mappings)) >>= requireRead
  let positions = fmap (.globalPosition) globalForward
      globalCells =
        [ ("global-forward-complete", length globalForward == 10000),
          ("global-forward-strict-order", positions == sort (nub positions)),
          ("global-backward-reverse", reverse globalBackward == globalForward),
          ("source-name-lookup", all (\i -> Map.lookup (mappings Map.! i) resolved == Just (streamName i)) [0 .. 15])
        ]
  recordCells context "cursor-semantics" [] (globalCells <> concat streamCells <> categoryCells)

collectPages :: cursor -> (cursor -> IO (Either StoreError (Vector RecordedEvent))) -> (RecordedEvent -> cursor) -> IO (Either StoreError [RecordedEvent])
collectPages first fetch advance = go first []
  where
    go cursor chunks = do
      result <- fetch cursor
      case result of
        Left err -> pure (Left err)
        Right page
          | Vector.null page -> pure (Right (concat (reverse chunks)))
          | otherwise -> go (advance (Vector.last page)) (Vector.toList page : chunks)

requireRead :: (Show err) => Either err value -> IO value
requireRead = either (fail . show) pure
