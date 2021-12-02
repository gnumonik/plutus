{-# LANGUAGE DeriveAnyClass    #-}
{-# LANGUAGE OverloadedStrings #-}

module PlutusCore.Parser.Type
    ( Keyword (..)
    , Token (..)
    , allKeywords
    , IdentifierState
    , newIdentifier
    , emptyIdentifierState
    , identifierStateFrom
    ) where

import PlutusPrelude

import PlutusCore.Name

import Control.Monad.State
import Data.Map qualified as M
import Data.Text qualified as T
import Prettyprinter.Internal ((<+>))
import Text.Megaparsec (SourcePos)

{- Note [Literal Constants]
For literal constants, we accept certain types of character sequences that are
then passed to user-defined parsers which convert them to built-in constants.
Literal constants have to specify the type of the constant, so we have (con
integer 9), (con string "Hello"), and so on.  This allows us to use the same
literal syntax for different types (eg, integer, short, etc) and shift most
of the responsibility for parsing constants out of the lexer and into the
parser (and eventually out of the parser to parsers supplied by the types
themselves).

In the body of a constant we allow:
  * ()
  * Single-quoted possibly empty sequences of printable characters
  * Double-quoted possibly empty sequences of printable characters
  * Unquoted non-empty sequences of printable characters not including '(' or ')',
    and not beginning with a single or double quote.  Spaces are allowed in the
    body of the sequence, but are ignored at the beginning or end.

"Printable" here uses Alex's definition: Unicode code points 32 to 0x10ffff.
This includes spaces but excludes tabs amongst other things.  One can use the
usual escape sequences though, as long as the type-specific parser deals with
them.

These allow us to parse all of the standard types.  We just return all of the
characters in a TkLiteralConst token, not attempting to do things like stripping
off quotes or interpreting escape sequences: it's the responsibility of the
parser for the relevant type to do these things.  Note that 'read' will often do
the right thing.

The final item above even allows the possibility of parsing complex types such as
tuples and lists as long as parentheses are not involved.  For example, (con
tuple <1,2.3,"yes">) and (con intlist [1, 2, -7]) are accepted by the lexer, as
is the somewhat improbable-looking (con intseq 12 4 55 -4).  Comment characters
are also allowed, but are not treated specially.  We don't allow (con )) or (con
tuple (1,2,3)) because it would be difficult for the lexer to decide when it
had reached the end of the literal: consider a tuple containing a quoted string
containing ')', for example.
-}

-- | A keyword in Plutus Core. Some of these are only for UPLC or TPLC, but it's simplest to share
-- the lexer, so we have a joint enumeration of them.
data Keyword
    = KwLam
    | KwProgram
    | KwCon  --TODO `andBegin` conargs
    -- ^ (con tyname) or (con tyname const)
    | KwBuiltin --TODO `andBegin` builtin
    -- ^ Switch the lexer into a mode where it's looking for a builtin id.
    -- These are converted into Builtin names in the parser.
    -- Outside this mode, all ids are parsed as Names.
    | KwError
    -- TPLC only
    | KwAbs
    | KwFun
    | KwAll
    | KwType
    | KwIFix
    | KwIWrap
    | KwUnwrap
    -- UPLC only
    | KwForce
    | KwDelay
    deriving (Show, Eq, Ord, Enum, Bounded, Generic, NFData)

-- See note [Literal Constants].
-- | A literal constant.
data LiteralConst
    = EmptyBrackets
    -- ^ ()
    | SingleQuotedChars
    -- ^ Single-quoted possibly empty sequences of printable characters
    | DoubleQuotedChars
    -- ^ Double-quoted possibly empty sequences of printable characters
    | UnQuotedChars
    -- ^ Unquoted non-empty sequences of printable characters not including '(' or ')',
    -- and not beginning with a single or double quote.  Spaces are allowed in the
    -- body of the sequence, but are ignored at the beginning or end.
    deriving (Show, Eq, Ord, Generic, NFData)

-- | A token generated by the tker.
data Token
    = TkName  { tkLoc        :: SourcePos
              , tkName       :: T.Text
              , tkIdentifier :: Unique -- ^ A 'Unique' assigned to the identifier during lexing.
              }
    | TkBuiltinFnId    { tkLoc :: SourcePos, tkBuiltinFnId   :: T.Text }
    | TkBuiltinTypeId  { tkLoc :: SourcePos, tkBuiltinTypeId :: T.Text }
    | TkConArgs        { tkLoc :: SourcePos, tkConArgsTy :: T.Text, tkConArgsName :: LiteralConst}
    -- ^ Things that can follow 'con': the name of a built-in type and possibly a literal constant of that type.
    | TkKeyword        { tkLoc :: SourcePos, tkKeyword       :: Keyword }
    | TkLiteralConst   { tkLoc :: SourcePos, tkLiteralConst  :: LiteralConst }
    | TkNat            { tkLoc :: SourcePos, tkNat           :: Natural }
    | EOF              { tkLoc :: SourcePos }
    deriving (Show, Eq, Ord, Generic, NFData)

instance Pretty Keyword where
    pretty KwAbs     = "abs"
    pretty KwLam     = "lam"
    pretty KwIFix    = "ifix"
    pretty KwFun     = "fun"
    pretty KwAll     = "all"
    pretty KwType    = "type"
    pretty KwProgram = "program"
    pretty KwCon     = "con"
    pretty KwIWrap   = "iwrap"
    pretty KwBuiltin = "builtin"
    pretty KwUnwrap  = "unwrap"
    pretty KwError   = "error"
    pretty KwForce   = "force"
    pretty KwDelay   = "delay"

instance Pretty LiteralConst where
    pretty EmptyBrackets     = "lit ()"
    pretty SingleQuotedChars = "lit '"
    pretty DoubleQuotedChars = "lit \""
    pretty UnQuotedChars     = "lit"

instance Pretty Token where
    pretty (TkName _ n _)            = pretty n
    pretty (TkNat _ n)               = pretty n
    pretty (TkBuiltinFnId _ ident)   = pretty ident
    pretty (TkBuiltinTypeId _ ident) = pretty ident
    pretty (TkConArgs _ ty lit)      = pretty ty <+> pretty lit
    pretty (TkLiteralConst _ lit)    = pretty lit
    pretty (TkKeyword _ kw)          = pretty kw
    pretty EOF{}                     = mempty

-- | The list of all 'Keyword's.
allKeywords :: [Keyword]
allKeywords = [minBound .. maxBound]

-- | An 'IdentifierState' includes a map indexed by 'Int's as well as a map
-- indexed by 'ByteString's. It is used during parsing.
type IdentifierState = (M.Map T.Text Unique, Unique)

emptyIdentifierState :: IdentifierState
emptyIdentifierState = (mempty, Unique 0)

identifierStateFrom :: Unique -> IdentifierState
identifierStateFrom u = (mempty, u)

newIdentifier :: (MonadState IdentifierState m) => T.Text -> m Unique
newIdentifier str = do
    (ss, nextU) <- get
    case M.lookup str ss of
        Just k -> pure k
        Nothing -> do
            let nextU' = Unique $ unUnique nextU + 1
            put (M.insert str nextU ss, nextU')
            pure nextU
