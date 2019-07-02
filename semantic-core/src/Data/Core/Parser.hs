module Data.Core.Parser
  ( module Text.Trifecta
  , core
  , lit
  , expr
  , lvalue
  ) where

-- Consult @doc/grammar.md@ for an EBNF grammar.

import           Control.Applicative
import qualified Data.Char as Char
import           Data.Core (Core, Edge(..))
import qualified Data.Core as Core
import           Data.Name
import           Data.Semigroup
import           Data.String
import qualified Text.Parser.Token as Token
import qualified Text.Parser.Token.Highlight as Highlight
import           Text.Trifecta hiding (ident)

-- * Identifier styles and derived parsers

validIdentifierStart :: Char -> Bool
validIdentifierStart c = not (Char.isDigit c) && isSimpleCharacter c

coreIdents :: TokenParsing m => IdentifierStyle m
coreIdents = Token.IdentifierStyle
  { _styleName              = "core"
  , _styleStart             = satisfy validIdentifierStart
  , _styleLetter            = satisfy isSimpleCharacter
  , _styleReserved          = reservedNames
  , _styleHighlight         = Highlight.Identifier
  , _styleReservedHighlight = Highlight.ReservedIdentifier
  }

reserved :: (TokenParsing m, Monad m) => String -> m ()
reserved = Token.reserve coreIdents

identifier :: (TokenParsing m, Monad m, IsString s) => m s
identifier = choice [quote, plain] <?> "identifier" where
  plain = Token.ident coreIdents
  quote = between (string "#{") (symbol "}") (fromString <$> some (noneOf "{}"))

-- * Parsers (corresponding to EBNF)

core :: (TokenParsing m, Monad m) => m (Core Name)
core = expr

expr :: (TokenParsing m, Monad m) => m (Core Name)
expr = atom `chainl1` go where
  go = choice [ (Core....) <$ dot
              , (Core.$$)  <$ notFollowedBy dot
              ]

atom :: (TokenParsing m, Monad m) => m (Core Name)
atom = choice
  [ comp
  , ifthenelse
  , edge
  , lit
  , ident
  , assign
  , parens expr
  ]

comp :: (TokenParsing m, Monad m) => m (Core Name)
comp = braces (sconcat <$> sepEndByNonEmpty expr semi) <?> "compound statement"

ifthenelse :: (TokenParsing m, Monad m) => m (Core Name)
ifthenelse = Core.if'
  <$ reserved "if"   <*> core
  <* reserved "then" <*> core
  <* reserved "else" <*> core
  <?> "if-then-else statement"

assign :: (TokenParsing m, Monad m) => m (Core Name)
assign = (Core..=) <$> try (lvalue <* symbolic '=') <*> core <?> "assignment"

edge :: (TokenParsing m, Monad m) => m (Core Name)
edge = kw <*> expr where kw = choice [ Core.edge Lexical <$ reserved "lexical"
                                     , Core.edge Import  <$ reserved "import"
                                     , Core.load         <$ reserved "load"
                                     ]

lvalue :: (TokenParsing m, Monad m) => m (Core Name)
lvalue = choice
  [ Core.let' <$ reserved "let" <*> name
  , ident
  , parens expr
  ]

-- * Literals

name :: (TokenParsing m, Monad m) => m Name
name = User <$> identifier <?> "name" where

lit :: (TokenParsing m, Monad m) => m (Core Name)
lit = let x `given` n = x <$ reserved n in choice
  [ Core.bool True  `given` "#true"
  , Core.bool False `given` "#false"
  , Core.unit       `given` "#unit"
  , Core.frame      `given` "#frame"
  , lambda
  ] <?> "literal"

lambda :: (TokenParsing m, Monad m) => m (Core Name)
lambda = Core.lam <$ lambduh <*> name <* arrow <*> core <?> "lambda" where
  lambduh = symbolic 'λ' <|> symbolic '\\'
  arrow   = symbol "→"   <|> symbol "->"

ident :: (Monad m, TokenParsing m) => m (Core Name)
ident = pure <$> name <?> "identifier"
