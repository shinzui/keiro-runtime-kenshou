module Main (main) where

import Kenshou.Cli (mainWith)
import Kenshou.Suite.Registry (program, runWithArgs)
import System.Environment (getArgs)
import System.Exit (exitWith)

main :: IO ()
main =
  getArgs >>= \case
    ["--version"] -> runWithArgs ["--version"] >>= exitWith
    _ -> mainWith program
