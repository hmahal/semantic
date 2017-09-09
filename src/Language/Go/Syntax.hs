{-# LANGUAGE DataKinds, DeriveAnyClass, RankNTypes, TypeOperators #-}
module Language.Go.Syntax
( assignment
, Syntax
, Grammar
, Term
) where

import Data.Functor (void)
import Data.Record
import Data.Syntax (emptyTerm, handleError, makeTerm)
import qualified Data.Syntax as Syntax
import Data.Syntax.Assignment hiding (Assignment, Error)
import qualified Data.Syntax.Assignment as Assignment
import qualified Data.Syntax.Comment as Comment
import qualified Data.Syntax.Declaration as Declaration
import qualified Data.Syntax.Expression as Expression
import qualified Data.Syntax.Literal as Literal
import qualified Data.Syntax.Statement as Statement
import qualified Data.Syntax.Type as Type
import Data.Union
import GHC.Stack
import Language.Go.Grammar as Grammar
import qualified Term

type Syntax =
  '[ Comment.Comment
   , Declaration.Constructor
   , Declaration.Function
   , Declaration.Import
   , Declaration.Interface
   , Declaration.Method
   , Declaration.Module
   , Expression.Call
   , Expression.MemberAccess
   , Literal.Channel
   , Literal.Hash
   , Literal.Integer
   , Literal.KeyValue
   , Literal.TextElement
   , Statement.Assignment
   , Syntax.Error
   , Syntax.Empty
   , Syntax.Identifier
   , Syntax.Program
   , Type.Annotation
   , []
   ]

type Term = Term.Term (Union Syntax) (Record Location)
type Assignment = HasCallStack => Assignment.Assignment [] Grammar Term

assignment :: Assignment
assignment = handleError $ makeTerm <$> symbol SourceFile <*> children (Syntax.Program <$> many expression)

expression :: Assignment
expression = handleError
           $  callExpression
          <|> comment
          <|> constVarDeclaration
          <|> constVarSpecification
          <|> expressionList
          <|> fieldDeclaration
          <|> functionDeclaration
          <|> importDeclaration
          <|> importSpec
          <|> typedIdentifier
          <|> literal
          <|> methodDeclaration
          <|> methodSpec
          <|> packageClause
          <|> parameterDeclaration
          <|> structType
          <|> typeDeclaration

identifiers :: Assignment
identifiers = makeTerm <$> location <*> many identifier

expressions :: Assignment
expressions = makeTerm <$> location <*> many expression

literal :: Assignment
literal =  channelType
       <|> identifier
       <|> interpretedStringLiteral
       <|> intLiteral
       <|> typeLiteral
       <|> rawStringLiteral
       <|> structType


-- Literals

intLiteral :: Assignment
intLiteral = makeTerm <$> symbol IntLiteral <*> (Literal.Integer <$> source)

rawStringLiteral :: Assignment
rawStringLiteral = makeTerm <$> symbol RawStringLiteral <*> (Literal.TextElement <$> source)

