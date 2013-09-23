import Control.Concurrent            (forkIO)
import Data.ByteString.Char8         (pack, unpack)
import Pipes
import Pipes.Safe                    (runSafeT)
import Pipes.Prelude                 (stdoutLn)
import Pipes.Process                 (process)
import Control.Monad                 (forever)


main =
    do (c, p) <- process "/bin/cat" [] Nothing Nothing
       forkIO $ runSafeT $ runEffect $ yield (pack "hello\n") >-> c
       runSafeT $ runEffect $ (p >> return ()) >-> label >-> stdoutLn
    where
      label =
        forever $
          do r <- await
             case r of
               (Left l)  -> yield (unpack l)
               (Right r) -> yield (unpack r)