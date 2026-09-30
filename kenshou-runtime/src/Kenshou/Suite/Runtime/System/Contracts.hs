module Kenshou.Suite.Runtime.System.Contracts
  ( OrderId (..),
    CustomerId (..),
    Sku (..),
    TopicPrefix (..),
    ShopMessage (..),
    WarehouseMessage (..),
    shopTopic,
    warehouseTopic,
  )
where

import Data.Aeson (FromJSON, ToJSON)
import Data.Int (Int64)
import Data.Text (Text)
import GHC.Generics (Generic)

newtype OrderId = OrderId Text
  deriving stock (Generic, Eq, Ord, Show)
  deriving newtype (FromJSON, ToJSON)

newtype CustomerId = CustomerId Text
  deriving stock (Generic, Eq, Ord, Show)
  deriving newtype (FromJSON, ToJSON)

newtype Sku = Sku Text
  deriving stock (Generic, Eq, Ord, Show)
  deriving newtype (FromJSON, ToJSON)

newtype TopicPrefix = TopicPrefix Text
  deriving stock (Generic, Eq, Ord, Show)
  deriving newtype (FromJSON, ToJSON)

data ShopMessage = OrderPlacedV1
  { orderId :: !OrderId,
    customer :: !CustomerId,
    sku :: !Sku,
    quantity :: !Int,
    amountCents :: !Int64,
    slowPick :: !Bool
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

data WarehouseMessage
  = FulfilmentShippedV1
      { orderId :: !OrderId,
        sku :: !Sku,
        quantity :: !Int
      }
  | FulfilmentRefusedV1
      { orderId :: !OrderId,
        reason :: !Text
      }
  | FulfilmentExpiredV1
      { orderId :: !OrderId
      }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

shopTopic :: TopicPrefix -> Text
shopTopic (TopicPrefix prefix) = prefix <> "-shop-events"

warehouseTopic :: TopicPrefix -> Text
warehouseTopic (TopicPrefix prefix) = prefix <> "-warehouse-events"
