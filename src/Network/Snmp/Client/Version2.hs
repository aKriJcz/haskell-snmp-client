module Network.Snmp.Client.Version2
( clientV1
, clientV2
)
where

import Network.Socket hiding (recv, socket, close)
import qualified Network.Socket as NS
import Network.Socket.ByteString.Lazy (recv, sendAll)
import Control.Applicative ((<$>))
import Control.Concurrent.Async
import Data.IORef (IORef, newIORef)
import Control.Concurrent (threadDelay)
import Control.Exception
import Control.Monad (when)
import Data.Monoid ((<>), mconcat, mempty)
import Data.Binary hiding (get)
import Data.Int (Int32)

import Network.Protocol.Snmp hiding (rid)
import Network.Snmp.Client.Internal
import Network.Snmp.Client.Types hiding (timeout, community, hostname, port)

v1 :: Packet
v1 = initial Version1

v2 :: Packet
v2 = initial Version2


receiveAndFilterRid :: Socket -> RequestId -> IO Packet
receiveAndFilterRid socket rid = do
    packet <- decode <$> recv socket 1500 :: IO Packet
    if rid == getRid packet
       then return packet
       else receiveAndFilterRid socket rid

processRequest :: IORef Int32 -> Socket -> (Int32 -> Packet) -> Int -> IO Suite
processRequest ioref socket requestMakeFunc timeout = do
    rid <- succCounter ioref
    sendAll socket $ encode $ requestMakeFunc rid
    result <- race (threadDelay timeout) (receiveAndFilterRid socket rid)
    case result of
         Right packet -> do
             when (getErrorStatus packet /= 0) $ throwIO $ ServerException $ getErrorStatus packet
             return $ getSuite packet
         Left _ -> throwIO TimeoutException

setRCS :: Community -> OIDS -> Packet -> Packet
setRCS c o = setCommunityP c . setSuite (Suite $ map (`Coupla` Zero) o)

clientV1 :: Hostname -> Port -> Int -> Int -> Community -> IO Client
clientV1 = clientV12 v1

clientV2 :: Hostname -> Port -> Int -> Int -> Community -> IO Client
clientV2 = clientV12 v2

clientV12 :: Packet -> Hostname -> Port -> Int -> Int -> Community -> IO Client
clientV12 packet hostname port timeout retryCount community = do
    socket <- makeSocket hostname port
    uniqInteger <- uniqID
    ref <- newIORef uniqInteger
    let
        processRequest' = processRequest ref socket
        req oids = setRCS community oids packet
        get' oids = withSocketsDo $ do
            let packet' = req oids
                version = getVersion packet'
                makeRequest rid = setRequest (GetRequest rid 0 0) packet'
            case version of
                 Version2 -> processRequest' makeRequest timeout
                 Version1 -> catch (processRequest' makeRequest timeout) (fixErrorV1Get oids)
                 Version3 -> error "imposible"
        fixErrorV1Get oids (ServerException 2) = return $ Suite $ map (`Coupla` NoSuchObject) oids
        fixErrorV1Get _ e = throwIO e

        bulkget' oids = withSocketsDo $ do
            let makeRequest rid = setRequest (GetBulk rid 0 10) (req oids)
            processRequest' makeRequest timeout

        getnext' oids = withSocketsDo $ do
            let packet' = req oids
                version = getVersion packet'
                makeRequest rid = setRequest (GetNextRequest rid 0 0) packet'
            case version of
                 Version2 -> processRequest' makeRequest timeout
                 Version1 -> catch (processRequest' makeRequest timeout) (fixErrorV1GetNext oids)
                 Version3 -> error "imposible"
        fixErrorV1GetNext oids (ServerException 2) = return $ Suite $ map (`Coupla` EndOfMibView) oids
        fixErrorV1GetNext _ e = throwIO e

        walk' oids base accumulator
            | oids == base = do
                first <- get' [oids]
                next <- getnext' [oids]
                case (first, next) of
                     (Suite [Coupla _ NoSuchObject], Suite [Coupla nextOid _]) -> walk' nextOid base next
                     (Suite [Coupla _ NoSuchInstance], Suite [Coupla nextOid _]) -> walk' nextOid base next
                     (Suite [Coupla _ EndOfMibView], _) -> return accumulator
                     (_, Suite [Coupla nextOid _]) -> walk' nextOid base first
                     (_, _) -> throwIO $ ServerException 5
            | otherwise = do
                nextData <- getnext' [oids]
                let Suite [Coupla next v] = nextData
                case (isUpLevel next base, v) of
                     (True, _) -> return accumulator
                     (_, NoSuchObject) -> walk' next base accumulator
                     (_, NoSuchInstance) -> walk' next base accumulator
                     (_, EndOfMibView) -> return accumulator
                     (_, _) -> walk' next base (accumulator <> nextData)

        bulkwalk' oids base accumulator = do
               first <- bulkget' [oids]
               let Coupla next snmpData = lastS first
                   filtered (Suite xs) = Suite $ filter (\(Coupla x _) -> not $ isUpLevel x base) xs
               case (isUpLevel next base , snmpData) of
                    (_, EndOfMibView) -> return $ accumulator <> filtered first
                    (False, _) -> bulkwalk' next base (accumulator <> first)
                    (True, _) -> return $ accumulator <> filtered first
        set' oids = withSocketsDo $ do
            let makeRequest rid = setRequest (SetRequest rid 0 0) . setCommunityP community . setSuite oids $ packet
            processRequest' makeRequest timeout

    return Client
        { get = get'
        , bulkget = bulkget'
        , getnext = getnext'
        , walk = \oids -> mconcat <$> mapM (\oi -> walk' oi oi mempty) oids
        , bulkwalk = \oids -> mconcat <$> mapM (\oi -> bulkwalk' oi oi mempty) oids
        , set = set'
        , close = NS.close socket
        }