typedIdentifier :: Assignment
typedIdentifier =  mkTypedIdentifier <$> symbol Identifier <*> source <*> types <*> source
  where
    mkTypedIdentifier loc' identifier' loc'' identifier'' = makeTerm loc' (Type.Annotation (makeTerm loc' (Syntax.Identifier identifier')) (makeTerm loc'' (Syntax.Identifier identifier'')))
    types =  symbol TypeIdentifier
         <|> symbol PointerType
         <|> symbol ParenthesizedType
         <|> symbol SliceType

channelType :: Assignment
channelType = makeTerm <$> symbol ChannelType <*> children (Literal.Channel <$> expression)

structType :: Assignment
structType = makeTerm <$> symbol StructType <*> children (Declaration.Constructor <$> emptyTerm <*> many fieldDeclaration)

identifier :: Assignment
identifier =
      mk FieldIdentifier
  <|> mk Identifier
  <|> mk PackageIdentifier
  <|> mk ParenthesizedType
  where mk s = makeTerm <$> symbol s <*> (Syntax.Identifier <$> source)

interpretedStringLiteral :: Assignment
interpretedStringLiteral = makeTerm <$> symbol InterpretedStringLiteral <*> (Literal.TextElement <$> source)

packageClause :: Assignment
packageClause = makeTerm <$> symbol PackageClause <*> children (Declaration.Module <$> identifier <*> pure [])

importDeclaration :: Assignment
importDeclaration = makeTerm <$> symbol ImportDeclaration <*> children (Declaration.Import <$> many expression)

importSpec :: Assignment
importSpec = symbol ImportSpec *> children expressions

comment :: Assignment
comment = makeTerm <$> symbol Comment <*> (Comment.Comment <$> source)

typeDeclaration :: Assignment
typeDeclaration = symbol TypeDeclaration *> children typeSpecs

typeSpecs :: Assignment
typeSpecs = makeTerm <$> location <*> many typeSpec

typeSpec :: Assignment
typeSpec =  mkStruct <$> symbol TypeSpec <*> children ((,) <$> typeLiteral <*> structType)
        <|> mkInterface <$> symbol TypeSpec <*> children ((,) <$> typeLiteral <*> interfaceType)
        <|> mkMap <$> symbol TypeSpec <*> children ((,) <$> typeLiteral <*> ((,) <$> symbol MapType <*> children ((,,,) <$> symbol TypeIdentifier <*> source <*> symbol TypeIdentifier <*> source)))
        <|> mkChannel <$> symbol TypeSpec <*> children ((,) <$> typeLiteral <*> channelType)
        <|> makeTerm <$> symbol TypeSpec <*> children (Type.Annotation <$> typeLiteral <*> typeLiteral)
structType :: Assignment
structType = makeTerm <$> symbol StructType <*> children (Declaration.Constructor <$> emptyTerm <*> many expression)
  where
    mkStruct loc (name, fields) = makeTerm loc $ Type.Annotation (makeTerm loc (Declaration.Constructor name fields)) name
    structType = symbol StructType *> children (many fieldDeclaration)

    mkInterface loc (name, interfaceBody) = makeTerm loc $ Type.Annotation (makeTerm loc (Declaration.Interface name interfaceBody)) name
    interfaceType = symbol InterfaceType *> children (many expression)

    mkMap loc (name, (mapLoc, (keyTypeLoc, keyTypeName, valueTypeLoc, valueTypeName))) =
      makeTerm loc $ Type.Annotation (makeTerm mapLoc (Literal.Hash (pure $ mapKeyValue keyTypeLoc keyTypeName valueTypeLoc valueTypeName))) name

    mkChannel loc (name, channel) = makeTerm loc $ Type.Annotation channel name

    mapKeyValue keyTypeLoc keyTypeName valueTypeLoc valueTypeName =
      makeTerm keyTypeLoc $
        Literal.KeyValue (makeTerm keyTypeLoc   (Type.Annotation (makeTerm keyTypeLoc   (Syntax.Empty)) (makeTerm keyTypeLoc   (Syntax.Identifier keyTypeName))))
                         (makeTerm valueTypeLoc (Type.Annotation (makeTerm valueTypeLoc (Syntax.Empty)) (makeTerm valueTypeLoc (Syntax.Identifier valueTypeName))))

fieldDeclaration :: Assignment
fieldDeclaration = mkFieldDeclaration <$> symbol FieldDeclaration <*> children ((,) <$> many identifier <*> typeLiteral)
  where mkFieldDeclaration loc (fields, type') = makeTerm loc $ Type.Annotation (makeTerm loc fields) type'

methodSpec :: Assignment
methodSpec =  handleError $ mkMethodSpec <$> symbol MethodSpec <*> children ((,,,,) <$> empty <*> identifier <*> parameters <*> (typeLiteral <|> parameters <|> emptyTerm) <*> empty)
  where parameters = makeTerm <$> symbol Parameters <*> children (many expression)
        empty = makeTerm <$> location <*> pure Syntax.Empty
        mkMethodSpec loc (receiver', name', params, optionaltypeLiteral, body') = makeTerm loc $ Type.Annotation (mkMethod loc receiver' name' params body') optionaltypeLiteral
        mkMethod loc empty' name' params empty'' = makeTerm loc $ Declaration.Method empty' name' (pure params) empty''

typeLiteral :: Assignment
typeLiteral =
      mk InterfaceType
  <|> mk TypeIdentifier
  <|> mk ParenthesizedType
  <|> mk PointerType
  <|> mk SliceType
  <|> qualifiedType
  where mk s = makeTerm <$> symbol s <*> (Syntax.Identifier <$> source)
        qualifiedType = makeTerm <$> symbol QualifiedType <*> children (Expression.MemberAccess <$> identifier <*> typeLiteral)

fieldDeclaration :: Assignment
fieldDeclaration =  mkFieldDeclarationWithTag <$> symbol FieldDeclaration <*> children ((,,) <$> many identifier <*> typeLiteral <*> optional literal)
  where
        mkFieldDeclarationWithTag loc (fields, type', (Just tag)) = makeTerm loc $ Type.Annotation (makeTerm loc (Type.Annotation (makeTerm loc fields) type')) tag
        mkFieldDeclarationWithTag loc (fields, type', Nothing) = makeTerm loc $ Type.Annotation (makeTerm loc fields) type'
constVarDeclaration :: Assignment
constVarDeclaration = (symbol ConstDeclaration <|> symbol VarDeclaration) *> children expressions

constVarSpecification :: Assignment
constVarSpecification = makeTerm <$> (symbol ConstSpec <|> symbol VarSpec) <*> children (Statement.Assignment
                                                                           <$> (annotatedLHS <|> identifiers)
                                                                           <*> expressions)
    where
      annotatedLHS = makeTerm <$> location <*> (Type.Annotation
                                              <$> (makeTerm <$> location <*> (manyTermsTill identifier (void (symbol TypeIdentifier))))
                                              <*> typeLiteral)

expressionList :: Assignment
expressionList = symbol ExpressionList *> children expressions

parameterDeclaration :: Assignment
parameterDeclaration = symbol ParameterDeclaration *> children expressions

block :: Assignment
block = symbol Block *> children expressions

functionDeclaration :: Assignment
functionDeclaration = mkTypedFunctionDeclaration <$> symbol FunctionDeclaration <*> children ((,,,) <$> typedIdentifier <*> parameters <*> types <*> block)
  where parameters = symbol Parameters *> children (many expression)
        types = symbol Parameters *> children expressions <|> emptyTerm
        mkTypedFunctionDeclaration loc (name', params', types', block') = makeTerm loc (Type.Annotation (makeTerm loc (Declaration.Function name' params' block')) types')

methodDeclaration :: Assignment
methodDeclaration = mkTypedMethodDeclaration <$> symbol MethodDeclaration <*> children ((,,,,) <$> receiver <*> identifier <*> parameters <*> typeLiteral <*> block)
  where parameters = symbol Parameters *> children (symbol ParameterDeclaration *> children (many typedIdentifier))
        receiver = symbol Parameters *> children (symbol ParameterDeclaration *> children typedIdentifier)
        mkTypedMethodDeclaration loc (receiver', name', parameters', type'', body') = makeTerm loc (Type.Annotation (makeTerm loc (Declaration.Method receiver' name' parameters' body')) type'')

callExpression :: Assignment
callExpression = makeTerm <$> symbol CallExpression <*> children (Expression.Call <$> identifier <*> pure [] <*> emptyTerm)

-- | Match a series of terms or comments until a delimiter is matched
manyTermsTill :: Show b => Assignment.Assignment [] Grammar Term -> Assignment.Assignment [] Grammar b -> Assignment.Assignment [] Grammar [Term]
manyTermsTill step end = manyTill (step <|> comment) end
