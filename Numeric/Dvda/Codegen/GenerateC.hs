-- GenerateC.hs

{-# OPTIONS_GHC -Wall #-}

module Numeric.Dvda.Codegen.GenerateC( generateCSource
                                     ) where

import Data.Graph.Inductive hiding(out)
import Data.Maybe(fromJust)
import Data.Hash.MD5(md5s, Str(..))

import qualified Numeric.Dvda.Codegen.Config as Config
import Numeric.Dvda.Expr.Expr
import Numeric.Dvda.Expr.ExprToGraph
import Numeric.Dvda.Expr.ElemwiseType
import Numeric.Dvda.Expr.SourceType

generateCSource :: (Eq a, Show a) => [Expr a] -> [Expr a] -> (String, String, String)
generateCSource inputs outputs = (src, include, hash)
  where
    hash = md5s (Str body)
    
    prototype = "void " ++ Config.nameCFunction hash ++ "(const double in[], double out[])"
    
    include = unlines [ "// " ++ Config.nameCInclude hash
                      , ""
                      , "#ifndef __" ++ hash ++ "__"
                      , "#define __" ++ hash ++ "__"
                      , ""
                      , prototype ++ ";"
                      , ""
                      , "#endif //__" ++ hash ++ "__"
                      ]

    src = unlines [ "// " ++ Config.nameCSource hash
                  , ""
                  , "#include \"math.h\""
                  , "#include \"" ++ Config.nameCInclude hash ++ "\""
                  , ""
                  , prototype 
                  , "{"
                  , body ++ "}"
                  ]

    body = "    // input declarations:\n" ++ 
           (unlines inputDeclarations) ++
           "\n" ++
           "    // body:\n" ++
           (unlines $ exprsToC outputs)

      where
        inputDeclarations = zipWith (\x k -> "    double " ++ show x ++" = in["++show k++"];") inputs [(0::Integer)..]
    

exprsToC :: (Eq a, Show a) => [Expr a] -> [String]
exprsToC exprs = map (\x -> "    "++x)  body
  where
    body = grToC $ exprsToGraph exprs

grToC :: (Eq a, Show a) => Gr (GraphOp a) b -> [String]
grToC gr = map f (topsort gr)
  where
    f idx = toC idx (pre gr idx) (fromJust $ lab gr idx)

outputArrayHack :: String -> String
outputArrayHack ('o':'u':'t':num) = "out["++num++"]"
outputArrayHack _ = error "outputArrayHack fail"

toC :: (Eq a, Show a) => Node -> [Node] -> GraphOp a -> String
toC _ (x:[]) (GOutput out) = (outputArrayHack out) ++ " = " ++ nodeName x ++ ";"
toC idx _ (GSource sym@(Sym _)) = assign idx ++ show sym ++ ";"
toC idx _ src@(GSource _) = assign idx ++ show src ++ ";"
toC idx (x:y:[]) (GOp2 op2t) = assign idx ++ nodeName x ++" "++ show op2t ++" "++ nodeName y ++ ";"
toC idx (x:[]) (GElemwise Inv) = assign idx ++ "1.0 / " ++ nodeName x ++ ";"
toC idx (x:[]) (GElemwise ewt) = assign idx ++ show ewt ++"( " ++ nodeName x ++ " )" ++ ";"

toC idx pres (GElemwise ew) = error $ "GElemwise fail: "++show (idx, pres, ew)
toC idx pres (GOp2 op2) = error $ "GOp2 fail: "++show (idx, pres, op2)
toC idx pres (GOutput out) = error $ "GOutput fail: " ++ show (idx, pres, out)

nodeName :: Int -> String
nodeName idx = 't':show idx

assign :: Int -> String
assign idx = Config.cType ++ " " ++ nodeName idx ++ " = "
