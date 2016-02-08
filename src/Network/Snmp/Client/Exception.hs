{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE NoImplicitPrelude         #-}
{-# LANGUAGE OverloadedStrings         #-}
--------------------------------------------------------------------------------
-- |
-- Module      : Network.Snmp.Client.Exception
-- Copyright   : (c) Anton Kondrachkov 2015
-- License     : BSD3
--
-- Maintainer  : Anton Kondrachkov <simplex91@gmail.com>
-- Stability   : Experimental
--
--------------------------------------------------------------------------------

module Network.Snmp.Client.Exception
    ( SomeClientException(..)
    , TimeoutException(..)
    , SnmpEngineException(..)
    ) where

import           BasicPrelude
import           Data.Typeable
import qualified Prelude

import           Network.Snmp.Client.Types (Coupla)

data SomeClientException
    = forall e . (Exception e) => SomeClientException e
  deriving Typeable

instance Show SomeClientException where
    show (SomeClientException e) = Prelude.show e
    {-# INLINE show #-}

instance Exception SomeClientException

newtype TimeoutException
    = TimeoutException Int
  deriving (Eq, Typeable, Show)

instance Exception TimeoutException where
    fromException = clientExceptionFromException
    {-# INLINE fromException #-}
    toException = clientExceptionToException
    {-# INLINE toException #-}

newtype SnmpEngineException
    = SnmpEngineException Coupla
  deriving (Eq, Typeable, Show)

instance Exception SnmpEngineException where
    fromException = clientExceptionFromException
    {-# INLINE fromException #-}
    toException = clientExceptionToException
    {-# INLINE toException #-}

--------------------------------------------------------------------------------

clientExceptionToException :: (Exception e) => e -> SomeException
clientExceptionToException = toException . SomeClientException

clientExceptionFromException :: (Exception e) => SomeException -> Maybe e
clientExceptionFromException e = do
    SomeClientException x <- fromException e
    cast x
