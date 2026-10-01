import Control.Concurrent
import Control.Monad
import GHC.Conc (listThreads, threadStatus)
import System.Mem (performGC)

probe label = do
  ts <- listThreads
  statuses <- mapM threadStatus ts
  putStrLn (label ++ ": " ++ show statuses)

main = do
  performGC
  probe "initial"
  replicateM_ 20 $ do
    done <- newEmptyMVar
    forkIO (putMVar done ())
    takeMVar done
  threadDelay 10000
  probe "finished before GC"
  performGC
  probe "after GC"
