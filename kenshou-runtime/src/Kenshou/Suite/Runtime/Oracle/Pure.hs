module Kenshou.Suite.Runtime.Oracle.Pure
  ( LedgerLeg (..),
    OrderFacts (..),
    OrderViolation (..),
    checkOrderFacts,
  )
where

import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Kenshou.Suite.Runtime.System.Model (FulfilmentPhase (..), OrderPhase (..), matchingTerminal)

-- SQL and stream readers will construct one value per durably accepted order.
-- This checker is deliberately independent of the Keiro transition graph.
data OrderFacts = OrderFacts
  { shopTerminals :: ![OrderPhase],
    warehouseTerminals :: ![FulfilmentPhase],
    ledgerLegCounts :: !(Map LedgerLeg Int),
    loyaltyFanout :: !Int
  }
  deriving stock (Eq, Show)

data LedgerLeg
  = HoldDebit
  | HoldCredit
  | CaptureDebit
  | CaptureCredit
  | RefundDebit
  | RefundCredit
  | ReserveDebit
  | ReserveCredit
  | CommitDebit
  | CommitCredit
  | ReleaseDebit
  | ReleaseCredit
  | LoyaltyDebit
  | LoyaltyCredit
  deriving stock (Eq, Ord, Show, Enum, Bounded)

data OrderViolation
  = ShopTerminalCount !Int
  | WarehouseTerminalCount !Int
  | TerminalMismatch !OrderPhase !FulfilmentPhase
  | InvalidLoyaltyFanout !Int
  | LedgerLegCount !LedgerLeg !Int !Int
  deriving stock (Eq, Show)

checkOrderFacts :: OrderFacts -> [OrderViolation]
checkOrderFacts facts =
  shopCardinality <> warehouseCardinality <> terminalMatch <> fanoutCheck <> ledgerChecks
  where
    shopCardinality = [ShopTerminalCount (length facts.shopTerminals) | length facts.shopTerminals /= 1]
    warehouseCardinality = [WarehouseTerminalCount (length facts.warehouseTerminals) | length facts.warehouseTerminals /= 1]
    terminalPair = case (facts.shopTerminals, facts.warehouseTerminals) of
      ([shop], [warehouse]) -> Just (shop, warehouse)
      _ -> Nothing
    terminalMatch = case terminalPair of
      Just (shop, warehouse) | not (matchingTerminal shop warehouse) -> [TerminalMismatch shop warehouse]
      _ -> []
    fanoutCheck = [InvalidLoyaltyFanout facts.loyaltyFanout | facts.loyaltyFanout < 0]
    expected = case terminalPair of
      Just (OrderCompleted, FulfilmentShipped) ->
        [ (HoldDebit, 1),
          (HoldCredit, 1),
          (CaptureDebit, 1),
          (CaptureCredit, 1),
          (ReserveDebit, 1),
          (ReserveCredit, 1),
          (CommitDebit, 1),
          (CommitCredit, 1),
          (LoyaltyDebit, 1),
          (LoyaltyCredit, facts.loyaltyFanout)
        ]
      Just (OrderRejected, FulfilmentRefused) ->
        [(HoldDebit, 1), (HoldCredit, 1), (RefundDebit, 1), (RefundCredit, 1)]
      Just (OrderExpired, FulfilmentExpired) ->
        [ (HoldDebit, 1),
          (HoldCredit, 1),
          (RefundDebit, 1),
          (RefundCredit, 1),
          (ReserveDebit, 1),
          (ReserveCredit, 1),
          (ReleaseDebit, 1),
          (ReleaseCredit, 1)
        ]
      _ -> []
    expectedMap = Map.fromList expected
    ledgerChecks = case terminalPair of
      Just (shop, warehouse)
        | matchingTerminal shop warehouse ->
            [ LedgerLegCount leg wanted actual
            | leg <- [minBound .. maxBound],
              let wanted = Map.findWithDefault 0 leg expectedMap
                  actual = Map.findWithDefault 0 leg facts.ledgerLegCounts,
              wanted /= actual
            ]
      _ -> []
