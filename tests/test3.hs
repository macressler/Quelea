{-# Language TemplateHaskell, ScopedTypeVariables #-}

import Tracer hiding (inActSoup)
import qualified Tracer as T
import Language.Haskell.TH

data Event = Put | Get deriving Show
instance SolverEvent Event

data Attr = Key | Value deriving Show
instance SolverAttr Attr

tabIO s = doIO $ (putStr "\t") >> s

inActSoup :: [Action] -> Prop
inActSoup [] = true_
inActSoup (x:xs) = (T.inActSoup x) `and_` inActSoup xs

main = do
  let readsFrom = forall_ $ \a -> exists_ $ \b -> prop $
                    (isEventOf a Get) `implies_`
                    (isEventOf b Put `and_` sameAttr Key a b `and_`
                    sameAttr Value a b `and_` visTo b a)
  let sameObj a b = sameAttr Key a b
  -----------------------------------------------------------------------------
  -- Test 1
  --
  -- Expect Fail
  putStrLn $ "Test 1: Expect Fail"
  let test = do
        r <- checkConsistency $ prop false_
        tabIO $ print r
  runECD $(liftEvent ''Event) $(liftAttr ''Attr) sameObj test

  -----------------------------------------------------------------------------
  -- Test 2
  --
  putStrLn $ "Test 2"

  let test = do
        s <- addSession "S"
        a <- addAction "a" Put [(Key,"x"), (Value,"1")] basicEventual s
        b <- addAction "b" Get [(Key,"x"), (Value,"1")] basicEventual s

        doIO $ putStrLn "(1) Expect Ok"
        r <- checkConsistency $ prop $ sameAttr Key a b
        tabIO $ print r

        doIO $ putStrLn "(2) Expect Ok"
        r <- checkConsistency $ prop $ sameAttr Value a b
        tabIO $ print r

        doIO $ putStrLn "(3) Expect Fail"
        r <- checkConsistency $ exists_ $ \c -> prop $
          (inActSoup [c] `and_` distinctActs [a,b,c])
        tabIO $ print r

        c <- addAction "c" Put [(Key,"x"), (Value,"2")] basicEventual s
        d <- addAction "d" Get [(Key,"x"), (Value,"2")] basicEventual s

        doIO $ putStrLn "(4) Expect Fail"
        r <- addAssertion readsFrom
        tabIO $ print r

        doIO $ putStrLn "(5) Expect Fail"
        r <- checkConsistency{-AndIfFailDo showModel -} $ prop false_
        tabIO $ print r

  runECD $(liftEvent ''Event) $(liftAttr ''Attr) sameObj test

  -----------------------------------------------------------------------------
  -- Test 3
  --
  putStrLn $ "Test 3"

  let test = do
        s <- addSession "S"
        w0 <- addInitWrite "w0" Put [(Key,"x"), (Value,"2")]
        a <- addAction "a" Put [(Key,"x"), (Value,"1")] basicEventual s
        b <- addAction "b" Get [(Key,"x"), (Value,"2")] basicEventual s

        doIO $ putStrLn "(1) Expect Fail"
        r <- addAssertion readsFrom
        tabIO $ print r

        doIO $ putStrLn "(2) Expect Fail"
        r <- checkConsistency{- AndIfFailDo showModel -} $ prop false_
        tabIO $ print r

  runECD $(liftEvent ''Event) $(liftAttr ''Attr) sameObj test

  -----------------------------------------------------------------------------
  -- Test 4
  --
  putStrLn $ "Test 4"

  let test = do
        s1 <- addSession "s1"
        a <- addAction "a" Get [(Key,"x"), (Value,"1")] basicEventual s1
        b <- addAction "b" Put [(Key,"y"), (Value,"1")] basicEventual s1

        s2 <- addSession "s2"
        c <- addAction "c" Get [(Key,"y"), (Value,"1")] basicEventual s2
        d <- addAction "d" Put [(Key,"x"), (Value,"1")] basicEventual s2

        doIO $ putStrLn "(1) Expect Fail"
        r <- addAssertion readsFrom
        tabIO $ print r

        -- In this example, the only possible assignment for the visibility
        -- relation creates a cycle. ThinAir axiom fails. Hence the execution
        -- is impossible.
        doIO $ putStrLn "(2) Expect ExecImpossible"
        r <- checkConsistency{- AndIfFailDo showModel -} $ prop false_
        tabIO $ print r

  runECD $(liftEvent ''Event) $(liftAttr ''Attr) sameObj test

