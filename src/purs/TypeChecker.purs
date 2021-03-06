module Block.TypeChecker where

import Prelude
import Control.Monad.Trans.Class (lift)
import Control.Monad.Reader.Class (ask, local)
import Control.Monad.Reader (Reader, ReaderT, runReader, runReaderT)
import Control.Monad.State (StateT, evalStateT, runStateT, get, put, modify)
import Data.Foldable (or)
import Data.Traversable (class Traversable, sequence)
import Data.Monoid (class Monoid, mempty)
import Data.Tuple (Tuple(..))
import Data.Array ((:), (\\), cons, snoc, unzip, uncons, foldr, head, toUnfoldable, elem, union, concatMap, null)
import Data.Array.NonEmpty as NE
import Data.List as L
import Data.Maybe (Maybe(..), maybe, fromMaybe)
import Data.Map as Map
import Data.String (charAt, singleton, charCodeAt)
import Data.Char (fromCharCode)


import Block.Data
import Block.Debug

--------------------------------------------------------------------------------

type Interpreter = Reader Envir
-- type Envir = {binds :: Map String Scheme,
--               classes :: Map String {class :: Constraint,
--                                      members :: Map String {expr :: Expr, scheme :: Scheme, define :: Boolean}},
--               instances :: Map String (Array Scheme),
--               vars :: Map String Type}

type Envir = Map.Map String Scheme

type Infer = StateT TypeEnv Interpreter
type TypeEnv = {tvars :: Map.Map TVar Type, temp :: Int}

-- type Unifier = StateT TypeEnv Infer



-- infer :: forall a. Statements -> Infer a -> Interpreter a
-- infer ss m = evalStateT (runReader m ss) {tvars: Map.empty, temp: 0}

--------------------------------------------------------------------------------

interpret :: forall a. Envir -> Interpreter a -> a
interpret = flip runReader

infer :: forall a. Infer a -> Interpreter a
infer m = do
    Tuple a s <- runStateT m {tvars: Map.empty, temp: 0}
    pure $ trace (Map.toUnfoldable s.tvars :: Array (Tuple TVar Type)) a

localEnv :: forall a. Envir -> Infer a -> Infer a
localEnv env = local ((<>) env)

backtrackUntil :: forall a. (a -> a -> Boolean) -> (a -> Infer a) -> a -> Infer a
backtrackUntil p f a = do
    tenv <- get
    a' <- f a
    if p a a'
        then pure a'
        else do
            put tenv
            backtrackUntil p f a'

getBind :: String -> Infer (Maybe Scheme)
getBind s = Map.lookup s <$> ask

-- newTVarT :: Infer Type
-- newTVarT = (\s -> Type (TVar s) Base []) <$> newTVarS

--------------------------------------------------------------------------------

