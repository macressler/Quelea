{-# LANGUAGE ScopedTypeVariables, EmptyDataDecls, TemplateHaskell,
    DataKinds, OverloadedStrings, DoAndIfThenElse  #-}

module Quelea.DBDriver (
  TableName(..),
  ReadRow,

  createTable,
  dropTable,

  cqlRead,
  cqlReadAfterTime,
  cqlReadWithTime,
  cqlReadAfterTimeWithTime,

  cqlInsert,
  -- cqlInsertWithTime,
  cqlDelete,

  getLock,
  releaseLock,

  getGCLock,
  releaseGCLock,

  createTxnTable,
  dropTxnTable,
  readTxn,
  insertTxn
) where


import Quelea.Consts
import Control.Concurrent (threadDelay)
import Quelea.Types
import Quelea.NameService.SimpleBroker
import Quelea.Marshall
import Data.Serialize
import Control.Applicative ((<$>))
import Control.Monad (forever)
import Data.ByteString hiding (map, pack)
import Data.Either (rights)
import Data.Map (Map)
import Data.Time
import qualified Data.Map as Map
import System.ZMQ4
import Control.Lens
import Database.Cassandra.CQL
import Data.UUID
import Data.Int (Int64)
import qualified Data.Set as S
import Data.Text hiding (map)
import Control.Monad.Trans (liftIO)
import Data.Maybe (fromJust)
import Control.Monad (when)

-- Simply an alias for Types.ObjType
type TableName = String

type ReadRow = (SessID, SeqNo, S.Set Addr, Cell, Maybe TxnID)
type ReadRowInternal = (UUID, SeqNo, Deps, Cell, Maybe UUID)

type ReadRowWithTime = (SessID, SeqNo, UTCTime, S.Set Addr, Cell, Maybe TxnID)
type ReadRowWithTimeInternal = (UUID, SeqNo, UTCTime, Deps, Cell, Maybe UUID)

type WriteRowInternal = (UTCTime, Key, UUID, SeqNo, Deps, Cell, Maybe UUID)

--------------------------------------------------------------------------------
-- Cassandra Link Layer
--------------------------------------------------------------------------------


-- A Row either corresponds to an effect (Cell is EffectVal bs) or a gc marker
-- (Cell is GCMarker). In case of GCMarker, the dependence set (deps value in
-- the row) is interpreted as a "Cursor". All effects that are encapsulated by
-- this cursor are considered to have been GC'ed.
mkCreateTable :: TableName -> Query Schema () ()
mkCreateTable tname = query $ pack $ "create table " ++ tname ++
                      " ( objid blob, sessid uuid, seqno bigint, addedat timestamp, deps blob, value blob, txnid uuid, primary key (objid, addedat, sessid, seqno))"

mkDropTable :: TableName -> Query Schema () ()
mkDropTable tname = query $ pack $ "drop table " ++ tname

mkInsert :: TableName -> Query Write WriteRowInternal ()
mkInsert tname = query $ pack $ "insert into " ++ tname ++ " (addedat, objid, sessid, seqno, deps, value, txnid) values (?, ?, ?, ?, ?, ?, ?)"

mkDelete :: TableName -> Query Write (Key, UTCTime, UUID, SeqNo) ()
mkDelete tname = query $ pack $ "delete from " ++ tname ++ " where objid = ? and addedat = ? and sessid = ? and seqno = ?"

mkRead :: TableName -> Query Rows (Key) ReadRowInternal
mkRead tname = query $ pack $ "select sessid, seqno, deps, value, txnid from " ++ tname ++ " where objid = ?"

mkReadAfterTime :: TableName -> Query Rows (Key,UTCTime) ReadRowInternal
mkReadAfterTime tname = query $ pack $ "select sessid, seqno, deps, value, txnid from " ++ tname ++ " where objid = ? and addedat > ?"

mkReadWithTime :: TableName -> Query Rows (Key) ReadRowWithTimeInternal
mkReadWithTime tname = query $ pack $ "select sessid, seqno, addedat, deps, value, txnid from " ++ tname ++ " where objid = ?"

mkReadAfterTimeWithTime :: TableName -> Query Rows (Key, UTCTime) ReadRowWithTimeInternal
mkReadAfterTimeWithTime tname = query $ pack $ "select sessid, seqno, addedat, deps, value, txnid from " ++ tname ++ " where objid = ? and addedat > ?"

-------------------------------------------------------------------------------

mkCreateLockTable :: TableName -> Query Schema () ()
mkCreateLockTable tname = query $ pack $ "create table " ++ tname ++ "_LOCK (objid blob, sessid uuid, primary key (objid))"

mkDropLockTable :: TableName -> Query Schema () ()
mkDropLockTable tname = query $ pack $ "drop table " ++ tname ++ "_LOCK"

mkLockInsert :: TableName -> Query Write (Key, UUID) ()
mkLockInsert tname = query $ pack $ "insert into " ++ tname ++ "_LOCK (objid, sessid) values (?, ?) if not exists"

mkLockUpdate :: TableName -> Query Write (UUID {- New -}, Key, UUID {- Old -}) ()
mkLockUpdate tname = query $ pack $ "update " ++ tname ++ "_LOCK set sessid = ? where objid = ? if sessid = ?"

-------------------------------------------------------------------------------

mkCreateGCLockTable :: TableName -> Query Schema () ()
mkCreateGCLockTable tname = query $ pack $ "create table " ++ tname ++ "_GC_LOCK (objid blob, sessid uuid, primary key (objid))"

mkDropGCLockTable :: TableName -> Query Schema () ()
mkDropGCLockTable tname = query $ pack $ "drop table " ++ tname ++ "_GC_LOCK"

mkGCLockInsert :: TableName -> Query Write (Key, UUID) ()
mkGCLockInsert tname = query $ pack $ "insert into " ++ tname ++ "_GC_LOCK (objid, sessid) values (?, ?) if not exists"

mkGCLockUpdate :: TableName -> Query Write (UUID {- New -}, Key, UUID {- Old -}) ()
mkGCLockUpdate tname = query $ pack $ "update " ++ tname ++ "_GC_LOCK set sessid = ? where objid = ? if sessid = ?"


-------------------------------------------------------------------------------

mkCreateTxnTable :: Query Schema () ()
mkCreateTxnTable = "create table Txns (txnid uuid, deps blob, primary key (txnid))"

mkDropTxnTable :: Query Schema () ()
mkDropTxnTable = "drop table Txns"

mkInsertTxnTable :: Query Write (UUID, TxnDepSet) ()
mkInsertTxnTable = "insert into Txns (txnid, deps) values (?, ?)"

mkReadTxnTable :: Query Rows (UUID) TxnDepSet
mkReadTxnTable = "select deps from Txns where txnid = ?"

-------------------------------------------------------------------------------

mkCreateGlobalLockTable :: Query Schema () ()
mkCreateGlobalLockTable = "create table GlobalLock (id uuid, txnid uuid, primary key id)"

mkDropGlobalLockTable :: Query Schema () ()
mkDropGlobalLockTable = "drop table GlobalLock"

mkGlobalLockInsert :: Query Write (UUID, UUID) ()
mkGlobalLockInsert = "insert into GlobalLock (id, txnid) values (?,?)"

mkGlobalLockUpdate :: Query Write (UUID {- New TxnID -}, UUID {- ID -}, UUID {- Old TxnID -}) ()
mkGlobalLockUpdate = "update GlobalLock set txnid = ? where id = ? if txnid = ?"

-------------------------------------------------------------------------------

cqlReadAfterTime :: TableName -> Consistency -> Key -> UTCTime -> Cas [ReadRow]
cqlReadAfterTime tname c k gcTime = do
  rows <- executeRows c (mkReadAfterTime tname) (k, gcTime)
  return $ map (\(sid, sqn, Deps deps, val, txid) -> (SessID sid, sqn, deps, val, TxnID <$> txid)) rows

cqlRead :: TableName -> Consistency -> Key -> Cas [ReadRow]
cqlRead tname c k = do
  rows <- executeRows c (mkRead tname) k
  return $ map (\(sid, sqn, Deps deps, val, txid) -> (SessID sid, sqn, deps, val, TxnID <$> txid)) rows

cqlReadAfterTimeWithTime :: TableName -> Consistency -> Key -> UTCTime -> Cas [ReadRowWithTime]
cqlReadAfterTimeWithTime tname c k gcTime = do
  rows <- executeRows c (mkReadAfterTimeWithTime tname) (k, gcTime)
  return $ map (\(sid, sqn, addedat, Deps deps, val, txid) -> (SessID sid, sqn, addedat, deps, val, TxnID <$> txid)) rows

cqlReadWithTime :: TableName -> Consistency -> Key -> Cas [ReadRowWithTime]
cqlReadWithTime tname c k = do
  rows <- executeRows c (mkReadWithTime tname) k
  return $ map (\(sid, sqn, addedat, Deps deps, val, txid) -> (SessID sid, sqn, addedat, deps, val, TxnID <$> txid)) rows

cqlInsertWithTime :: TableName -> Consistency -> Key -> ReadRow -> UTCTime -> Cas ()
cqlInsertWithTime tname c k (SessID sid, sqn, dep,val,txid) ct = do
  if sqn == 0
  then error "cqlInsert : sqn is 0"
  else do
    if S.size dep > 0
    then executeWrite c (mkInsert tname) (ct,k,sid,sqn,Deps dep,val,unTxnID <$> txid)
    else executeWrite c (mkInsert tname) (ct,k,sid,sqn,Deps $ S.singleton $ Addr (SessID sid) 0, val, unTxnID <$> txid)

cqlInsert :: TableName -> Consistency -> Key -> ReadRow -> Cas ()
cqlInsert tname c k row = do
  ct <- liftIO $ getCurrentTime
  cqlInsertWithTime tname c k row ct

cqlDelete :: TableName -> Key -> UTCTime -> SessID -> SeqNo -> Cas ()
cqlDelete tname k time (SessID sid) sqn =
  executeWrite ONE (mkDelete tname) (k,time,sid,sqn)

createTxnTable :: Cas ()
createTxnTable = liftIO . print =<< executeSchema ALL mkCreateTxnTable ()

dropTxnTable :: Cas ()
dropTxnTable = liftIO . print =<< executeSchema ALL mkDropTxnTable ()

insertTxn :: TxnID -> S.Set TxnDep -> Cas ()
insertTxn (TxnID txnid) deps = do
  when (S.size deps == 0) $ error "insertTxn: Txn has no actions"
  executeWrite ONE mkInsertTxnTable (txnid, TxnDepSet deps)

readTxn :: TxnID -> Cas (Maybe (S.Set TxnDep))
readTxn (TxnID txnid) = do
  result <- executeRow ONE mkReadTxnTable txnid
  case result of
    Nothing -> return Nothing
    Just (TxnDepSet s) -> return $ Just s

createTable :: TableName -> Cas ()
createTable tname = do
  liftIO . print =<< executeSchema ALL (mkCreateTable tname) ()
  liftIO . print =<< executeSchema ALL (mkCreateLockTable tname) ()
  liftIO . print =<< executeSchema ALL (mkCreateGCLockTable tname) ()

dropTable :: TableName -> Cas ()
dropTable tname = do
  liftIO . print =<< executeSchema ALL (mkDropTable tname) ()
  liftIO . print =<< executeSchema ALL (mkDropLockTable tname) ()
  liftIO . print =<< executeSchema ALL (mkDropGCLockTable tname) ()

----------------------------------------------------------------------------------

tryGetLock :: TableName -> Key -> SessID -> Bool {- tryInsert -} -> Cas Bool
tryGetLock tname k (SessID sid) True = do
  res <- executeTrans (mkLockInsert tname) (k, sid) ALL
  if res then return True
  else tryGetLock tname k (SessID sid) False
tryGetLock tname k (SessID sid) False = do
  res <- executeTrans (mkLockUpdate tname) (sid, k, knownUUID) ALL
  if res then return True
  else do
    liftIO $ threadDelay cLOCK_DELAY
    tryGetLock tname k (SessID sid) False

getLock :: TableName -> Key -> SessID -> Pool -> IO ()
getLock tname k sid pool = runCas pool $ do
  tryGetLock tname k sid True
  return ()

releaseLock :: TableName -> Key -> SessID -> Pool -> IO ()
releaseLock tname k (SessID sid) pool = runCas pool $ do
  res <- executeTrans (mkLockUpdate tname) (knownUUID, k, sid) ALL
  if res then return ()
  else error $ "releaseLock : key=" ++ show k ++ " sid=" ++ show sid

--------------------------------------------------------------------------------

tryGetGCLock :: TableName -> Key -> SessID -> Bool {- tryInsert -} -> Cas Bool
tryGetGCLock tname k (SessID sid) True = do
  res <- executeTrans (mkGCLockInsert tname) (k, sid) ALL
  if res then return True
  else tryGetGCLock tname k (SessID sid) False
tryGetGCLock tname k (SessID sid) False = do
  res <- executeTrans (mkGCLockUpdate tname) (sid, k, knownUUID) ALL

  if res then return True
  else do
    liftIO $ threadDelay cLOCK_DELAY
    tryGetGCLock tname k (SessID sid) False

getGCLock :: TableName -> Key -> SessID -> Pool -> IO ()
getGCLock tname k sid pool = runCas pool $ do
  tryGetGCLock tname k sid True
  return ()

releaseGCLock :: TableName -> Key -> SessID -> Pool -> IO ()
releaseGCLock tname k (SessID sid) pool = runCas pool $ do
  res <- executeTrans (mkGCLockUpdate tname) (knownUUID, k, sid) ALL
  if res then return ()
  else error $ "releaseGCLock : key=" ++ show k ++ " sid=" ++ show sid

--------------------------------------------------------------------------------

createGlobalLockTable :: Cas ()
createGlobalLockTable = do
  liftIO . print =<< executeSchema ALL mkCreateGlobalLockTable ()
  executeWrite ALL mkGlobalLockInsert (knownUUID, knownUUID)

getGlobalLock :: TxnID -> Pool -> IO ()
getGlobalLock (TxnID txnid) pool = runCas pool loop
  where
    loop = do
      success <- executeTrans mkGlobalLockUpdate (txnid, knownUUID, knownUUID) ALL
      when (not success) loop

releaseGlobalLock :: TxnID -> Pool -> IO ()
releaseGlobalLock (TxnID txnid) pool = runCas pool $ do
  success <- executeTrans mkGlobalLockUpdate (knownUUID, knownUUID, txnid) ALL
  when (not success) (error $ "releaseGlobalLock: key=" ++ show (TxnID txnid))
