-- Required for Show instances
{-# LANGUAGE FlexibleContexts, UndecidableInstances #-}
-- Required more generally
{-# LANGUAGE MultiParamTypeClasses, FunctionalDependencies #-}

{-# OPTIONS_GHC -Wall -fwarn-tabs #-}
----------------------------------------------------------------
--                                                  ~ 2014.05.27
-- |
-- Module      :  Control.Unification.Types
-- Copyright   :  Copyright (c) 2007--2014 wren gayle romano
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
    -- * Unification terms
      UTerm(..)
    , freeze
    , unfreeze
    -- * Errors
    , UnificationFailure(..)
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
import Data.Monoid             (Monoid(..), (<>))
import Data.Foldable           (Foldable(..))
import Data.Traversable        (Traversable(..))
import Control.Applicative     (Applicative(..), (<$>), Alternative(..))
import Control.Monad           (MonadPlus(..))
import Control.Monad.Error     (Error(..))
----------------------------------------------------------------
----------------------------------------------------------------

-- TODO: incorporate Ed's cheaper free monads, at least as a view.

-- | The type of terms generated by structures @t@ over variables
-- @v@. The structure type should implement 'Unifiable' and the
-- variable type should implement 'Variable'.
--
-- The 'Show' instance doesn't show the constructors, in order to
-- improve legibility for large terms.
--
-- All the category theoretic instances ('Functor', 'Foldable',
-- 'Traversable',...) are provided because they are often useful;
-- however, beware that since the implementations must be pure,
-- they cannot read variables bound in the current context and
-- therefore can create incoherent results. Therefore, you should
-- apply the current bindings before using any of the functions
-- provided by those classes.

data UTerm t v
    = UVar  !v               -- ^ A unification variable.
    | UTerm !(t (UTerm t v)) -- ^ Some structure containing subterms.

instance (Show v, Show (t (UTerm t v))) => Show (UTerm t v) where
    showsPrec p (UVar  v) = showsPrec p v
    showsPrec p (UTerm t) = showsPrec p t

instance (Functor t) => Functor (UTerm t) where
    fmap f (UVar  v) = UVar  (f v)
    fmap f (UTerm t) = UTerm (fmap (fmap f) t)

instance (Foldable t) => Foldable (UTerm t) where
    foldMap f (UVar  v) = f v
    foldMap f (UTerm t) = foldMap (foldMap f) t

instance (Traversable t) => Traversable (UTerm t) where
    traverse f (UVar  v) = UVar  <$> f v
    traverse f (UTerm t) = UTerm <$> traverse (traverse f) t

-- Does this even make sense for UTerm? It'd mean (a->b) is a
-- variable type...
instance (Functor t) => Applicative (UTerm t) where
    pure                  = UVar
    UVar  a  <*> UVar  b  = UVar  (a b)
    UVar  a  <*> UTerm mb = UTerm (fmap a  <$> mb)
    UTerm ma <*> b        = UTerm ((<*> b) <$> ma)

-- Does this even make sense for UTerm? It may be helpful for
-- building terms at least; though bind is inefficient for that.
-- Should use the cheaper free...
instance (Functor t) => Monad (UTerm t) where
    return        = UVar
    UVar  v >>= f = f v
    UTerm t >>= f = UTerm ((>>= f) <$> t)

-- This really doesn't make sense for UTerm...
instance (Alternative t) => Alternative (UTerm t) where
    empty   = UTerm empty
    a <|> b = UTerm (pure a <|> pure b)

-- This really doesn't make sense for UTerm...
instance (Functor t, MonadPlus t) => MonadPlus (UTerm t) where
    mzero       = UTerm mzero
    a `mplus` b = UTerm (return a `mplus` return b)

-- There's also MonadTrans, MonadWriter, MonadReader, MonadState,
-- MonadError, MonadCont; which make even less sense for us. See
-- Ed Kmett's free package for the implementations.


-- | /O(n)/. Embed a pure term as a mutable term.
unfreeze :: (Functor t) => Fix t -> UTerm t v
unfreeze = UTerm . fmap unfreeze . unFix


-- | /O(n)/. Extract a pure term from a mutable term, or return
-- @Nothing@ if the mutable term actually contains variables. N.B.,
-- this function is pure, so you should manually apply bindings
-- before calling it.
freeze :: (Traversable t) => UTerm t v -> Maybe (Fix t)
freeze (UVar  _) = Nothing
freeze (UTerm t) = Fix <$> mapM freeze t


----------------------------------------------------------------
-- TODO: provide zipper context so better error messages can be generated.
--
-- | The possible failure modes that could be encountered in
-- unification and related functions. While many of the functions
-- could be given more accurate types if we used ad-hoc combinations
-- of these constructors (i.e., because they can only throw one of
-- the errors), the extra complexity is not considered worth it.
--
-- /Updated: 0.8.1/ added 'Functor', 'Foldable', and 'Traversable' instances.
data UnificationFailure t v
    
    = OccursIn v (UTerm t v)
        -- ^ A cyclic term was encountered (i.e., the variable
        -- occurs free in a term it would have to be bound to in
        -- order to succeed). Infinite terms like this are not
        -- generally acceptable, so we do not support them. In logic
        -- programming this should simply be treated as unification
        -- failure; in type checking this should result in a \"could
        -- not construct infinite type @a = Foo a@\" error.
        --
        -- Note that since, by default, the library uses visited-sets
        -- instead of the occurs-check these errors will be thrown
        -- at the point where the cycle is dereferenced\/unrolled
        -- (e.g., when applying bindings), instead of at the time
        -- when the cycle is created. However, the arguments to
        -- this constructor should express the same context as if
        -- we had performed the occurs-check, in order for error
        -- messages to be intelligable.
    
    | TermMismatch (t (UTerm t v)) (t (UTerm t v))
        -- ^ The top-most level of the terms do not match (according
        -- to 'zipMatch'). In logic programming this should simply
        -- be treated as unification failure; in type checking this
        -- should result in a \"could not match expected type @Foo@
        -- with inferred type @Bar@\" error.
    
    | UnknownError String
        -- ^ Required for the 'Error' instance, which in turn is
        -- required to appease @ErrorT@ in the MTL. We do not use
        -- this anywhere.


-- Can't derive this because it's an UndecidableInstance
instance (Show (t (UTerm t v)), Show v) =>
    Show (UnificationFailure t v)
    where
    showsPrec p (OccursIn v t) =
        showParen (p > 9)
            ( showString "OccursIn "
            . showsPrec 11 v
            . showString " "
            . showsPrec 11 t
            )
    showsPrec p (TermMismatch tl tr) =
        showParen (p > 9)
            ( showString "TermMismatch "
            . showsPrec 11 tl
            . showString " "
            . showsPrec 11 tr
            )
    showsPrec p (UnknownError msg) =
        showParen (p > 9)
            ( showString "UnknownError: "
            . showString msg
            )

instance Error (UnificationFailure t v) where
    noMsg  = UnknownError ""
    strMsg = UnknownError


instance (Functor t) => Functor (UnificationFailure t) where
    fmap f (OccursIn v t)       = OccursIn (f v) (fmap f t)
    fmap f (TermMismatch tl tr) = TermMismatch (fmap f <$> tl) (fmap f <$> tr)
    fmap _ (UnknownError msg)   = UnknownError msg

instance (Foldable t) => Foldable (UnificationFailure t) where
    foldMap f (OccursIn v t)       = f v <> foldMap f t
    foldMap f (TermMismatch tl tr) = foldMap (foldMap f) tl
                                  <> foldMap (foldMap f) tr
    foldMap _ (UnknownError _)     = mempty

instance (Traversable t) => Traversable (UnificationFailure t) where
    traverse f (OccursIn v t)       = OccursIn <$> f v <*> traverse f t
    traverse f (TermMismatch tl tr) = TermMismatch <$> traverse (traverse f) tl 
                                                   <*> traverse (traverse f) tr
    traverse _ (UnknownError msg)   = pure (UnknownError msg)

----------------------------------------------------------------

-- | An implementation of syntactically unifiable structure. The
-- @Traversable@ constraint is there because we also require terms
-- to be functors and require the distributivity of 'sequence' or
-- 'mapM'.
class (Traversable t) => Unifiable t where
    
    -- | Perform one level of equality testing for terms. If the
    -- term constructors are unequal then return @Nothing@; if they
    -- are equal, then return the one-level spine filled with
    -- resolved subterms and\/or pairs of subterms to be recursively
    -- checked.
    zipMatch :: t a -> t a -> Maybe (t (Either a (a,a)))


-- | An implementation of unification variables. The 'Eq' requirement
-- is to determine whether two variables are equal /as variables/,
-- without considering what they are bound to. We use 'Eq' rather
-- than having our own @eqVar@ method so that clients can make use
-- of library functions which commonly assume 'Eq'.
class (Eq v) => Variable v where
    
    -- | Return a unique identifier for this variable, in order to
    -- support the use of visited-sets instead of occurs-checks.
    -- This function must satisfy the following coherence law with
    -- respect to the 'Eq' instance:
    --
    -- @x == y@ if and only if @getVarID x == getVarID y@
    getVarID :: v -> Int


----------------------------------------------------------------

-- | The basic class for generating, reading, and writing to bindings
-- stored in a monad. These three functionalities could be split
-- apart, but are combined in order to simplify contexts. Also,
-- because most functions reading bindings will also perform path
-- compression, there's no way to distinguish \"true\" mutation
-- from mere path compression.
--
-- The superclass constraints are there to simplify contexts, since
-- we make the same assumptions everywhere we use @BindingMonad@.

class (Unifiable t, Variable v, Applicative m, Monad m) =>
    BindingMonad t v m | m -> t v
    where
    
    -- | Given a variable pointing to @UTerm t v@, return the
    -- term it's bound to, or @Nothing@ if the variable is unbound.
    lookupVar :: v -> m (Maybe (UTerm t v))
    
    
    -- | Generate a new free variable guaranteed to be fresh in
    -- @m@.
    freeVar :: m v
    
    
    -- | Generate a new variable (fresh in @m@) bound to the given
    -- term. The default implementation is:
    --
    -- > newVar t = do { v <- freeVar ; bindVar v t ; return v }
    newVar :: UTerm t v -> m v
    newVar t = do { v <- freeVar ; bindVar v t ; return v }
    
    
    -- | Bind a variable to a term, overriding any previous binding.
    bindVar :: v -> UTerm t v -> m ()


----------------------------------------------------------------
-- | The target of variables for 'RankedBindingMonad's. In order
-- to support weighted path compression, each variable is bound to
-- both another term (possibly) and also a \"rank\" which is related
-- to the length of the variable chain to the term it's ultimately
-- bound to.
--
-- The rank can be at most @log V@, where @V@ is the total number
-- of variables in the unification problem. Thus, A @Word8@ is
-- sufficient for @2^(2^8)@ variables, which is far more than can
-- be indexed by 'getVarID' even on 64-bit architectures.
data Rank t v =
    Rank {-# UNPACK #-} !Word8 !(Maybe (UTerm t v))

-- Can't derive this because it's an UndecidableInstance
instance (Show v, Show (t (UTerm t v))) => Show (Rank t v) where
    show (Rank n mb) = "Rank "++show n++" "++show mb

-- TODO: flatten the Rank.Maybe.UTerm so that we can tell that if semiprune returns a bound variable then it's bound to a term (not another var)?

{-
instance Monoid (Rank t v) where
    mempty = Rank 0 Nothing
    mappend (Rank l mb) (Rank r _) = Rank (max l r) mb
-}


-- | An advanced class for 'BindingMonad's which also support
-- weighted path compression. The weightedness adds non-trivial
-- implementation complications; so even though weighted path
-- compression is asymptotically optimal, the constant factors may
-- make it worthwhile to stick with the unweighted path compression
-- supported by 'BindingMonad'.
class (BindingMonad t v m) => RankedBindingMonad t v m | m -> t v where
    
    -- | Given a variable pointing to @UTerm t v@, return its
    -- rank and the term it's bound to.
    lookupRankVar :: v -> m (Rank t v)
    
    -- | Increase the rank of a variable by one.
    incrementRank :: v -> m ()
    
    -- | Bind a variable to a term and increment the rank at the
    -- same time. The default implementation is:
    --
    -- > incrementBindVar t v = do { incrementRank v ; bindVar v t }
    incrementBindVar :: v -> UTerm t v -> m ()
    incrementBindVar v t = do { incrementRank v ; bindVar v t }

----------------------------------------------------------------
----------------------------------------------------------- fin.
