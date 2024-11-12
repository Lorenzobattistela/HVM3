module HVML.Parse where

import Data.List
import Data.Maybe
import Data.Word
import Debug.Trace
import HVML.Show
import HVML.Type
import Highlight (highlightError)
import System.Console.ANSI
import Text.Parsec hiding (State)
import Text.Parsec.Error
import Text.Parsec.Pos
import Text.Parsec.String
import qualified Data.Map.Strict as MS

-- Core Parsers
-- ------------

data ParserState = ParserState {
  constructorAliases :: MS.Map String Word64
}

type ParserM = Parsec String ParserState

parseCore :: ParserM Core
parseCore = do
  skip
  head <- lookAhead anyChar
  case head of
    '*' -> do
      consume "*"
      return Era
    'λ' -> do
      consume "λ"
      vr0 <- parseName
      bod <- parseCore
      return $ Lam vr0 bod
    '(' -> do
      next <- lookAhead (anyChar >> anyChar)
      case next of
        '+' -> parseOper OP_ADD
        '-' -> parseOper OP_SUB
        '*' -> parseOper OP_MUL
        '/' -> parseOper OP_DIV
        '%' -> parseOper OP_MOD
        '=' -> parseOper OP_EQ
        '!' -> parseOper OP_NE
        '&' -> parseOper OP_AND
        '|' -> parseOper OP_OR
        '^' -> parseOper OP_XOR
        '<' -> do
          next <- lookAhead (anyChar >> anyChar >> anyChar)
          case next of
            '<' -> parseOper OP_LSH
            '=' -> parseOper OP_LTE
            _   -> parseOper OP_LT
        '>' -> do
          next <- lookAhead (anyChar >> anyChar >> anyChar)
          case next of
            '>' -> parseOper OP_RSH
            '=' -> parseOper OP_GTE
            _   -> parseOper OP_GT
        _ -> do
          consume "("
          fun <- parseCore
          args <- many $ do
            closeWith ")"
            arg <- parseCore
            return arg
          char ')'
          return $ foldl App fun args
    '&' -> do
      consume "&"
      lab <- read <$> many1 digit
      consume "{"
      tm0 <- parseCore
      tm1 <- parseCore
      consume "}"
      return $ Sup lab tm0 tm1
    '!' -> do
      consume "!"
      consume "&"
      lab <- read <$> many1 digit
      consume "{"
      dp0 <- parseName
      dp1 <- parseName
      consume "}"
      consume "="
      val <- parseCore
      bod <- parseCore
      return $ Dup lab dp0 dp1 val bod
    '@' -> do
      consume "@"
      nam <- parseName
      return $ Ref nam 0
    '#' -> parseCtr
    '~' -> parseMat
    _ -> do
      name <- parseName
      case reads name of
        [(num, "")] -> return $ U32 (fromIntegral (num :: Integer))
        _           -> return $ Var name

parseCtr :: ParserM Core
parseCtr = do
  consume "#"
  nam <- parseName
  cid <- if length nam == 0
    then return 0
    else do
      ali <- constructorAliases <$> getState
      case MS.lookup nam ali of
        Just id -> return id
        Nothing -> case reads nam of
          [(num, "")] -> return (fromIntegral (num :: Integer))
          otherwise   -> fail $ "Unknown constructor: " ++ nam
  fds <- option [] $ do
    try $ consume "{"
    fds <- many $ do
      closeWith "}"
      parseCore
    consume "}"
    return fds
  return $ Ctr cid fds

parseMat :: ParserM Core
parseMat = do
  consume "~"
  val <- parseCore
  consume "{"
  css <- many $ do
    closeWith "}"
    consume "#"
    name <- parseName
    ali <- constructorAliases <$> getState
    cid <- case MS.lookup name ali of
      Just id -> return id
      Nothing -> case reads name of
        [(num, "")] -> return (fromIntegral (num :: Integer))
        _ -> if name == "_"
          then return 0xFFFFFFF
          else fail $ "Unknown constructor: " ++ name
    consume ":"
    cas <- parseCore
    return (cid, cas)
  consume "}"
  let sortedCss = map snd $ sortOn fst css
  return $ Mat val sortedCss

parseOper :: Oper -> ParserM Core
parseOper op = do
  consume "("
  consume (operToString op)
  nm0 <- parseCore
  nm1 <- parseCore
  consume ")"
  return $ Op2 op nm0 nm1

parseName :: ParserM String
parseName = skip >> many (alphaNum <|> char '_')

