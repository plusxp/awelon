{-# LANGUAGE CPP #-}
-- just a few classifiers for characters
-- (I use this instead of Data.Char for stability and control of AO)
module AO.Char
    ( isWordSep, isWordStart, isWordCont
    , isTokenChar
    , isControl, isDigit, isNZDigit, isHexDigit
    , isPathSep
    ) where

-- most word separators are spaces, but [] and (|) are also okay
-- (this parser doesn't actually support ambiguous (foo|bar) code)
isWordSep :: Char -> Bool
isWordSep c = sp || block || amb where
    sp = (' ' == c) || ('\n' == c)
    block = ('[' == c) || (']' == c)
    amb = ('(' == c) || ('|' == c) || (')' == c)

isWordStart, isWordCont :: Char -> Bool
isWordCont c = not (sep || ctl || txt || tok) where
    sep = isWordSep c
    ctl = isControl c
    txt = '"' == c
    tok = '{' == c || '}' == c
isWordStart c = isWordCont c && not (isDigit c || '%' == c || '@' == c)

-- in token {foo} the token text 'foo' cannot
-- contain newlines or curly braces
isTokenChar :: Char -> Bool
isTokenChar c = not (lf || cb) where
    lf = ('\n' == c)
    cb = ('{' == c) || ('}' == c)


isControl, isDigit, isNZDigit, isHexDigit :: Char -> Bool
isControl c = isC0 || isC1orDEL where
    n = fromEnum c
    isC0 = n <= 0x1F
    isC1orDEL = n >= 0x7F && n <= 0x9F
isDigit c = ('0' <= c) && (c <= '9')
isNZDigit c = isDigit c && not ('0' == c)
isHexDigit c = isDigit c || smallAF || bigAF where
    smallAF = ('a' <= c) && (c <= 'f')
    bigAF = ('A' <= c) && (c <= 'F')


-- OS-dependent AO_PATH separator (used by AOFile)
isPathSep :: Char -> Bool
#if defined(WinPathFmt)
isPathSep = (== ';') -- flag defined if os(windows) in cabal file
#else
isPathSep = (== ':') -- suitable for most *nix systems and Mac
#endif


