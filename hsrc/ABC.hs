{-# LANGUAGE PatternGuards #-}

-- | This module provides just enough to interpret ABC or AMBC code.
-- 
-- It does not typecheck or compile the stream. Performance is not
-- considered especially critical at this time, since this is meant
-- for bootstrapping a compiler, not final use.
--
-- To handle invocations requires calling out; this is modeled by a
-- monad for ABC. AMBC might be interpreted in MonadPlus. The AMBC
-- here will remain ambiguous across copies, so it isn't correct for AO.
-- 
module ABC
    ( V(..), Op(..), Code
    , runABC, runAMBC
    , readABC, showABC
    , droppable, copyable, observable
    , quote, divModQ
    ) where

import Control.Monad
import Data.Ratio
import Text.Parsec
import qualified Text.Parsec.Text as T
import Data.Text (Text)
import qualified Data.Text as T

readABC :: Text -> Code
showABC :: Code -> Text
droppable, droppable, observable :: V -> Bool
prod, sum, number, block, unit :: V -> Bool
runABC :: (Monad m) => (Text -> V -> m V) -> V -> Code -> m V

data V -- ABC's structural types
    = L V        -- sum left
    | R V        -- sum right
    | N Rational -- number
    | B BT Code  -- block
    | P V V      -- product
    | U          -- unit
data Op
    = Op Char  -- a normal operator
    | BL Code  -- block literal
    | TL Text  -- text literal
    | Invoke Text -- {invocation}
    | Amb [Code] -- AMBC extension to ABC 
type Code = [Op]
data BT = BT { bt_rel :: Bool, bt_aff :: Bool }

-- the true 'bytecodes'
opCodeList :: [Char]
opCodeList = " \nlrwzvcLRWZVC%^$'okf0123456789#+*-/Q?DFMKPSBN>"

-- to cut down on verbose code, and because the 
-- syntax highlighting of 'Just' is distracting...
j :: v -> Maybe v
j = Just 

-- run pure operations; return Nothing if no rule applies
-- (excludes invocation, amb, '$', and '?')
runPureOp :: Op -> V -> Maybe V
runPureOp (Op ' ') v = j v
runPureOp (Op '\n') v = j v
runPureOp (Op 'l') (P a (P b c)) = j (P (P a b) c)
runPureOp (Op 'r') (P (P a b) c) = j (P a (P b c))
runPureOp (Op 'w') (P a (P b c)) = j (P b (P a c))
runPureOp (Op 'z') (P a (P b (P c d))) = j (P a (P c (P b d)))
runPureOp (Op 'v') a = j (P a U)
runPureOp (Op 'c') (P a U) = j a
runPureOp (Op 'L') (P s e) = mbP (sumL s) e
runPureOp (Op 'R') (P s e) = mbP (sumR s) e
runPureOp (Op 'W') (P s e) = mbP (sumW s) e
runPureOp (Op 'Z') (P s e) = mbP (sumZ s) e
runPureOp (Op 'V') (P s e) = j (P (L s) e)
runPureOp (Op 'C') (P (L s) e) = j (P s e)
runPureOp (Op '%') (P x e) | droppable x = j e
runPureOp (Op '^') (P x e) | copyable x = j (P x (P x e))
runPureOp (Op 'o') (P (B b1 yz) (P (B b2 xy) e)) = j (P b' e)
    where b' = B bt' (xy ++ yz) -- concatenation is composition!
          bt' = BT { bt_aff = (bt_aff b1 || bt_aff b2)
                   , bt_rel = (bt_rel b1 || bt_rel b2) }
runPureOp (Op '\'') (P v e) = j (P (quote v) e)
runPureOp (Op 'k') (P (B bt xy) e) = j (P b' e) 
    where b' = B bt' xy
          bt' = bt { bt_rel = True }
runPureOp (Op 'f') (P (B bt xy) e) = j (P b' e)
    where b' = B bt' xy
          bt' = bt { bt_aff = True }
runPureOp (Op '#') e = j (P (N 0) e)
runPureOp (Op '0') (P (N x) e) = j (P (N (10*x + 0)) e)
runPureOp (Op '1') (P (N x) e) = j (P (N (10*x + 1)) e)
runPureOp (Op '2') (P (N x) e) = j (P (N (10*x + 2)) e)
runPureOp (Op '3') (P (N x) e) = j (P (N (10*x + 3)) e)
runPureOp (Op '4') (P (N x) e) = j (P (N (10*x + 4)) e)
runPureOp (Op '5') (P (N x) e) = j (P (N (10*x + 5)) e)
runPureOp (Op '6') (P (N x) e) = j (P (N (10*x + 6)) e)
runPureOp (Op '7') (P (N x) e) = j (P (N (10*x + 7)) e)
runPureOp (Op '8') (P (N x) e) = j (P (N (10*x + 8)) e)
runPureOp (Op '9') (P (N x) e) = j (P (N (10*x + 9)) e)
runPureOp (Op '+') (P (N x) (P (N y) e)) = j (P (N (x + y)) e)
runPureOp (Op '*') (P (N x) (P (N y) e)) = j (P (N (x * y)) e)
runPureOp (Op '/') (P (N x) e) | (0 /= x) = j (P (N (recip x)) e)
runPureOp (Op '-') (P (N x) e) = j (P (N (negate x)) e)
runPureOp (Op 'Q') (P (N b) (P (N a) e)) | (0 /= x) =
    let (r,q) = divModQ b a in
    j (P (N r) (P (N (fromIntegral q)) e))
runPureOp (Op 'D') (P a (P (L v) e)) = j (P (L (P a v)) e)
runPureOp (Op 'D') (P a (P (R v) e)) = j (P (R (P a v)) e)
runPureOp (Op 'F') (P (L (P a b)) e) = j (P (L a) (P (L b) e))
runPureOp (Op 'F') (P (R (P c d)) e) = j (P (R c) (P (R d) e))
runPureOp (Op 'M') (P (L a) e) = j (P a e) -- M assumes (a + a)
runPureOp (Op 'M') (P (R a) e) = j (P a e) -- M assumes (a + a)
runPureOp (Op 'K') (P (R b) e) = j (P b e) -- K asserts in right
runPureOp (Op 'P') (P x e) = mbP (obs prod x) e
runPureOp (Op 'S') (P x e) = mbP (obs sum x) e
runPureOp (Op 'B') (P x e) = mbP (obs block x) e
runPureOp (Op 'N') (P x e) = mbP (obs number x) e
runPureOp (Op '>') (P x (P y e)) =
    case opGT y x of
        Nothing -> Nothing
        Just True -> j (P (R (P x y)) e)
        Just False -> j (P (L (P y x)) e)
runPureOp (BL code) e = j (P (B bt0 code) e) 
    where bt0 = BT { bt_rel = False, bt_aff = False }
runPureOp (TL text) e = j (P (textToVal text) e)
runPureOp _ _ = Nothing -- no more rules!

mbP :: Maybe V -> V -> Maybe V
mbP Nothing _ = Nothing
mbP (j v1) v2 = j (P v1 v2)

obs :: (V -> Bool) -> V -> Maybe V
obs pred v = 
    if pred v then Just (R v) else
    if observable v then Just (L v) else
    Nothing

sumL, sumR, sumW, sumZ :: V -> Maybe V
sumL (L a) = j (L (L a))
sumL (R (L b)) = j (L (R b))
sumL (R (R c)) = j (R c)
sumL _ = Nothing
sumR (L (L a)) = j (L a)
sumR (L (R b)) = j (R (L b))
sumR (R c) = j (R (R c))
sumR _ = Nothing
sumW (L a) = j (R (L a))
sumW (R (L b)) = j (L b)
sumW (R (R c)) = j (R (R c))
sumW _ = Nothing
sumZ (L a) = j (L a)
sumZ (R (L b)) = j (R (R (L b)))
sumZ (R (R (L c))) = j (R (L c))
sumZ (R (R (R d))) = j (R (R (R d)))
sumZ _ = Nothing

-- divModQ b a = (r,q)
--   such that qb + r = a
--             q is integral
--             r is in (b,0] or [0,b)
-- i.e. this is a divMod for rationals
divModQ :: Rational -> Rational -> (Rational, Integer)
divModQ b a = 
    let num = numerator a * denominator b in
    let den = numerator b * denominator a in
    let (qN,rN) = num `divMod` den in
    let denR = denominator a * denominator b in
    (rN % denR, qN)

-- opGreaterThan y x = Just (y > x)
--   unless it attempts to compare something incomparable
--   in that case, returns Nothing.
-- this implementation won't catch every unsafe use
-- ... but it will catch some, perhaps enough
opGT :: V -> V -> Maybe Bool
opGT (P a b) (P a' b') =
    if (opGT a a') then j True else
    if (opGT a' a) then j False else
    opGT b b'
opGT (N y) (N x) = j (y > x)
opGT y x | structGT y x = j True
opGT y x | structGT x y = j False
opGT (L a) (L a') = j (opGT a a')
opGT (R b) (R b') = j (opGT b b')
opGT U U = j False
opGT _ _ = Nothing

-- greater-than due to structure
structGT :: V -> V -> Bool
structGT (P _ _) x = number x || sum x
structGT (N _) x = sum x
structGT (R _) (L _) = True
structGT _ _ = False

-- lazily compute a text value!
textToVal :: Text -> V
textToVal t = 
    case T.uncons t of
        Nothing -> N 3 -- ETX
        Just(c,t') ->
            let tV' = textToVal t' in
            let nC = fromIntegral (ord c) in
            P (N nC) tV'

-- convert some values back to text!
valToText :: V -> Maybe Text
valToText (P (N r) v) =
    case charFromRational r of
        Nothing -> Nothing
        Just c ->
            case valToText v of
                Nothing -> Nothing
                Just t -> Just (c `cons` t)
valToText (N 3) = Just T.empty
valToText _ = Nothing

-- convert some numbers to characters!
charFromRational r :: Rational -> Maybe Char
charFromRational r =
    let d = denominator r in
    if (1 /= r) then return Nothing else
    let n = numerator r in
    if ((0 > n) || (n > 0x10ffff)) then Nothing else
    Just ((fromEnum . fromIntegral) n)

-- showABC :: Code -> Text
showABC = T.concat . map showOp 

showOp :: Op -> Text
showOp (Op c) = T.singleton c
showOp (BL code) = '[' `cons` showABC code `snoc` ']'
showOp (TL text) = '"' `cons` escapeLF text `snoc` '\n' `snoc` '~'
showOp (Invoke text) = '{' `cons` text `snoc` '}'
showOp (Amb opts) = 
    let opTexts = map showABC opts in
    let sepOpts = T.intercalate (T.singleton '|') opTexts in
    '(' `cons` sepOpts `snoc` ')'

-- add ABC's peculiar model for escaped text
--  each LF in text is followed by SP
escapeLF :: Text -> Text
escapeLF = T.intercalate lfsp . T.split (=='\n') 
    where lfsp = T.pack "\n "

-- can we drop this value?
droppable (B bt _) = not (bt_rel bt)
droppable (P a b) = droppable a && droppable b
droppable (L v) = droppable v
droppable (R v) = droppable v
droppable (N _) = True
droppable U = True

-- can we copy this value?
copyable (B bt _) = not (bt_aff bt)
copyable (P a b) = copyable a && copyable b
copyable (L v) = copyable v
copyable (R v) = copyable v
copyable (N _) = True
copyable U = True

-- can we introspect the value's structure?
observable = not . unit

prod (P _ _) = True
prod _ = False

sum (L _) = True
sum (R _) = True
sum _ = False

block (B _ _) = True
block _ = False

number (N _) = True
number _ = False

unit U = True
unit _ = False

-- convert a value to a block of [1->val]
quote :: V -> V
quote v = B bt code where
    (bt,code) = quoteVal bt0 [Op 'c'] v
    -- todo: optimize and verify generated code

quoteVal :: BT -> Code -> V -> (BT, Code)
quoteVal bt c U = (bt, intro1 ++ c)
    where intro1 = [Op 'v', Op 'v', Op 'r', Op 'w', Op 'l', Op 'c']
quoteVal bt c (L a) = quoteVal bt (Op 'V' : c) a
quoteVal bt c (R b) = quoteVal bt (intro0 ++ c) b
    where intro0 = [Op 'V', Op 'V', Op 'R', Op 'W', Op 'L', Op 'C']
quoteVal bt c v@(P a b) =
    case valToText v of
        Just t -> (bt, TL t : c)
        Nothing ->
            let (btb,cb) = quoteVal bt (Op 'w' : Op 'l' : c) b in
            quoteVal btb cb a
quoteVal bt c (N r) = (bt, quoteNum r ++ c)
quoteVal bt c (B btb code) = 
    let fc = if (bt_aff btb) then (Op 'f' : c) else c in
    let kfc = if (bt_rel btb) then (Op 'k' : fc) else fc in
    let code' = BL code : kfc in
    let bt' = BT { bt_rel = (bt_rel bt || bt_rel btb)
                 , bt_aff = (bt_aff bt || bt_aff btb) } in
    (bt',code')

-- given number, find code that generates it as a literal
quoteNum :: Rational -> Code
quoteNum r =
    if (r < 0) then quoteNum (negate r) ++ [Op '-'] else
    let num = numerator r in
    let den = denominator r in
    if (1 == den) then (quoteNat [] num) else
    if (1 == num) then (quoteNat [Op '/'] den) else
    quoteNat (quoteNat [Op '/', Op '*'] den) num 

-- build from right to left
quoteNat :: Code -> Integer -> Code
quoteNat code n =
    if (0 == n) then (Op '#' : code) else
    let (q,r) = n `divMod` 10 in
    quoteNat (iop r : code) q

-- partial function
iop :: Integer -> Op 
iop 0 = Op '0'
iop 1 = Op '1'
iop 2 = Op '2'
iop 3 = Op '3'
iop 4 = Op '4'
iop 5 = Op '5'
iop 6 = Op '6'
iop 7 = Op '7'
iop 8 = Op '8'
iop 9 = Op '9'
iop n = error "iop expects argument between 0 and 9"


-- readABC :: Text -> Code


