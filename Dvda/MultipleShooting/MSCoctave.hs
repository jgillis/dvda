{-# OPTIONS_GHC -Wall #-}
{-# Language FlexibleContexts #-}
{-# Language TypeFamilies #-}

module Dvda.MultipleShooting.MSCoctave ( msCoctave
                                       , run
                                       ) where

import qualified Control.Monad.State as State
import Data.Hashable ( Hashable )
import qualified Data.HashSet as HS
import Data.List ( elemIndex, transpose, zipWith6 )
import Data.Maybe ( fromMaybe )

import Dvda.AD ( rad )
import Dvda.CGen  ( showMex )
import Dvda.CSE ( cse )
import Dvda.Codegen ( writeSourceFile )
import Dvda.Expr ( Expr(..), Sym(..), sym, substitute )
import Dvda.FunGraph -- ( (:*)(..), toFunGraph, countNodes )
import Dvda.HashMap ( HashMap )
import qualified Dvda.HashMap as HM
import Dvda.MultipleShooting.MSMonad
import Dvda.MultipleShooting.Types

{-
    min f(x) st:
    
    c(x) <= 0
    ceq(x) == 0
    A*x <= b
    Aeq*x == beq
    lb <= x <= ub
-}
type Integrator a = [Expr Double]
                   -> [Expr Double]
                   -> [Expr Double]
                   -> [Expr Double]
                   -> ([Expr Double]
                       -> [Expr Double] -> [Expr Double])
                   -> Expr Double
                   -> [Expr Double]

-- take user provided bounds and make sure they're complete
setupBounds :: (Eq a, Hashable a, Show a)
               => [(Expr a, (a,a, BCTime))]
               -> Int
               -> (Expr a -> Int -> (a,a), Expr a -> (a,a))
setupBounds userBounds nSteps = (lookupAll, lookupParam)
  where
    lookupAll x k
      | k >= nSteps = error "don't ask for bounds at timestep >= number of total timesteps"
      | otherwise = case HM.lookup (x,k) specificTimestepBounds of
        Just bnd -> bnd
        Nothing -> case HM.lookup x everyTimestepBounds of
          Just bnd -> bnd
          Nothing -> error $ "need to set bounds for \"" ++ show x ++ "\" at timestep " ++ show k

    lookupParam x = case HM.lookup x everyTimestepBounds of
        Just bnd -> bnd
        Nothing -> error $ "need to set bounds for \"" ++ show x ++ "\""

    -- bounds set at only one timestep
--    everyTimestepBounds :: HashMap (Expr a) (a,a)
    everyTimestepBounds = let
      everyTS (e,(lb,ub,ALWAYS)) = [(e,(lb,ub))]
      everyTS _ = []
      f (e,lbub) hm =
        if HM.member e hm
        then error $ "you set bounds twice for \"" ++ show e ++ "\""
        else HM.insert e lbub hm
      in foldr f HM.empty $ concatMap everyTS userBounds

    -- bounds set at specific timestep
--    specificTimestepBounds :: HashMap (Expr a, Int) (a,a)
    specificTimestepBounds = let
      specificTS (e,(lb,ub,TIMESTEP k)) = [((e,k),(lb,ub))]
      specificTS _ = []
      f (e,lbub) hm =
        if HM.member e hm
        then error $ "you set bounds twice for \"" ++ show e ++ "\""
        else HM.insert e lbub hm
      in foldr f HM.empty $ concatMap specificTS userBounds

vectorizeDvs :: [[a]] -> [[a]] -> [a] -> [a]
vectorizeDvs allStates allActions params = concat allStates ++ concat allActions ++ params

getWithErr :: Step a -> String -> (Step a -> Maybe c) -> c
getWithErr step name f = case f step of
  Nothing -> error $ "need to set " ++ name
  Just ret -> ret

msCoctave ::
  State (Step Double) b
  -> Integrator Double
  -> Int
  -> String
  -> FilePath
  -> IO ()
msCoctave userStep' odeError n funDir name = do
  let step = State.execState userStep' $
             Step { stepStates  = Nothing
                  , stepActions = Nothing
                  , stepDxdt = Nothing
                  , stepDt = Nothing
                  , stepLagrangeTerm = Nothing
                  , stepMayerTerm = Nothing
                  , stepBounds = []
                  , stepConstraints = []
                  , stepParams = HS.empty
                  , stepConstants = HS.empty
                  , stepOutputs = HM.empty
                  , stepPeriodic = HS.empty
                  }
      actions = getWithErr step "actions" stepActions
      dt      = getWithErr step "dt"      stepDt
      (states,outputs,dxdt,lagrangeState) = let
        states'  = getWithErr step "states" stepStates
        dxdt'    = getWithErr step "dxdt"   stepDxdt
        outputs' = stepOutputs step
        in
         case stepLagrangeTerm step of
           Nothing -> (states',outputs',dxdt',Nothing)
           Just (lagrangeTerm,(lb,ub)) ->
             ( states' ++ [lagrangeState']
             , HM.union outputs' $ HM.fromList
               [(lagrangeStateName, lagrangeState'), (lagrangeTermName, lagrangeTerm)]
             , dxdt'++[lagrangeTerm]
             , Just (lagrangeState',(lb,ub)) )
              where
                lagrangeState' = sym lagrangeStateName
        
      params    = HS.toList (stepParams    step)
      constants = HS.toList (stepConstants step)

      allStates   = [[sym $ show x ++ "__" ++ show k | x <-  states] | k <- [0..(n-1)]]
      allActions  = [[sym $ show u ++ "__" ++ show k | u <- actions] | k <- [0..(n-1)]]
      dvs = vectorizeDvs allStates allActions params

      outputMap :: HashMap String [Expr Double]
      outputMap = HM.map f outputs
        where
          f output = zipWith (subStatesActions output) allStates allActions

      -- mapOverTimesteps :: [[Expr a]] -> [[Expr a]] -> [Expr a]
--      mapOverTimesteps f = zipWith3 f allStates allActions (replicate params)
      subStatesActions f x u = substitute f (zip states x ++ zip actions u)

      subAllTimesteps :: Expr Double -> [Expr Double]
      subAllTimesteps something = zipWith (subStatesActions something) allStates allActions

      (lbs,ubs) = unzip $ vectorizeDvs stateBounds actionBounds paramBounds
        where
          (getAllBounds,getParamBounds) = setupBounds bounds n
          stateBounds  = [[getAllBounds x k | x <- states ] | k <- [0..(n-1)]]
          actionBounds = [[getAllBounds u k | u <- actions] | k <- [0..(n-1)]]
          paramBounds  = [getParamBounds p | p <- params]

          bounds = stepBounds step ++ lagrangeBound
            where
              lagrangeBound = case lagrangeState of
                Nothing -> []
                Just (ls,(lb,ub)) -> [(ls,(0,0,TIMESTEP 0)),(ls, (lb, ub, ALWAYS))]

      cost = subStatesActions finalCost (last allStates) (last allActions)
        where
          finalCost = case (stepMayerTerm step, lagrangeState) of
            (Just mc, Nothing) -> mc
            (Nothing, Just (ls,_)) -> ls
            (Just mc, Just (ls,_)) -> mc + ls
            (Nothing,Nothing) -> error "need to set cost function"

      (ceq, cineq) = foldl f ([],[]) allConstraints
        where
          f (eqs,ineqs) (Constraint x EQ y) = (eqs ++ [x - y], ineqs)
          f (eqs,ineqs) (Constraint x LT y) = (eqs, ineqs ++ [x - y])
          f (eqs,ineqs) (Constraint x GT y) = (eqs, ineqs ++ [y - x])
      
          execDxdt x u = map (flip substitute (zip states x ++ zip actions u)) dxdt

          dodeConstraints = map (Constraint 0 EQ) $ concat $
                            zipWith6 odeError (init allStates) (init allActions) (tail allStates) (tail allActions)
                            (repeat execDxdt) (repeat dt)

          allConstraints = dodeConstraints ++ (concatMap (g . (fmap subAllTimesteps)) (stepConstraints step)) ++ periodicConstraints
            where
              g (Constraint [] _ _) = []
              g (Constraint _ _ []) = []
              g (Constraint (x:xs) ord (y:ys)) = Constraint x ord y : g (Constraint xs ord ys)
            
              periodicConstraints = map lookup' $ HS.toList (stepPeriodic step)
                where
                  lookup' x = fromMaybe (error $ "couldn't find periodic thing \"" ++ show x ++ "\" in hashmap")
                              $ HM.lookup x xuMap
                  xuMap = HM.fromList $ zip states  (zipWith setEqual (head  allStates) (last allStates )) ++
                                        zip actions (zipWith setEqual (head allActions) (last allActions))
                    where
                      setEqual x y = Constraint x EQ y

  (costSource,costFg0,costFg) <- do
    let costGrad = rad cost dvs
    fg0 <- toFunGraph (dvs :* constants) (cost :* costGrad)
    let fg = cse fg0
    return (showMex (name ++ "_cost") fg, fg0, fg)
  
  (constraintsSource,constraintsFg0,constraintsFg) <- do
    let cineqJacob = map (flip rad dvs) cineq
        ceqJacob   = map (flip rad dvs) ceq
    fg0 <- toFunGraph (dvs :* constants) (cineq :* ceq :* cineqJacob :* ceqJacob)
    let fg = cse fg0
    return (showMex (name ++ "_constraints") fg, fg0, fg)

  (timeSource,timeFg) <- do
    fg <- toFunGraph (dvs :* constants) (take n $ scanl (+) 0 (repeat dt))
    return (showMex (name ++ "_time") fg, fg)

  (outputSource,outputFg) <- do
    fg <- toFunGraph (dvs :* constants) (HM.elems outputMap)
    return (showMex (name ++ "_outputs") fg, fg)

  (simSource,simFg) <- do
    fg <- toFunGraph (states :* actions :* params :* constants) dxdt
    return (showMex (name ++ "_sim") fg, fg)
      
  let setupSource = writeSetupSource name dvs lbs ubs
      mexAllSource = writeMexAll name
      unstructConstsSource = writeUnstructConsts name constants
      structSource = writeToStruct name dvs params constants outputMap
      
      -- take nice matlab structs and return vector of design variables
      unstructSource =
        unlines $
        [ "function dvs = " ++ name ++ "_unstruct(dvStruct)\n"
        , "dvs = zeros(" ++ show (length dvs) ++ ", 1);"
        , ""
        , concatMap fromParam params
        , concat $ zipWith fromXU states  (transpose allStates)
        , concat $ zipWith fromXU actions (transpose allActions)
        ]
        where
          dvIdx e = fromMaybe (error $ "dvIdx error - " ++ show e ++ " is not a design variable")
                    (e `elemIndex` dvs)
          fromParam e = "dvs(" ++ show (1 + dvIdx e) ++ ") = dvStruct." ++ show e ++ ";\n"
          fromXU e es =
            "dvs(" ++ show (map ((1 +) . dvIdx) es) ++ ") = dvStruct." ++ show e ++ ";\n"

      plotSource =
        unlines $
        [ "function " ++ name ++ "_plot(designVars, constants)\n"
        , "x = " ++ name ++ "_struct(designVars, constants);\n"
        , init $ unlines $ zipWith f (HM.keys outputMap) [(1::Int)..]
        ]
        where
          rows = ceiling $ sqrt $ (fromIntegral ::Int -> Double) $ HM.size outputMap
          cols = (HM.size outputMap `div` rows) + 1
          f name' k = unlines $
                      [ "subplot(" ++ show rows ++ "," ++ show cols ++ ","++show k++");"
                      , "plot( x.time, x." ++ name' ++ " );"
                      , "xlabel('time');"
                      , "ylabel('" ++ name'' ++ "');"
                      , "title('"  ++ name'' ++ "');"
                      ]
            where
              name'' = foldl (\acc x -> if x == '_' then acc ++ "\\_" else acc ++ [x]) "" name'


  _ <- writeSourceFile         mexAllSource funDir $ name ++ "_mex_all.m"
  _ <- writeSourceFile          setupSource funDir $ name ++ "_setup.m"
  _ <- writeSourceFile         structSource funDir $ name ++ "_struct.m"
  _ <- writeSourceFile unstructConstsSource funDir $ name ++ "_unstructConstants.m"
  _ <- writeSourceFile       unstructSource funDir $ name ++ "_unstruct.m"
  _ <- writeSourceFile           plotSource funDir $ name ++ "_plot.m"

  _ <- writeSourceFile           timeSource funDir $ name ++ "_time.c"
  _ <- writeSourceFile         outputSource funDir $ name ++ "_outputs.c"
  _ <- writeSourceFile            simSource funDir $ name ++ "_sim.c"
  _ <- writeSourceFile           costSource funDir $ name ++ "_cost.c"
  _ <- writeSourceFile    constraintsSource funDir $ name ++ "_constraints.c"

  putStrLn $ "nodes in time:        " ++ show (countNodes timeFg)
  putStrLn $ "nodes in output:      " ++ show (countNodes outputFg)
  putStrLn $ "nodes in sim:         " ++ show (countNodes simFg)
  putStrLn $ "nodes in cost:        " ++ show (countNodes costFg) ++
    " (" ++ show (countNodes costFg0) ++ " before CSE)"
  putStrLn $ "nodes in constraints: " ++ show (countNodes constraintsFg) ++
    " (" ++ show (countNodes constraintsFg0) ++ " before CSE)"
  

writeMexAll :: String -> String
writeMexAll name = unlines $ map f ["time", "outputs", "sim", "cost", "constraints"]
  where
    f x = "tic\nfprintf('mexing " ++ file ++ "...  ')\n"++"mex " ++ file ++ "\nt1 = toc;\nfprintf('finished in %.2f seconds\\n', t1)"
      where
        file = name ++ "_" ++ x ++ ".c"


writeSetupSource :: Show a => String -> [Expr a] -> [a] -> [a] -> String
writeSetupSource name dvs lbs ubs =
  unlines $
  [ "function [x0, Aineq, bineq, Aeq, beq, lb, ub] = "++ name ++"_setup()"
  , ""
  , "x0 = zeros(" ++ show (length dvs) ++ ",1);"
  , "Aineq = [];"
  , "bineq = [];"
  , "Aeq = [];"
  , "beq = [];"
  , "lb = " ++ show lbs ++ "';"
  , "ub = " ++ show ubs ++ "';"
  ]


-- take nice matlab structs and return vector of design constants
writeUnstructConsts :: Eq a => String -> [Expr a] -> String
writeUnstructConsts name constants =
  unlines $
  [ "function constants = " ++ name ++ "_unstructConstants(constStruct)\n"
  , "constants = zeros(" ++ show (length constants) ++ ", 1);"
  , ""
  , concatMap fromConst constants
  ]
  where
    readName e = case e of
      ESym (Sym nm) -> nm
      _ -> error "const not ESym Sym"
    fromConst e = "constants(" ++ show (1 + (fromJustErr "fromConst error" $ e `elemIndex` constants)) ++ ") = constStruct." ++ readName e ++ ";\n"


---- take vector of design variables and vector of constants and return nice matlab struct
writeToStruct :: (Eq a, Show a, Hashable a)
                 => String -> [Expr a] -> [Expr a] -> [Expr a] -> HashMap String [Expr a] -> String
writeToStruct name dvs params constants outputMap =
  unlines $
  ["function ret = " ++ name ++ "_struct(designVars,constants)"
  , ""
  , "ret.time = " ++ name ++ "_time(designVars, constants);"
  , "outs = " ++ name ++ "_outputs(designVars, constants);"
  , concat $ zipWith (\name' k -> "ret." ++name'++ " = outs("++show k++",:);\n") (HM.keys outputMap) [(1::Int)..]
  ] ++
  toStruct dvs "designVars" (map show params) (map (\x -> [x]) params) ++
  toStruct constants "constants" (map show constants) (map (\x -> [x]) constants)
    where
      dvsToIdx dvs' = (fromJustErr "toStruct error") . (flip HM.lookup (HM.fromList (zip dvs' [(1::Int)..])))

      toStruct dvs' nm = zipWith (\name' vars -> "ret." ++ name' ++ " = " ++ nm ++ "(" ++ show (map (dvsToIdx dvs') vars) ++ ");\n")



fromJustErr :: String -> Maybe a -> a
fromJustErr _ (Just x) = x
fromJustErr message Nothing = error $ "fromJustErr got Nothing, message: \"" ++ message ++ "\""


spring :: State (Step Double) ()
spring = do
  [x, v] <- setStates ["x","v"]
  [u]    <- setActions ["u"]
  [k, b] <- addConstants ["k", "b"]
  let cost = 2*x*x + 3*v*v + 10*u*u
  setDxdt [v, -k*x - b*v + u]
  setDt (tEnd/((fromIntegral n')-1))

  setLagrangeTerm cost (-1,2000)

  setBound x (5,5) (TIMESTEP 0)
  setBound v (0,0) (TIMESTEP 0)
  
  setBound x (-5,5) ALWAYS
  setBound v (-10,10) ALWAYS
  setBound u (-200, 200) ALWAYS

  setBound v (0,0) (TIMESTEP (n'-1))

  setPeriodic x
  setPeriodic u

tEnd :: Expr Double
tEnd = 1.5

n' :: Int
n' = 18

run :: IO ()
run = msCoctave spring simpsonsRuleError' n' "../Documents/MATLAB/" "spring"
--run = msCoctave spring eulerError' n' "../Documents/MATLAB/" "spring"
