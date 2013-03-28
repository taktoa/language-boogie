-- | Abstract syntax tree for Boogie 2
module Language.Boogie.AST where

import Language.Boogie.Position
import Language.Boogie.Heap
import Data.Map (Map)
import qualified Data.Map as M

{- Basic -}

-- | Program: a list of top-level declarations
newtype Program = Program [Decl]
  deriving Eq

{- Types -}

-- | Type
data Type = BoolType |        -- ^ bool 
  IntType |                   -- ^ int
  MapType [Id] [Type] Type |  -- 'MapType' @type_vars domains range@ : arrow type (used for maps, function and procedure signatures)
  IdType Id [Type]            -- 'IdType' @name args@: type denoted by an identifier (either type constructor, possibly with arguments, or a type variable)
  deriving Eq -- syntactic equality

-- | 'nullaryType' @id@ : type denoted by @id@ without arguments
nullaryType id = IdType id []

-- | Dummy type used during type checking to denote error
noType = nullaryType "NoType"

{- Expressions -}

-- | Unary operators
data UnOp = Neg | Not
  deriving (Eq, Ord)

-- | Binary operators  
data BinOp = Plus | Minus | Times | Div | Mod | And | Or | Implies | Explies | Equiv | Eq | Neq | Lc | Ls | Leq | Gt | Geq
  deriving (Eq, Ord)

-- | Quantifiers
data QOp = Forall | Exists | Lambda
  deriving (Eq, Ord)
  
-- | Expression with a source position attached  
type Expression = Pos BareExpression
  
-- | Expression
data BareExpression = 
  Literal Type Value |
  Var Id |                                        -- ^ 'Var' @name@
  Application Id [Expression] |                   -- ^ 'Application' @f args@
  MapSelection Expression [Expression] |          -- ^ 'MapSelection' @map indexes@
  MapUpdate Expression [Expression] Expression |  -- ^ 'MapUpdate' @map indexes rhs@
  Old Expression |
  IfExpr Expression Expression Expression |       -- ^ 'IfExpr' @cond eThen eElse@
  Coercion Expression Type |
  UnaryExpression UnOp Expression |
  BinaryExpression BinOp Expression Expression |
  Quantified QOp [Id] [IdType] Expression         -- ^ 'Quantified' @qop type_vars bound_vars expr@
  deriving Eq -- syntactic equality
  
-- | 'mapSelectExpr' @m args@ : map selection expression with position of @m@ attached
mapSelectExpr m args = attachPos (position m) (MapSelection m args)  

ff = Literal BoolType (BoolValue False)
tt = Literal BoolType (BoolValue True)
numeral n = Literal IntType (IntValue n)
  
-- | Wildcard or expression  
data WildcardExpression = Wildcard | Expr Expression
  deriving Eq
  
{- Statements -}

-- | Statement with a source position attached  
type Statement = Pos BareStatement

-- | Statement
data BareStatement = Predicate SpecClause |      -- ^ Predicate statement (assume or assert)
  Havoc [Id] |                                   -- ^ 'Havoc' @var_names@
  Assign [(Id , [[Expression]])] [Expression] |  -- ^ 'Assign' @var_map_selects rhss@
  Call [Id] Id [Expression] |                    -- ^ 'Call' @lhss proc_name args@
  CallForall Id [WildcardExpression] |           -- ^ 'CallForall' @proc_name args@
  If WildcardExpression Block (Maybe Block) |    -- ^ 'If' @wild_or_expr then_block else_block@
  While WildcardExpression [SpecClause] Block |  -- ^ 'While' @wild_or_expr free_loop_inv loop_body@
  Break (Maybe Id) |                             -- ^ 'Break' @label@
  Return |
  Goto [Id] |                                    -- ^ 'Goto' @labels@
  Skip                                           -- ^ only used at the end of a block
  deriving Eq -- syntactic equality

-- | Statement labeled by multiple labels with a source position attached  
type LStatement = Pos BareLStatement

-- | Statement labeled by multiple labels
type BareLStatement = ([Id], Statement)

-- | Statement block
type Block = [LStatement] 

-- | Block consisting of a single non-labeled statement
singletonBlock s = [attachPos (position s) ([], s)]

-- | Procedure body: consists of local variable declarations and a statement block
type Body = ([[IdTypeWhere]], Block)

-- | Basic block is a list of statements labeled by a single label;
-- the list contains no jump, if or while statements,
-- except for the last statement, which can be a goto or return
type BasicBlock = (Id, [Statement])

