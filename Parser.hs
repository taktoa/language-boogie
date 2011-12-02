module Parser where

import AST
import Tokens
import Data.List
import Text.ParserCombinators.Parsec hiding (token)
import qualified Text.ParserCombinators.Parsec.Token as P
import Text.ParserCombinators.Parsec.Expr

{- Lexical analysis -}

opNames :: [String]
opNames = map snd unOpTokens ++ map snd binOpTokens ++ otherOps

opStart :: [Char]
opStart = nub (map head opNames)

opLetter :: [Char]
opLetter = nub (concat (map tail opNames))

boogieDef :: P.LanguageDef st
boogieDef = P.LanguageDef 
	commentStart
	commentEnd
	commentLine
	False
	(letter <|> oneOf identifierChars)
	(alphaNum <|> oneOf identifierChars)
	(oneOf opStart)
	(oneOf opLetter)
	keywords
	opNames
	True
	
lexer :: P.TokenParser ()
lexer = P.makeTokenParser boogieDef    
      
identifier = P.identifier lexer
reserved = P.reserved lexer
reservedOp = P.reservedOp lexer
charLiteral = P.charLiteral lexer
stringLiteral = P.stringLiteral lexer
natural = P.natural lexer
integer = P.integer lexer
symbol = P.symbol lexer
whiteSpace = P.whiteSpace lexer
angles = P.angles lexer
brackets = P.brackets lexer
parens = P.parens lexer
braces = P.braces lexer
semi = P.semi lexer
comma = P.comma lexer
commaSep = P.commaSep lexer
commaSep1 = P.commaSep1 lexer

{- Types -}

typeAtom :: Parser Type
typeAtom = do { reserved "int"; return IntType } <|>
		   do { reserved "bool"; return BoolType } <|>
		   -- bit vector
		   parens type_
		   
typeArgs :: Parser [Id]
typeArgs = option [] (angles (commaSep1 identifier))
		   
mapType :: Parser Type
mapType = do { 
	args <- typeArgs; 
	domains <- brackets (commaSep1 type_); 
	range <- type_; 
	return (MapType args domains range) 
	}
	
typeCtorArgs :: Parser [Type]
typeCtorArgs = do { x <- typeAtom; xs <- option [] typeCtorArgs; return (x : xs) } <|>
               do { x <- identifier; xs <- option [] typeCtorArgs; return ((Instance x []) : xs) } <|>
			   do { x <- mapType; return [x] }

type_ :: Parser Type
type_ = typeAtom <|> mapType <|>
	do { id <- identifier; args <- option [] typeCtorArgs; return (Instance id args) }
	<?> "type"


{- Expressions -}

qop :: Parser QOp
qop = (do { reserved "forall"; return Forall }) <|> (do { reserved "exists"; return Exists })
	
e9 :: Parser Expression
e9 = do { reserved "false"; return FF } <|>
     do { reserved "true"; return TT } <|> 
	 do { n <- natural; return (Numeral n) } <|> 
	 -- str bitVector <|>
	 do { id <- identifier; ( do { args <- parens (commaSep e0); return (Application id args) }) <|> return (Var id) } <|>
	 do { reserved "old"; e <- parens e0; return (Old  e) } <|>
	 try (parens e0) <|>
	 parens (do { 
		op <- qop; 
		args <- typeArgs; 
		vars <- commaSep1 idsType; 
		reservedOp "::"; 
		many trigAttr; 
		e <- e0; 
		return (Quantified op args (concat vars) e )})

e8 :: Parser Expression
e8 = do { e <- e9; mapOps <- many (brackets (mapOp)); return (foldr (.) id (reverse mapOps) e) }

mapOp :: Parser (Expression -> Expression)
mapOp = do { args <- commaSep1 e0; option ((flip MapSelection) args) (do { reservedOp ":="; e <- e0; return (flip ((flip MapUpdate) args) e)}) }

e0 :: Parser Expression	
e0 = buildExpressionParser table e8 <?> "expression"

table = [[unOp Neg, unOp Not],
         [binOp Times AssocLeft, binOp Div AssocLeft, binOp Mod AssocLeft],
		 [binOp Plus AssocLeft, binOp Minus AssocLeft],
		 --[binOp Concat AssocLeft],
		 [binOp Eq AssocNone, binOp Neq AssocNone, binOp Ls AssocNone, binOp Leq AssocNone, binOp Gt AssocNone, binOp Geq AssocNone, binOp Lc AssocNone],
		 [binOp And AssocLeft], -- ToDo: && and || on the same level but do not interassociate
		 [binOp Or AssocLeft],
		 [binOp Implies AssocRight],
		 [binOp Equiv AssocRight]]
	where
		binOp node assoc = Infix (do { reservedOp (token node binOpTokens); return (\e1 e2 -> (BinaryExpression node e1 e2)) }) assoc
		unOp node = Prefix (do { reservedOp (token node unOpTokens); return (\e -> UnaryExpression node e)})

{- Misc -}

skip :: Parser a -> Parser ()
skip p = do { p; return () }

idsType :: Parser [(Id, Type)]
idsType = do { ids <- commaSep1 identifier; reservedOp ":"; t <- type_; return (zip ids (repeat t)) }

trigAttr :: Parser ()
trigAttr = (try trigger) <|> attribute <?> "attribute or trigger"

trigger :: Parser ()
trigger = skip (braces (commaSep1 e0)) <?> "trigger"

attribute :: Parser ()
attribute = skip (braces (do {reservedOp ":"; identifier; commaSep1 ((skip e0) <|> (skip stringLiteral))})) <?> "attribute"
		
{-
qop :: Parser String
qop = str (reserved "forall" <|> reserved "exists")

qsep :: Parser String
qsep = str (reservedOp "::")

typeArgs :: Parser String
typeArgs = str (angles (commaSep1 identifier))

bitVectorType :: Parser String
bitVectorType = do { reserved "bv"; n <- natural; return (show n)}

typeAtom :: Parser String
typeAtom = str (reserved "int") <|> str (reserved "bool") <|> bitVectorType <|> parens type_

mapType :: Parser String
mapType = do {optional typeArgs; brackets (commaSep type_); type_; return "map type"}

typeCtorArgs :: Parser String
typeCtorArgs = do {type_; optional typeCtorArgs; return "typeCtorArgs"} <|>
	do {identifier; optional typeCtorArgs; return "typeCtorArgs"} <|>
	mapType

type_ :: Parser String
type_ = typeAtom <|> mapType <|> do {identifier; optional typeCtorArgs; return "type identifier"}

idsType :: Parser String
idsType = do { commaSep1 identifier; symbol ":"; type_}

trigAttr :: Parser String
trigAttr = trigger <|> attribute

trigger :: Parser String
trigger = str (braces (commaSep1 e0))

attribute :: Parser String
attribute = braces (do {reservedOp ":"; identifier; commaSep1 attrArg; return "attribute"})

attrArg :: Parser String
attrArg = e0 <|> stringLiteral

bitVector :: Parser String
bitVector = do {
		i <- many1 digit;
		string "bv";
		natural;
		return i
	}
-}			