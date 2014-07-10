{-# LANGUAGE ScopedTypeVariables, EmptyDataDecls, TemplateHaskell  #-}

module Codeec.Shim (
 runShimNode,
 mkDtLib
) where

import Codeec.Types
import Codeec.NameService.SimpleBroker
import Codeec.Marshall
import Database.Cassandra.CQL
import Data.Serialize
import Control.Applicative ((<$>))
import Control.Monad (forever)
import Data.ByteString hiding (map)
import Data.Either (rights)
import Data.Map (Map)
import qualified Data.Map as Map
import System.ZMQ4
import Data.Maybe (fromJust)
import Control.Lens

performOp :: DatatypeLibrary -> Request -> IO ByteString
performOp dtLib (Request objType operName arg) =
  let im = fromJust $ dtLib ^.at objType
      (op,_) = fromJust $ im ^.at operName
      (res, _) = op [] arg
  in return res

runShimNode :: DatatypeLibrary -> Backend -> Int -> IO ()
runShimNode dtlib backend port = do
  ctxt <- context
  sock <- socket ctxt Rep
  let myaddr = "tcp://*:" ++ show port
  bind sock myaddr
  serverJoin backend $ "tcp://localhost:" ++ show port
  forever $ do
    req <- receive sock
    result <- performOp dtlib $ decodeRequest req
    send sock [] result

mkDtLib :: OTC a => [(a,Datatype)] -> DatatypeLibrary
mkDtLib l =
  let l' = map (\(v1,v2) -> (ObjType $ show v1, v2)) l
  in Map.fromList l'