-- | Procedure body transformed to basic blocks:
-- consists of local variable declarations and a set of basic blocks
-- (represented as a map from their labels to statement lists)
type BasicBody = ([IdTypeWhere], Map Id [Statement])

{- Specs -}

-- | Types of specification clauses
data SpecType = Inline | Precondition | Postcondition | LoopInvariant | Where | Axiom
  deriving Eq

-- | Specification clause
data SpecClause = SpecClause {
  specType :: SpecType,   -- ^ Source of the clause
  specFree :: Bool,       -- ^ Is it free (assumption) or checked (assertions)?
  specExpr :: Expression  -- ^ Boolean expression
  } deriving Eq

-- | Procedure contract clause 
data Contract = Requires Bool Expression |  -- ^ 'Requires' @e free@
  Modifies Bool [Id] |                      -- ^ 'Modifies' @var_names free@
  Ensures Bool Expression                   -- ^ 'Ensures' @e free@
  deriving Eq

{- Declarations -}

-- | Top-level declaration with a source position attached  
type Decl = Pos BareDecl

-- | Top-level declaration
data BareDecl = 
  TypeDecl [NewType] |
  ConstantDecl Bool [Id] Type ParentInfo Bool |                                -- ^ 'ConstantDecl' @unique names type orderSpec complete@
  FunctionDecl Id [Id] [FArg] FArg (Maybe Expression) |                        -- ^ 'FunctionDecl' @name type_args formals ret body@
  AxiomDecl Expression |
  VarDecl [IdTypeWhere] |
  ProcedureDecl Id [Id] [IdTypeWhere] [IdTypeWhere] [Contract] (Maybe Body) |  -- ^ 'ProcedureDecl' @name type_args formals rets contract body@
  ImplementationDecl Id [Id] [IdType] [IdType] [Body]                          -- ^ 'ImplementationDecl' @name type_args formals rets body@
  deriving Eq
  
{- Values -}

-- | Representation of a map value
data MapRepr = 
  Source (Map [Value] Value) |    -- ^ Map that comes directly from a non-deterministic choice, possibly with some key-value pairs defined
  Derived Ref (Map [Value] Value) -- ^ Map that is derived from another map by redefining values at some keys
  deriving (Eq, Ord)
  
-- | Representation of an empty map  
emptyMap = Source M.empty

-- | Key-value pairs stored explicitly in a map representation
stored :: MapRepr -> Map [Value] Value
stored (Source vals) = vals
stored (Derived _ override) = override
  
-- | Run-time value
data Value = IntValue Integer |  -- ^ Integer value
  BoolValue Bool |               -- ^ Boolean value
  CustomValue Id Int |           -- ^ Value of a user-defined type
  MapValue MapRepr |             -- ^ Value of a map type: consists of an optional reference to the base map (if derived from base by updating) and key-value pairs that override base
  Reference Ref                  -- ^ Logical variable: reference to a symbolic value stored in the heap (currently only maps)
  deriving (Eq, Ord)
  
-- | 'valueFromInteger' @t n@: value of type @t@ with an integer code @n@
valueFromInteger :: Type -> Integer -> Value  
valueFromInteger IntType n        = IntValue n
valueFromInteger (IdType id _) n  = CustomValue id (fromInteger n)
valueFromInteger _ _              = error "cannot create a boolean or map value from integer" 
  
unValueBool (BoolValue b) = b  
vnot (BoolValue b) = BoolValue (not b)

unValueMap (MapValue repr) = repr  
    
{- Misc -}

-- | Identifier
type Id = String

-- | Definition of a type
data NewType = NewType {
  tId :: Id,
  tArgs :: [Id],
  tValue :: Maybe Type
  } deriving Eq

-- | Name declaration (identifier, type)
type IdType = (Id, Type)

-- | Name declaration with a where clause
data IdTypeWhere = IdTypeWhere { 
  itwId :: Id, 
  itwType :: Type, 
  itwWhere :: Expression 
  } deriving Eq
  
-- | Strip the where clause  
noWhere itw = (itwId itw, itwType itw)  
  
-- | Formal argument of a function  
type FArg = (Maybe Id, Type)

-- | Argument name used for unnamed function arguments
-- (does not matter, because it is never referred to from function's body)  
dummyFArg = ""

-- | Parent edge of a constant declaration (uniqueness, parent name)
type ParentEdge = (Bool, Id)

-- | Parent information in a constant declaration
-- (Nothing means no information, while empty list means no parents)
type ParentInfo = Maybe [ParentEdge]
