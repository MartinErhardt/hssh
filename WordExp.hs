--   Copyright 2022 Martin Erhardt
--
--   Licensed under the Apache License, Version 2.0 (the "License");
--   you may not use this file except in compliance with the License.
--   You may obtain a copy of the License at
--
--       http://www.apache.org/licenses/LICENSE-2.0
--
--   Unless required by applicable law or agreed to in writing, software
--   distributed under the License is distributed on an "AS IS" BASIS,
--   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
--   See the License for the specific language governing permissions and
--   limitations under the License.

module WordExp(
  expandWord,
  expandNoSplit
) where
import ShCommon
import ExpArith
import Control.Monad.Trans.Class
import Control.Monad.Trans.State.Lazy
import Data.Stack
import qualified Data.List as L
import qualified Data.Map as Map
import Text.Parsec
import Text.Parsec.String (Parser)
import System.Posix.IO
import System.Posix.Process
import System.IO
import System.Exit

type Field = String

launchCmdSub :: (String -> Shell ExitCode) -> String -> Shell String
launchCmdSub launcher cmd = do
  pipe      <- lift createPipe
  curEnv    <- get
  forkedPId <- lift . forkProcess $ do
    closeFd . fst $ pipe
    dupTo (snd pipe) stdOutput
    evalStateT (launcher cmd) curEnv
    return ()
  lift $ closeFd . snd $ pipe
  lift $ getProcessStatus False False forkedPId -- TODO Error handling
  lift $ ( (fdToHandle . fst $ pipe) >>= hGetContents >>= return . reverse . dropWhile (=='\n') . reverse)

expandParams :: String -> Shell String
expandParams name = getVar name >>= return . handleVal
  where handleVal var =  case var of (Just val) -> val -- set and not null
                                     (Nothing)  -> ""  -- unset

fieldExpand :: String -> Shell [Field]
fieldExpand s = getVar "IFS" >>= return . ifsHandler >>= (flip parse2Shell) s . split2F
  where ifsHandler var = case var of (Just val) -> val
                                     (Nothing)  -> " \t\n"

split2F :: String -> Parser [Field]
split2F ifs = (eof >> return [""])
          <|> ( (\c fs -> [ [c] ++ head fs] ++ tail fs) <$> noneOf ifs <*> split2F ifs )
          <|> (                                  oneOf ifs >> ([""]++) <$> split2F ifs )

escapeUnorigQuotes :: Parser String
escapeUnorigQuotes = (eof >> return "") <|> handle <$> anyChar <*> escapeUnorigQuotes
  where handle c str =  (if c `elem` "\xfe\xff\"'\\" then ['\xfe',c] else [c]) ++ str

removeEscReSplit :: Parser [Field]
removeEscReSplit = (eof >> return [""])
                <|> (char '\xff' >> removeEscReSplit >>= return . ([""]++) )
                <|> (char '\xfe' >> appendC <$> anyChar <*> removeEscReSplit )
                <|> (               appendC <$> anyChar <*> removeEscReSplit )
  where appendC c rest = [[c] ++ head rest] ++ tail rest

removeQuotes :: Parser String
removeQuotes = (eof >> return "")
           <|> (char '\''   >> (++) <$> quoteEsc escapes       (char '\'' >> return "") <*> removeQuotes )
           <|> (char '"'    >> (++) <$> quoteEsc dQuoteRecCond (char '"'  >> return "") <*> removeQuotes )
           <|> (char '\\'   >> (++) <$> (anyChar >>= return . (:[]) )                   <*> removeQuotes )
           <|> (char '\xfe' >> (++) <$> (anyChar >>= return . (['\xfe']++) . (:[]) )    <*> removeQuotes )
           <|> (               (++) <$> (anyChar >>= return . (:[]) )                   <*> removeQuotes )
  where escapes = (++) <$> (escape '\xfe' <|> (char '\\' >> anyChar >>= return . (:[])) )
        dQuoteRecCond = escapes <|> ((++) <$> getDollarExp id stackNew)

parse2Shell :: (Show a) => Parser a -> String -> Shell a
parse2Shell parser = return . (\(Right v) -> v) . parse parser "string"

