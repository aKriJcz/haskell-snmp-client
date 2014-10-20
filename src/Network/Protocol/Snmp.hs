{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE CPP #-}
{-# LANGUAGE FlexibleInstances #-}
module Network.Protocol.Snmp (
-- * snmp types
  Value(..)
, OID
, OIDS
-- * top level types
, V2
, V3
, Version(..)
, Packet
-- ** header
, Header 
-- *** header snmpV2
, Community(..)
-- *** header snmpV3
, ID(..)
, MaxSize(..)
, Flag(..)
, SecurityModel(..)
, SecurityParameter(..)
, Reportable
, PrivAuth(..)
, EngineBootId
, PrivacyParameter
, EngineTime
, EngineId
-- ** PDU
, PDU (CryptedPDU)
-- *** PDU universal
, Request(..)
, RequestId
, ErrorStatus
, ErrorIndex
, Suite(..)
, Coupla(..)
-- *** PDU snmpV3
, ContextEngineID(..)
, ContextName(..)
-- * pack, unpack Packet
, Pack(..)
-- * some classes and helpers 
-- *** universal, for work with both versions
, HasItem(..)
-- *** v2 only, for work with Header V2
, HasV2(..)
-- *** v3 only, for work with Header V3, PDU V3
, HasV3(..)
-- *** create new Packet
, Construct(..)
-- ** helpers for work with Packet
-- *** universal
, getVersion
, getRequest
, setRequest
, getRid
, setRid
, getSuite
, setSuite
, getErrorStatus
, setErrorStatus
-- *** v2 only
, setCommunityP
-- *** v3 only
, setIDP
, setMaxSizeP
, setUserNameP
, getAuthenticationParametersP
, setAuthenticationParametersP
, setReportableP
, setPrivAuthP
, getEngineIdP
, setEngineIdP
, getEngineBootsP
, setEngineBootsP
, getEngineTimeP
, setEngineTimeP
, getPrivParametersP
, setPrivParametersP
-- * authentication
, passwordToKey
, signPacket
, AuthType(..)
, PrivType(..)
, Password
, Key
, cleanPass
-- * priv
, Salt
, Raw
, Encrypted
, Rand32
, Rand64
, desEncrypt
, desDecrypt
, aesEncrypt
, aesDecrypt
, toSalt
-- * exceptions
, ClientException(..) 
-- * usage example
-- $example
)
where

import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as BL
import Data.Word (Word8, Word32, Word64)
#if MIN_VERSION_base(4,7,0)
import Data.Bits (testBit, complement, shiftL, (.|.), (.&.), setBit, shiftR, zeroBits, xor, clearBit)
#else
import Data.Bits (testBit, complement, shiftL, (.|.), (.&.), setBit, shiftR, xor, clearBit)
#endif
import Data.ASN1.Types (ASN1Object(..), ASN1(..), OID, ASN1ConstructionType(..), ASN1Class(..))
import Data.ASN1.Parse (getNext, getObject, runParseASN1, runParseASN1State, ParseASN1, getNextContainer, onNextContainer, getMany)
import Data.ASN1.BinaryEncoding (DER(..))
import Data.ASN1.Encoding (encodeASN1', decodeASN1')
import Control.Applicative ((<$>), (<*>), (*>), (<*))
import Data.Monoid (Monoid, (<>))
import Control.Exception (Exception, throw)
import Data.Typeable (Typeable)
import qualified Crypto.Hash.MD5 as Md5
import qualified Crypto.Hash.SHA1 as Sha
import qualified Crypto.MAC.HMAC as HMAC
import qualified Crypto.Cipher.Types as Priv
import qualified Crypto.Cipher.DES as Priv
import qualified Crypto.Cipher.AES as Priv
import Data.Int

-- $example
--
-- Here example for snmpV2 
--
-- @
-- import Network.Protocol.Snmp
-- import Control.Applicative
-- import Network.Socket.ByteString (recv, sendAll)
-- import Network.Socket hiding (recv, sendAll)
--
-- -- create new empty packet
-- v2 :: Packet
-- v2 = initial Version2
-- 
-- community = Community "hello"
--
-- oi = Coupla [1,3,6,1,2,1,1,4,0] Zero
--
-- -- set community, oid
-- packet :: Community -> Coupla -> Packet
-- packet community oi = 
--   setCommunityP community . setSuite (Suite [oi]) $ v2
-- 
-- -- here must be code for create udp socket
-- makeSocket :: Hostname -> Port -> IO Socket
-- makeSocket = undefined
--
-- main :: IO ()
-- main = do
--    socket <- makeSocket "localhost" "161"
--    sendAll socket $ encode $ setRequest (GetRequest 1 0 0) packet
--    result <- decode <$\> recv socket 1500 :: IO Packet
--    print $ getSuite result 
-- 
-- @
-- 

-----------------------------------------------------------------------------------------------------------------

fI :: (Num b, Integral a) => a -> b
fI = fromIntegral

#if MIN_VERSION_base(4,7,0)
#else
zeroBits :: a
zeroBits = clearBit (bit 0) 0
  where
  bit :: (Bits a, Num a) => Int -> a
  bit i = 1 `shiftL` i
#endif

-- | Phantom type for version 2 (Header V2, PDU V2)
data V2
-- | Phantom type for version 3 (Header V3, PDU V3)
data V3

-- | Snmp version tag
data Version = Version1
             | Version2 
             | Version3
             deriving (Eq, Show)

type OIDS = [OID]

-- | Top level type, which describe snmp packet
data Packet where
  V2Packet :: Version -> Header V2 -> PDU V2 -> Packet
  V3Packet :: Version -> Header V3 -> PDU V3 -> Packet

deriving instance Show Packet 
deriving instance Eq Packet 

-- | Snmp header without version tag
data Header a where
  V2Header :: Community -> Header V2
  V3Header :: ID -> MaxSize -> Flag -> SecurityModel -> SecurityParameter -> Header V3

deriving instance Show (Header a)
deriving instance Eq (Header a)

-- | Snmp body
data PDU a where
  PDU :: Request -> Suite -> PDU V2
  ScopedPDU :: ContextEngineID -> ContextName -> PDU V2 -> PDU V3
  CryptedPDU :: ByteString -> PDU V3

deriving instance Show (PDU a)
deriving instance Eq (PDU a)

-- | Snmp data types
data Value = OI OID
           | Zero
           | Integer Int32
           | String ByteString
           | IpAddress Word8 Word8 Word8 Word8
           | Counter32 Word32
           | Gaude32 Word32
           | TimeTicks Word32
           | Opaque ByteString
           | Counter64 Word64
           | ZeroDotZero
           | NoSuchInstance
           | NoSuchObject
           | EndOfMibView
           deriving (Show, Eq)

-- | Request id 
type RequestId = Int32

-- | Error status 
type ErrorStatus = Integer

-- | Error index 
type ErrorIndex = Integer

-- | requests
data Request = GetRequest     { rid :: RequestId, es :: ErrorStatus, ei :: ErrorIndex }
             | GetNextRequest { rid :: RequestId, es :: ErrorStatus, ei :: ErrorIndex }
             | GetResponse    { rid :: RequestId, es :: ErrorStatus, ei :: ErrorIndex }
             | SetRequest     { rid :: RequestId, es :: ErrorStatus, ei :: ErrorIndex }
             | GetBulk        { rid :: RequestId, es :: ErrorStatus, ei :: ErrorIndex }
             | Inform         { rid :: RequestId, es :: ErrorStatus, ei :: ErrorIndex }
             | V2Trap         { rid :: RequestId, es :: ErrorStatus, ei :: ErrorIndex }
             | Report         { rid :: RequestId, es :: ErrorStatus, ei :: ErrorIndex }
             deriving (Show, Eq)

-- | Coupla oid -> value
data Coupla = Coupla { oid :: OID, value :: Value } deriving (Eq)

-- | Variable bindings
newtype Suite = Suite [Coupla] deriving (Eq, Monoid)

-- ** Types describing header

-- | (snmp2 only) Community for 2(1) version
newtype Community = Community ByteString deriving (Show, Eq)

-- | (snmp3 only) Message Identifier (like RequestId in PDU)
newtype ID = ID Int32 deriving (Show, Eq)

-- | (snmp3 only) Message max size must be > 484
newtype MaxSize = MaxSize Integer deriving (Show, Eq)

-- | (snmp3 only) rfc3412, type for create message flag
data PrivAuth = NoAuthNoPriv | AuthNoPriv | AuthPriv deriving (Show, Eq)

-- | (snmp3 only) rfc3412, as PrivAuth
type Reportable = Bool

-- | (snmp3 only) rfc3412, message flag
data Flag = Flag Reportable PrivAuth  deriving (Show, Eq)

-- | (snmp3 only) rfc3412, security model
data SecurityModel = UserBasedSecurityModel deriving (Show, Eq)

-- | (snmp3 only) rfc3412, security parameter
data SecurityParameter = SecurityParameter 
  { authoritiveEngineId :: ByteString
  , authoritiveEngineBoots :: Int32
  , authoritiveEngineTime :: Int32
  , userName :: ByteString
  , authenticationParameters :: ByteString
  , privacyParameters :: ByteString
  }
  deriving (Eq)

-- | (snmp3 only) rfc3412, types for ScopedPDU
newtype ContextEngineID = ContextEngineID ByteString deriving (Show, Eq)
newtype ContextName = ContextName ByteString deriving (Show, Eq)

-- | some exception
data ClientException = TimeoutException 
                     | ServerException Integer
                     deriving (Typeable, Eq)

-- | class for make binary packet from [ASN1] 
class Pack a where
    encode :: a -> ByteString
    decode :: ByteString -> a

-- | some universal getters, setters
class HasItem a where
    getHeader :: Packet -> Header a
    setHeader :: Header a -> Packet -> Packet
    getPDU :: Packet -> PDU a
    setPDU :: PDU a -> Packet -> Packet

-- | (snmp2 only) getters, setters for work with Header V2
class HasV2 a where
    getCommunity :: Header a -> Community
    setCommunity :: Community -> Header a -> Header a

-- | (snmp3 only) getters, setters for work with Header V3 and PDU V3.
class HasV3 a where
    getID :: Header a -> ID
    getMaxSize :: Header a -> MaxSize
    getFlag :: Header a -> Flag
    getSecurityModel :: Header a -> SecurityModel
    getSecurityParameter :: Header a -> SecurityParameter
    getAuthoritiveEngineId :: Header a -> ByteString
    getAuthoritiveEngineBoots :: Header a -> Int32
    getAuthoritiveEngineTime :: Header a -> Int32
    getUserName :: Header a -> ByteString
    getAuthenticationParameters :: Header a -> ByteString
    getPrivacyParameters :: Header a -> ByteString
    getContextEngineID :: PDU a -> ContextEngineID
    getContextName :: PDU a -> ContextName
    setID :: ID -> Header a -> Header a
    setMaxSize :: MaxSize -> Header a -> Header a
    setFlag :: Flag -> Header a -> Header a
    setSecurityModel :: SecurityModel -> Header a -> Header a
    setSecurityParameter :: SecurityParameter -> Header a -> Header a
    setAuthoritiveEngineId :: ByteString -> Header a -> Header a
    setAuthoritiveEngineBoots :: Int32 -> Header a -> Header a
    setAuthoritiveEngineTime :: Int32 -> Header a -> Header a
    setUserName :: ByteString -> Header a -> Header a
    setAuthenticationParameters :: ByteString -> Header a -> Header a
    setPrivacyParameters :: ByteString -> Header a -> Header a
    setContextEngineID :: ContextEngineID -> PDU a -> PDU a
    setContextName :: ContextName -> PDU a -> PDU a

-- | initial new object, like mempty for monoid
class Construct a where
    initial :: a

----------------------------------------------------------------------------------------
instance Construct (Version -> Packet) where
    initial Version3 = V3Packet Version3 initial initial
    initial Version2 = V2Packet Version2 initial initial
    initial Version1 = error "not inplemented"

instance Construct (Header V3) where
    initial = V3Header (ID 0) (MaxSize 65007) (Flag False NoAuthNoPriv) UserBasedSecurityModel initial

instance Construct (Header V2) where
    initial = V2Header (Community "")

instance Construct (PDU V3) where
    initial = ScopedPDU (ContextEngineID "") (ContextName "") initial

instance Construct (PDU V2) where
    initial = PDU initial initial

instance Construct SecurityParameter where
    initial = SecurityParameter "" 0 0 "" "" ""

instance Construct Suite where
    initial = Suite []

instance Construct Request where
     initial = GetRequest 0 0 0
----------------------------------------------------------------------------------------
instance HasItem V2 where
    getHeader (V2Packet _ x _) = x
    getHeader _ = undefined
    setHeader h (V2Packet v _ x) = V2Packet v h x
    setHeader _ _ = undefined
    getPDU (V2Packet _ _ x) = x
    getPDU _ = undefined
    setPDU p (V2Packet v h _) = V2Packet v h p
    setPDU _ _ = undefined

instance HasItem V3 where
    getHeader (V3Packet _ x _) = x
    getHeader _ = undefined
    setHeader h (V3Packet v _ x) = V3Packet v h x
    setHeader _ _ = undefined
    getPDU (V3Packet _ _ x) = x
    getPDU _ = undefined
    setPDU p (V3Packet v h _) = V3Packet v h p
    setPDU _ _ = undefined

instance HasV2 V2 where
    getCommunity (V2Header c) = c
    setCommunity c (V2Header _) = V2Header c

instance HasV3 V3 where
    getID (V3Header i _ _ _ _) = i
    getMaxSize (V3Header _ i _ _ _) = i
    getFlag (V3Header _ _ i _ _) = i
    getSecurityModel (V3Header _ _ _ i _) = i
    getSecurityParameter (V3Header _ _ _ _ i) = i
    getAuthoritiveEngineId = authoritiveEngineId . getSecurityParameter
    getAuthoritiveEngineBoots = authoritiveEngineBoots . getSecurityParameter
    getAuthoritiveEngineTime = authoritiveEngineTime . getSecurityParameter
    getUserName = userName . getSecurityParameter
    getAuthenticationParameters = authenticationParameters . getSecurityParameter
    getPrivacyParameters = privacyParameters . getSecurityParameter
    getContextEngineID (ScopedPDU i _ _) = i
    getContextEngineID _ = undefined
    getContextName (ScopedPDU _ i _) = i
    getContextName _ = undefined
    setID i (V3Header _ a b c d) = V3Header i a b c d
    setMaxSize i (V3Header a _ b c d) = V3Header a i b c d
    setFlag i (V3Header a b _ c d) = V3Header a b i c d
    setSecurityModel i (V3Header a b c _ d) = V3Header a b c i d
    setSecurityParameter i (V3Header a b c d _) = V3Header a b c d i
    setAuthoritiveEngineId      i (V3Header a b c d f) = V3Header a b c d (f { authoritiveEngineId = i })
    setAuthoritiveEngineBoots   i (V3Header a b c d f) = V3Header a b c d (f { authoritiveEngineBoots = i })
    setAuthoritiveEngineTime    i (V3Header a b c d f) = V3Header a b c d (f { authoritiveEngineTime = i })
    setUserName                 i (V3Header a b c d f) = V3Header a b c d (f { userName = i })
    setAuthenticationParameters i (V3Header a b c d f) = V3Header a b c d (f { authenticationParameters = i })
    setPrivacyParameters        i (V3Header a b c d f) = V3Header a b c d (f { privacyParameters = i })
    setContextEngineID i (ScopedPDU _ b c) = ScopedPDU i b c
    setContextEngineID _ _ = undefined
    setContextName i (ScopedPDU a _ b) = ScopedPDU a i b 
    setContextName _ _ = undefined

----------------------------------------------------------------------------------------
setIDP :: ID -> Packet -> Packet 
setIDP x p = 
  let header = getHeader p :: Header V3
      newHeader = setID x header
  in setHeader newHeader p

setMaxSizeP :: MaxSize -> Packet -> Packet 
setMaxSizeP x p = 
  let header = getHeader p :: Header V3
      newHeader = setMaxSize x header
  in setHeader newHeader p 

setCommunityP :: Community -> Packet -> Packet 
setCommunityP x p = 
  let header = getHeader p :: Header V2
      newHeader = setCommunity x header
  in setHeader newHeader p

getEngineIdP :: Packet -> EngineId
getEngineIdP p = 
  let header = getHeader p :: Header V3
  in getAuthoritiveEngineId header

setEngineIdP :: EngineId -> Packet -> Packet
setEngineIdP x p =
  let header = getHeader p :: Header V3
      newHeader = setAuthoritiveEngineId x header
  in setHeader newHeader p

getEngineBootsP :: Packet -> EngineBootId
getEngineBootsP p = 
  let header = getHeader p :: Header V3
  in getAuthoritiveEngineBoots header

setEngineBootsP :: EngineBootId -> Packet -> Packet
setEngineBootsP x p =
  let header = getHeader p :: Header V3
      newHeader = setAuthoritiveEngineBoots x header
  in setHeader newHeader p
  
getEngineTimeP :: Packet -> Int32
getEngineTimeP p = 
  let header = getHeader p :: Header V3
  in getAuthoritiveEngineTime header

setEngineTimeP :: Int32 -> Packet -> Packet
setEngineTimeP x p =
  let header = getHeader p :: Header V3
      newHeader = setAuthoritiveEngineTime x header
  in setHeader newHeader p

setReportableP :: Reportable -> Packet -> Packet
setReportableP r p = 
  let header = getHeader p :: Header V3
      Flag _ a = getFlag header
      newHeader = setFlag (Flag r a) header
  in setHeader newHeader p

setPrivAuthP :: PrivAuth -> Packet -> Packet
setPrivAuthP x p = 
  let header = getHeader p :: Header V3
      Flag r _ = getFlag header
      newHeader = setFlag (Flag r x) header
  in setHeader newHeader p

setUserNameP :: ByteString -> Packet -> Packet 
setUserNameP x p = 
  let header = getHeader p :: Header V3
      sp = getSecurityParameter header
      newHeader = setSecurityParameter (sp { userName = x }) header
  in setHeader newHeader p

setAuthenticationParametersP :: ByteString -> Packet -> Packet 
setAuthenticationParametersP x p = 
  let header = getHeader p :: Header V3
      sp = getSecurityParameter header
      newHeader = setSecurityParameter (sp { authenticationParameters = x }) header
  in setHeader newHeader p
  
getAuthenticationParametersP :: Packet -> ByteString
getAuthenticationParametersP p = 
  let header = getHeader p :: Header V3
  in authenticationParameters (getSecurityParameter header)

setPrivParametersP :: ByteString -> Packet -> Packet 
setPrivParametersP x p = 
  let header = getHeader p :: Header V3
      sp = getSecurityParameter header
      newHeader = setSecurityParameter (sp { privacyParameters = x }) header
  in setHeader newHeader p

getPrivParametersP :: Packet -> ByteString
getPrivParametersP p =
  let header = getHeader p :: Header V3
  in privacyParameters $ getSecurityParameter header


getVersion :: Packet -> Version
getVersion (V2Packet v _ _) = v
getVersion (V3Packet v _ _) = v

getRid :: Packet -> RequestId 
getRid (V2Packet _ _ (PDU r _)) = rid r 
getRid (V3Packet _ _ (ScopedPDU _ _ (PDU r _))) = rid r 
getRid _ = undefined

setRid :: RequestId -> Packet -> Packet
setRid r (V2Packet v h (PDU req s)) = V2Packet v h (PDU req { rid = r } s)
setRid r (V3Packet v h (ScopedPDU a b (PDU req s))) = V3Packet v h (ScopedPDU a b (PDU req { rid = r } s))
setRid _ _ = undefined

getErrorStatus :: Packet -> ErrorStatus 
getErrorStatus (V2Packet _ _ (PDU r _)) = es r 
getErrorStatus (V3Packet _ _ (ScopedPDU _ _ (PDU r _))) = es r 
getErrorStatus _ = undefined

setErrorStatus :: ErrorStatus -> Packet -> Packet
setErrorStatus e (V2Packet v h (PDU req s)) = V2Packet v h (PDU req { es = e } s)
setErrorStatus e (V3Packet v h (ScopedPDU a b (PDU req s))) = V3Packet v h (ScopedPDU a b (PDU req { es = e } s))
setErrorStatus _ _ = undefined

getSuite :: Packet -> Suite
getSuite (V2Packet _ _ (PDU _ r)) = r 
getSuite (V3Packet _ _ (ScopedPDU _ _ (PDU _ r))) = r 
getSuite _ = undefined

setSuite :: Suite -> Packet -> Packet
setSuite s (V2Packet v h (PDU req _)) = V2Packet v h (PDU req s)
setSuite s (V3Packet v h (ScopedPDU a b (PDU req _))) = V3Packet v h (ScopedPDU a b (PDU req s))
setSuite _ _ = undefined

getRequest :: Packet -> Request
getRequest (V2Packet _ _ (PDU r _)) = r 
getRequest (V3Packet _ _ (ScopedPDU _ _ (PDU r _))) = r 
getRequest _ = undefined

setRequest :: Request -> Packet -> Packet
setRequest req (V2Packet v h (PDU _ s)) = V2Packet v h (PDU req s)
setRequest req (V3Packet v h (ScopedPDU a b (PDU _ s))) = V3Packet v h (ScopedPDU a b (PDU req s))
setRequest _ _ = undefined
----------------------------------------------------------------------------------------

instance ASN1Object (Header V2) where
    toASN1 (V2Header c) = toASN1 c 
    fromASN1 asn = flip runParseASN1State asn $ V2Header <$> getObject

sS :: ParseASN1 ()
sS = do
    Start Sequence <- getNext
    return ()

eS :: ParseASN1 ()
eS = do
    End Sequence <- getNext
    return ()

instance ASN1Object (Header V3) where
    toASN1 (V3Header i ms f sm sp) xs = 
        Start Sequence : toASN1 i (toASN1 ms (toASN1 f (toASN1 sm [End Sequence]))) ++ toASN1 sp xs
    fromASN1 asn = flip runParseASN1State asn $
        V3Header <$> (sS *> getObject) <*> getObject <*> getObject <*> (getObject <* eS) <*> getObject

instance ASN1Object (PDU V2) where
    toASN1 (PDU (GetRequest rid _ _    ) sd) xs = (Start $ Container Context 0):IntVal (fromIntegral rid) : IntVal 0  : IntVal 0 : Start Sequence : toASN1 sd [] ++ [ End Sequence, End (Container Context 0)] ++ xs
    toASN1 (PDU (GetNextRequest rid _ _) sd) xs = (Start $ Container Context 1):IntVal (fromIntegral rid) : IntVal 0  : IntVal 0 : Start Sequence : toASN1 sd [] ++ [ End Sequence, End (Container Context 1)] ++ xs
    toASN1 (PDU (GetResponse rid es ei ) sd) xs = (Start $ Container Context 2):IntVal (fromIntegral rid) : IntVal es : IntVal ei: Start Sequence : toASN1 sd [] ++ [ End Sequence, End (Container Context 2)] ++ xs
    toASN1 (PDU (SetRequest rid _ _    ) sd) xs = (Start $ Container Context 3):IntVal (fromIntegral rid) : IntVal 0  : IntVal 0 : Start Sequence : toASN1 sd [] ++ [ End Sequence, End (Container Context 3)] ++ xs
    toASN1 (PDU (GetBulk rid es ei     ) sd) xs = (Start $ Container Context 5):IntVal (fromIntegral rid) : IntVal es : IntVal ei: Start Sequence : toASN1 sd [] ++ [ End Sequence, End (Container Context 4)] ++ xs
    toASN1 (PDU (Inform rid es ei     ) sd) xs = (Start $ Container Context 6):IntVal (fromIntegral rid) : IntVal es : IntVal ei: Start Sequence : toASN1 sd [] ++ [ End Sequence, End (Container Context 4)] ++ xs
    toASN1 (PDU (V2Trap rid es ei     ) sd) xs = (Start $ Container Context 7):IntVal (fromIntegral rid) : IntVal es : IntVal ei: Start Sequence : toASN1 sd [] ++ [ End Sequence, End (Container Context 4)] ++ xs
    toASN1 (PDU (Report rid es ei      ) sd) xs = (Start $ Container Context 8):IntVal (fromIntegral rid) : IntVal es : IntVal ei: Start Sequence : toASN1 sd [] ++ [ End Sequence, End (Container Context 8)] ++ xs
    fromASN1 asn = runParseASN1State pduParser asn 

pduParser :: ParseASN1 (PDU V2)
pduParser = do
    Start (Container Context n) <- getNext
    IntVal rid' <- getNext
    IntVal es <- getNext
    IntVal ei <- getNext
    x <- getNextContainer Sequence 
    End (Container Context _) <- getNext
    let psuite = fromASN1 x
        rid = fromIntegral rid'
    case (n, psuite) of
         (0, Right (suite, _)) -> return $ PDU (GetRequest     rid es ei) suite
         (1, Right (suite, _)) -> return $ PDU (GetNextRequest rid es ei) suite
         (2, Right (suite, _)) -> return $ PDU (GetResponse    rid es ei) suite
         (3, Right (suite, _)) -> return $ PDU (SetRequest     rid es ei) suite
         (5, Right (suite, _)) -> return $ PDU (GetBulk        rid es ei) suite
         (6, Right (suite, _)) -> return $ PDU (Inform         rid es ei) suite
         (7, Right (suite, _)) -> return $ PDU (V2Trap         rid es ei) suite
         (8, Right (suite, _)) -> return $ PDU (Report         rid es ei) suite
         _ -> throw $ ServerException 9

instance ASN1Object (PDU V3) where
    toASN1 (ScopedPDU (ContextEngineID x) (ContextName y) pdu) xs = 
      [Start Sequence, OctetString x, OctetString y] ++ toASN1 pdu (End Sequence :xs)
    toASN1 (CryptedPDU cryptedBody) xs = OctetString cryptedBody : xs
    fromASN1 asn = flip runParseASN1State asn $ do
        whatIs <- getNext
        case whatIs of
             Start Sequence -> do
                 OctetString x <- getNext
                 OctetString y <- getNext
                 p <- pduParser 
                 End Sequence <- getNext
                 return $ ScopedPDU (ContextEngineID x) (ContextName y) p
             OctetString x -> return $ CryptedPDU x
             _ -> throw $ ServerException 9

instance ASN1Object Version where
    toASN1 Version1 xs = IntVal 0 : xs
    toASN1 Version2 xs = IntVal 1 : xs
    toASN1 Version3 xs = IntVal 3 : xs
    fromASN1 asn = flip runParseASN1State asn $ do
        IntVal x <- getNext
        case x of 
             0 -> return Version1
             1 -> return Version2
             3 -> return Version3
             _ -> throw $ ServerException 10

instance ASN1Object Packet where
    toASN1 (V2Packet Version2 header body) _ = Start Sequence : toASN1 Version2 (toASN1 header (toASN1 body [End Sequence]))
    toASN1 (V3Packet Version3 header body) _ = Start Sequence : toASN1 Version3 (toASN1 header (toASN1 body [End Sequence]))
    toASN1 _ _ = throw $ ServerException 10
    fromASN1 asn = flip runParseASN1State asn $ onNextContainer Sequence $ do
        v <- getObject
        case v of
             Version2 -> V2Packet Version2 <$> getObject <*> getObject
             Version3 -> V3Packet Version3 <$> getObject <*> getObject
             _ -> throw $ ServerException 10

instance ASN1Object Value where
    toASN1 NoSuchObject xs = Other Context 0 "" : xs
    toASN1 NoSuchInstance xs = Other Context 1 "" : xs
    toASN1 EndOfMibView xs = Other Context 2 "" : xs
    toASN1 (OI x) xs = OID x : xs
    toASN1 Zero xs = Null : xs
    toASN1 ZeroDotZero xs = OID [0,0] : xs
    toASN1 (Integer x) xs = IntVal (fI x) : xs
    toASN1 (String x) xs = OctetString x : xs
    toASN1 (IpAddress a1 a2 a3 a4) xs = Other Application 0 (B.pack [a1, a2, a3, a4]) : xs
    toASN1 (Counter32 x) xs = Other Application 1 (packInteger (fI x)) : xs
    toASN1 (Gaude32 x) xs = Other Application 2 (packInteger (fI x)) : xs
    toASN1 (TimeTicks x) xs = Other Application 3 (packInteger (fI x)) : xs
    toASN1 (Opaque x) xs = Other Application 4 x : xs
    toASN1 (Counter64 x) xs = Other Application 6 (packInteger (fI x)) : xs
    fromASN1 asn = runParseASN1State (unp =<< getNext) asn
      where
      unp (Other Context 0 "") = return NoSuchObject
      unp (Other Context 1 "") = return NoSuchInstance
      unp (Other Context 2 "") = return EndOfMibView
      unp Null = return Zero
      unp (OID [0,0]) = return ZeroDotZero
      unp (IntVal x) = return $ Integer (fI x)
      unp (OctetString x) = return $ String x
      unp (Other Application 0 y) = let [a1, a2, a3, a4] = B.unpack y
                                    in return $ IpAddress a1 a2 a3 a4
      unp (Other Application 1 y) = case unpackInteger y of
                                         Right z -> return $ Counter32 (fI z)
                                         Left _ -> throw $ ServerException 9
      unp (Other Application 2 y) = case unpackInteger y of
                                         Right z -> return $ Gaude32 (fI z)
                                         Left _ -> throw $ ServerException 9
      unp (Other Application 3 y) = case unpackInteger y of
                                         Right z -> return $ TimeTicks (fI z)
                                         Left _ -> throw $ ServerException 9
      unp (Other Application 4 y) = return $ Opaque y
      unp (Other Application 6 y) = case unpackInteger y of
                                         Right z -> return $ Counter64 (fI z)
                                         Left _ -> throw $ ServerException 9
      unp (OID x) = return . OI $ x
      unp _ = throw $ ServerException 9

instance ASN1Object Community where
    toASN1 (Community x) xs = OctetString x : xs
    fromASN1 asn = flip runParseASN1State asn $ do
        OctetString x <- getNext
        return $ Community x

instance Show SecurityParameter where
    show msg = "SecurityParameter:\n\t\tAuthoritiveEngineId: " 
       ++ show (authoritiveEngineId msg )
       ++ "\n\t\tAuthoritiveEngineBoots: " ++ show (authoritiveEngineBoots msg )
       ++ "\n\t\tAuthoritiveEngineTime: " ++ show (authoritiveEngineTime msg )
       ++ "\n\t\tUserName: " ++ show (userName msg )
       ++ "\n\t\tAuthenticationParameters: " ++ show (authenticationParameters msg )
       ++ "\n\t\tPrivacyParameters: " ++ show (privacyParameters msg )

instance ASN1Object ID where
    toASN1 (ID x) xs = IntVal (fromIntegral x) : xs
    fromASN1 asn = flip runParseASN1State asn $ do
        IntVal x <- getNext
        return $ ID (fromIntegral x)

instance ASN1Object MaxSize where
    toASN1 (MaxSize x) xs = IntVal x : xs
    fromASN1 asn = flip runParseASN1State asn $ do
        IntVal x <- getNext
        return $ MaxSize x

instance ASN1Object Flag where
    toASN1 (Flag r pa) xs = let zero = zeroBits :: Word8
                                reportable = if r then setBit zero 0 else zero
                                privauth = case pa of
                                                NoAuthNoPriv -> zero
                                                AuthNoPriv -> setBit zero 2
                                                AuthPriv -> setBit zero 1 .|. setBit zero 2
                                flag = reportable .|. privauth
                            in OctetString (B.pack [flag]) : xs
    fromASN1 asn = flip runParseASN1State asn $ do
        OctetString x <- getNext
        let [w] = B.unpack x
        return $ case (testBit w 0, testBit w 1) of
                      (True, True) -> Flag (testBit w 2) AuthPriv
                      (False, False) -> Flag (testBit w 2) NoAuthNoPriv
                      (True, False) -> Flag (testBit w 2) AuthNoPriv
                      _ -> throw $ ServerException 10


instance ASN1Object SecurityModel where
    toASN1 UserBasedSecurityModel xs = IntVal 3 : xs
    fromASN1 asn = flip runParseASN1State asn $ do
        IntVal x <- getNext
        case x of
             3 -> return UserBasedSecurityModel
             _ -> throw $ ServerException 7

instance ASN1Object SecurityParameter where
    toASN1 SecurityParameter{..} xs = OctetString (encodeASN1' DER
      [ Start Sequence
      ,   OctetString authoritiveEngineId 
      ,   IntVal $ fromIntegral authoritiveEngineBoots 
      ,   IntVal $ fromIntegral authoritiveEngineTime 
      ,   OctetString userName 
      ,   OctetString authenticationParameters 
      ,   OctetString privacyParameters 
      , End Sequence
      ]) : xs
    fromASN1 asn = flip runParseASN1State asn $ do
        OctetString packed <- getNext
        let r = case decodeASN1' DER packed of
             Left _ -> throw $ ServerException 9
             Right asn' -> parseMsgSecurityParameter asn'
        case r of
             Left _ -> throw $ ServerException 9
             Right r' -> return r'

parseMsgSecurityParameter :: [ASN1] -> Either String SecurityParameter
parseMsgSecurityParameter asn = flip runParseASN1 asn $ do
     Start Sequence <- getNext
     OctetString msgAuthoritiveEngineId <- getNext
     IntVal msgAuthoritiveEngineBoots <- getNext
     IntVal msgAuthoritiveEngineTime <- getNext
     OctetString msgUserName <- getNext
     OctetString msgAuthenticationParameters <- getNext
     OctetString msgPrivacyParameters <- getNext
     End Sequence <- getNext
     return $ SecurityParameter msgAuthoritiveEngineId (fromIntegral msgAuthoritiveEngineBoots) (fromIntegral msgAuthoritiveEngineTime) msgUserName msgAuthenticationParameters msgPrivacyParameters 

instance Pack (PDU V3) where
    encode s = encodeASN1' DER $ toASN1 s []
    decode = toP

toP :: ByteString -> PDU V3
toP bs = let a = fromASN1 <$> decodeASN1' DER bs
         in case a of
                 Right (Right (r, _)) -> r
                 _ -> throw $ ServerException 9

instance Pack Packet where
    encode s = encodeASN1' DER $ toASN1 s []
    decode = toB 

toB :: ByteString -> Packet 
toB bs = let a = fromASN1 <$> decodeASN1' DER bs
         in case a of
                 Right (Right (r, _)) -> r
                 _ -> throw $ ServerException 9
                 --}
                 --
instance Show Coupla where
    show (Coupla o v) = oidToString o ++ " = " ++ show v

instance Show Suite where
    show (Suite xs) = unlines $ map show xs

oidToString :: OID -> String
oidToString xs = foldr1 (\x y -> x ++ "." ++ y) $ map show xs

instance ASN1Object Suite where
    toASN1 (Suite xs) ys = foldr toA [] xs ++ ys
      where 
      toA ::Coupla -> [ASN1] -> [ASN1]
      toA (Coupla o v) zs = [Start Sequence , OID o] ++ toASN1 v (End Sequence : zs)
    fromASN1 asn = flip runParseASN1State asn $ do
        xs <- getMany $ do
               Start Sequence <- getNext
               OID x <- getNext
               v <-  getObject
               End Sequence <- getNext
               return $ Coupla x v
        return $ Suite xs

instance Show ClientException where
    show TimeoutException = "Timeout exception"
    show (ServerException 1) = "tooBig"
    show (ServerException 2) = "noSuchName"
    show (ServerException 3) = "badValue"
    show (ServerException 4) = "readOnly"
    show (ServerException 5) = "genErr"
    show (ServerException 6) = "noAccess"
    show (ServerException 7) = "wrongType"
    show (ServerException 8) = "wrongLength"
    show (ServerException 9) = "wrongEncoding"
    show (ServerException 10) = "wrongValue"
    show (ServerException 11) = "noCreation"
    show (ServerException 12) = "inconsistentValue"
    show (ServerException 13) = "resourceUnavailable"
    show (ServerException 14) = "commitFailed"
    show (ServerException 15) = "undoFailed"
    show (ServerException 16) = "authorizationError"
    show (ServerException 17) = "notWritable"
    show (ServerException 18) = "inconsistentName"
    show (ServerException 80) = "General IO failure occured on the set request"
    show (ServerException 81) = "General SNMP timeout occured"
    show (ServerException x) = "Exception " ++ show x

instance Exception ClientException

-- copy paste from asn1-encoding

packInteger :: Integer -> ByteString
packInteger = B.pack . bytesOfInt 

unpackInteger :: ByteString -> Either String Integer
unpackInteger = getIntegerRaw "Integer"

bytesOfInt :: Integer -> [Word8]
bytesOfInt i
  | i > 0      = if testBit (head uints) 7 then 0 : uints else uints
  | i == 0     = [0]
  | otherwise  = if testBit (head nints) 7 then nints else 0xff : nints
      where
      uints = bytesOfUInt (abs i)
      nints = reverse $ plusOne $ reverse $ map complement uints
      plusOne []     = [1]
      plusOne (x:xs) = if x == 0xff then 0 : plusOne xs else (x+1) : xs


--bytesOfUInt i = B.unfoldr (\x -> if x == 0 then Nothing else Just (fromIntegral (x .&. 0xff), x `shiftR` 8)) i
bytesOfUInt :: Integer -> [Word8]
bytesOfUInt x = reverse (list x)
  where list i = if i <= 0xff then [fromIntegral i] else (fromIntegral i .&. 0xff) : list (i `shiftR` 8)

{- | According to X.690 section 8.4 integer and enumerated values should be encoded the same way. -}
getIntegerRaw :: String -> ByteString -> Either String Integer
getIntegerRaw typestr s
    | B.length s == 0 = Left $ typestr ++ ": null encoding"
    | B.length s == 1 = Right $ snd $ intOfBytes s
    | otherwise       =
        if (v1 == 0xff && testBit v2 7) || (v1 == 0x0 && not (testBit v2 7))
            then Left $ typestr ++ ": not shortest encoding"
            else Right $ snd $ intOfBytes s
    where
        v1 = s `B.index` 0
        v2 = s `B.index` 1

{- | intOfBytes returns the number of bytes in the list and
the represented integer by a two's completement list of bytes -}
intOfBytes :: ByteString -> (Int, Integer)
intOfBytes b
    | B.length b == 0   = (0, 0)
    | otherwise         = (len, if isNeg then -(maxIntLen - v + 1) else v)
    where
        (len, v)  = uintOfBytes b
        maxIntLen = 2 ^ (8 * len) - 1
        isNeg     = testBit (B.head b) 7

{- | uintOfBytes returns the number of bytes and the unsigned integer represented by the bytes -}
uintOfBytes :: ByteString -> (Int, Integer)
uintOfBytes b = (B.length b, B.foldl (\acc n -> (acc `shiftL` 8) + fromIntegral n) 0 b)

------------------------------------------------------------------------------------------------------

cleanPass :: ByteString
cleanPass = B.pack $ replicate 12 0x00
 
data PrivType = DES | AES deriving (Show, Eq)
data AuthType = MD5 | SHA deriving (Show, Eq)
type Key = ByteString
type Password = ByteString

hash :: AuthType -> ByteString -> ByteString
hash MD5 = Md5.hash
hash SHA = Sha.hash

hashlazy :: AuthType -> BL.ByteString -> ByteString
hashlazy MD5 = Md5.hashlazy
hashlazy SHA = Sha.hashlazy

-- | (only V3) sign Packet 
signPacket :: AuthType -> Key -> Packet -> Packet 
signPacket at key packet = 
    let packetAsBin = encode packet
        sign = B.take 12 $ HMAC.hmac (hash at) 64 key packetAsBin 
    in setAuthenticationParametersP sign packet

-- | create auth key from password and context engine id
passwordToKey :: AuthType -> Password -> EngineId -> Key
passwordToKey at pass eid = 
  let buf = BL.take 1048576 $ BL.fromChunks $ repeat pass
      authKey = hashlazy at buf
  in hash at $ authKey <> eid <> authKey

-----------------------------------------------------------------------------------------------------

type EngineBootId = Int32
type PrivacyParameter = ByteString
type EngineId = ByteString
type Salt = ByteString
type Encrypted = ByteString
type Raw = ByteString
type Rand32 = Int32
type Rand64 = Int64

desEncrypt :: Key -> EngineBootId -> Rand32 -> Raw -> (Encrypted, Salt)
desEncrypt privKey engineBoot localInt dataToEncrypt = 
    let desKey = B.take 8 privKey
        preIV = B.drop 8 $ B.take 16 privKey
        salt = toSalt engineBoot localInt
        ivR = B.pack $ zipWith xor (B.unpack preIV) (B.unpack salt)
        Just iv = Priv.makeIV ivR
        Right key = Priv.makeKey desKey 
        des = Priv.cipherInit key :: Priv.DES
        tailLen = (8 - B.length dataToEncrypt `rem` 8) `rem` 8
        tailB = B.replicate tailLen 0x00
    in (Priv.cbcEncrypt des iv (dataToEncrypt <> tailB), salt)

type EngineTime = Int32

aesEncrypt :: Key -> EngineBootId -> EngineTime -> Rand64 -> Raw -> (Encrypted, Salt)
aesEncrypt privKey engineBoot engineTime rcounter dataToEncrypt =
    let aesKey = B.take 16 privKey
        salt = wToBs rcounter
        Just iv = Priv.makeIV $ toSalt engineBoot engineTime <> salt
        Right key = Priv.makeKey aesKey
        aes = Priv.cipherInit key :: Priv.AES128
    in (Priv.cfbEncrypt aes iv dataToEncrypt, salt)


wToBs :: Int64 -> ByteString
wToBs x = B.pack
  [ fromIntegral $ x `shiftR` 56 .&. 0xff
  , fromIntegral $ x `shiftR` 48 .&. 0xff
  , fromIntegral $ x `shiftR` 40 .&. 0xff
  , fromIntegral $ x `shiftR` 32 .&. 0xff
  , fromIntegral $ x `shiftR` 24 .&. 0xff
  , fromIntegral $ x `shiftR` 16 .&. 0xff
  , fromIntegral $ x `shiftR` 8 .&. 0xff
  , fromIntegral $ x `shiftR` 0 .&. 0xff
  ]

toSalt :: Int32 -> Int32 -> ByteString
toSalt x y = B.pack
  [ fromIntegral $ x `shiftR` 24 .&. 0xff 
  , fromIntegral $ x `shiftR` 16 .&. 0xff
  , fromIntegral $ x `shiftR`  8 .&. 0xff
  , fromIntegral $ x `shiftR`  0 .&. 0xff
  , fromIntegral $ y `shiftR` 24 .&. 0xff
  , fromIntegral $ y `shiftR` 16 .&. 0xff
  , fromIntegral $ y `shiftR`  8 .&. 0xff
  , fromIntegral $ y `shiftR`  0 .&. 0xff
  ]

desDecrypt :: Key -> Salt -> Encrypted -> Raw
desDecrypt privKey privParameters dataToDecrypt =
    let desKey = B.take 8 privKey
        preIV = B.drop 8 $ B.take 16 privKey
        salt = privParameters
        ivR = zipWith xor (B.unpack preIV) (B.unpack salt)
        Just iv = Priv.makeIV (B.pack ivR)
        Right key = Priv.makeKey desKey
        des = Priv.cipherInit key :: Priv.DES
    in stripBS $ Priv.cbcDecrypt des iv dataToDecrypt

aesDecrypt :: Key -> Salt -> EngineBootId -> EngineTime -> Encrypted -> Raw
aesDecrypt privKey privParameters engineBoot engineTime dataToDecrypt =
    let aesKey = B.take 16 privKey
        salt = privParameters
        ivR = toSalt engineBoot engineTime <> salt
        Just iv = Priv.makeIV ivR
        Right key = Priv.makeKey aesKey
        aes = Priv.cipherInit key :: Priv.AES128
    in stripBS $ Priv.cfbDecrypt aes iv dataToDecrypt

stripBS :: ByteString -> ByteString
stripBS bs = 
    let bs' = B.drop 1 bs
        l1 = fromIntegral $ B.head bs'
    in if testBit l1 7
        then case clearBit l1 7 of
                  0   -> throw $ ServerException 12
                  len -> 
                    let size = uintbs (B.take len (B.drop 1 bs'))
                    in B.take (size + len + 2) bs
        else B.take (l1 + 2) bs
    where
      {- uintbs return the unsigned int represented by the bytes -}
      uintbs = B.foldl (\acc n -> (acc `shiftL` 8) + fromIntegral n) 0

