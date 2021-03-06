module Block.Bridge where

import Prelude
import Data.Monoid
import Data.Array (updateAt, deleteAt, modifyAt, head, length)
import Data.Tuple
import Data.Maybe (fromMaybe, maybe, Maybe(..))

import Block.Data
import Block.Data as D
import Block.TypeChecker
import Block.TypeChecker as TC


-- default :: Array Statement
-- default = [BindStmt [Bind ()]]

main_module :: Statements
main_module = typeChecks prelude [BindStmt [Bind baz hoge],
                                  BindStmt [Bind foo $ app (epure $ Var "negate") one]]

prelude :: Statements
prelude = typeChecks []
    [BindStmt [Bind (epure $ Var "one") (epure $ Num 0)]] <>
    [BindStmt [Bind (idefault (spure $ arrow (tpure $ Id "Int") (tpure $ Id "Int")) (Var "negate")) eempty],
     -- BindStmt [Bind (idefault (spure (tpure $ TVar $ Named "a")) (Var "hoge")) eempty],
     BindStmt [Bind (idefault int2 (Oper (idefault int2 $ Var "+") Nothing Nothing)) eempty],
     BindStmt [Bind (idefault int2 (Oper (idefault int2 $ Var "-") Nothing Nothing)) eempty],
     BindStmt [Bind (idefault int2 (Oper (idefault int2 $ Var "*") Nothing Nothing)) eempty],
     BindStmt [Bind (idefault int2bool (Oper (idefault int2bool $ Var "==") Nothing Nothing)) eempty],
     BindStmt [Bind (idefault int2bool (Oper (idefault int2bool $ Var "=<") Nothing Nothing)) eempty],
     BindStmt [Bind (idefault int2bool (Oper (idefault int2bool $ Var ">=") Nothing Nothing)) eempty]]

sampleExprs :: Array Expr
sampleExprs = [idefault intS (Num 0),
               idefault (spure $ arrow ta tb) (Lambda [ea] ebe),
               idefault ta' $ If (idefault (spure' $ Id "Bool") Empty) eae eae,
               idefault tb' $ Case eae [Tuple ea ebe],
               idefault tb' $ Let [Bind ea eae] ebe]

ta = tpure $ TVar $ Named "a"
tb = tpure $ TVar $ Named "b"
ta' = spure ta
tb' = spure tb
ea  = idefault ta' $ Var "a"
eae = idefault ta' Empty
ebe = idefault tb' Empty
-- eb = idefault tb' Empty

exprB = epure $ App exprA (epure $ Var "fuga")
exprA = epure $ App (epure $ Var "hoge") (epure $ Num 0)
bar = epure $ App (epure $ Var "bar") (epure $ Var "x")
foo = epure $ App (epure $ Var "foo") (epure $ Var "y")
baz = toApp (epure $ Var "baz") [epure $ Var "f", epure $ Var "x"]
hoge = epure $ App (epure $ Var "f") (epure $ Var "x")
one = epure $ Num 1
operA = epure $ Oper (epure $ Var "+") Nothing Nothing
int2 = spure $ arrow intT $ arrow intT intT
int2bool = spure $ arrow intT $ arrow intT boolT
intT = tpure $ Id "Int"
boolT = tpure $ Id "Bool"
intS = spure intT

app a b = epure $ App a b
spure' = spure <<< tpure

typeChecks = TC.typeChecks
typeCheck  = TC.typeCheck

appToArray :: Expr -> Array Expr
appToArray = appToArray_

tappToArray :: Type -> Array Type
tappToArray = tappToArray_

arrowToArray :: Type -> Array Type
arrowToArray = arrowToArray_

toApp :: Expr -> Array Expr -> Expr
toApp = D.toApp

spure = D.spure
eempty = D.eempty

pempty :: Expr
pempty = epure $ Var "_"
aempty :: Tuple Expr Expr
aempty = Tuple pempty D.eempty
bempty :: Bind
bempty = Bind (epure $ Var "a") D.eempty

bindStmtVar :: Statement -> Expr
bindStmtVar s = case s of
    BindStmt bs -> maybe eempty bindVar $ head bs