parseDef :: ParserM (String, Core)
parseDef = do
  try $ do
    skip
    consume "@"
  name <- parseName
  skip
  consume "="
  core <- parseCore
  return (name, core)

parseADT :: ParserM ()
parseADT = do
  try $ do
    skip
    consume "data"
  name <- parseName
  skip
  consume "{"
  constructors <- many parseADTCtr
  consume "}"
  let aliases = zip (map fst constructors) [0..]
  modifyState (\s -> s { constructorAliases = MS.union (MS.fromList aliases) (constructorAliases s) })

parseADTCtr :: ParserM (String, [String])
parseADTCtr = do
  skip
  consume "#"
  name <- parseName
  fields <- option [] $ do
    try $ consume "{"
    fds <- many $ do
      closeWith "}"
      parseName
    skip
    consume "}"
    return fds
  skip
  return (name, fields)

parseBook :: ParserM [(String, Core)]
parseBook = do
  skip
  many parseADT
  defs <- many parseDef
  skip
  eof
  return defs

doParseCore :: String -> IO Core
doParseCore code = case runParser parseCore (ParserState MS.empty) "" code of
  Right core -> return $ core
  Left  err  -> do
    showParseError "" code err
    return $ Ref "⊥" 0

doParseBook :: String -> IO Book
doParseBook code = case runParser parseBook (ParserState MS.empty) "" code of
  Right defs -> return $ createBook defs
  Left  err  -> do
    showParseError "" code err
    return $ Book MS.empty MS.empty MS.empty

-- Helper Parsers
-- --------------

consume :: String -> ParserM String
consume str = spaces >> string str

closeWith :: String -> ParserM ()
closeWith str = try $ do
  spaces
  notFollowedBy (string str)

skip :: ParserM ()
skip = skipMany (parseSpace <|> parseComment) where
  parseSpace = (try $ do
    space
    return ()) <?> "space"
  parseComment = (try $ do
    string "//"
    skipMany (noneOf "\n")
    char '\n'
    return ()) <?> "Comment"

-- Adjusting
-- ---------

createBook :: [(String, Core)] -> Book
createBook defs = 
  let nameToId' = MS.fromList $ zip (map fst defs) [0..]
      idToName' = MS.fromList $ map (\(k,v) -> (v,k)) $ MS.toList nameToId'
      decorDefs = map (\ (name, core) -> (nameToId' MS.! name, decorateFnIds nameToId' core)) defs
      idToCore' = MS.fromList decorDefs
  in Book idToCore' idToName' nameToId'

decorateFnIds :: MS.Map String Word64 -> Core -> Core
decorateFnIds fids term = case term of
  Var nam       -> Var nam
  Ref nam _     -> Ref nam (fids MS.! nam)
  Lam x bod     -> Lam x (decorateFnIds fids bod)
  App f x       -> App (decorateFnIds fids f) (decorateFnIds fids x)
  Sup l x y     -> Sup l (decorateFnIds fids x) (decorateFnIds fids y)
  Dup l x y v b -> Dup l x y (decorateFnIds fids v) (decorateFnIds fids b)
  Ctr cid fds   -> Ctr cid (map (decorateFnIds fids) fds)
  Mat x cs      -> Mat (decorateFnIds fids x) (map (decorateFnIds fids) cs)
  Op2 op x y    -> Op2 op (decorateFnIds fids x) (decorateFnIds fids y)
  U32 n         -> U32 n
  Era           -> Era

-- Errors
-- ------

-- Error handling
extractExpectedTokens :: ParseError -> String
extractExpectedTokens err =
    let expectedMsgs = [msg | Expect msg <- errorMessages err, msg /= "space", msg /= "Comment"]
    in intercalate " | " expectedMsgs

showParseError :: String -> String -> ParseError -> IO ()
showParseError filename input err = do
  let pos = errorPos err
  let lin = sourceLine pos
  let col = sourceColumn pos
  let errorMsg = extractExpectedTokens err
  putStrLn $ setSGRCode [SetConsoleIntensity BoldIntensity] ++ "\nPARSE_ERROR" ++ setSGRCode [Reset]
  putStrLn $ "- expected: " ++ errorMsg
  putStrLn $ "- detected:"
  putStrLn $ highlightError (lin, col) (lin, col + 1) input
  putStrLn $ setSGRCode [SetUnderlining SingleUnderline] ++ filename ++ setSGRCode [Reset]
