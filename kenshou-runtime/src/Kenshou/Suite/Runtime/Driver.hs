module Kenshou.Suite.Runtime.Driver
  ( GeneratedOrder (..),
    generateOrder,
    driverIndices,
    SubmitOutcome (..),
    submitOrder,
    DriverReport (..),
    runDriver,
  )
where

import Control.Concurrent (threadDelay)
import Control.Concurrent.MVar (MVar, tryReadMVar)
import Data.Aeson (FromJSON, ToJSON)
import Data.Int (Int64)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime, addUTCTime, diffUTCTime, getCurrentTime)
import GHC.Generics (Generic)
import Keiro.Command (defaultRunCommandOptions)
import Kenshou.Core.Id (Seed, deriveGen)
import Kenshou.Suite.Runtime.System.Config (SystemConfig (..), customerCount, skuCount)
import Kenshou.Suite.Runtime.System.Contracts (CustomerId (..), OrderId (..), Sku (..))
import Kenshou.Suite.Runtime.System.Dispatch (Dispatched (..), dispatchOnce)
import Kenshou.Suite.Runtime.System.Order (OrderCommand (..), PlaceOrderData (..), orderEventStream, orderStream)
import Kenshou.Suite.Runtime.System.Schema (orderProjection)
import Kenshou.Suite.Runtime.System.Store (ContextStore, deterministicEventId, runContext)
import System.Random.SplitMix (nextDouble, nextWord64)

data GeneratedOrder = GeneratedOrder
  { index :: !Int,
    orderId :: !OrderId,
    customer :: !CustomerId,
    sku :: !Sku,
    quantity :: !Int,
    amountCents :: !Int64,
    slowPick :: !Bool
  }
  deriving stock (Eq, Show)

-- | Order @i@ is a pure function of the run seed, so every driver process,
-- every restart and every oracle derives the same order.
generateOrder :: Seed -> SystemConfig -> Int -> GeneratedOrder
generateOrder seed config i =
  let g0 = deriveGen seed ("runtime-order-" <> Text.pack (show i))
      (refuseDraw, g1) = nextDouble g0
      (expireDraw, g2) = nextDouble g1
      (customerDraw, g3) = nextWord64 g2
      (skuDraw, g4) = nextWord64 g3
      (quantityDraw, g5) = nextWord64 g4
      (amountDraw, _) = nextWord64 g5
      refused = refuseDraw < config.refuseFraction
      skuName
        | refused = "discontinued-" <> Text.pack (show (skuDraw `mod` 4))
        | otherwise = "sku-" <> Text.pack (show (skuDraw `mod` fromIntegral skuCount))
   in GeneratedOrder
        { index = i,
          orderId = OrderId ("o-" <> Text.pack (show i)),
          customer = CustomerId ("customer-" <> Text.pack (show (customerDraw `mod` fromIntegral customerCount))),
          sku = Sku skuName,
          quantity = 1 + fromIntegral (quantityDraw `mod` 3),
          amountCents = 100 + fromIntegral (amountDraw `mod` 4900),
          slowPick = not refused && expireDraw < config.expireFraction
        }

-- | Driver @k@ of @n@ submits every order whose index is congruent to @k@.
driverIndices :: Int -> Int -> Int -> [Int]
driverIndices total processes k = [i | i <- [0 .. total - 1], i `mod` max 1 processes == k]

data SubmitOutcome = SubmitAccepted | SubmitDuplicate | SubmitFailed !Text
  deriving stock (Eq, Show)

-- | The event identifier is fixed per order, so a resubmission after a
-- driver restart is recognised as a duplicate rather than a second order.
submitOrder :: ContextStore -> GeneratedOrder -> IO SubmitOutcome
submitOrder store order = attempt (5 :: Int)
  where
    OrderId identifier = order.orderId
    command = PlaceOrder (PlaceOrderData order.orderId order.customer order.sku order.quantity order.amountCents order.slowPick)
    attempt remaining = do
      result <- runContext store (dispatchOnce defaultRunCommandOptions orderEventStream (orderStream order.orderId) (deterministicEventId ("place/" <> identifier)) command [orderProjection])
      case result of
        Right DispatchAppended -> pure SubmitAccepted
        Right DispatchDuplicate -> pure SubmitDuplicate
        Right DispatchRejected -> pure (SubmitFailed "order aggregate rejected PlaceOrder")
        Right (DispatchFailed problem)
          | remaining > 0 -> threadDelay 200000 >> attempt (remaining - 1)
          | otherwise -> pure (SubmitFailed (Text.pack (show problem)))
        Left storeError
          | remaining > 0 -> threadDelay 200000 >> attempt (remaining - 1)
          | otherwise -> pure (SubmitFailed (Text.pack (show storeError)))

data DriverReport = DriverReport
  { attempted :: !Int,
    accepted :: !Int,
    duplicates :: !Int,
    failed :: !Int,
    stopped :: !Bool
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

-- | Open-loop submission: order @i@ is due at @start + i / rate@ whether or
-- not earlier submissions have finished. A stop request ends submission.
runDriver :: ContextStore -> Seed -> SystemConfig -> Int -> MVar stop -> (GeneratedOrder -> SubmitOutcome -> IO ()) -> IO DriverReport
runDriver store seed config k stop observe = do
  start <- getCurrentTime
  let rate = max 1 config.ratePerSecond
      total = if config.orders > 0 then config.orders else config.durationSeconds * rate
      processes = max 1 config.processesPerRole
      -- Each driver issues its share of the rate; position p of its own
      -- sequence is due at p / (rate / processes) after the start.
      intended position = addUTCTime (fromIntegral position * fromIntegral processes / fromIntegral rate) start
      indices
        | config.replicatedDrivers = [0 .. total - 1]
        | otherwise = driverIndices total processes k
      sequence' = zip [0 :: Int ..] (concat (replicate (max 1 config.submissionRounds) indices))
      go report [] = pure report
      go report ((position, i) : rest) = do
        requested <- tryReadMVar stop
        case requested of
          Just _ -> pure report {stopped = True}
          Nothing -> do
            waitUntil (intended position)
            let order = generateOrder seed config i
            outcome <- submitOrder store order
            observe order outcome
            let next = case outcome of
                  SubmitAccepted -> report {attempted = report.attempted + 1, accepted = report.accepted + 1}
                  SubmitDuplicate -> report {attempted = report.attempted + 1, duplicates = report.duplicates + 1}
                  SubmitFailed _ -> report {attempted = report.attempted + 1, failed = report.failed + 1}
            go next rest
  go (DriverReport 0 0 0 0 False) sequence'

waitUntil :: UTCTime -> IO ()
waitUntil target = do
  now <- getCurrentTime
  let remaining = diffUTCTime target now
  if remaining > 0 then threadDelay (ceiling (remaining * 1000000)) else pure ()
