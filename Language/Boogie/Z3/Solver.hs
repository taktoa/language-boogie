{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE BangPatterns #-}
module Language.Boogie.Z3.Solver (solverContext, solve, solver) where

import           Control.Applicative
import           Control.Monad
import           Control.Monad.IO.Class
import           Control.Concurrent
import           Control.Exception

import           Data.Foldable (Foldable, toList)
import           Data.Map (Map)
import qualified Data.Map as Map
import           Data.Maybe
import qualified Data.Set as Set
import           Data.List

import           System.IO.Unsafe

import qualified Z3.Base as Z3 (mkConfig, mkContext, mkSolver, mkSimpleSolver)
import           Z3.Monad hiding (Context, Solver)
import qualified Z3.Monad as Z3 (Context, Solver)

import           Language.Boogie.AST
import           Language.Boogie.Generator
import           Language.Boogie.Position
import           Language.Boogie.Solver
import           Language.Boogie.TypeChecker
import           Language.Boogie.Util ((|=|), conjunction, enot)
import           Language.Boogie.Z3.GenMonad
import           Language.Boogie.Z3.Solution

solver :: (MonadPlus m, Foldable m)
      => Bool          -- ^ Is a minimal solution desired?
      -> Maybe Int     -- ^ Bound on number of solutions
      -> Solver m
solver minWanted mBound = unsafePerformIO $ mkSolver minWanted mBound

mkSolver :: (MonadPlus m, Foldable m)
      => Bool          -- ^ Is a minimal solution desired?
      -> Maybe Int     -- ^ Bound on number of solutions
      -> IO (Solver m)
mkSolver minWanted mBound = do
    (slvNoModel, ctxNoModel) <- solverContext False
    (slvModel, ctxModel) <- solverContext True
    return Solver {
          solPick = \cs state -> do 
            (mSolution, newNAssert) <- solve minWanted True mBound cs (pickState state) slvModel ctxModel
            case mSolution of
              NoSoln -> mzero
              Soln -> error "solution found, but no model requested"
              SolnWithModel solution -> return (solution, state { pickState = newNAssert }),
          solCheck = \cs state ->
                      let (mSolution, newNAssert) = head $ solve False False (Just 1) cs (checkState state) slvNoModel ctxNoModel 
                          foundSoln = case mSolution of
                                        NoSoln -> False
                                        _ -> True
                      in (foundSoln, state { checkState = newNAssert })
        }

solverContext :: Bool -> IO (Z3.Solver, Z3.Context)
solverContext modelWanted =
  do cfg <- Z3.mkConfig
     setOpts cfg opts
     ctx <- Z3.mkContext cfg
     slv <- Z3.mkSolver ctx
     return (slv, ctx)
    where
      opts = stdOpts +? (opt "AUTO_CONFIG" False)
                     +? (opt "MODEL" modelWanted)
                     +? (opt "MBQI" False)
                     -- +? (opt "SOFT_TIMEOUT" (100::Int))
                     -- +? (opt "MODEL_ON_TIMEOUT" True)

solve :: (MonadPlus m, Foldable m)
      => Bool          -- ^ Is a minimal solution desired?
      -> Bool          -- ^ Is a solution wanted?
      -> Maybe Int     -- ^ Bound on number of solutions
      -> ConstraintSet -- ^ Set of constraints
      -> Int           -- ^ Desired number of backtracking points in the solver
      -> Z3.Solver     -- ^ Z3 solver to use
      -> Z3.Context    -- ^ Z3 context to use
      -> m (SolveResult, Int)
solve minWanted solnWanted mBound constrs nAssert slv ctx = 
    case solRes of
      SolnWithModel soln -> return (solRes, newNAssert) `mplus` go
          where
            neq = newConstraint soln
            go = if mBound == Nothing || (fromJust mBound > 1)
                    then solve
                           minWanted
                           solnWanted
                           (fmap pred mBound)
                           (neq : constrs)
                           nAssert
                           slv
                           ctx
                    else mzero
      _ -> return x
  where
    x@(solRes, newNAssert) =
      stepConstrs minWanted solnWanted constrs nAssert slv ctx
data StepResult
    = StepNoSoln
    | StepSoln
    | StepSolnWithModel Solution Expression

stepConstrs :: Bool
            -> Bool
            -> [Expression]
            -> Int
            -> Z3.Solver
            -> Z3.Context
            -> (SolveResult, Int)
stepConstrs minWanted solnWanted constrs nAssert slv ctx = unsafePerformIO act
    where
      act = 
       do evalZ3GenWith slv ctx $ 
           do 
              debug ("stepConstrs: start")
              debug ("stepConstrs: " ++ show (minWanted, constrs, nAssert))
              debug1 ("interpreter thinks " ++ show nAssert)              
              popStack
              push
              debug1 ("constraints " ++ show (length constrs) ++ "\n" ++ (intercalate "\n" $ map show constrs))              
              solnRes <- solveConstr minWanted solnWanted constrs
              debug1 (show solnRes)
              newNAssert <- getNumScopes
              debug ("new " ++ show newNAssert) 
              debug ("stepConstrs: done")
              return (solnRes, newNAssert)
      popStack = do
        nAssertSolver <- getNumScopes
        debug1 ("solver thinks " ++ show nAssertSolver)
        if nAssert == 0
          then reset
          else if nAssert > nAssertSolver
            then error "Solver has fewer assertions than the interpreter"
            else if nAssert < nAssertSolver
              then do
                debug ("pop")
                pop 1
                popStack
              else return ()

newConstraint :: Solution -> Expression
newConstraint soln = enot (conjunction (logicEqs ++ customEqs))
    where
      logicEq :: Ref -> Expression -> Expression
      logicEq r e = logic e r |=| e
      
      -- Logical equations only for non-idType values.
      logicEqs :: [Expression]
      logicEqs = Map.foldrWithKey go [] soln
          where
            go ref expr es =
                case thunkType expr of
                  t@(IdType {..}) -> es
                  _ -> logicEq ref expr : es

      logict t r = gen (Logical t r)
      logic e r = gen (Logical (thunkType e) r)

      customEqs :: [Expression]
      customEqs = eqs ++ notEqs
          where
            eqs = concatMap (uncurry eqFold) (Map.toList customEqRel)
            notEqs = concat $ map snd $
                     Map.toList $ Map.mapWithKey allNeqs neqMaps
                where
                  neq t e r = enot (e |=| logict t r)
                  neqs t e = map (neq t e)

                  allNeqs :: Type -> [Ref] -> [Expression]
                  allNeqs t [] = []
                  allNeqs t (r:rs) = neqs t (logict t r) rs ++ allNeqs t rs

                  neqMaps :: Map Type [Ref]
                  neqMaps = Map.mapKeysWith (++) thunkType
                              (Map.map mkNeqData customEqRel)
                  mkNeqData refs = [head $ Set.toList refs]

            eqOp e r1 r2  = logic e r1 |=| logic e r2
            neqOp e r1 r2 = enot (eqOp e r1 r2)

            interPair op e [r1]       = [op e r1 r1]
            interPair op e (r1:r2:rs) = (op e r1 r2):(interPair op e (r2:rs))

            eqFold expr = interPair eqOp expr . Set.toList
            neqFold expr = interPair neqOp expr

      -- Equality relation on customs.
      customEqRel = Map.foldWithKey go Map.empty soln
          where
            go ref expr m =
                case thunkType expr of
                  t@(IdType {..}) -> 
                      Map.insertWith Set.union expr (Set.singleton ref) m
                  _ -> m