assignExpr :: Expr -> Expr -> Expr
assignExpr a@(Info ae sx _) b@(Info be sy _) = case ae of
    Empty | match a b -> b
    Empty -> let n = length $ arrowToArray_ $ typeOf a
                 m = length $ arrowToArray_ $ typeOf b
             in fillExpr (m - n) b
    _ -> case be of
        Lambda as c | isEmpty c -> epure $ Lambda as a
        Oper o Nothing e -> epure $ Oper o (Just a) e
        Oper o d Nothing -> epure $ Oper o d (Just a)
        Oper o (Just d) e | isEmpty d -> epure $ Oper o (Just a) e
        Oper o d (Just e) | isEmpty e -> epure $ Oper o d (Just a)
        If c d e | isEmpty c && match a c -> epure $ If a d e
                 | isEmpty d -> epure $ If c a e
                 | isEmpty e -> epure $ If c d a
        _ | isArrow sy -> app b a
        _ -> b
    where
        assign :: Expr -> Expr -> Expr
        assign x@(Info ex _ _) y = case ex of
            Empty | match x y -> y
            Empty -> let n = length $ arrowToArray_ $ typeOf x
                         m = length $ arrowToArray_ $ typeOf y
                     in fillExpr (m - n) y
            _ -> y

        isArrow :: Scheme -> Boolean
        isArrow (Forall _ t) = case t of
            Info (TOper "->" _ _) _ _ -> true
            _                         -> false
        isEmpty :: Expr -> Boolean
        isEmpty (Info Empty _ _) = true
        isEmpty _                = false

        match :: Expr -> Expr -> Boolean
        match ax bx = typeOf ax `matchTypes` typeOf bx

fillExprWith :: Int -> Expr -> Expr -> Expr
fillExprWith 0 a f = app f a
fillExprWith i a f = app (fillExprWith (i - 1) D.eempty f) a

fillExpr :: Int -> Expr -> Expr
fillExpr 0 a = a
fillExpr i a =
    let a'@(Info e sc i) = fillExpr (i - 1) a
    in case e of
        Oper o Nothing  Nothing -> Info (Oper o (Just D.eempty) Nothing) sc i
        Oper o (Just x) Nothing -> Info (Oper o (Just x) (Just D.eempty)) sc i
        Oper o Nothing (Just y) -> Info (Oper o (Just D.eempty) (Just y)) sc i
        _ -> app a' D.eempty

econs :: ExprA -> String
econs e = case e of
    Var _      -> "var"
    App _ _    -> "app"
    Num _      -> "num"
    Lambda _ _ -> "lam"
    Oper _ _ _ -> "ope"
    If _ _ _   -> "ift"
    Case _ _   -> "cas"
    Let _ _    -> "let"
    Empty      -> "emp"

tcons :: TypeA -> String
tcons t = case t of
    Id _     -> "id"
    TVar _   -> "var"
    TOper _ _ _ -> "ope"
    -- Arrow    -> "arr"
    -- TApp (Info (TApp (Info Arrow _ _) _) _ _) _ -> "arr"
    TApp _ _ -> "app"
    Unknown  -> "unk"

errcons :: Error -> String
errcons e = case e of
  EOutOfScopeVar _ -> "var"
  EMisMatch _ _    -> "match"
  EOccursCheck _ _ -> "occurs"

renewI :: forall a. Int -> a -> Array a -> Array a
renewI i x xs = fromMaybe xs $ updateAt i x xs

deleteI :: forall a. Int -> Array a -> Array a
deleteI i xs = fromMaybe xs $ deleteAt i xs

renewBindStmt :: Int -> Bind -> Statement -> Statement
renewBindStmt i b (BindStmt bs) = BindStmt $ renewI i b bs

renewLeft :: Expr -> Bind -> Bind
renewLeft l (Bind _ r) = Bind l r

renewRight :: Expr -> Bind -> Bind
renewRight r (Bind l _) = Bind l r

renewExpr :: ExprA -> Expr -> Expr
renewExpr e (Info _ t i) = Info e t i

renewArgs :: Int -> Expr -> Array Expr -> Expr -> Expr
renewArgs i a as b = toApp b $ renewI i a as

deleteArg :: Int -> Array Expr -> Expr -> Expr
deleteArg i as b = toApp b $ fromMaybe as $ deleteAt i as

renewLambda :: Int -> Expr -> Array Expr -> Expr -> Expr
renewLambda i a as b = epure $ Lambda (renewI i a as) b

deleteLambda :: Int -> Array Expr -> Expr -> Expr
deleteLambda i as b = lambdaC (fromMaybe as $ deleteAt i as) b

renewFirsts  :: forall a b. Int -> a -> Array (Tuple a b) -> Array (Tuple a b)
renewFirsts i a ts  = fromMaybe ts $ modifyAt i (\(Tuple _ b) -> Tuple a b) ts

renewSeconds :: forall a b. Int -> b -> Array (Tuple a b) -> Array (Tuple a b)
renewSeconds i b ts = fromMaybe ts $ modifyAt i (\(Tuple a _) -> Tuple a b) ts

appC    = App
varC    = Var
numC    = Num
ifC     = If
caseC   = Case
caseAltC = Tuple
letC    = Let
operC o a b = Oper o (Just a) (Just b)
operC0 o   = Oper o Nothing Nothing
operCA o a = Oper o (Just a) Nothing
operCB o b = Oper o Nothing (Just b)
lambdaC [] b = b
lambdaC as b = epure $ Lambda as b
