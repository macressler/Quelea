{-# LANGUAGE TemplateHaskell, ScopedTypeVariables #-}

module RubisTxns (
  login,
  searchItem,
  bidForItem,
  showMyBids,
  cancelMyBid,
  openAuction,
  showMyAuctions,
  concludeAuction
) where

import Codeec.ClientMonad
import Codeec.TH (checkTxn)

import RubisDefs
import RubisCtrts

import Control.Monad.Trans (liftIO)
import System.Random (randomIO)
import Control.Applicative ((<$>))
import Data.Maybe (fromJust)
import Control.Monad (foldM, when)
import Control.Exception.Base

login:: WalletID -> CSN WalletID
login wid = do
  return wid 

searchItem :: ()
searchItem = ()

getItem :: ItemID -> CSN (Maybe (String,Int,Int))
getItem id = do
  let key = mkKey id
  resOp <- invoke key ShowItem (id);
  case resOp of
    Nothing -> error "Sorry, Item not available anymore"
    Just res -> return res
 
-- User places a bid for ItemID. The bid is placed only if the item is 
-- still available and the bid amount is greater than min price
-- decided by the seller. 
-- User won't billed until he wins the auction.
bidForItem :: WalletID -> ItemID -> Int -> CSN BidID 
bidForItem wid id amt = 
  atomically ($(checkTxn "_bidForItemTxn" bidForItemTxnCtrt)) $ do
    resOp  <- getItem id
    let (desc,mp,maxb) = case resOp of
                            Just x -> x
                            Nothing -> error "Sorry, Item not available anymore"
    let _ = if amt >= mp then () else error "Bid amount less than min price"
    let wkey = mkKey wid
    bidID <- liftIO $ BidID <$> randomIO
    let bkey = mkKey bidID
    let ikey = mkKey id
    r::() <- invoke bkey AddBid (wid,id,amt)
    r::() <- invoke ikey AddItemBid bidID
    r::() <- invoke wkey AddWalletBid bidID 
    if amt>maxb then invoke ikey UpdateMaxBid (amt) else return ()
    return bidID

bidIdFold :: [(ItemID,Int)] -> BidID -> CSN [(ItemID,Int)]
bidIdFold acc (bidID) = do
  resOp :: Maybe (WalletID,ItemID,Int)  <- invoke (mkKey bidID) GetBid ()
  let (_,id,amt) = fromJust resOp
  return $ (id,amt):acc
-- Get all my bids. 
showMyBids :: WalletID -> CSN [(ItemID,Int{-amt-})]
showMyBids wid = 
  atomically ($(checkTxn "_showMyBidsTxn" showMyBidsTxnCtrt)) $ do
    bidIDs::[BidID] <- invoke (mkKey wid) GetBidsByWallet ()
    bids <- foldM bidIdFold [] bidIDs
    return bids
-- This transaction removes things from bids table, and two other
-- materialized views. For consistency, it needs MAV.
-- We do a trivial withdraw of $0 immediately after we cancel the bid.
-- The total-order contract of withdraw, coupled with atomicity on
-- this transaction, means that a different MAV transaction that sees
-- withdraw from this transaction will also see CancelBid. This
-- property will be used in concludeAuction to rule out canceled bids
-- while determining the winner of the auction.
cancelMyBid :: BidID -> CSN ()
cancelMyBid bidID = 
  atomically ($(checkTxn "_cancelBidTxn" cancelBidTxnCtrt)) $ do
    resOp :: Maybe (WalletID,ItemID,Int) <- invoke (mkKey bidID) GetBid ()
    let (wID,itemID,_) = case resOp of
              Just x -> x
              Nothing -> error "Cannot Cancel Bid. Please try again."
    r::()<- invoke (mkKey wID) WithdrawFromWallet (0::Int) 
    r::() <- invoke (mkKey bidID) CancelBid ()
    r::() <- invoke (mkKey itemID) RemoveItemBid (itemID)
    r::() <- invoke (mkKey wID) RemoveWalletBid (wID)
    return ()

-- Put up an item for auction.
openAuction :: WalletID -> ItemID -> String{-desc-} -> Int{-minPrice-} -> CSN ()
openAuction wid id desc mp =
  atomically ($(checkTxn "_openAuctionTxn" openAuctionTxnCtrt)) $ do
    r::() <- invoke (mkKey id) StockItem (desc,mp,0::Int)
    r::() <- invoke (mkKey wid) AddWalletItem (id)
    return ()

-- Show all items that I offered for auction, along with a local
-- maxbid. 
showMyAuctions :: WalletID -> CSN [(ItemID,String,Int{-minPrice-},Int{-maxBid-})]
showMyAuctions wid = 
  atomically ($(checkTxn "_showMyAuctionsTxn" showMyAuctionsTxnCtrt)) $ do
    itemIDs <- invoke (mkKey wid) GetItemsByWallet ()
    items <- foldM f [] itemIDs
    return items
      where
        f :: [(ItemID,String,Int,Int)] -> ItemID -> CSN [(ItemID,String,Int,Int)]
        f acc (itemID) = do
          resOp <- invoke (mkKey itemID) ShowItem ()
          let (desc,mp,maxb) = fromJust resOp
          return $ (itemID,desc,mp,maxb):acc

-- For each bidID in bidIDs, query details of the bidID, and determine
-- maxbidder.
-- Note: Two invocations of getMaxBid with same list of bidIDs may
-- return different maxbidder. This happens if maxbidder from previous
-- invocation has cancelled his bid meanwhile. 
getMaxBid :: [BidID] -> CSN (Maybe (BidID,WalletID, Int{-maxbid-}))
getMaxBid bidIDs = foldM f Nothing bidIDs
  where
    f accOp bidID = do
      (resOp::Maybe (WalletID,ItemID,Int))<- invoke (mkKey bidID) GetBid ()
      case (resOp,accOp) of 
        (Nothing,_) -> return accOp
        (Just (wid,_,amt), Nothing) -> return $ Just (bidID,wid,amt)
        (Just (wid,_,amt::Int), Just (_,_,amt')) -> 
          return $ if amt>amt' then Just (bidID,wid,amt) else accOp
-- Bills best bidder, and returns billed amount. The function
-- terminates because the list of bidIDs in recursive calls
-- monotonically decreases.
billBestBidder :: [BidID] -> CSN Int
billBestBidder bidIDs = do
  resOp <- getMaxBid bidIDs
  case resOp of 
    Nothing -> return 0
    Just (bidID,wid,maxbid) -> 
      let f b = b/=bidID in
      let billNextBest :: () -> CSN Int
          billNextBest () = billBestBidder $ f `filter` bidIDs in
        do
          r::Bool <- invoke (mkKey wid) WithdrawFromWallet (maxbid::Int)
          if r 
          then do -- Best bidder is succesfully billed
            (resOp :: Maybe (WalletID,Int,Int))<- invoke (mkKey bidID) GetBid ()
            case resOp of
              Just _ -> return maxbid -- Best bid is not cancelled
              Nothing -> do -- If best bid is cancelled, deposit money back
                r::() <- invoke (mkKey wid) DepositToWallet (maxbid)
                billNextBest () -- Find next best
          else do
            billNextBest ()
          
-- This transaction needs to be MAV to ensure that this is in total
-- order with all cancelBid transactions.
concludeAuction :: WalletID{-seller-} -> ItemID -> CSN Int {-max bid -}
concludeAuction wID itemID = do
  let ikey = mkKey itemID 
  -- Remove the item from stock to prevent future bids from
  -- being placed on this item.
  r::() <- invoke ikey RemoveFromStock ();
  atomically ($(checkTxn "_concludeAuctionTxn" concludeAuctionTxnCtrt)) $ do
    let (wkey,ikey) =  (mkKey wID, mkKey itemID)
    -- Get all bids on the item
    bidIDs <- invoke ikey GetBidsByItem ()
    -- Among bidIDs, find best bid and bill best bidder.
    amt::Int <- billBestBidder bidIDs
    r::() <- if amt>0 then invoke wkey DepositToWallet (amt) else return ()
    return amt

