-- Required for Show (MutTerm v t) instance
{-# LANGUAGE FlexibleContexts, UndecidableInstances #-}
-- Required more generally
{-# LANGUAGE MultiParamTypeClasses, FunctionalDependencies #-}

{-# OPTIONS_GHC -Wall -fwarn-tabs #-}

----------------------------------------------------------------
--                                                  ~ 2011.07.06
-- |
-- Module      :  Control.Unification.Types
-- Copyright   :  Copyright (c) 2007--2011 wren ng thornton
-- License     :  BSD
-- Maintainer  :  wren@community.haskell.org
-- Stability   :  experimental
-- Portability :  semi-portable (MPTCs, fundeps,...)
--
-- This module defines the classes and primitive types used by
-- unification and related functions.
----------------------------------------------------------------
module Control.Unification.Types
    (
    -- * Mutable terms
      MutTerm(..)
    , freeze
    , unfreeze
    -- * Basic type classes
    , Unifiable(..)
    , Variable(..)
    , BindingMonad(..)
    -- * Weighted path compression
    , Rank(..)
    , RankedBindingMonad(..)
    ) where

import Prelude hiding (mapM, sequence, foldr, foldr1, foldl, foldl1)

import Data.Word               (Word8)
import Data.Functor.Fixedpoint (Fix(..))
import Data.Traversable        (Traversable(..))
import Control.Applicative     (Applicative(..), (<$>))
----------------------------------------------------------------
----------------------------------------------------------------

-- | The type of terms generated by structures @t@ over variables
-- @v@. The structure type should implement 'Unifiable' and the
-- variable type should implement 'Variable'. The 'Show' instance
-- doesn't show the constructors, for legibility.
data MutTerm v t
    = MutVar  !(v (MutTerm v t))
    | MutTerm !(t (MutTerm v t))

instance (Show (v (MutTerm v t)), Show (t (MutTerm v t))) =>
    Show (MutTerm v t)
    where
    show (MutVar  v) = show v
    show (MutTerm t) = show t


-- | /O(n)/. Embed a pure term as a mutable term.
unfreeze :: (Functor t) => Fix t -> MutTerm v t
unfreeze = MutTerm . fmap unfreeze . unFix


-- | /O(n)/. Extract a pure term from a mutable term, or return
-- @Nothing@ if the mutable term actually contains variables. N.B.,
-- this function is pure, so you should manually apply bindings
-- before calling it; cf., 'freezeM'.
freeze :: (Traversable t) => MutTerm v t -> Maybe (Fix t)
freeze (MutVar  _) = Nothing
freeze (MutTerm t) = Fix <$> mapM freeze t


----------------------------------------------------------------

-- | An implementation of syntactically unifiable structure.
class (Traversable t) => Unifiable t where
    -- | Perform one level of equality testing for terms. If the
    -- term constructors are unequal then return @Nothing@; if they
    -- are equal, then return the one-level spine filled with pairs
    -- of subterms to be recursively checked.
    zipMatch :: t a -> t b -> Maybe (t (a,b))


-- | An implementation of unification variables.
class Variable v where
    -- | Determine whether two variables are equal /as variables/,
    -- without considering what they are bound to.
    eqVar :: v a -> v b -> Bool
    eqVar x y = getVarID x == getVarID y
    
    -- | Return a unique identifier for this variable, in order to
    -- support the use of visited-sets instead of occurs-checks.
    getVarID :: v a -> Int


----------------------------------------------------------------

-- | The basic class for generating, reading, and writing to bindings
-- stored in a monad. These three functionalities could be split
-- apart, but are combined in order to simplify contexts. Also,
-- because most functions reading bindings will also perform path
-- compression, there's no way to distinguish ``true'' mutation
-- from mere path compression.

class (Unifiable t, Variable v, Applicative m, Monad m) =>
    BindingMonad v t m | m -> v t
    where
    
    -- | Given a variable pointing to @t@, return the @t@ it's bound
    -- to (or @Nothing@ if the variable is unbound).
    lookupVar :: v (MutTerm v t) -> m (Maybe (MutTerm v t))

    -- | Generate a new free variable guaranteed to be fresh in
    -- @m@.
    freeVar :: m (v (MutTerm v t))
    
    -- | Generate a new variable (fresh in @m@) bound to the given
    -- term.
    newVar :: MutTerm v t -> m (v (MutTerm v t))
    newVar t = do { v <- freeVar ; bindVar v t ; return v }
    
    -- | Bind a variable to a term, overriding any previous binding.
    bindVar :: v (MutTerm v t) -> MutTerm v t -> m ()


----------------------------------------------------------------
-- | The target of variables for 'RankedBindingMonad's. In order
-- to support weighted path compression, each variable is bound to
-- both another term (possibly) and also a ``rank'' which is related
-- to the length of the variable chain to the term it's ultimately
-- bound to.
--
-- The rank can be at most @log V@, where @V@ is the total number
-- of variables in the unification problem. Thus, A @Word8@ is
-- sufficient for @2^(2^8)@ variables, which is far more than can
-- be indexed by 'getVarID' even on 64-bit architectures.
data Rank v t =
    Rank {-# UNPACK #-} !Word8 !(Maybe (MutTerm v t))

-- Can't derive this because it's an UndecidableInstance
instance (Show (v (MutTerm v t)), Show (t (MutTerm v t))) =>
    Show (Rank v t)
    where
    show (Rank n mb) = "Rank "++show n++" "++show mb

-- TODO: flatten the Rank.Maybe.MutTerm so that we can tell that if semiprune returns a bound variable then it's bound to a term (not another var)?

{-
instance Monoid (Rank v t) where
    mempty = Rank 0 Nothing
    mappend (Rank l mb) (Rank r _) = Rank (max l r) mb
-}


-- | An advanced class for 'BindingMonad's which also support
-- weighted path compression. The weightedness adds non-trivial
-- implementation complications; so even though weighted path
-- compression is asymptotically optimal, the constant factors may
-- make it worthwhile to stick with the unweighted path compression
-- supported by 'BindingMonad'.

class (BindingMonad v t m) => RankedBindingMonad v t m | m -> v t where
    -- | Given a variable pointing to @t@, return its rank and the
    -- @t@ it's bound to (or @Nothing@ if the variable is unbound).
    lookupRankVar :: v (MutTerm v t) -> m (Rank v t)
    
    -- | Increase the rank of a variable by one.
    incrementRank :: v (MutTerm v t) -> m ()
    
    -- | Bind a variable to a term and increment the rank at the same time.
    incrementBindVar :: v (MutTerm v t) -> MutTerm v t -> m ()
    incrementBindVar v t = do { incrementRank v ; bindVar v t }

----------------------------------------------------------------
----------------------------------------------------------- fin.
