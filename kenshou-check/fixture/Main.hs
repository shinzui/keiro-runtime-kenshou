module Main (main) where

import Control.Concurrent (threadDelay)

main :: IO ()
main = threadDelay maxBound
