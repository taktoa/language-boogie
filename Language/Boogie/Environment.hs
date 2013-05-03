{-# LANGUAGE TemplateHaskell, Rank2Types, FlexibleInstances, TypeSynonymInstances #-}

-- | Execution state for the interpreter
module Language.Boogie.Environment ( 
  Store,
  emptyStore,
  userStore,
  MapInstance,
  MapCache,
  Memory,
  StoreLens,
  memLocals,
  memGlobals,
  memOld,
  memModified,
  memConstants,
  memMaps,
  memLogical,
  emptyMemory,
  visibleVariables,
  userMemory,
  memoryDoc,
  NameConstraints,
  -- MapConstraints,
  constraintUnion,  
  ConstraintMemory,
  conLocals,
  conGlobals,
  -- conMaps,
  conLogical,
  conChanged,
  Environment,
  envMemory,
  envProcedures,
  envFunctions,
  envConstraints,
  envTypeContext,
  envSolver,
  envGenerator,
  envCustomCount,
  envMapCount,
  envLogicalCount,
  envInOld,
  envLabelCount,
  initEnv,
  lookupProcedure,
  lookupNameConstraints,
  -- lookupMapConstraints,
  lookupCustomCount,
  addProcedureImpl,
  addNameConstraint,
  -- addMapConstraint,
  addLogicalConstraint,
  setCustomCount,
  markModified,
  isRecursive
) where

import Language.Boogie.Util
import Language.Boogie.Position
import Language.Boogie.AST
import Language.Boogie.Solver
import Language.Boogie.Generator
import Language.Boogie.TypeChecker (Context, ctxGlobals)
import Language.Boogie.Pretty
import Language.Boogie.PrettyAST
import Data.List
import Data.Map (Map, (!))
import qualified Data.Map as M
import Data.Set (Set)
import qualified Data.Set as S
import Control.Lens hiding (Context, at)
  
{- Memory -}

-- | Store: stores variable values at runtime 
type Store = Map Id Thunk

-- | A store with no variables
emptyStore = M.empty

-- | 'userStore' @heap store@ : @store@ with all reference values completely dereferenced given @heap@
userStore :: MapCache -> Store -> Store
userStore maps store = store -- M.map (deepDeref maps . fromLiteral) store

-- | Pretty-printed store
instance Pretty Store where
  pretty = vMapDoc pretty pretty
    
-- | Partial map instance
type MapInstance = Map [Thunk] Thunk

instance Pretty MapInstance where
  pretty = let keysDoc keys = ((if length keys > 1 then parens else id) . commaSep . map pretty) keys
    in hMapDoc keysDoc pretty
    
-- | MapCache: stores partial map instances    
type MapCache = Map Ref MapInstance
    
emptyCache = M.empty  
  
instance Pretty MapCache where
  pretty = vMapDoc refDoc pretty

-- | Memory: stores thunks associated with names, map references and logical variables
data Memory = Memory {
  _memLocals :: Store,      -- ^ Local variable store
  _memGlobals :: Store,     -- ^ Global variable store
  _memOld :: Store,         -- ^ Old global variable store (in two-state contexts)
  _memModified :: Set Id,   -- ^ Set of global variables, which have been modified since the beginning of the current procedure  
  _memConstants :: Store,   -- ^ Constant store  
  _memMaps :: MapCache,     -- ^ Partial instances of maps
  _memLogical :: Solution   -- ^ Logical variable store
} deriving Eq

makeLenses ''Memory

-- | Lens that selects a store from memory
type StoreLens = SimpleLens Memory Store

-- | Empty memory
emptyMemory = Memory {
  _memLocals = emptyStore,
  _memGlobals = emptyStore,
  _memOld = emptyStore,
  _memModified = S.empty,
  _memConstants = emptyStore,
  _memMaps = emptyCache,
  _memLogical = M.empty
}

-- | Visible values of all identifiers in a memory (locals shadow globals) 
visibleVariables :: Memory -> Store
visibleVariables mem = (mem^.memLocals) `M.union` (mem^.memGlobals) `M.union` (mem^.memConstants)

-- -- | 'userStore' @conMem mem@ : @mem@ with all reference values completely dereferenced and cache of defined maps removed 
userMemory :: ConstraintMemory -> Memory -> Memory
userMemory conMem mem = let maps = mem^.memMaps in
  over memLocals (userStore maps) $
  over memGlobals (userStore maps) $
  over memOld (userStore maps) $
  over memModified (const S.empty) $
  over memConstants (userStore maps) $
  over memLogical (const M.empty)
  mem

-- | 'memoryDoc' @inNames outNames mem@ : pretty-printed @mem@ where
-- locals in @inNames@ will be printed as input variables
-- and locals in @outNames@ will be printed as output variables
memoryDoc :: [Id] -> [Id] -> Memory -> Doc
memoryDoc inNames outNames mem = vsep $ 
  docNonEmpty ins (labeledDoc "Ins") ++
  docNonEmpty locals (labeledDoc "Locals") ++
  docNonEmpty outs (labeledDoc "Outs") ++
  docNonEmpty allGlobals (labeledDoc "Globals") ++
  docNonEmpty (mem^.memOld) (labeledDoc "Old globals") ++
  docWhen (not (S.null $ mem^.memModified)) (text "Modified:" <+> commaSep (map text (S.toList $ mem^.memModified))) ++
  docNonEmpty (mem^.memMaps) (labeledDoc "Maps") ++
  docNonEmpty (mem^.memLogical) (labeledDoc "Logical")
  where
    allLocals = mem^.memLocals
    ins = restrictDomain (S.fromList inNames) allLocals
    outs = restrictDomain (S.fromList outNames) allLocals
    locals = removeDomain (S.fromList $ inNames ++ outNames) allLocals
    allGlobals = (mem^.memGlobals) `M.union` (mem^.memConstants)
    labeledDoc label x = (text label <> text ":") <+> align (pretty x)
    docWhen flag doc = if flag then [doc] else [] 
    docNonEmpty m mDoc = docWhen (not (M.null m)) (mDoc m)
    
instance Pretty Memory where
  pretty mem = memoryDoc [] [] mem
  
{- Constraint memory -}

-- | Mapping from names to their constraints
type NameConstraints = Map Id ConstraintSet

-- | Pretty-printed variable constraints
instance Pretty NameConstraints where
  pretty = vMapDoc pretty constraintSetDoc

-- -- | Mapping from map references to their parametrized constraints
-- type MapConstraints = Map Ref ConstraintSet

-- instance Pretty MapConstraints where
  -- pretty = vMapDoc refDoc constraintSetDoc  
  
-- | Union of constraints (values at the same key are concatenated)
constraintUnion s1 s2 = M.unionWith (++) s1 s2  

-- | Constraint memory: stores constraints associated with names, map references and logical variables
data ConstraintMemory = ConstraintMemory {
  _conLocals :: NameConstraints,        -- ^ Local name constraints
  _conGlobals :: NameConstraints,       -- ^ Global name constraints
  -- _conMaps :: MapConstraints,        -- ^ Parametrized map constraints
  _conLogical :: ConstraintSet,         -- ^ Constraint on logical variables
  _conChanged :: Bool                   -- ^ Have the constraints changed since the last check?
}

makeLenses ''ConstraintMemory

-- | Symbolic memory with no constraints
emptyConstraintMemory = ConstraintMemory {
  _conLocals = M.empty,
  _conGlobals = M.empty,
  -- _conMaps = M.empty,
  _conLogical = [],
  _conChanged = True
}

constraintMemoryDoc :: ConstraintMemory -> Doc
constraintMemoryDoc mem = vsep $ 
  docNonEmpty (mem^.conLocals) (labeledDoc "CLocal") ++
  docNonEmpty (mem^.conGlobals) (labeledDoc "CGlobal") ++
  -- docNonEmpty (mem^.conMaps) (labeledDoc "CMap") ++
  docWhen (not $ null (mem^.conLogical)) ((text "CLogical" <> text ":") <+> align (constraintSetDoc (mem^.conLogical)))
  where
    labeledDoc label x = (text label <> text ":") <+> align (pretty x)
    docWhen flag doc = if flag then [doc] else [] 
    docNonEmpty m mDoc = docWhen (not (M.null m)) (mDoc m)
    
instance Pretty ConstraintMemory where
  pretty = constraintMemoryDoc

{- Environment -}
  
-- | Execution state
data Environment m = Environment
  {
    _envMemory :: Memory,                   -- ^ Values
    _envConstraints :: ConstraintMemory,    -- ^ Constraints
    _envProcedures :: Map Id [PDef],        -- ^ Procedure implementations
    _envFunctions :: Map Id Expression,     -- ^ Functions with definitions
    _envTypeContext :: Context,             -- ^ Type context
    _envSolver :: Solver m,                 -- ^ Constraint solver
    _envGenerator :: Generator m,           -- ^ Value generator
    _envMapCount :: Int,                    -- ^ Number of map references currently in use
    _envLogicalCount :: Int,                -- ^ Number of logical varibles currently in use
    _envCustomCount :: Map Type Int,        -- ^ For each user-defined type, number of distinct values of this type already generated
    _envLabelCount :: Map (Id, Id) Integer, -- ^ For each procedure-label pair, number of times a transition with that label was taken
    _envInOld :: Bool                       -- ^ Is an old expression currently being evaluated?
  }
  
makeLenses ''Environment
   
-- | 'initEnv' @tc s@: Initial environment in a type context @tc@ with constraint solver @s@  
initEnv tc s g = Environment
  {
    _envMemory = emptyMemory,
    _envConstraints = emptyConstraintMemory,
    _envProcedures = M.empty,
    _envFunctions = M.empty,
    _envTypeContext = tc,
    _envSolver = s,
    _envGenerator = g,
    _envCustomCount = M.empty,
    _envMapCount = 0,
    _envLogicalCount = 0,
    _envLabelCount = M.empty,
    _envInOld = False
  }
  
-- | 'lookupGetter' @getter def key env@ : lookup @key@ in a map accessible with @getter@ from @env@; if it does not occur return @def@
lookupGetter getter def key env = case M.lookup key (env ^. getter) of
  Nothing -> def
  Just val -> val
  
combineGetters f g1 g2 = to $ \env -> (env ^. g1) `f` (env ^. g2)  
  
-- Environment queries  
lookupProcedure = lookupGetter envProcedures []  
lookupNameConstraints = lookupGetter (combineGetters M.union (envConstraints.conLocals) (envConstraints.conGlobals)) []
-- lookupMapConstraints = lookupGetter (envConstraints.conMaps) []
lookupCustomCount = lookupGetter envCustomCount 0

-- Environment modifications
addProcedureImpl name def env = over envProcedures (M.insert name (lookupProcedure name env ++ [def])) env
addNameConstraint :: Id -> SimpleLens (Environment m) NameConstraints -> Expression -> Environment m -> Environment m
addNameConstraint name lens c env = over lens (M.insert name (nub $ c : lookupGetter lens [] name env)) env
-- addMapConstraint r c env = over (envConstraints.conMaps) (M.insert r (nub $ c : lookupMapConstraints r env)) env
addLogicalConstraint c = over (envConstraints.conLogical) (nub . (c :))
setCustomCount t n = over envCustomCount (M.insert t n)
markModified name env = if M.member name (env^.envTypeContext.to ctxGlobals) 
  then over (envMemory.memModified) (S.insert name) env
  else env
  
-- | 'isRecursive' @name functions@ : is function @name@ (mutually) recursive according to definitions in @functions@?
isRecursive name functions = name `elem` reachable [] name
  where
    reachable visited f = let direct = called f
      in direct ++ concatMap (reachable (visited ++ direct)) (direct \\ visited)
    called f = case M.lookup f functions of
                      Nothing -> []
                      Just (Pos _ (Quantified Lambda tv vars body)) -> map fst $ applications body
