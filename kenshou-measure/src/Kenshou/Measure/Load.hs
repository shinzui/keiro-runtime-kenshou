module Kenshou.Measure.Load
  ( module Kenshou.Measure.Load.Types,
    runLoad,
  )
where

import Kenshou.Measure.Load.Closed (runClosed)
import Kenshou.Measure.Load.Open (runOpen)
import Kenshou.Measure.Load.Types
import Kenshou.Measure.Session (Measurement)

runLoad :: Measurement -> LoadModel -> Operation -> IO LoadReport
runLoad measurement model operation = case model of
  ClosedLoop config -> runClosed measurement config operation
  OpenLoop config -> runOpen measurement config operation
