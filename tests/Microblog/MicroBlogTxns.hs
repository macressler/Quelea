{-# LANGUAGE TemplateHaskell, ScopedTypeVariables #-}

module MicroBlogTxns (
  addNewUser,
  getPassword,
  followUser
) where

import Codeec.ClientMonad
import Codeec.TH (checkTxn)

import MicroBlogDefs
import MicroBlogCtrts

type Username = String
type Password = String

addNewUser :: UserID -> Username -> Password -> CSN Bool
addNewUser uid uname pwd = atomically ($(checkTxn "addNewUserTxn" addNewUserTxnCtrt)) $ do
  r::Bool <- invoke (mkKey uname) AddUsername uid
  if not r
  then return False {- username has already been taken -}
  else do {- success -}
    r::() <- invoke (mkKey uid) AddUser (uname,pwd)
    return True

-- Returns (Just pwd) on Success
getPassword :: Username -> CSN (Maybe Password)
getPassword uname = atomically ($(checkTxn "getPasswordTxn" getPasswordTxnCtrt)) $ do
  mbUid::Maybe UserID <- invoke (mkKey uname) GetUserID ()
  case mbUid of
    Nothing -> return Nothing
    Just uid -> do
      Just (_::String, pwd) <- invoke (mkKey uid) GetUserInfo ()
      return $ Just pwd

-- Returns True on Success
followUser :: Username -> Username -> CSN Bool
followUser me target = atomically ($(checkTxn "followUserTxn" followUserTxnCtrt)) $ do
  mbMyUid::Maybe UserID <- invoke (mkKey me) GetUserID ()
  case mbMyUid of
    Nothing -> return False
    Just myUid -> do
      mbTargetUid::Maybe UserID <- invoke (mkKey target) GetUserID ()
      case mbTargetUid of
        Nothing -> return False
        Just targetUid -> do
          _::() <- invoke (mkKey myUid) AddFollowing targetUid
          _::() <- invoke (mkKey targetUid) AddFollower myUid
          return True