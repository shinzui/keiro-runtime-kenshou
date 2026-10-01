module Kenshou.Cli.Attest.KeiroLease (replayLeaseCells, recomputeLease) where

import Control.Exception (IOException, try)
import Data.Aeson (FromJSON (..), Value (..), eitherDecodeFileStrict', object, toJSON, withObject, (.:), (.=))
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (parseEither)
import Data.Int (Int64)
import Data.List (sort)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime, addUTCTime)
import Kenshou.Core.Outcome (Outcome (..), outcomeExitCode)
import Kenshou.Evidence.Attest (Recomputation (..))
import Kenshou.Evidence.Source (RunResultView (..), RunSource (..))
import System.FilePath ((</>))

-- Deliberately independent of the scenario's oracle and verdict documents.
data Lease = Lease
  { message :: !Int64,
    reads :: !Int64,
    readAt :: !UTCTime,
    visible :: !UTCTime,
    observed :: !UTCTime
  }

instance FromJSON Lease where
  parseJSON = withObject "lease row" \o -> Lease <$> o .: "messageId" <*> o .: "readCount" <*> o .: "lastReadAt" <*> o .: "visibleAt" <*> o .: "observedAt"

data Delivery = Delivery {attempt :: !Word, payload :: !Text}

instance FromJSON Delivery where
  parseJSON = withObject "handler delivery" \o -> Delivery <$> o .: "attempt" <*> o .: "payload"

data Arm = Arm
  { initial :: !Lease,
    contested :: !Lease,
    deliveries :: ![Maybe Delivery],
    completed :: !Bool,
    effects :: ![Text],
    remaining :: ![Lease]
  }

instance FromJSON Arm where
  parseJSON = withObject "lease observations" \o -> do
    schema <- o .: "schema"
    if schema /= ("kenshou.queue-lease-observations/v1" :: Text) then fail "unsupported lease observation schema" else pure ()
    Arm <$> o .: "initial" <*> o .: "contested" <*> o .: "deliveries" <*> o .: "completionObserved" <*> o .: "effects" <*> o .: "remainingRows"

replayLeaseCells :: Value -> Value -> Either Text [(Text, Bool)]
replayLeaseCells rawUnextended rawExtended = do
  unextended <- either (Left . Text.pack) Right (parseEither parseJSON rawUnextended :: Either String Arm)
  extended <- either (Left . Text.pack) Right (parseEither parseJSON rawExtended :: Either String Arm)
  let common :: Arm -> Text -> Bool
      common arm expectedPayload =
        length arm.deliveries == 2
          && all (\delivery -> delivery.payload == expectedPayload) [delivery | Just delivery <- arm.deliveries]
          && arm.initial.message == arm.contested.message
          && arm.initial.reads == 1
          && arm.initial.readAt <= arm.initial.observed
          && arm.initial.observed < arm.initial.visible
          && arm.contested.readAt <= arm.contested.observed
          && arm.contested.observed >= addUTCTime 6 arm.initial.readAt
      attempts :: Arm -> [Word]
      attempts arm = sort [delivery.attempt | Just delivery <- arm.deliveries]
      unextendedReads =
        common unextended "unextended"
          && unextended.contested.reads == 2
          && unextended.contested.readAt >= unextended.initial.visible
          && attempts unextended == [0, 1]
      extendedReads =
        common extended "extended"
          && extended.contested.reads == 1
          && extended.contested.readAt == extended.initial.readAt
          && extended.contested.visible == extended.initial.visible
          && extended.contested.observed < extended.contested.visible
          && attempts extended == [0]
  pure
    [ ("unextended-lease-expires", unextended.completed && unextended.effects == ["unextended", "unextended"]),
      ("unextended-read-count-and-cadence", unextendedReads),
      ("extension-prevents-duplicate", extended.completed && extended.effects == ["extended"]),
      ("extended-read-count-one", extendedReads),
      ("both-queues-drained", null unextended.remaining && null extended.remaining)
    ]

recomputeLease :: FilePath -> RunSource -> IO (Either Text Recomputation)
recomputeLease root source = do
  unextended <- readDocument (root </> "logs/queue-lease-unextended.json")
  extended <- readDocument (root </> "logs/queue-lease-extended.json")
  result <- readDocument (root </> "run-result.json")
  pure do
    u <- unextended
    e <- extended
    document <- result
    if field "scenarioRevision" document /= Just (Number 3)
      then Left "lease replay supports only scenario revision 3"
      else pure ()
    cells <- replayLeaseCells u e
    let failures = [label | (label, False) <- cells]
        outcome = if null failures then Passed else Failed
        expectedSummary = object ["checks" .= length cells, "failures" .= failures]
        agrees =
          field "failures" document == Just (toJSON failures)
            && field "blocking" document == Just (Bool (outcome == Failed))
            && field "exitCode" document == Just (toJSON (outcomeExitCode outcome))
            && source.result.resultKnownDefect == Nothing
            && (source.result.resultSummaries >>= field "verdicts" >>= field "keiro/queue/concurrency/lease-extension") == Just expectedSummary
    pure
      Recomputation
        { agreesWithDocuments = agrees,
          outcome = Just outcome,
          comparisonVerdict = Nothing,
          detail = "recomputed five queue lease checks from sealed SQL rows and parked-handler observations"
        }

readDocument :: FilePath -> IO (Either Text Value)
readDocument path = do
  attempted <- try (eitherDecodeFileStrict' path) :: IO (Either IOException (Either String Value))
  pure $ case attempted of
    Left err -> Left (Text.pack (show err))
    Right value -> either (Left . Text.pack) Right value

field :: Text -> Value -> Maybe Value
field name (Object value) = KeyMap.lookup (Key.fromText name) value
field _ _ = Nothing
