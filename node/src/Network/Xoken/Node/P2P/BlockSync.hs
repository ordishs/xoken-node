{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Network.Xoken.Node.P2P.BlockSync
    ( createSocket
    , setupPeerConnection
    , initPeerListeners
    , runEgressStream
    ) where

import Control.Concurrent.Async (mapConcurrently)
import Control.Concurrent.Async.Lifted as LA (async)
import Control.Concurrent.MVar
import Control.Concurrent.STM.TVar
import Control.Exception
import qualified Control.Exception.Lifted as LE (try)
import Control.Monad
import Control.Monad.Logger
import Control.Monad.Reader
import Control.Monad.STM
import Control.Monad.State.Strict
import qualified Data.Aeson as A (decode, encode)
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as C
import qualified Data.ByteString.Lazy as BSL
import qualified Data.ByteString.Lazy.Char8 as LC
import Data.ByteString.Short as BSS
import Data.Function ((&))
import Data.Functor.Identity
import Data.Int
import qualified Data.List as L
import qualified Data.Map.Strict as M
import Data.Maybe
import Data.Serialize
import Data.String.Conversions
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock
import Data.Time.Clock.POSIX
import Data.Word
import qualified Database.CQL.IO as Q
import Network.Socket
import qualified Network.Socket.ByteString as SB (recv)
import qualified Network.Socket.ByteString.Lazy as LB (recv, sendAll)
import Network.Xoken.Block.Common
import Network.Xoken.Block.Headers
import Network.Xoken.Constants
import Network.Xoken.Crypto.Hash
import Network.Xoken.Network.Common -- (GetData(..), MessageCommand(..), NetworkAddress(..))
import Network.Xoken.Network.Message
import Network.Xoken.Node.Env
import Network.Xoken.Node.P2P.Types
import Network.Xoken.P2P.Common
import Streamly
import Streamly.Prelude ((|:), nil)
import qualified Streamly.Prelude as S
import System.Random

data BlockSyncException
    = BlocksNotChainedException
    | MessageParsingException
    | KeyValueDBInsertException
    | BlockHashNotFoundInDB
    | DuplicateBlockHeader
    | InvalidMessageType
    | EmptyHeadersMessage
    deriving (Show)

instance Exception BlockSyncException

createSocket :: AddrInfo -> IO (Maybe Socket)
createSocket = createSocketWithOptions []

createSocketWithOptions :: [SocketOption] -> AddrInfo -> IO (Maybe Socket)
createSocketWithOptions options addr = do
    sock <- socket AF_INET Stream (addrProtocol addr)
    mapM_ (\option -> when (isSupportedSocketOption option) (setSocketOption sock option 1)) options
    res <- try $ connect sock (addrAddress addr)
    case res of
        Right () -> return $ Just sock
        Left (e :: IOException) -> do
            print ("TCP socket connect fail: " ++ show (addrAddress addr))
            return Nothing

sendEncMessage :: MVar Bool -> Socket -> BSL.ByteString -> IO ()
sendEncMessage writeLock sock msg = do
    a <- takeMVar writeLock
    (LB.sendAll sock msg) `catch` (\(e :: IOException) -> putStrLn ("caught: " ++ show e))
    putMVar writeLock a

setupPeerConnection :: (HasService env m) => m ()
setupPeerConnection = do
    bp2pEnv <- asks getBitcoinP2PEnv
    let net = bncNet $ bitcoinNodeConfig bp2pEnv
        seeds = getSeeds net
        hints = defaultHints {addrSocketType = Stream}
        port = getDefaultPort net
    liftIO $ print (show seeds)
    let sd = map (\x -> Just (x :: HostName)) seeds
    addrs <- liftIO $ mapConcurrently (\x -> head <$> getAddrInfo (Just hints) (x) (Just (show port))) sd
    res <-
        liftIO $
        mapConcurrently
            (\y -> do
                 sock <- createSocket y
                 case sock of
                     Just sx -> do
                         fl <- doVersionHandshake net sx $ addrAddress y
                         mv <- newMVar True
                         let bp = BitcoinPeer (addrAddress y) sock mv fl Nothing 99999 Nothing
                         atomically $ modifyTVar (bitcoinPeers bp2pEnv) (M.insert (addrAddress y) bp)
                     Nothing -> do
                         mv <- newMVar True
                         let bp = BitcoinPeer (addrAddress y) sock mv False Nothing 99999 Nothing
                         atomically $ modifyTVar (bitcoinPeers bp2pEnv) (M.insert (addrAddress y) bp))
            addrs
    return ()

-- Helper Functions
recvAll :: Socket -> Int -> IO B.ByteString
recvAll sock len = do
    msg <- SB.recv sock len
    if B.length msg == len
        then return msg
        else B.append msg <$> recvAll sock (len - B.length msg)

readNextMessage :: Network -> Socket -> IO (Maybe Message)
readNextMessage net sock = do
    res <- liftIO $ try $ (SB.recv sock 24)
    case res of
        Right hdr -> do
            case (decode hdr) of
                Left e -> do
                    liftIO $ print ("Error decoding incoming message header: " ++ e)
                    return Nothing
                Right (MessageHeader _ _ len _) -> do
                    byts <-
                        if len == 0
                            then return hdr
                            else do
                                rs <- liftIO $ try $ (recvAll sock (fromIntegral len))
                                case rs of
                                    Left (e :: IOException) -> do
                                        liftIO $ print ("Error, reading: " ++ show e)
                                        throw e
                                    Right y -> return $ hdr `B.append` y
                    case runGet (getMessage net) $ byts of
                        Left e -> do
                            liftIO $ print ("Error, unexpected message header: " ++ e)
                            return Nothing
                        Right msg -> return $ Just msg
        Left (e :: IOException) -> do
            liftIO $ print ("socket read fail")
            return Nothing

doVersionHandshake :: Network -> Socket -> SockAddr -> IO (Bool)
doVersionHandshake net sock sa = do
    g <- liftIO $ getStdGen
    now <- round <$> liftIO getPOSIXTime
    myaddr <- head <$> getAddrInfo (Just defaultHints {addrSocketType = Stream}) (Just "192.168.0.106") (Just "3000")
    let nonce = fst (random g :: (Word64, StdGen))
        ad = NetworkAddress 0 $ addrAddress myaddr -- (SockAddrInet 0 0)
        bb = 1 :: Word32 -- ### TODO: getBestBlock ###
        rmt = NetworkAddress 0 sa
        ver = buildVersion net nonce bb ad rmt now
        em = runPut . putMessage net $ (MVersion ver)
    mv <- (newMVar True)
    sendEncMessage mv sock (BSL.fromStrict em)
    hs1 <- readNextMessage net sock
    case hs1 of
        Just (MVersion __) -> do
            hs2 <- readNextMessage net sock
            case hs2 of
                Just MVerAck -> do
                    let em2 = runPut . putMessage net $ (MVerAck)
                    sendEncMessage mv sock (BSL.fromStrict em2)
                    print ("Version handshake complete: " ++ show sa)
                    return True
                __ -> do
                    print "Error, unexpected message (2) during handshake"
                    return False
        __ -> do
            print "Error, unexpected message (1) during handshake"
            return False

produceGetHeadersMessage :: (HasService env m) => m (Message)
produceGetHeadersMessage = do
    liftIO $ print ("producing - called.")
    bp2pEnv <- asks getBitcoinP2PEnv
    dbe' <- asks getDBEnv
    liftIO $ takeMVar (bestBlockUpdated bp2pEnv) -- be blocked until a new best-block is updated in DB.
    let conn = keyValDB $ dbHandles dbe'
    let net = bncNet $ bitcoinNodeConfig bp2pEnv
    bl <- liftIO $ getBlockLocator conn net
    let gh =
            GetHeaders
                { getHeadersVersion = myVersion
                , getHeadersBL = bl
                , getHeadersHashStop = "0000000000000000000000000000000000000000000000000000000000000000"
                }
    liftIO $ print ("block-locator: " ++ show bl)
    return (MGetHeaders gh)

sendRequestMessages :: (HasService env m) => Message -> m ()
sendRequestMessages msg = do
    liftIO $ print ("sendRequestMessages - called.")
    bp2pEnv <- asks getBitcoinP2PEnv
    dbe' <- asks getDBEnv
    let conn = keyValDB $ dbHandles dbe'
    let net = bncNet $ bitcoinNodeConfig bp2pEnv
    allPeers <- liftIO $ readTVarIO (bitcoinPeers bp2pEnv)
    let connPeers = L.filter (\x -> bpConnected (snd x)) (M.toList allPeers)
    case msg of
        MGetHeaders hdr -> do
            let fbh = getHash256 $ getBlockHash $ (getHeadersBL hdr) !! 0
                md = BSS.index fbh $ (BSS.length fbh) - 1
                pds =
                    map
                        (\p -> (fromIntegral (md + p) `mod` L.length connPeers))
                        [1 .. fromIntegral (L.length connPeers)]
                indices =
                    case L.length (getHeadersBL hdr) of
                        x
                            | x >= 19 -> take 4 pds -- 2^19 = blk ht 524288
                            | x < 19 -> take 1 pds
            res <-
                liftIO $
                try $
                mapM_
                    (\z -> do
                         let pr = snd $ connPeers !! z
                         case (bpSocket pr) of
                             Just q -> do
                                 let em = runPut . putMessage net $ msg
                                 liftIO $ sendEncMessage (bpSockLock pr) q (BSL.fromStrict em)
                                 liftIO $ print ("sending out get data: " ++ show (bpAddress pr))
                             Nothing -> liftIO $ print ("Error sending, no connections available"))
                    indices
            case res of
                Right () -> return ()
                Left (e :: SomeException) -> do
                    liftIO $ print ("Error, sending out data: " ++ show e)
        ___ -> undefined

msgOrder :: Message -> Message -> Ordering
msgOrder m1 m2 = do
    if msgType m1 == MCGetHeaders
        then LT
        else GT

runEgressStream :: (HasService env m) => m ()
runEgressStream = do
    res <- LE.try $ runStream $ (S.repeatM produceGetHeadersMessage) & (S.mapM sendRequestMessages)
    case res of
        Right () -> return ()
        Left (e :: SomeException) -> liftIO $ print ("[ERROR] runEgressStream " ++ show e)
        -- S.mergeBy msgOrder (S.repeatM produceGetHeadersMessage) (S.repeatM produceGetHeadersMessage) &
        --    S.mapM   sendRequestMessages

validateChainedBlockHeaders :: Headers -> Bool
validateChainedBlockHeaders hdrs = do
    let xs = headersList hdrs
        pairs = zip xs (drop 1 xs)
        res = map (\x -> (headerHash $ fst (fst x)) == (prevBlock $ fst (snd x))) pairs
    if all (== True) res
        then True
        else False

markBestBlock :: Text -> Int32 -> Q.ClientState -> IO ()
markBestBlock hash height conn = do
    let str = "insert INTO xoken.proc_summary (name, strval, numval, boolval) values (? ,? ,?, ?)"
        qstr = str :: Q.QueryString Q.W (Text, Text, Int32, Maybe Bool) ()
        par = Q.defQueryParams Q.One ("best", hash, height :: Int32, Nothing)
    res <- try $ Q.runClient conn (Q.write (Q.prepared qstr) par)
    case res of
        Right () -> return ()
        Left (e :: SomeException) ->
            print ("Error: Marking [Best] blockhash failed: " ++ show e) >> throw KeyValueDBInsertException

getBlockLocator :: Q.ClientState -> Network -> IO ([BlockHash])
getBlockLocator conn net = do
    (hash, ht) <- fetchBestBlock conn net
    let bl = L.insert ht $ filter (> 0) $ takeWhile (< ht) $ map (\x -> ht - (2 ^ x)) [0 .. 20] -- [1,2,4,8,16,32,64,... ,262144,524288,1048576]
        str = "SELECT height, blockhash from xoken.blocks_height where height in ?"
        qstr = str :: Q.QueryString Q.R (Identity [Int32]) ((Int32, T.Text))
        p = Q.defQueryParams Q.One $ Identity bl
    op <- Q.runClient conn (Q.query qstr p)
    if L.length op == 0
        then return [headerHash $ getGenesisHeader net]
        else do
            print ("Best-block from DB: " ++ (show $ last op))
            return $
                catMaybes $
                (map (\x ->
                          case (hexToBlockHash $ snd x) of
                              Just y -> Just y
                              Nothing -> Nothing)
                     (reverse op))

fetchBestBlock :: Q.ClientState -> Network -> IO ((BlockHash, Int32))
fetchBestBlock conn net = do
    let str = "SELECT strval, numval from xoken.proc_summary where name = ?"
        qstr = str :: Q.QueryString Q.R (Identity Text) ((T.Text, Int32))
        p = Q.defQueryParams Q.One $ Identity "best"
    op <- Q.runClient conn (Q.query qstr p)
    if L.length op == 0
        then print ("Bestblock is genesis.") >> return ((headerHash $ getGenesisHeader net), 0)
        else do
            print ("Best-block from DB: " ++ show ((op !! 0)))
            case (hexToBlockHash $ fst (op !! 0)) of
                Just x -> return (x, snd (op !! 0))
                Nothing -> do
                    print ("block hash seems invalid, startin over from genesis") -- not optimal, but unforseen case.
                    return ((headerHash $ getGenesisHeader net), 0)

processHeaders :: (HasService env m) => Headers -> m ()
processHeaders hdrs = do
    dbe' <- asks getDBEnv
    bp2pEnv <- asks getBitcoinP2PEnv
    if (L.length $ headersList hdrs) == 0
        then liftIO $ print "Nothing to process!" >> throw EmptyHeadersMessage
        else liftIO $ print $ "Processing Headers with " ++ show (L.length $ headersList hdrs) ++ " entries."
    case validateChainedBlockHeaders hdrs of
        True -> do
            let net = bncNet $ bitcoinNodeConfig bp2pEnv
                genesisHash = blockHashToHex $ headerHash $ getGenesisHeader net
                conn = keyValDB $ dbHandles dbe'
                headPrevHash = (blockHashToHex $ prevBlock $ fst $ head $ headersList hdrs)
            bb <- liftIO $ fetchBestBlock conn net
            if (blockHashToHex $ fst bb) == genesisHash
                then liftIO $ print ("First Headers set from genesis")
                else if (blockHashToHex $ fst bb) == headPrevHash
                         then liftIO $ print ("Links okay!")
                         else liftIO $ print ("Does not match DB best-block") >> throw BlockHashNotFoundInDB -- likely a previously sync'd block
            let indexed = zip [((snd bb) + 1) ..] (headersList hdrs)
                str1 = "insert INTO xoken.blocks_hash (blockhash, header, height, transactions) values (?, ? , ? , ?)"
                qstr1 = str1 :: Q.QueryString Q.W (Text, Text, Int32, Maybe Text) ()
                str2 = "insert INTO xoken.blocks_height (height, blockhash, header, transactions) values (?, ? , ? , ?)"
                qstr2 = str2 :: Q.QueryString Q.W (Int32, Text, Text, Maybe Text) ()
            liftIO $ print ("indexed " ++ show (L.length indexed))
            mapM_
                (\y -> do
                     let hdrHash = blockHashToHex $ headerHash $ fst $ snd y
                         hdrJson = T.pack $ LC.unpack $ A.encode $ fst $ snd y
                         par1 = Q.defQueryParams Q.One (hdrHash, hdrJson, fst y, Nothing)
                         par2 = Q.defQueryParams Q.One (fst y, hdrHash, hdrJson, Nothing)
                     res1 <- liftIO $ try $ Q.runClient conn (Q.write (Q.prepared qstr1) par1)
                     case res1 of
                         Right () -> return ()
                         Left (e :: SomeException) ->
                             liftIO $
                             print ("Error: INSERT into 'blocks_hash' failed: " ++ show e) >>=
                             throw KeyValueDBInsertException
                     res2 <- liftIO $ try $ Q.runClient conn (Q.write (Q.prepared qstr2) par2)
                     case res2 of
                         Right () -> return ()
                         Left (e :: SomeException) ->
                             liftIO $
                             print ("Error: INSERT into 'blocks_height' failed: " ++ show e) >>=
                             throw KeyValueDBInsertException)
                indexed
            liftIO $ print ("done..")
            liftIO $ do
                markBestBlock (blockHashToHex $ headerHash $ fst $ snd $ last $ indexed) (fst $ last indexed) conn
                putMVar (bestBlockUpdated bp2pEnv) True
            return ()
        False -> liftIO $ print ("Error: BlocksNotChainedException") >> throw BlocksNotChainedException
    return ()

messageHandler :: (HasService env m) => (Maybe Message) -> m (MessageCommand)
messageHandler mm = do
    bp2pEnv <- asks getBitcoinP2PEnv
    case mm of
        Just msg -> do
            case (msg) of
                MHeaders hdrs -> do
                    liftIO $ takeMVar (headersWriteLock bp2pEnv)
                    res <- LE.try $ processHeaders hdrs
                    case res of
                        Right () -> return ()
                        Left BlockHashNotFoundInDB -> return ()
                        Left EmptyHeadersMessage -> return ()
                        Left e -> liftIO $ print ("[ERROR] Unhandled exception!" ++ show e) >> throw e
                    liftIO $ putMVar (headersWriteLock bp2pEnv) True
                    return $ msgType msg
                MInv inv -> do
                    let lst = invList inv
                    mapM_
                        (\x ->
                             if (invType x) == InvBlock
                                 then do
                                     liftIO $ print ("Unsolicited INV, a new Block: " ++ (show $ invHash x))
                                     liftIO $ putMVar (bestBlockUpdated bp2pEnv) True -- will trigger a GetHeaders to peers
                                 else return ())
                        lst
                    return $ msgType msg
                MTx tx -> do
                    return $ msgType msg
                _ -> do
                    return $ msgType msg
        Nothing -> do
            liftIO $ print "Error, invalid message"
            throw InvalidMessageType

readNextMessage' :: (HasService env m) => Network -> Socket -> m (Maybe Message)
readNextMessage' net sock = liftIO $ readNextMessage net sock

logMessage :: (HasService env m) => MessageCommand -> m ()
logMessage mg = do
    liftIO $ print ("processed: " ++ show mg)
    return ()

initPeerListeners :: (HasService env m) => m ()
initPeerListeners = do
    bp2pEnv <- asks getBitcoinP2PEnv
    let net = bncNet $ bitcoinNodeConfig bp2pEnv
    allpr <- liftIO $ readTVarIO (bitcoinPeers bp2pEnv)
    let conpr = L.filter (\x -> bpConnected (snd x)) (M.toList allpr)
    mapM_ (\pr -> LA.async $ handleIncomingMessages $ snd pr) conpr
    return ()

handleIncomingMessages :: (HasService env m) => BitcoinPeer -> m ()
handleIncomingMessages pr = do
    bp2pEnv <- asks getBitcoinP2PEnv
    let net = bncNet $ bitcoinNodeConfig bp2pEnv
    case (bpSocket pr) of
        Just s -> do
            liftIO $ print ("reading from:  " ++ show (bpAddress pr))
            res <-
                LE.try $ runStream $ S.repeatM (readNextMessage' net s) & S.mapM (messageHandler) & S.mapM (logMessage)
            case res of
                Right () -> return ()
                Left (e :: SomeException) -> liftIO $ print ("[ERROR] handleIncomingMessages " ++ show e)
        Nothing -> undefined
    return ()