data ExpType = NoExp | ParamExp | CmdExp | ArithExp deriving (Eq,Show,Enum)
data ExpTok = ExpTok { expTyp :: ExpType
                     , fSplit :: Bool
                     , expStr :: String} deriving(Eq, Show)

parseExps :: Bool -> [String] -> Parser [ExpTok]
parseExps doFExps names = (eof >> return [])
        <|> (char '$'  >>((++) . (:[]) . (ExpTok ParamExp doFExps)       <$> getVExp names    <*> parseExps doFExps names
                      <|> (++) . (:[]) . (ExpTok ParamExp doFExps)       <$> getExp "{" "}"   <*> parseExps doFExps names
                      <|> (++) . (:[]) . (ExpTok ArithExp doFExps)       <$> getExp "((" "))" <*> parseExps doFExps names
                      <|> (++) . (:[]) . (ExpTok CmdExp   doFExps)       <$> getExp "(" ")"   <*> parseExps doFExps names ) )
        <|> (char '`'  >> (++) . (:[]) . (ExpTok CmdExp   doFExps)       <$> bQuoteRem        <*> parseExps doFExps names )
        <|> (char '\'' >> (++) . (:[]) . (ExpTok NoExp False) . enc '\'' <$> quoteRem         <*> parseExps doFExps names )
        <|> (char '"'  >> (++) . processDQuote                           <$> dQuoteRem        <*> parseExps doFExps names )
        <|>               (++) . (:[]) . (ExpTok NoExp False)            <$> readNoExp        <*> parseExps doFExps names
  where enc c = (++[c]) . ([c]++)
        readNoExp = (++) <$> (escape '\\' <|> (noneOf "$`'\"" >>= return . (:[])) ) <*> (readNoExp <|> return "")

        quoteRem =  quote  (char '\'' >> return "")
        dQuoteRem = dQuote (char '"'  >> return "")
        bQuoteRem = quoteEsc ( (++) <$> (char '\\' >> (((char '\\' <|> char '$' <|> char '`') >> anyChar >>= return . (:[]) )
                                                  <|> (anyChar >>= return . (['\\']++) . (:[]) ) ) ) ) (char '`' >> return "")
        getVExp :: [String] -> Parser String
        getVExp names = foldl1 (<|>) ((\a -> try $ string a >> return a ) <$> names )
        getExp begin end = try( string begin) >> (quote $ getDollarExp (\_ -> "") (stackPush stackNew end) )
        processDQuote = enc (ExpTok NoExp False "\"") . (\(Right v) -> v) . parse (parseExps False names) "qE"

execExp :: (String -> Shell ExitCode) -> ExpTok -> Shell [Field]
execExp launcher (ExpTok NoExp _ s) = return [s]
execExp launcher (ExpTok t split s) = case t of CmdExp   -> launchCmdSub launcher s
                                                ParamExp -> expandParams s
                                                ArithExp -> expandArith s
                         >>= return . (\(Right v) -> v) . parse escapeUnorigQuotes "EscapeUnorigQuotes"
                         >>= if split then fieldExpand else return . (:[])

expandWord :: (String -> Shell ExitCode) -> Bool -> String -> Shell [Field]
expandWord launcher split cmdWord = do
  env  <- get
  exps <- parse2Shell (parseExps split $ names env) cmdWord
  -- lift $ print exps
  fs   <- foldl1 (\a1 a2 -> ppJoinEnds <$> a1 <*> a2) (execExp launcher <$> exps)
-- TODO expandedPNFields <- Pathname expansion
-- how to exploit my shell? on command substitution print to stdout ['\0','\0', 'f'] -> profit
-- expand split2F to accept [String] aa field seperator
  -- lift $ print fs
  noQuotes <- parse2Shell removeQuotes ( concat . L.intersperse ['\xff'] $ filter (/="") fs)
  -- lift $ putStrLn noQuotes
  res <- parse2Shell removeEscReSplit noQuotes-- TODO expandedPNFields <- Pathname expansion
  -- lift $ print res
  return res
  where names env = fst <$> (Map.toList $ var env)
        ppJoinEnds l1 l2 = init l1 ++ [last l1 ++ head l2] ++ tail l2

expandNoSplit :: (String -> Shell ExitCode) -> String -> Shell Field
expandNoSplit launcher cmdWord = expandWord launcher False cmdWord >>= return . head
