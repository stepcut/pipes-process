import Control.Concurrent            (forkIO)
import Control.Monad                 (forever)
import Data.ByteString.Char8         (ByteString, pack, unpack)
import Pipes
import Pipes.Safe                    (runSafeT)
import Pipes.Prelude                 (stdoutLn)
import Pipes.Process                 (closeStdin, withProcess, writeProcess, readProcess, flushProcess)
import System.Process                (CreateProcess, createProcess, proc)


catProcess :: CreateProcess
catProcess = proc "cat" []


mergeEither :: (Monad m) => Pipe (Either a a) a m r
mergeEither =
    forever $ do
      e <- await
      yield $ either id id e

unpackPipe :: (Monad m) => Pipe ByteString String m r
unpackPipe =
    forever $ do
      bs <- await
      yield $ unpack bs


main :: IO ()
main =
    runSafeT $ withProcess catProcess $ \process ->
        do liftIO $ forkIO $ runSafeT $ runEffect $ yield (pack "hello\n") >-> writeProcess process

           runEffect $ (readProcess process >> return ()) >->
                       mergeEither >->
                       unpackPipe >->
                       stdoutLn
           return ()