typeChecks :: Statements -> Statements -> Statements
typeChecks lib ss =
    let ss' = interpret (traceId $ mconcat $ map envirs $ lib <> ss) $ mapM inferStmt ss
            -- unzip $ map (typeCheck (lib <> ss) >>>
            --              \{s: s, updated: u} -> Tuple s u) ss
    in
        -- if map envirs ss /= map envirs ss' then typeChecks lib ss' else ss'

        trace {old: (Map.toUnfoldable $ mconcat $ map envirs ss) :: Array _,
               new: (Map.toUnfoldable $ mconcat $ map envirs ss') :: Array _,
               updated: map envirs ss /= map envirs ss'} ss'

typeCheck :: Statements -> Statements -> Statement -> {s :: Statement, updated :: Boolean}
typeCheck lib ss s =
    let s' = interpret (mconcat $ map envirs $ lib <> ss) $ inferStmt s
    in  {s: s', updated: (envirs s /= envirs s')}

matchTypes :: Type -> Type -> Boolean
matchTypes a b = let {infos: Infos i} = interpret Map.empty $ infer $ unify a b
                 in  null i.errors

inferStmt :: Statement -> Interpreter Statement
inferStmt st = case st of
    BindStmt bs -> BindStmt <$> infer (mapM (inferBind >=> showTypes) bs)

inferBind :: Bind -> Infer Bind
inferBind x@(Bind a b) = do
    let {head: Info e _ _, tail: as} = NE.uncons $ operToArray a
    tv <- newTVarT
    {args: as', expr: b', infos: i} <-
        localEnv (binds' (spure tv) x) $ inferLambda tv as b

    traceWith "bind" {tv: tv, i: i} pure $ Bind (appBindVar (Info e (spure tv) i) as') b'
  where
    appBindVar :: Expr -> Array Expr -> Expr
    appBindVar = toApp

inferBinds :: Array Bind -> Infer (Array Bind)
inferBinds = backtrackUntil
    (\bs bs' -> map binds bs == map binds bs')
    -- (\bs bs' -> true)
    (\bs -> do
        tvs <- tvars
        sequence $ mapWithOthers (\b xs ->
            let env = map (generalize tvs) $ mconcat $ map binds xs
            in  localEnv env $ inferBind b >>= showTypes) bs )
        -- env <- mapM generalize $ mconcat $ map binds bs
        -- localEnv env $ mapM (inferBind >=> showTypes) xs)
    -- if map binds bs == map binds bs' then pure bs' else inferBinds bs'

inferLambda :: Type -> Array Expr -> Expr -> Infer {args :: Array Expr, expr :: Expr, type :: Type, infos :: Infos}
inferLambda t as b = case uncons as of
    Just {head: a, tail: bs} -> do
        ta <- newTVarT
        tb <- newTVarT
        a' <- inferParam ta a
        {type: t', infos: j} <- unify t (arrow ta tb)
        {args: bs', expr: b', infos: i} <-
            localEnv (paramVars a') $ inferLambda tb bs b
        pure {args: a':bs', expr: b', type: t', infos: i <> j}
    Nothing -> do
        b' <- inferExpr t b
        pure {args: as, expr: b', type: t, infos: mempty}
    -- case uncons as of
    --     Just {head: a, tail: as'} -> do

inferParam :: Type -> Expr -> Infer Expr
inferParam t (Info e _ _) = pure $ Info e (spure t) mempty

inferExpr :: Type -> Expr -> Infer Expr
inferExpr t (Info e _ _) = case e of
    Var s -> do
        ms <- getBind s
        case ms of
            Just sc -> do
                ts <- instantiate sc
                {type: t', infos: i} <- unify t ts
                pure $ Info e (spure t') i
            Nothing -> traceWith "error" s $ pure $ Info e (spure t) (Infos{ errors: [EOutOfScopeVar s] })
    -- App a b -> do
    --     ta <- newTVarT
    --     tb <- newTVarT
    --     a' <- inferExpr (arrow tb t) a
    --     b' <- inferExpr tb b
    --     pure $ idefault (spure t) $ App a' b'
    App f a -> do
        tp <- newTVarT
        f' <- inferExpr (arrow tp t) f
        a' <- inferExpr tp a
        pure $ idefault (spure t) $ App f' a'
    Lambda as b -> do
        {args: as', expr: b', type: t', infos: i} <- inferLambda t as b
        pure $ Info (Lambda as' b') (spure t') i
    Num _ -> do
        {type: t', infos: i} <- unify t $ tpure (Id "Int")
        pure $ Info e (spure t') i
    If c a b -> do
        c' <- inferExpr (tpure $ Id "Bool") c
        a' <- inferExpr t a
        b' <- inferExpr t b
        pure $ idefault (spure t) $ If c' a' b'
    Case a as -> do
        tv  <- newTVarT
        a'  <- inferExpr tv a
        as' <- forM as \(Tuple p b) -> do
            p' <- inferParam tv p
            b' <- localEnv (paramVars p') $ inferExpr t b
            pure $ Tuple p' b'
        pure $ idefault (spure t) $ Case a' as'
    Let bs a -> do
        tvs <- tvars
        bs' <- inferBinds bs
        tvs' <- currentTVars tvs
        let env = map (generalize tvs') $ mconcat $ map binds bs'
        -- env <- mapM generalize $ mconcat $ map binds bs'
        a' <- localEnv env $ inferExpr t a
        pure $ idefault (spure t) $ Let bs' a'
    Oper o (Just a) (Just b) -> do
        tp0 <- newTVarT
        tp1 <- newTVarT
        o'  <- inferExpr (arrow tp0 $ arrow tp1 t) o
        a'  <- inferExpr tp0 a
        b'  <- inferExpr tp1 b
        pure $ idefault (spure t) $ Oper o' (Just a') (Just b')
    Oper o (Just a) Nothing -> do
        tp0 <- newTVarT
        tp1 <- newTVarT
        tr  <- newTVarT
        {type: t', infos: i} <- unify t $ arrow tp1 tr
        o'  <- inferExpr (arrow tp0 t') o
        a'  <- inferExpr tp0 a
        pure $ Info (Oper o' (Just a') Nothing) (spure t') i
    Oper o Nothing (Just b) -> do
        tp0 <- newTVarT
        tp1 <- newTVarT
        tr  <- newTVarT
        {type: t', infos: i} <- unify t $ arrow tp0 tr
        o'  <- inferExpr (arrow tp0 $ arrow tp1 tr) o
        b'  <- inferExpr tp1 b
        pure $ Info (Oper o' Nothing (Just b')) (spure t') i
    Oper o Nothing Nothing -> do
        tp0 <- newTVarT
        tp1 <- newTVarT
        tr  <- newTVarT
        {type: t', infos: i} <- unify t $ arrow tp0 $ arrow tp1 tr
        o' <- inferExpr t' o
        pure $ Info (Oper o' Nothing Nothing) (spure t') i
    Empty -> pure $ idefault (spure t) e

--------------------------------------------------------------------------------

envirs :: Statement -> Envir
envirs s = case s of
    BindStmt bs -> maybe mempty (binds >>> map generalize') $ head bs

binds :: Bind -> Envir
binds b = let Info e sc _ = bindVar b
          in Map.singleton (bindVarS b) sc
          -- case e of
          --     Var s -> Map.singleton s sc
          --     Oper (Info (Var s) _ _) _ _
          --           -> Map.singleton s sc
          --     _     -> Map.empty

binds' :: Scheme -> Bind -> Envir
binds' sc b = Map.singleton (bindVarS b) sc


-- extend :: forall a. String -> Scheme -> Infer a -> Infer a
-- extend s sc m = local (Map.insert s sc) m

paramVars :: Expr -> Envir
paramVars (Info e sc _) = case e of
    Var s | charAt 0 s == Just '_'
          -> Map.empty
    Var s -> Map.singleton s sc
    _     -> Map.empty

toScheme :: Type -> Infer Scheme
toScheme t = pure $ spure t

--------------------------------------------------------------------------------

newTVarT :: Infer Type
newTVarT = TVar >>> tpure <$> newTVar

newTVar :: Infer TVar
newTVar = do
    r <- get
    let s = Temp r.temp
    put $ r {tvars = Map.insert s tempty r.tvars,
             temp = r.temp + 1}
    pure s

newTVarOf :: TVar -> Infer Unit
newTVarOf v = do
    r <- get
    put $ r {tvars = Map.insert v tempty r.tvars}

getTVar :: TVar -> Infer Type
getTVar v = do
    r <- get
    pure $ maybe tempty id (Map.lookup v r.tvars)

assignTVar :: TVar -> Type -> Infer Unit
assignTVar v t = modify \r -> r {tvars = Map.insert v t r.tvars}

getVar :: String -> Infer (Maybe Type)
getVar s = getBind s >>= \ms -> sequence $ instantiate <$> ms

tvars :: Infer (Array TVar)
tvars = (\r -> L.toUnfoldable $ Map.keys r.tvars) <$> get

currentTVars :: Array TVar -> Infer (Array TVar)
currentTVars tvs = (union tvs <<< concatMap tvarsOf) <$>
                   mapM (TVar >>> tpure >>> evalType) tvs

evalType :: Type -> Infer Type
evalType x@(Info t k i) = case t of
    TVar v -> do
        x'@(Info t' _ _) <- getTVar v
        case t' of
            Unknown -> pure x
            _       -> evalType x'
    TApp a b -> do
        t' <- TApp <$> evalType a <*> evalType b
        pure $ Info t' k i
    TOper s a b -> do
        t' <- TOper s <$> sequence (map evalType a) <*> sequence (map evalType b)
        pure $ Info t' k i
    _     -> pure x

deepEvalType :: Type -> Infer Type
deepEvalType = evalType

instantiate :: Scheme -> Infer Type
instantiate (Forall ts t) = do
    vts <- mapM (\v -> Tuple v <$> newTVarT) ts
    pure $ replace (Map.fromFoldable vts) t
  where
    replace :: Map.Map TVar Type -> Type -> Type
    replace m x@(Info ta k i) = case ta of
        TVar v      -> fromMaybe x $ Map.lookup v m
        TApp a b    -> Info (TApp (replace m a) (replace m b)) k i
        TOper s a b -> Info (TOper s (replace m <$> a) (replace m <$> b)) k i
        _           -> x

generalize :: Array TVar -> Scheme -> Scheme
generalize tvs (Forall _ t) = Forall (tvarsOf t \\ tvs) t

generalize' :: Scheme -> Scheme
generalize' (Forall _ t) = Forall (tvarsOf t) t

unify :: Type -> Type -> Infer {type :: Type, infos :: Infos}
unify a b = do
    a'@(Info tx _ _) <- deepEvalType a
    b'@(Info ty _ _) <- deepEvalType b
    case Tuple tx ty of
        Tuple Unknown _ -> success b
        Tuple _ Unknown -> success a
        Tuple (TVar x) (TVar y) | x == y -> success a
        Tuple (TVar x) (TVar y) | x > y -> do
            -- getCstrs x >>= addCstrs y
            assignTVar x b
            success b
        Tuple (TVar x) (TVar y) | x < y -> do
            -- getCstrs y >>= addCstrs x
            assignTVar y a
            success a
        Tuple (TVar x) _ ->
            if occursCheck x b'
            then error b $ EOccursCheck a' b'
            else do
                assignTVar x b
                success b
        Tuple _ (TVar y) ->
            if occursCheck y a'
            then error a $ EOccursCheck b' a'
            else do
                assignTVar y a
                success a
        -- Tuple Arrow Arrow -> success a
        Tuple (Id xs) (Id ys) | xs == ys -> success a
        Tuple (TApp ax bx) (TApp ay by) -> do
            {type: ta, infos: ia} <- unify ax ay
            {type: tb, infos: ib} <- unify bx by
            pure {type: tpure $ TApp ta tb, infos: ia <> ib}
        Tuple (TOper xs Nothing Nothing) (TOper ys Nothing Nothing) | xs == ys -> success a
        Tuple (TOper xs (Just ax) Nothing) (TOper ys (Just ay) Nothing) | xs == ys -> do
            {type: ta, infos: ia} <- unify ax ay
            pure {type: tpure $ TOper xs (Just ta) Nothing, infos: ia}
        Tuple (TOper xs (Just ax) (Just bx)) (TOper ys (Just ay) (Just by)) | xs == ys -> do
            {type: ta, infos: ia} <- unify ax ay
            {type: tb, infos: ib} <- unify bx by
            pure {type: tpure $ TOper xs (Just ta) (Just tb), infos: ia <> ib}
        -- Tuple (TOper ao (Just ax) Nothing) (TOper bo (Just bx) Nothing) -> do
        --     {type: to, infos: io} <- unify ao bo
        --     {type: tx, infos: ix} <- unify ax bx
        --     pure {type: tpure $ TOper to (Just tx) Nothing, infos: io <> ix}
        _ -> error b $ EMisMatch a' b'
  where
    occursCheck :: TVar -> Type -> Boolean
    occursCheck v t = v `elem` tvarsOf t

    success :: Type -> Infer {type :: Type, infos :: Infos}
    success t = pure {type: t, infos: mempty}

    error :: Type -> Error -> Infer {type :: Type, infos :: Infos}
    error t e = pure {type: t, infos: Infos {errors: [e]}}

tvarsOf :: Type -> Array TVar
tvarsOf (Info t _ _) = case t of
    TVar v      -> [v]
    TApp a b    -> tvarsOf a <> tvarsOf b
    TOper _ a b -> fromMaybe [] (tvarsOf <$> a) <> fromMaybe [] (tvarsOf <$> b)
    _           -> []

--------------------------------------------------------------------------------

showTypes :: Bind -> Infer Bind
showTypes (Bind x y) = Bind <$> goExpr x <*> goExpr y
  where
    goExpr :: Expr -> Infer Expr
    goExpr (Info e sc i) = do
        e' <- case e of
            App a b      -> App <$> goExpr a <*> goExpr b
            Lambda as b  -> Lambda <$> mapM goExpr as <*> goExpr b
            Oper o ma mb -> Oper <$> goExpr o <*> (sequence $ goExpr <$> ma) <*> (sequence $ goExpr <$> mb)
            If c a b     -> If <$> goExpr c <*> goExpr a <*> goExpr b
            Case a as    -> Case <$> goExpr a <*> forM as
                               \(Tuple p b) -> Tuple <$> goExpr p <*> goExpr b
            Let bs a     -> Let <$> mapM showTypes bs <*> goExpr a
            _ -> pure e
        sc' <- goScheme sc
        pure $ Info e' sc' i

    goScheme :: Scheme -> Infer Scheme
    goScheme (Forall ts t) = Forall <$> mapM nameTVar ts <*> (evalType >=> nameType) t

nameType :: Type -> Infer Type
nameType x = do
    Info t k i <- evalType x
    t' <- case t of
        TVar v      -> TVar <$> nameTVar v
        TApp a b    -> TApp <$> nameType a <*> nameType b
        TOper s a b -> TOper s <$> sequence (map nameType a) <*> sequence (map nameType b)
        _           -> pure t
    pure $ Info t' k i

nameTVar :: TVar -> Infer TVar
nameTVar v@(Named _) = pure v
nameTVar v@(Temp _) = do {tvars: m} <- get
                         let v' = newNamed m "a"
                         newTVarOf v'
                         assignTVar v $ tpure $ TVar v'
                         pure v'
    where
        newNamed :: Map.Map TVar Type -> String -> TVar
        newNamed m s = if Map.member (Named s) m
                       then newNamed m $ succ s
                       else Named s

        succ :: String -> String
        succ s = maybe s (\n -> singleton $ fromCharCode $ n + 1)
                         (charCodeAt 0 s)


--------------------------------------------------------------------------------

mapWithOthers :: forall a b. (a -> Array a -> b) -> Array a -> Array b
mapWithOthers f = go []
    where
        go :: Array a -> Array a -> Array b
        go xs ys = case uncons ys of
            Just {head: y, tail: ys'} -> f y (xs <> ys') `cons` go (xs `snoc` y) ys'
            Nothing                   -> []

mapM :: forall m t a b. Monad m => Traversable t => (a -> m b) -> t a -> m (t b)
mapM f = map f >>> sequence

forM :: forall m t a b. Monad m => Traversable t => t a -> (a -> m b) -> m (t b)
forM = flip mapM

mconcat :: forall m. Monoid m => Array m -> m
mconcat = foldr (<>) mempty
