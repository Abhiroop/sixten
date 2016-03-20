{-# LANGUAGE DeriveFoldable, DeriveFunctor, DeriveTraversable, Rank2Types, ViewPatterns #-}
module Syntax.Abstract where

import Control.Monad
import Data.Bifunctor
import qualified Data.Foldable as Foldable
import Data.Monoid
import qualified Data.Set as S
import Data.String
import Prelude.Extras

import Syntax
import Util

-- | Expressions with variables of type @v@.
data Expr v
  = Var v
  | Global Name
  | Con QConstr
  | Lit Literal
  | Pi  !NameHint !Annotation (Type v) (Scope1 Expr v)
  | Lam !NameHint !Annotation (Type v) (Scope1 Expr v)
  | App  (Expr v) !Annotation (Expr v)
  | Case (Expr v) (Branches QConstr Expr v)
  deriving (Eq, Foldable, Functor, Ord, Show, Traversable)

-- | Synonym for documentation purposes
type Type = Expr

-------------------------------------------------------------------------------
-- * Views and smart constructors
pi_ :: Name -> Annotation -> Type Name -> Expr Name -> Expr Name
pi_ n p t e = Pi (Hint $ Just n) p t $ abstract1 n e

lam :: Name -> Annotation -> Type Name -> Expr Name -> Expr Name
lam n p t e = Lam (Hint $ Just n) p t $ abstract1 n e

etaLam :: Hint (Maybe Name) -> Annotation -> Expr v -> Scope1 Expr v -> Expr v
etaLam _ p _ (Scope (App e p' (Var (B ()))))
  | B () `S.notMember` toSet (second (const ()) <$> e) && p == p'
    = join $ unvar (error "etaLam impossible") id <$> e
etaLam n p t s = Lam n p t s

piView :: Expr v -> Maybe (NameHint, Annotation, Type v, Scope1 Expr v)
piView (Pi n p e s) = Just (n, p, e, s)
piView _            = Nothing

usedPiView :: Expr v -> Maybe (NameHint, Annotation, Type v, Scope1 Expr v)
usedPiView (Pi n p e s@(unusedScope -> Nothing)) = Just (n, p, e, s)
usedPiView _                                     = Nothing

lamView :: Expr v -> Maybe (NameHint, Annotation, Type v, Scope1 Expr v)
lamView (Lam n p e s) = Just (n, p, e, s)
lamView _             = Nothing

appsView :: Expr v -> (Expr v, [(Annotation, Expr v)])
appsView = second reverse . go
  where
    go (App e1 p e2) = second ((p, e2) :) $ go e1
    go e = (e, [])

arrow :: Annotation -> Expr v -> Expr v -> Expr v
arrow p a b = Pi (Hint Nothing) p a $ Scope $ pure $ F b

betaApp :: Expr v -> Annotation -> Expr v -> Expr v
betaApp e1@(Lam _ p1 _ s) p2 e2 | p1 == p2 = case bindings s of
  []  -> instantiate1 e2 s
  [_] -> instantiate1 e2 s
  _   -> App e1 p1 e2
betaApp e1 p e2 = App e1 p e2

apps :: Foldable t => Expr v -> t (Annotation, Expr v) -> Expr v
apps = Foldable.foldl (uncurry . App)

globals :: Expr v -> Expr (Var Name v)
globals expr = case expr of
  Var v       -> Var $ F v
  Global g    -> Var $ B g
  Con c       -> Con c
  Lit l       -> Lit l
  Pi  x p t s -> Pi x p (globals t) (exposeScope globals s)
  Lam x p t s -> Lam x p (globals t) (exposeScope globals s)
  App e1 p e2 -> App (globals e1) p (globals e2)
  Case e brs  -> Case (globals e) (exposeBranches globals brs)

telescope :: Expr v -> Telescope Expr v
telescope (bindingsView piView -> (tele, _)) = tele

-------------------------------------------------------------------------------
-- Instances
instance Eq1 Expr
instance Ord1 Expr
instance Show1 Expr

instance Applicative Expr where
  pure = return
  (<*>) = ap

instance Monad Expr where
  return = Var
  expr >>= f = case expr of
    Var v       -> f v
    Global g    -> Global g
    Con c       -> Con c
    Lit l       -> Lit l
    Pi  x p t s -> Pi x p (t >>= f) (s >>>= f)
    Lam x p t s -> Lam x p (t >>= f) (s >>>= f)
    App e1 p e2 -> App (e1 >>= f) p (e2 >>= f)
    Case e brs  -> Case (e >>= f) (brs >>>= f)

instance (Eq v, IsString v, Pretty v) => Pretty (Expr v) where
  prettyM expr = case expr of
    Var v     -> prettyM v
    Global g  -> prettyM g
    Con c     -> prettyM c
    Lit l     -> prettyM l
    Pi  _ a t (unusedScope -> Just e) -> parens `above` arrPrec $
      (prettyAnnotation a $ prettyM t)
      <+> prettyM "->" <+>
      associate arrPrec (prettyM e)
    (bindingsViewM usedPiView -> Just (tele, s)) -> withTeleHints tele $ \ns ->
      parens `above` absPrec $
      prettyM "forall" <+> prettyTeleVarTypes ns tele <> prettyM "." <+>
      prettyM (instantiateTele (pure . fromText <$> ns) s)
    Pi {} -> error "impossible prettyPrec pi"
    (bindingsViewM lamView -> Just (tele, s)) -> withTeleHints tele $ \ns ->
      parens `above` absPrec $
      prettyM "\\" <> prettyTeleVarTypes ns tele <> prettyM "." <+>
      prettyM (instantiateTele (pure . fromText <$> ns) s)
    Lam {} -> error "impossible prettyPrec lam"
    App e1 a e2 -> prettyApp (prettyM e1) (prettyAnnotation a $ prettyM e2)
    Case e brs -> parens `above` casePrec $
      prettyM "case" <+> inviolable (prettyM e) <+> prettyM "of" <$$> indent 2 (prettyM brs)
