{-# LANGUAGE FlexibleContexts, RankNTypes, ScopedTypeVariables, TupleSections #-}
module Build.Algorithm (
    topological,
    reordering, Chain,
    recursive
    ) where

import Control.Monad.State
import Control.Monad.Trans.Except
import Data.Set (Set)

import Build
import Build.Task
import Build.Task.Applicative hiding (exceptional)
import Build.Store
import Build.Utilities

import qualified Data.Set as Set

-- Shall we skip writing to the store if the value is the same?
-- We could skip writing if hash oldValue == hash newValue.
updateValue :: Eq k => k -> v -> v -> Store i k v -> Store i k v
updateValue key _oldValue newValue = putValue key newValue

---------------------------------- Topological ---------------------------------
topological :: Ord k => (k -> v -> Task Applicative k v -> Task (MonadState i) k v)
    -> Build Applicative i k v
topological transformer tasks key = execState $ forM_ chain $ \k ->
    case tasks k of
        Nothing   -> return ()
        Just task -> do
            currentValue <- gets (getValue k)
            let t = transformer k currentValue task
                fetch :: k -> StateT i (State (Store i k v)) v
                fetch = lift . gets . getValue
            info <- gets getInfo
            (value, newInfo) <- runStateT (run t fetch) info
            modify $ putInfo newInfo . updateValue k currentValue value
  where
    deps  = maybe [] dependencies . tasks
    chain = case topSort (graph deps key) of
        Nothing -> error "Cannot build tasks with cyclic dependencies"
        Just xs -> xs

---------------------------------- Reordering ----------------------------------
type Chain k = [k]

trying :: Task (MonadState i) k v -> Task (MonadState i) k (Either e v)
trying task = Task $ \fetch -> runExceptT $ run task (ExceptT . fetch)

reordering :: forall i k v. Ord k
           => (k -> v -> Task Monad k v -> Task (MonadState i) k v)
           -> Build Monad (i, Chain k) k v
reordering transformer tasks key = execState $ do
    chain    <- snd . getInfo <$> get
    newChain <- go Set.empty $ chain ++ [key | key `notElem` chain]
    modify . mapInfo $ \(i, _) -> (i, newChain)
  where
    go :: Set k -> Chain k -> State (Store (i, [k]) k v) (Chain k)
    go _    []     = return []
    go done (k:ks) = do
        case tasks k of
            Nothing -> (k :) <$> go (Set.insert k done) ks
            Just task -> do
                currentValue <- gets (getValue k)
                let t = transformer k currentValue task
                    tryFetch :: k -> StateT i (State (Store (i, [k]) k v)) (Either k v)
                    tryFetch k | k `Set.member` done = do
                                   store <- lift get
                                   return $ Right (getValue k store)
                               | otherwise = return (Left k)
                info <- fst <$> gets getInfo
                (result, newInfo) <- runStateT (run (trying t) tryFetch) info
                case result of
                    Left dep -> go done $ [ dep | dep `notElem` ks ] ++ ks ++ [k]
                    Right value -> do
                        modify $ putInfo (newInfo, []) . updateValue k currentValue value
                        (k :) <$> go (Set.insert k done) ks

----------------------------------- Recursive ----------------------------------
recursive :: forall i k v. Eq k
          => (k -> v -> Task Monad k v -> Task (MonadState i) k v)
          -> Build Monad i k v
recursive transformer tasks key store = fst $ execState (fetch key) (store, [])
  where
    fetch :: k -> State (Store i k v, [k]) v
    fetch key = case tasks key of
        Nothing -> gets (getValue key . fst)
        Just task -> do
            done <- gets snd
            when (key `notElem` done) $ do
                currentValue <- gets (getValue key . fst)
                let t = transformer key currentValue task
                info <- gets (getInfo . fst)
                (value, newInfo) <- runStateT (run t (lift . fetch)) info
                modify $ \(s, done) -> (putInfo newInfo $ updateValue key currentValue value s, done)
            gets (getValue key . fst)
