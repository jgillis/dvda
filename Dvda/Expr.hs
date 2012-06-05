{-# Options_ghc -Wall #-}
{-# Language StandaloneDeriving #-}
{-# Language GADTs #-}
{-# Language FlexibleContexts #-}

module Dvda.Expr ( Expr(..)
                 , Const(..)
                 , sym
                 , vsym
                 , msym
                 , vec
                 , mat
                 , scale
--                 , dot
                 , diff
                 , grad
                 , jacob
                 , hess
                 , dim
                 ) where

import Data.Array.Repa(DIM0,DIM1,DIM2,Z(..),(:.)(..), listOfShape, Shape(shapeOfList))
import Numeric.LinearAlgebra ( Matrix, Vector, Element )
import qualified Numeric.LinearAlgebra as LA
import Foreign.Storable ( Storable )
import Data.IntMap ( Key )
import Data.Hashable ( Hashable, hash, combine )

-- import Dvda.Dot ( Dot(..), dotDims )
import Dvda.BinUn ( BinOp(..), UnOp(..), showBinary, showUnary )

showShapeR :: Shape sh => sh -> String
showShapeR = show . reverse . listOfShape

dim :: Expr sh a -> sh
dim (ESym sh _) = sh
dim (EConst (CMat sh _)) = sh
dim (EConst (CVec sh _)) = sh
dim (EConst (CTensor sh _)) = sh
dim (EDimensionless _) = error "EDimensionless doesn't have a dimension, ya goon"
dim (ESingleton sh _) = sh
dim (EUnary _ x) = dim x
dim (EBinary _ x1 _) = dim x1
dim (EScale _ y) = dim y
--dim (EDot x y) = dotDims (dim x) (dim y)
dim (ERef sh _) = sh
dim (EDeriv _ _) = Z
dim (EGrad _ args) = dim args
dim (EJacob x args) = Z :. head (listOfShape (dim x)) :. head (listOfShape (dim args))

data Const sh a where
  CVec :: DIM1 -> Vector a -> Const DIM1 a
  CMat :: DIM2 -> Matrix a -> Const DIM2 a
  CTensor :: sh -> Vector a -> Const sh a 

deriving instance (Show sh, Show a, Element a) => Show (Const sh a)

instance (Shape sh, Element a, Eq a) => Eq (Const sh a) where
  (==) (CVec sh0 v0) (CVec sh1 v1) = sh0 == sh1 && v0 == v1
  (==) (CMat sh0 m0) (CMat sh1 m1) = sh0 == sh1 && (LA.flatten m0) == (LA.flatten m1)
  (==) (CTensor sh0 v0) (CTensor sh1 v1) = sh0 == sh1 && v0 == v1
  (==) _ _ = False
  
instance (Hashable a, Shape sh, Element a) => Hashable (Const sh a) where
  hash (CVec sh v) = LA.foldVector (\x acc -> acc `combine` hash x) (24 `combine` hash (listOfShape sh)) v
  hash (CMat sh v) = LA.foldVector (\x acc -> acc `combine` hash x) (25 `combine` hash (listOfShape sh)) (LA.flatten v)
  hash (CTensor sh v) = LA.foldVector (\x acc -> acc `combine` hash x) (26 `combine` hash (listOfShape sh)) v


cmap :: (Storable a, Storable b) => (a -> b) -> Const sh a -> Const sh b
cmap f (CTensor sh x) = CTensor sh (LA.mapVector f x)
cmap f (CVec    sh x) = CVec    sh (LA.mapVector f x)
cmap f (CMat    sh x) = CMat    sh (LA.mapMatrix f x)

czipWith :: (Storable c, Element a, Element b) => (a -> b -> c) -> Const sh a -> Const sh b -> Const sh c
czipWith f (CTensor sh x) (CTensor _ y) = CTensor sh (LA.zipVectorWith f x y)
czipWith f (CVec    sh x) (CVec    _ y) = CVec    sh (LA.zipVectorWith f x y)
czipWith f (CMat    sh x) (CMat    _ y) = CMat    sh (LA.reshape (LA.cols x) z)
  where
    z = LA.zipVectorWith f (LA.flatten x) (LA.flatten y)
czipWith _ _ _ = error "don't call czipWith on unlike constructors"

data Expr sh a where
  ESym :: sh -> String -> Expr sh a
  EConst :: Const sh a -> Expr sh a
  EDimensionless :: a -> Expr sh a
  ESingleton :: sh -> a -> Expr sh a
  EUnary :: UnOp -> Expr sh a -> Expr sh a
  EBinary :: BinOp -> Expr sh a -> Expr sh a -> Expr sh a
  EScale :: Expr DIM0 a -> Expr sh a -> Expr sh a
--  EDot :: Dot sh1 sh2 => Expr sh1 a -> Expr sh2 a -> Expr (DotT sh1 sh2) a
  ERef :: sh -> Key -> Expr sh a

  EDeriv :: Expr DIM0 a -> Expr DIM0 a -> Expr DIM0 a
  EGrad  :: Expr DIM0 a -> Expr sh a -> Expr sh a
  EJacob :: Expr DIM1 a -> Expr DIM1 a -> Expr DIM2 a

deriving instance (Shape sh, Eq a, Element a) => Eq (Expr sh a)

instance (Hashable a, Shape sh, Element a) => Hashable (Expr sh a) where
  hash (ESym sh name)     = 27 `combine` hash (listOfShape sh) `combine` hash name
  hash (EConst c)         = 28 `combine` hash c
  hash (EDimensionless x) = 29 `combine` hash x
  hash (ESingleton sh x)  = 30 `combine` hash (listOfShape sh) `combine` hash x
  hash (EUnary op x)      = 31 `combine` hash op `combine` hash x
  hash (EBinary op x y)   = 32 `combine` hash op `combine` hash x `combine` hash y
  hash (EScale x y)       = 33 `combine` hash x `combine` hash y
  hash (ERef sh k)        = 34 `combine` hash (listOfShape sh) `combine` k

  hash (EDeriv x y)       = 35 `combine` hash x `combine` hash y
  hash (EGrad x y)        = 36 `combine` hash x `combine` hash y
  hash (EJacob x y)       = 37 `combine` hash x `combine` hash y


isVal :: Eq a => a -> Expr sh a -> Bool
isVal x (EDimensionless y) = x == y
isVal x (ESingleton _ y) = x == y
isVal _ _ = False

-- | first layer of binary simplification: infer dimension of EDimensionless if possible
makeBinary :: (Eq a, Num (Vector a), LA.Container Vector a, Shape sh) =>
              BinOp -> (a -> a -> a) -> Expr sh a -> Expr sh a -> Expr sh a
-- | can't infer dimension, just apply operation
makeBinary _  f (EDimensionless x) (EDimensionless y) = EDimensionless (f x y)
-- | infer dimension, then call makeBinary' for further simplification
makeBinary op f (EDimensionless x) y = makeBinary' op f (ESingleton (dim y) x) y
makeBinary op f x (EDimensionless y) = makeBinary' op f x (ESingleton (dim x) y)
-- | dimension inferred, call makeBinary'
makeBinary op f x y = makeBinary' op f x y

-- | second layer of binary simplification: check dimensions
makeBinary' :: (Eq a, Num (Vector a), LA.Container Vector a, Shape sh) =>
               BinOp -> (a -> a -> a) -> Expr sh a -> Expr sh a -> Expr sh a
makeBinary' op f x y
  | shx == shy  = makeBinary'' op f x y
  | otherwise = error $ "Binary op \""++ sop ++"\" dimension mismatch ya goon (" ++ sdx ++ ", " ++ sdy ++ ")"
  where
    shx = dim x
    shy = dim y
    sdx = showShapeR shx
    sdy = showShapeR shy
    sop = show op

-- | third layer of binary simplification: 0*x == x*0 == 0
-- |                                       1*x == x*1 == x
-- |                                       0+x == x+0 == x
-- |                                       x/0 == error
-- |                                       x/1 == x
-- |                                       0/x == 0
-- |                                       x - 0 == 0
-- |                                       0 - x == neg x
makeBinary'' :: (Eq a, Num (Vector a), LA.Container Vector a, Shape sh) =>
                BinOp -> (a -> a -> a) -> Expr sh a -> Expr sh a -> Expr sh a
makeBinary'' Mul f x y
  | isVal 0 x = x
  | isVal 0 y = y
  | isVal 1 x = y
  | isVal 1 y = x
  | otherwise = makeBinary''' Mul f x y
makeBinary'' Add f x y
  | isVal 0 x = y
  | isVal 0 y = x
  | otherwise = makeBinary''' Add f x y
makeBinary'' Div f x y
  | isVal 0 y = error "divide by zero"
  | isVal 1 y = x
  | isVal 0 x = x
  | otherwise = makeBinary''' Div f x y
makeBinary'' Sub f x y
  | isVal 0 x = negate y
  | isVal 0 y = x
  | otherwise = makeBinary''' Sub f x y
makeBinary'' op f x y = makeBinary''' op f x y


-- | fourth layer of binary simplification: make reasonable simplifications
makeBinary''' :: (Num (Vector a), LA.Container Vector a) =>
                 BinOp -> (a -> a -> a) -> Expr sh a -> Expr sh a -> Expr sh a
-- | apply operation to constants
makeBinary''' Add _ (EConst (CVec sh x)) (EConst (CVec _ y)) = EConst $ CVec sh (x + y)
makeBinary''' Sub _ (EConst (CVec sh x)) (EConst (CVec _ y)) = EConst $ CVec sh (x - y)
makeBinary''' Mul _ (EConst (CVec sh x)) (EConst (CVec _ y)) = EConst $ CVec sh (x * y)
makeBinary''' Div _ (EConst (CVec sh x)) (EConst (CVec _ y)) = EConst $ CVec sh (x / y)
makeBinary''' Add _ (EConst (CMat sh x)) (EConst (CMat _ y)) = EConst $ CMat sh (x + y)
makeBinary''' Sub _ (EConst (CMat sh x)) (EConst (CMat _ y)) = EConst $ CMat sh (x - y)
makeBinary''' Mul _ (EConst (CMat sh x)) (EConst (CMat _ y)) = EConst $ CMat sh (x * y)
makeBinary''' Div _ (EConst (CMat sh x)) (EConst (CMat _ y)) = EConst $ CMat sh (x / y)
makeBinary''' Add _ (EConst (CTensor sh x)) (EConst (CTensor _ y)) = EConst $ CTensor sh (x + y)
makeBinary''' Sub _ (EConst (CTensor sh x)) (EConst (CTensor _ y)) = EConst $ CTensor sh (x - y)
makeBinary''' Mul _ (EConst (CTensor sh x)) (EConst (CTensor _ y)) = EConst $ CTensor sh (x * y)
makeBinary''' Div _ (EConst (CTensor sh x)) (EConst (CTensor _ y)) = EConst $ CTensor sh (x / y)
makeBinary''' _ f (EConst x) (EConst y) = EConst $ czipWith f x y
-- | broadcast constant operations
makeBinary''' _ f (ESingleton _ x) (EConst y) = EConst $ cmap (f x) y
makeBinary''' _ f (EConst x) (ESingleton _ y) = EConst $ cmap (`f` y) x
-- | otherwise make symbolic binary
makeBinary''' op _ x y = EBinary op x y


-- | apply unary operations on constants
makeUnary :: Storable a => UnOp -> (a -> a) -> Expr sh a -> Expr sh a
makeUnary _ f (EDimensionless x) = EDimensionless (f x)
makeUnary _ f (ESingleton sh x) = ESingleton sh (f x)
makeUnary _ f (EConst x) = EConst $ cmap f x
makeUnary op _ x = EUnary op x

instance (Shape sh, Num a, Eq a, Num (Vector a), LA.Container Vector a) =>
         Num (Expr sh a) where
  (*) = makeBinary Mul (*)
  (+) = makeBinary Add (+)
  (-) = makeBinary Sub (-)
  abs = makeUnary Abs abs
  signum = makeUnary Signum signum
  fromInteger = EDimensionless . fromInteger
  negate = makeUnary Neg negate

instance (Shape sh, Fractional a, Eq a, Num (Vector a), LA.Container Vector a) =>
         Fractional (Expr sh a) where
  (/) = makeBinary Div (/)
  fromRational = EDimensionless . fromRational

instance (Shape sh, Floating a, Eq a, Num (Vector a), LA.Container Vector a) =>
         Floating (Expr sh a) where
  pi    = EDimensionless pi
  (**)  = makeBinary Pow (**)
  exp   = makeUnary Exp exp
  log   = makeUnary Log log
  sin   = makeUnary Sin sin
  cos   = makeUnary Cos cos
  asin  = makeUnary ASin asin
  atan  = makeUnary ATan atan
  acos  = makeUnary ACos acos
  sinh  = makeUnary Sinh sinh
  cosh  = makeUnary Cosh cosh
  asinh = error "no instance for asinh"
  atanh = error "no instance for atanh"
  acosh = error "no instance for acosh"

paren :: Show a => a -> String
paren x = "( "++show x++" )"

instance (Shape sh, Show sh, Show a, Element a) => Show (Expr sh a) where
  show (ESingleton _ x) = show x
  show (EDimensionless x) = show x
  show (ESym sh name) = name++"{"++showShapeR sh++"}"
  show (EConst x) = "{" ++ show x ++ "}" 
  show (EUnary op x) = showUnary x op
  show (EBinary op x y) = paren x ++ showBinary op ++ paren y
  show (EScale s x) = paren s ++ "*" ++ paren x
--  show (EDot _ _) = "EDot ?? ??"
  show (ERef sh k) = "{ref:" ++ showShapeR sh ++ ":" ++ show k ++ "}"
  show (EDeriv x y) = "deriv(" ++ show x ++ ", " ++ show y ++ ")"
  show (EGrad  x y) = "grad("  ++ show x ++ ", " ++ show y ++ ")"
  show (EJacob x y) = "jacob(" ++ show x ++ ", " ++ show y ++ ")"

sym :: String -> Expr DIM0 a
sym = ESym Z

vsym :: Int -> String -> Expr DIM1 a
vsym k = ESym (Z :. k)

msym :: (Int,Int) -> String -> Expr DIM2 a
msym (r,c) = ESym (Z :. r :. c)

vec :: Storable a => [a] -> Expr DIM1 a
vec xs = EConst $ CVec (shapeOfList [length xs]) (LA.fromList xs)

mat :: Element a => (Int,Int) -> [[a]] -> Expr DIM2 a
mat (r,c) xs 
  | r*c == sum (map length xs) && r == length xs = EConst $ CMat (shapeOfList [c,r]) (LA.fromLists xs)
  | otherwise = error $ "bad dims in mat!"++
                "\ngiven (r,c):  " ++ show (r,c) ++
                "\nactual (r,c): " ++ show (length xs, map length xs)

scale :: Expr DIM0 a -> Expr sh a -> Expr sh a
scale = EScale

--dot :: (Dot sh1 sh2, DotT sh1 sh2 ~ sh) => Expr sh1 a -> Expr sh2 a -> Expr sh a
--dot = EDot

diff :: Expr DIM0 a -> Expr DIM0 a -> Expr DIM0 a
diff = EDeriv

grad :: Expr DIM0 a -> Expr DIM1 a -> Expr DIM1 a
grad = EGrad

jacob :: Expr DIM1 a -> Expr DIM1 a -> Expr DIM2 a
jacob = EJacob

hess :: Expr DIM0 a -> Expr DIM1 a -> Expr DIM2 a
hess expr args = jacob (grad expr args) args




simplifyCommutativeOps :: Bool
simplifyCommutativeOps = True
