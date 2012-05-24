{- Basic block transformation for imperative Boogie code -}
module BasicBlocks (toBasicBlocks, startLabel) where

import AST
import Position
import Data.Map (Map, (!))
import qualified Data.Map as M
import Control.Monad.State
import Control.Applicative

-- | Transform procedure body into a sequence of basic blocks.
-- | A basic block starts with a label and contains no jump, if or while statements,
-- | except for the last statement, which can be a goto or return
toBasicBlocks :: Block -> [BasicBlock]
toBasicBlocks body = let 
  tbs = evalState (concat <$> (mapM (transform M.empty) (map contents body))) 0
  -- By the properties of transform, tbs' is a sequence of basic blocks
  tbs' = attach startLabel (tbs ++ [justStatement Return])  
  -- Append a labeled statement to a sequence of basic blocks
  -- (the first labeled statement cannot have empty label)
  append :: [BasicBlock] -> BareLStatement -> [BasicBlock]
  append bbs ([l], Pos _ Skip) = (l, []) : bbs
  append bbs ([l], s) = (l, [s]) : bbs
  append ((l, ss) : bbs) ([], s) = (l, ss ++ [s]) :  bbs  
  in
    -- First flatten control flow with transform, and then convert to basic blocks
    reverse (foldl append [] tbs')

-- | Label of the first block in a procedure
startLabel = "start"    

-- | Attach a label to the first statement (with an empty label) in a non-empty list of labeled statements    
attach :: Id -> [BareLStatement] -> [BareLStatement]
attach l (([], stmts) : lsts) = ([l], stmts) : lsts

-- | LStatement with no label
justStatement s = ([], gen s)

-- | LStatement with no statement
justLabel l = ([l], gen Skip)

-- | Special label value that denoted the innermost loop (used for break) 
innermost = "innermost"

-- | genFreshLabel kind i: returns a label of kind with id i and the id for the next label
genFreshLabel :: String -> Int -> (String, Int)
genFreshLabel kind i = (show i ++ "_" ++ kind, i + 1)

-- | transform m statement: transform statement into a sequence of basic blocks;
-- | m is a map from statement labels to labels of their exit points (used for break)
transform :: Map Id Id -> BareLStatement -> State Int [BareLStatement]  
transform m (l:lbs, Pos p Skip) = do
  t <- transform m (lbs, Pos p Skip)
  return $ (justStatement $ Goto [l]) : attach l t
transform m (l:lbs, stmt) = do
  lDone <- state $ genFreshLabel "done"
  t <- transform (M.insert l lDone m) (lbs, stmt)
  return $ [justStatement $ Goto [l]] ++ attach l t ++ [justStatement $ Goto [lDone], justLabel lDone]
transform m ([], Pos p stmt) = case stmt of  
  Goto lbs -> do
    lUnreach <- state $ genFreshLabel "unreachable"
    return $ [justStatement $ Goto lbs, justLabel lUnreach]
  Break (Just l) -> do
    lUnreach <- state $ genFreshLabel "unreachable"
    return $ [justStatement $ Goto [m ! l], justLabel lUnreach]
  Break Nothing -> do
    lUnreach <- state $ genFreshLabel "unreachable"
    return $ [justStatement $ Goto [m ! innermost], justLabel lUnreach]
  Return -> do
    lUnreach <- state $ genFreshLabel "unreachable"
    return $ [justStatement Return, justLabel lUnreach]
  If cond thenBlock Nothing -> transform m (justStatement $ If cond thenBlock (Just []))
  If we thenBlock (Just elseBlock) -> do
    lThen <- state $ genFreshLabel "then"
    lElse <- state $ genFreshLabel "else"
    lDone <- state $ genFreshLabel "done"
    t1 <- transBlock m thenBlock
    t2 <- transBlock m elseBlock
    case we of
      Wildcard -> return $ 
        [justStatement $ Goto [lThen, lElse]] ++ 
        attach lThen (t1 ++ [justStatement $ Goto [lDone]]) ++
        attach lElse (t2 ++ [justStatement $ Goto [lDone]]) ++
        [justLabel lDone]
      Expr e -> return $
        [justStatement $ Goto [lThen, lElse]] ++
        [([lThen], gen $ Assume e)] ++ t1 ++ [justStatement $ Goto [lDone]] ++
        [([lElse], gen $ Assume (gen $ UnaryExpression Not e))] ++ t2 ++ [justStatement $ Goto [lDone]] ++
        [justLabel lDone]      
  While Wildcard invs body -> do
    lHead <- state $ genFreshLabel "head"
    lBody <- state $ genFreshLabel "body"
    lDone <- state $ genFreshLabel "done"
    t <- transBlock (M.insert innermost lDone m) body
    return $
      [justStatement $ Goto [lHead]] ++
      attach lHead (map (justStatement . loopInv) invs ++ [justStatement $ Goto [lBody, lDone]]) ++ 
      attach lBody (t ++ [justStatement $ Goto [lHead]]) ++
      [justLabel lDone]
  While (Expr e) invs body -> do
    lHead <- state $ genFreshLabel "head"
    lBody <- state $ genFreshLabel "body"
    lGDone <- state $ genFreshLabel "guarded_done"
    lDone <- state $ genFreshLabel "done"
    t <- transBlock (M.insert innermost lDone m) body
    return $
      [justStatement $ Goto [lHead]] ++
      attach lHead (map (justStatement . loopInv) invs ++ [justStatement $ Goto [lBody, lGDone]]) ++
      [([lBody], gen $ Assume e)] ++ t ++ [justStatement $ Goto [lHead]] ++
      [([lGDone], gen $ Assume (gen $ UnaryExpression Not e))] ++ [justStatement $ Goto [lDone]] ++
      [justLabel lDone]    
  s -> return [justStatement stmt]  
  where
    transBlock m b = concat <$> mapM (transform m) (map contents b)
    loopInv (False, e) = Assert e
    loopInv (True, e) = Assume e