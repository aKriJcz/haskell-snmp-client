{-# LANGUAGE OverloadedStrings #-}
module Network.Protocol.Snmp 
( SnmpVersion(..)
, SnmpData(..)
, Community(..)
, Request(..)
, PDU(..)
, RequestId
, SnmpPacket(..)
, encode
, decode
)
where

import Data.ASN1.Parse
import Data.ASN1.Types
import Data.ASN1.Encoding
import Data.ASN1.BinaryEncoding
import Data.ByteString (ByteString)
import Data.ByteString.Lazy (toStrict, fromStrict)
import Control.Applicative
import Network.Protocol.Simple
import Data.Monoid
import Debug.Trace

newtype Community = Community ByteString deriving (Show, Eq)
type RequestId = Integer
type ErrorStatus = Integer
type ErrorIndex = Integer

data SnmpVersion = Version1
                 | Version2
                 | Version3
                 deriving (Show, Eq)

data Request = GetRequest RequestId ErrorStatus ErrorIndex 
             | GetNextRequest RequestId ErrorStatus ErrorIndex 
             | GetResponse RequestId ErrorStatus ErrorIndex  
             | SetRequest RequestId ErrorStatus ErrorIndex 
             | GetBulk RequestId ErrorStatus ErrorIndex 
             | Inform
             | V2Trap
             | Report
             deriving (Show, Eq)

data PDU = PDU Request SnmpData deriving (Show, Eq)

data SnmpData = SnmpData [(OID, SnmpType)] deriving (Eq)

instance Monoid SnmpData where
    mempty = SnmpData []
    mappend (SnmpData xs) (SnmpData ys) = SnmpData $ xs <> ys

instance Show SnmpData where
    show (SnmpData xs) = unlines $ map (\(oid, snmptype) -> oidToString oid ++ " = " ++ show snmptype) xs

oidToString :: OID -> String
oidToString xs = foldr1 (\x y -> x ++ "." ++ y) $ map show xs

data SnmpPacket = SnmpPacket SnmpVersion Community PDU deriving (Show, Eq)

instance ASN1Object SnmpVersion where
    toASN1 Version1 xs = IntVal 0 : xs
    toASN1 Version2 xs = IntVal 1 : xs
    toASN1 Version3 xs = IntVal 2 : xs
    fromASN1 asn = flip runParseASN1State asn $ do
        IntVal x <- getNext
        case x of
             0 -> return Version1
             1 -> return Version2
             2 -> return Version3
             _ -> error "unknown version"

instance ASN1Object Community where
    toASN1 (Community x) xs = OctetString x : xs
    fromASN1 asn = flip runParseASN1State asn $ do
        OctetString x <- getNext
        return $ Community x

instance ASN1Object Request where
    toASN1 (GetRequest rid _ _    ) xs = (Start $ Container Context 0):IntVal rid : IntVal 0  : IntVal 0 : Start Sequence : xs ++ [ End Sequence, End (Container Context 0)]
    toASN1 (GetNextRequest rid _ _) xs = (Start $ Container Context 1):IntVal rid : IntVal 0  : IntVal 0 : Start Sequence : xs ++ [ End Sequence, End (Container Context 1)]
    toASN1 (GetResponse rid es ei ) xs = (Start $ Container Context 2):IntVal rid : IntVal es : IntVal ei: Start Sequence : xs ++ [ End Sequence, End (Container Context 2)]
    toASN1 (SetRequest rid _ _    ) xs = (Start $ Container Context 3):IntVal rid : IntVal 0  : IntVal 0 : Start Sequence : xs ++ [ End Sequence, End (Container Context 3)]
    toASN1 (GetBulk rid es ei     ) xs = (Start $ Container Context 5):IntVal rid : IntVal es : IntVal ei: Start Sequence : xs ++ [ End Sequence, End (Container Context 4)]
    toASN1 _ _ = error "not inplemented"
    fromASN1 asn = 
      case fromASN1Request asn of
           Left e -> Left e
           Right (r, _) -> Right r


fromASN1Request :: [ASN1] -> Either String ((Request, [ASN1]), [ASN1])
fromASN1Request asn = flip runParseASN1State asn $ do
        Start container <- getNext
        IntVal rid <- getNext
        IntVal es <- getNext
        IntVal ei <- getNext
        x <- getNextContainer Sequence
        End container' <- getNext
        case (container == container', container) of
             (True, Container Context 0) -> return (GetRequest rid es ei, x)
             (True, Container Context 1) -> return (GetNextRequest rid es ei, x)
             (True, Container Context 2) -> return (GetResponse rid es ei, x)
             (True, Container Context 3) -> return (SetRequest rid es ei, x)
             (True, Container Context 5) -> return (GetBulk rid es ei, x)
             _ -> error "not inplemented or bad sequence"

instance ASN1Object SnmpData where
    toASN1 (SnmpData xs) ys = foldr toA [] xs ++ ys
      where 
      toA ::(OID,SnmpType) -> [ASN1] -> [ASN1]
      toA (o, v) zs = [Start Sequence , OID o] ++ toASN1 v (End Sequence : zs)
    fromASN1 asn = flip runParseASN1State asn $ do
        xs <- getMany $ do
               Start Sequence <- getNext
               OID x <- getNext
               v <-  getObject
               End Sequence <- getNext
               return (x, v)
        return $ SnmpData xs


instance ASN1Object PDU where
    toASN1 (PDU r sd) xs = toASN1 r (toASN1 sd []) ++  xs
    fromASN1 asn = flip runParseASN1State asn $ do
        r <- getObject 
        sd <- getObject
        return $ PDU r sd

instance ASN1Object SnmpPacket where
    toASN1 (SnmpPacket sv c pdu) _ = Start Sequence :( toASN1 sv . toASN1 c . toASN1 pdu $ [End Sequence])
    fromASN1 asn = flip runParseASN1State asn $ onNextContainer Sequence $ do
        sv <- getObject
        c <- getObject
        pdu <- getObject
        return $ SnmpPacket sv c pdu

class Pack a where
    encode :: a -> ByteString
    decode :: ByteString -> a

instance Pack SnmpPacket where
    encode s = toStrict $ encodeASN1 DER $ toASN1 s []
    decode = toB 

toB :: ByteString -> SnmpPacket
toB bs = let a = fromASN1 <$> decodeASN1 DER (fromStrict bs)
         in case a of
                 Right (Right (r, _)) -> r
                 _ -> error "bad packet"

