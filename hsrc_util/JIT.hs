{-# LANGUAGE ViewPatterns, ImpredicativeTypes #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

-- | A JIT for ABC.
--
-- This particular just-in-time compiler leverages Haskell's plugins
-- framework. Sadly, Haskell's plugins framework - at least the 
-- System.Eval interface - is very buggy (something to do with the
-- caching and naming of modules). I'm overcoming this by using a
-- unique name per object, based on secure hash of ABC source.
--
-- Further, prior to GHC 7.8.1, object code is never unloaded (even if
-- we use `unload` operations). Also, it seems System.Plugins doesn't
-- even call GHC's unload. So developers will have a severe limit on what
-- they can load, and how often. JIT is a memory leak! Fortunately, for 
-- most applications, it isn't a problem for developers to constrain use
-- of JIT to a few essential objects. 
-- 
--
-- IMPROVEMENTS TO CONSIDER:
--
--   Let-based construction: (high priority)
--
--     Translate program into a sequence of 'let' expressions and an
--     occasional imperative operation. This should also be easier to
--     read in the common case.
--
--   Partial Evaluation: (high priority)
--
--     Track constants in the program (numbers, blocks) and use them
--     to specialize code or inline functions.
--
--   Cycle recognition: (high priority)
--
--     Detect when a block needs itself. Translate this into appropriate
--     Haskell code, especially in cases where it can inline itself.
--
--   Incremental: (low priority)
--
--     Create a JIT-based interpreter that JIT's small chunks of a 
--     program and runs those. 
--
module JIT 
    ( abc_jit, abc2hs -- default implementation
    ) where

import Control.Applicative 
import qualified Control.Exception as Err

import qualified Data.Map as M
import qualified Data.List as L
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import qualified Data.ByteString as B
import qualified Data.Byteable as B
import qualified Crypto.Hash as CH
import qualified Codec.Binary.Base32 as B32
import Data.Char (toLower)

import qualified System.Environment as Env
import qualified System.IO as Sys
import qualified System.Plugins as Sys

import qualified Filesystem as FS
import qualified Filesystem.Path.CurrentOS as FS

import ABC.Operators
import ABC.Simplify
import ABC.Imperative.Value
import ABC.Imperative.Resource
import ABC.Imperative.Runtime

type Error = String

-- | Use Haskell's plugins module to just-in-time compile code.
--
-- The given ops should be pre-optimized and pre-simplified before
-- reaching this final JIT compilation step. 
--
-- Since plugins work through the filesystem, this first creates
-- a resource in the filesystem (under the AO_TEMP directory), then 
-- builds it externally before loading the result. Resources are
-- uniquely named based on a secure hash of the ABC that generates
-- them.
--
-- It isn't entirely clear to me how GC of loaded plugins works.
-- For now, I'll just hope it works. 
--
-- This may fail if any operation cannot be completed.
--
abc_jit :: (Runtime m) => [Op] -> IO (Prog m)
abc_jit ops =
    let un = uniqueStr ops in
    let rn = 'R':un in
    getJitTmpDir >>= \ jitDir ->
    let rscDir = jitDir FS.</> dirFromId [2,2] un in
    let abcFile = rscDir FS.</> (FS.fromText (T.pack rn) FS.<.> T.pack "abc") in
    let rscFile = rscDir FS.</> (FS.fromText (T.pack rn) FS.<.> T.pack "hs") in
    FS.createTree rscDir >>
    FS.writeTextFile abcFile (T.pack (show ops)) >>
    either fail (FS.writeTextFile rscFile . T.pack) (abc2hs ops) >>
    asProg <$> makeAndLoad (FS.encodeString rscFile)

-- obtain the program resource
makeAndLoad :: Sys.FilePath -> IO Resource
makeAndLoad hsFile =
    Sys.make hsFile makeArgs >>= \ makeStatus ->
    case makeStatus of
        Sys.MakeFailure errs -> fail (L.unlines errs)
        Sys.MakeSuccess _ objFile ->
            Sys.load objFile [] [] "resource" >>= \ loadStatus ->
            case loadStatus of
                Sys.LoadFailure errs -> fail (L.unlines errs)
                Sys.LoadSuccess _ rsc -> return rsc

makeArgs :: [String]
makeArgs = warnOpts ++ compOpts where
    warnOpts =  ["-Wall","-Werror"
                ,"-fno-warn-unused-imports"]
    compOpts =  ["-O1","-fno-enable-rewrite-rules"]

abc2hs :: [Op] -> Either Error String
abc2hs = return . abc2hs_naive . simplify

abc2hs_imports_naive :: [String]
abc2hs_imports_naive = 
    ["ABC.Imperative.Operations"
    ,"ABC.Imperative.Resource"
    ,"Control.Monad (return)"
    ]

abc2hs_naive :: [Op] -> String
abc2hs_naive ops = (showHdr . showRsc . showFtr) "" where
    showHdr = lang . showChar '\n' . 
              modHdr . showChar '\n' . 
              showImports abc2hs_imports_naive . showChar '\n'
    lang = showString "{-# LANGUAGE NoImplicitPrelude #-}"
    modHdr = showString "module R" . 
             showString (uniqueStr ops) . 
             showString " (resource) where"
    showImports (x:xs) = showString "import " . showString x . 
                         showChar '\n' . showImports xs
    showImports [] = id
    showRsc = 
        showString "resource :: Resource\n" .
        showString "resource = Resource (" .
        ops2hs_naive ops . showChar ')'
    showFtr = showString "\n\n"

ops2hs_naive :: [Op] -> ShowS
ops2hs_naive [] = showString "return"
ops2hs_naive (Op_ap:Op_c:[]) = showString "apc"
ops2hs_naive (op:[]) = op2hs_naive op
ops2hs_naive (op:ops) = op2hs_naive op . showString ">=>" . ops2hs_naive ops

opMapNaive :: M.Map Op String
opMapNaive = M.fromList $
    [(Op_l,"l"),(Op_r,"r"),(Op_w,"w"),(Op_z,"z"),(Op_v,"v"),(Op_c,"c")
    ,(Op_L,"sL"),(Op_R,"sR"),(Op_W,"sW"),(Op_Z,"sZ"),(Op_V,"sV"),(Op_C,"sC")
    ,(Op_copy,"cp"),(Op_drop,"rm")
    ,(Op_add,"add"),(Op_neg,"neg"),(Op_mul,"mul"),(Op_inv,"inv"),(Op_divMod,"divQ")
    ,(Op_ap,"ap"),(Op_cond,"co"),(Op_quote,"qu"),(Op_comp,"o")
    ,(Op_rel,"k"),(Op_aff,"f")
    ,(Op_distrib,"sD"),(Op_factor,"sF"),(Op_merge,"sM"),(Op_assert,"sK")
    ,(Op_gt,"gt")
    ,(Op_introNum,"n0")
    ,(Op_0,"d0"),(Op_1,"d1"),(Op_2,"d2"),(Op_3,"d3"),(Op_4,"d4")
    ,(Op_5,"d5"),(Op_6,"d6"),(Op_7,"d7"),(Op_8,"d8"),(Op_9,"d9")
    ,(Op_SP,"return"),(Op_LF,"return")
    ]
inOpMap :: Op -> Maybe String
inOpMap = flip M.lookup opMapNaive

op2hs_naive :: Op -> ShowS
op2hs_naive (inOpMap -> Just s) = showString s
op2hs_naive (TL s) = showString "tl" . shows s
op2hs_naive (Tok s) = showString "tok" . shows s
op2hs_naive (BL ops) = showString "bl" . opsStr . progVal where
    opsStr = shows (show ops) -- show all ops in a string
    progVal = showChar '(' . ops2hs_naive ops . showChar ')'
op2hs_naive op = error $ "op2hs_naive missing def for " ++ show op

toBase32 :: B.ByteString -> String
toBase32 = fmap toLower . B32.encode . B.unpack

splits :: [Int] -> [a] -> [[a]]
splits [] _ = []
splits _ [] = []
splits (n:ns) aa = 
    let (aa0,aa') = L.splitAt n aa in
    aa0:splits ns aa'    

dirFromId :: [Int] -> String -> FS.FilePath
dirFromId sp = toFP . fmap toPath . splits sp where
    toFP = L.foldr FS.append FS.empty 
    toPath = FS.fromText . T.pack

uniqueStr :: [Op] -> String
uniqueStr = L.take 48 . toBase32 . getCodeHash 

getCodeHash :: [Op] -> B.ByteString
getCodeHash = B.toBytes . sha3_384 . T.encodeUtf8 . T.pack . show where
    sha3_384 :: B.ByteString -> CH.Digest CH.SHA3_384
    sha3_384 = CH.hash -- algorithm inferred from type

-- (idempotent) obtain (and create) the JIT storage directory
-- may raise an IOError based on permissions or similar
getJitTmpDir :: IO FS.FilePath
getJitTmpDir =  
    getAO_TEMP >>= \ aoTmp ->
    let jitFullDir = aoTmp FS.</> FS.fromText (T.pack "jit") in
    FS.createDirectory True jitFullDir >>
    return jitFullDir

-- (idempotent) obtain (and create) the AO_TEMP directory
-- may raise an IOError based on permissions or similar
getAO_TEMP :: IO FS.FilePath
getAO_TEMP = 
    (maybe "aotmp" id <$> tryJust (Env.getEnv "AO_TEMP")) >>= \ d0 ->
    let fp0 = FS.fromText (T.pack d0) in
    FS.createTree fp0 >>
    FS.canonicalizePath fp0

try :: IO a -> IO (Either Err.SomeException a)
try = Err.try -- type forced

tryJust :: IO a -> IO (Maybe a)
tryJust op = either (const Nothing) (Just) <$> try op
