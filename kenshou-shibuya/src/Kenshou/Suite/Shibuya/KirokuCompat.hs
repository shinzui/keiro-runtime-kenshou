{-# LANGUAGE CPP #-}

module Kenshou.Suite.Shibuya.KirokuCompat
  ( subscriptionBatchSize,
    subscriptionBufferSize,
    configuredConsumerGroup,
    consumerGroupSize,
  )
where

import Data.Int (Int32)
import Kiroku.Store.Subscription.Types qualified as Sub
#if MIN_VERSION_kiroku_store(0,10,0)
import Kiroku.Store.Subscription.Stream qualified as Stream
#else
import Numeric.Natural (Natural)
#endif

-- Keep the same numeric workload on both sides of the validated-capacity API
-- introduced by mori://shinzui/kiroku/packages/kiroku-store at 0.10.0.0.
#if MIN_VERSION_kiroku_store(0,10,0)
subscriptionBatchSize :: Int32 -> Sub.BatchSize
subscriptionBatchSize = either (error . show) id . Sub.mkBatchSize

subscriptionBufferSize :: Int32 -> Stream.StreamBufferSize
subscriptionBufferSize = either (error . show) id . Stream.mkStreamBufferSize . fromIntegral

consumerGroupSize :: Int32 -> Sub.ConsumerGroupSize
consumerGroupSize = either (error . show) id . Sub.mkConsumerGroupSize

configuredConsumerGroup :: Int32 -> Int32 -> Sub.ConsumerGroup
configuredConsumerGroup member size = either (error . show) id (Sub.mkConsumerGroup member (consumerGroupSize size))
#else
subscriptionBatchSize :: Int32 -> Int32
subscriptionBatchSize = id

subscriptionBufferSize :: Int32 -> Natural
subscriptionBufferSize = fromIntegral

consumerGroupSize :: Int32 -> Int32
consumerGroupSize = id

configuredConsumerGroup :: Int32 -> Int32 -> Sub.ConsumerGroup
configuredConsumerGroup = Sub.ConsumerGroup
#endif
