-- | General purpose pipes

{-# LANGUAGE RankNTypes #-}
{-# OPTIONS_GHC -fno-warn-unused-do-bind #-}

module Pipes.Prelude (
    -- * Producers
    stdin,
    fromHandle,
    readLn,

    -- * Unfolds
    map,
    mapM,
    filter,

    -- * Push-based Pipes
    take,
    takeWhile,
    drop,
    dropWhile,
    read,

    -- * Folds
    -- $folds
    all,
    any,
    head,

    -- * Zips
    zip,
    zipWith,

    -- * Utilities
    tee,
    generalize
    ) where

import Control.Monad (unless)
import Control.Monad.Trans.Writer.Strict (WriterT, tell)
import Control.Monad.Trans.State.Strict(get, put)
import qualified Data.Monoid   as M
import qualified System.IO     as IO
import Pipes
import Pipes.Lift (evalStateP)
import Prelude hiding (
    print,
    readLn,
    map,
    mapM,
    mapM_,
    concat,
    take,
    takeWhile,
    drop,
    dropWhile,
    filter,
    read,
    enumFrom,
    all,
    any,
    sum,
    product,
    length,
    head,
    last,
    foldr,
    zip,
    zipWith )
import qualified Prelude

-- | Read 'String's from 'IO.stdin' using 'getLine'
stdin :: Producer' String IO ()
stdin = fromHandle IO.stdin
{-# INLINABLE stdin #-}

-- | Read 'String's from a 'IO.Handle' using 'IO.hGetLine'
fromHandle :: IO.Handle -> Producer' String IO ()
fromHandle h = go
  where
    go = do
        eof <- lift $ IO.hIsEOF h
        unless eof $ do
            str <- lift $ IO.hGetLine h
            respond str
            go
{-# INLINABLE fromHandle #-}

-- | 'read' from 'IO.stdin' using 'Prelude.readLn'
readLn :: (Read b) => Producer' b IO ()
readLn = go
  where
    go = do
        eof <- lift $ IO.hIsEOF IO.stdin
        unless eof $ do
            str <- lift Prelude.readLn
            respond str
            go
{-# INLINABLE readLn #-}

{-| Transform all values using a pure function

> map (g . f) = map f />/ map g
>
> map id = respond
-}
map :: (Monad m) => (a -> b) -> a -> Producer' b m ()
map f = respond . f
{-# INLINABLE map #-}

{-| Transform all values using a monadic function

> mapM (f >=> g) = mapM f />/ mapM g
>
> mapM return = respond
-}
mapM :: (Monad m) => (a -> m b) -> a -> Producer' b m ()
mapM f a = do
    b <- lift (f a)
    respond b
{-# INLINABLE mapM #-}

{-| @(filter p)@ discards values going downstream if they fail the predicate
    @p@

> filter (\a -> f a && g a) = filter f />/ filter g
>
> filter (\_ -> True) = respond
-}
filter :: (Monad m) => (a -> Bool) -> a -> Producer a m ()
filter predicate a = if (predicate a) then respond a else return ()
{-# INLINABLE filter #-}

-- | @(take n)@ only allows @n@ values to pass through
take :: (Monad m) => Int -> a -> Pipe a a m ()
take = go
  where
    go n a =
        if (n <= 0)
        then return ()
        else do
            respond a
            request () >>= go (n - 1)
{-# INLINABLE take #-}

{-| @(takeWhile p)@ allows values to pass downstream so long as they satisfy
    the predicate @p@.
-}
takeWhile :: (Monad m) => (a -> Bool) -> a -> Pipe a a m ()
takeWhile predicate = go
  where
    go a =
        if (predicate a)
        then do
            respond a
            request () >>= go
        else return ()
{-# INLINABLE takeWhile #-}

-- | @(drop n)@ discards @n@ values going downstream
drop :: (Monad m) => Int -> a -> Pipe a a m r
drop = go
  where
    go n a =
        if (n <= 0)
        then push a
        else do
            respond a
            request () >>= go (n - 1)
{-# INLINABLE drop #-}

{-| @(dropWhile p)@ discards values going downstream until one violates the
    predicate @p@.
-}
dropWhile :: (Monad m) => (a -> Bool) -> a -> Pipe a a m r
dropWhile predicate = go
  where
    go a =
        if (predicate a)
        then request () >>= go
        else push a
{-# INLINABLE dropWhile #-}

-- | Parse 'Read'able values, only forwarding the value if the parse succeeds
read :: (Monad m, Read a) => String -> Producer a m ()
read str = case (reads str) of
    [(a, "")] -> respond a
    _         -> return ()

{- $folds
    For most folds, just use 'WriterT' in the base monad to store the result.
    Here are some example folds:

> -- Sum the elements of the list
> execWriter $ runEffect $
>     for (each [1..10]) $ \i -> do
>         lift $ tell (Sum i)
>
> -- Get the last element of the list
> execWriter $ runEffect $
>     for (each [1..10]) $ \i -> do
>         lift $ tell $ Last (Just i)

    I provide 'all', 'any' and 'head' because these folds can be smart and
    terminate early when they are done.  You can also use 'next' instead of
    'head'.
-}

{-| Fold that returns whether 'M.All' input values satisfy the predicate

    'all' terminates on the first value that fails the predicate.
-}
all :: (Monad m) => (a -> Bool) -> a -> Consumer' a (WriterT M.All m) ()
all predicate = go
  where
    go a =
        if (predicate a)
        then request () >>= go
        else lift $ tell (M.All False)
{-# INLINABLE all #-}

{-| Fold that returns whether 'M.Any' input value satisfies the predicate

    'any' terminates on the first value that satisfies the predicate.
-}
any :: (Monad m) => (a -> Bool) -> a -> Consumer' a (WriterT M.Any m) ()
any predicate = go
  where
    go a =
        if (predicate a)
        then lift $ tell (M.Any True)
        else request () >>= go
{-# INLINABLE any #-}

{-| Retrieve the 'M.First' input value

    'head' terminates on the first value it receives.
-}
head :: (Monad m) => a -> Consumer' a (WriterT (M.First a) m) ()
head a = lift $ tell $ M.First (Just a)
{-# INLINABLE head #-}

-- | Zip two 'Producer's
zip :: (Monad m)
    => (Producer   a     m r)
    -> (Producer      b  m r)
    -> (Producer' (a, b) m r)
zip = zipWith (,)
{-# INLINABLE zip #-}

-- | Zip two 'Producer's using the provided combining function
zipWith :: (Monad m)
    => (a -> b -> c)
    -> (Producer  a m r)
    -> (Producer  b m r)
    -> (Producer' c m r)
zipWith f = go
  where
    go p1 p2 = do
        e1 <- lift $ next p1
        case e1 of
            Left r         -> return r
            Right (a, p1') -> do
                e2 <- lift $ next p2
                case e2 of
                    Left r         -> return r
                    Right (b, p2') -> do
                        respond (f a b)
                        go p1' p2'
{-# INLINABLE zipWith #-}

{-| Transform a 'Consumer' to a 'Pipe' that reforwards all values further
    downstream
-}
tee :: (Monad m) => (() -> Consumer a m r) -> (() -> Pipe a a m r)
tee p () = evalStateP Nothing $ do
    r <- (up \>\ (hoist lift . p />/ dn)) ()
    ma <- lift get
    case ma of
        Nothing -> return ()
        Just a  -> respond a
    return r
  where
    up () = do
        ma <- lift get
        case ma of
            Nothing -> return ()
            Just a  -> respond a
        a <- request ()
        lift $ put (Just a)
        return a
    dn _ = return ()
{-# INLINABLE tee #-}

{-| Transform a unidirectional 'Pipe' to a bidirectional 'Pipe'

> generalize (f >-> g) = generalize f >-> generalize g
>
> generalize pull = pull
-}
generalize :: (Monad m) => (() -> Pipe a b m r) -> x -> Proxy x a x b m r
generalize p x0 = evalStateP x0 $ (up \>\ hoist lift . p />/ dn) ()
  where
    up () = do
        x <- lift get
        request x
    dn a = do
        x <- respond a
        lift $ put x
{-# INLINABLE generalize #-}