module Pipes.Process where

import Control.Concurrent            (killThread, forkIO)
import Control.Concurrent.STM        (atomically)
import Control.Concurrent.STM.TMVar  (newEmptyTMVar, putTMVar, takeTMVar)
import Control.Exception             (SomeException, catch, throw)
import Control.Monad.Catch           (MonadCatch)
import Data.ByteString               (ByteString, hGetSome, hPut)
import Data.ByteString.Lazy.Internal (defaultChunkSize)
import Pipes
import Pipes.Safe                    (SafeT, finally)
import System.Exit                   (ExitCode)
import System.IO                     (hClose, hIsEOF, hFlush)
import System.Process                (runInteractiveProcess, waitForProcess, terminateProcess, getProcessExitCode)


data IOAction
    = Stdout ByteString
    | Stderr ByteString
    | Terminated ExitCode
    | ExceptionRaised SomeException

data InAction
    = Stdin ByteString
    | CloseStdin
      deriving Show
{-
process' :: (MonadIO m) =>
           FilePath                 -- ^ path to executable
        -> [String]                 -- ^ arguments to pass to executable
        -> Maybe String             -- ^ optional working directory
        -> Maybe [(String, String)] -- ^ optional environment (otherwise inherit)
        -> Producer (Either ByteString ByteString) m ExitCode
process' executable args wd environment =
    dp <- lift $ liftIO initProcess
       destroyProcess
       go p
    where

      initProcess =
          do action <- atomically newEmptyTMVar
             outEOF <- atomically newEmptyTMVar
             errEOF <- atomically newEmptyTMVar
             (tids, proch)   <-
               do (_inh, outh, errh, proch) <- runInteractiveProcess executable args wd environment
--                  hClose inh

                  outTid <- forkIO $ let loop = do b <- hGetSome outh defaultChunkSize
                                                   atomically $ putTMVar action (Stdout b)
                                                   eof <- hIsEOF outh
                                                   if eof
                                                    then atomically $ putTMVar outEOF ()
                                                    else loop
                                     in loop `catch` (\e -> do atomically $ putTMVar action (ExceptionRaised e))
                  errTid <- forkIO $ let loop = do b <- hGetSome errh 100
                                                   atomically $ putTMVar action (Stderr b)
                                                   eof <- hIsEOF errh
                                                   if eof
                                                    then atomically $ putTMVar errEOF ()
                                                    else loop
                                     in loop `catch` (\e -> do atomically $ putTMVar action (ExceptionRaised e))

                  termTid <- forkIO $
                     (do atomically $ takeTMVar outEOF
                         atomically $ takeTMVar errEOF
                         ec <- waitForProcess proch
                         atomically $ putTMVar action (Terminated ec))
                     `catch` (\e -> do atomically $ putTMVar action (ExceptionRaised e))

                  return ([outTid, errTid, termTid], proch)
             return (action, tids, proch)

      go (action, _, _) = go'
          where
            go' =
                do a <- lift $ liftIO $ atomically $ takeTMVar action
                   case a of
                     (Stdout b) ->
                         do yield (Right b)
                            go'
                     (Stderr b) ->
                         do yield (Left b)
                            go'
                     (Terminated ec) ->
                         do return ec
                     (ExceptionRaised e) ->
                         throw e

-}
process :: (MonadCatch m, MonadIO m) =>
           FilePath                 -- ^ path to executable
        -> [String]                 -- ^ arguments to pass to executable
        -> Maybe String             -- ^ optional working directory
        -> Maybe [(String, String)] -- ^ optional environment (otherwise inherit)
        -> IO (Consumer ByteString (SafeT m) (), Producer (Either ByteString ByteString) (SafeT m) ExitCode)
process executable args wd environment =
    do p@(_,input,inh,_,_) <- initProcess
       return $ (consumer p `finally` (liftIO $ atomically $ putTMVar input CloseStdin), producer p `finally` (destroyProcess p) )
    where
      destroyProcess (_, _, _, tids, proch) = liftIO $
        do mec <- getProcessExitCode proch
           case mec of
             Nothing ->
                 do -- putStrLn "terminating process."
                    terminateProcess proch
                    _ <- waitForProcess proch
                    return ()
             (Just _) -> return ()
           -- putStrLn "cleaning up process threads"
           mapM_ killThread tids

      initProcess =
          do action <- atomically newEmptyTMVar
             outEOF <- atomically newEmptyTMVar
             errEOF <- atomically newEmptyTMVar
             input  <- atomically newEmptyTMVar
             (inh, tids, proch)   <-
               do (inh, outh, errh, proch) <- runInteractiveProcess executable args wd environment
                  inTid <- forkIO $ let loop = do inaction <- atomically $ takeTMVar input
                                                  -- print ("in loop", inaction)
                                                  case inaction of
                                                    (Stdin bs) ->
                                                        do hPut inh bs
                                                           loop
                                                    (CloseStdin) ->
                                                        do hFlush inh
                                                           hClose inh
                                    in loop

                  outTid <- forkIO $ let loop = do b <- hGetSome outh defaultChunkSize
  --                                                 print ("out",b)
                                                   atomically $ putTMVar action (Stdout b)
                                                   eof <- hIsEOF outh
                                                   if eof
                                                    then atomically $ putTMVar outEOF ()
                                                    else loop
                                     in loop `catch` (\e -> do atomically $ putTMVar action (ExceptionRaised e))
                  errTid <- forkIO $ let loop = do b <- hGetSome errh 100
                                                   atomically $ putTMVar action (Stderr b)
                                                   eof <- hIsEOF errh
                                                   if eof
                                                    then atomically $ putTMVar errEOF ()
                                                    else loop
                                     in loop `catch` (\e -> do atomically $ putTMVar action (ExceptionRaised e))

                  termTid <- forkIO $
                     (do atomically $ takeTMVar outEOF
                         atomically $ takeTMVar errEOF
                         ec <- waitForProcess proch
                         atomically $ putTMVar action (Terminated ec))
                     `catch` (\e -> do atomically $ putTMVar action (ExceptionRaised e))

                  return (inh, [inTid, outTid, errTid, termTid], proch)
             return (action, input, inh, tids, proch)

      consumer (_, input, _, _, _) = go'
          where
            go' =
                do bs <- await
                   -- lift $ liftIO $ print ("consumer",bs)
                   lift $ liftIO $ atomically $ putTMVar input (Stdin bs)
                   go'
      producer (action, _, _, _, _) = go'
          where
            go' =
                do a <- lift $ liftIO $ atomically $ takeTMVar action
                   case a of
                     (Stdout b) ->
                         do yield (Right b)
                            go'
                     (Stderr b) ->
                         do yield (Left b)
                            go'
                     (Terminated ec) ->
                         do return ec
                     (ExceptionRaised e) ->
                         throw e

