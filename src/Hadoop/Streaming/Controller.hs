{-# LANGUAGE DeriveFunctor              #-}
{-# LANGUAGE EmptyDataDecls             #-}
{-# LANGUAGE ExistentialQuantification  #-}
{-# LANGUAGE FlexibleContexts           #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GADTs                      #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE NoMonomorphismRestriction  #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE RankNTypes                 #-}
{-# LANGUAGE RecordWildCards            #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE TemplateHaskell            #-}
{-# LANGUAGE UndecidableInstances       #-}

-----------------------------------------------------------------------------
-- |
-- Module      :  Hadoop.Streaming.Controller
-- Copyright   :  Soostone Inc
-- License     :  BSD3
--
-- Maintainer  :  Ozgun Ataman
-- Stability   :  experimental
--
-- High level flow-control of Hadoop programs with ability to define a
-- sequence of Map-Reduce operations in a Monad, have strongly typed
-- data locations.
----------------------------------------------------------------------------

module Hadoop.Streaming.Controller
    (
    -- * Command Line Entry Point
      hadoopMain
    , HadoopSettings (..)
    , clouderaDemo
    , amazonEMR

    -- * Logging Related

    , logTo

    -- * Hadoop Program Construction
    , Controller
    , MapReduce (..)
    , Tap (..)
    , Tap'
    , tap


    -- * Buil-in Map-Reduce applications

    , joinStep
    , DataDefs
    , DataSet
    , JoinType (..)
    , JoinKey

    -- * Control flow operations

    , connect
    , io

    ) where

-------------------------------------------------------------------------------
import           Control.Applicative
import           Control.Concurrent
import           Control.Error
import           Control.Lens
import           Control.Monad.Operational as O
import           Control.Monad.State
import           Control.Monad.Trans
import qualified Data.ByteString           as B
import           Data.Conduit
import           Data.Default
import qualified Data.HashMap.Strict       as HM
import           Data.List
import qualified Data.Map                  as M
import           Data.Monoid
import           Data.Serialize
import qualified Data.Text                 as T
import           System.Environment
-------------------------------------------------------------------------------
import           Hadoop.Streaming
import           Hadoop.Streaming.Hadoop
import           Hadoop.Streaming.Join
import           Hadoop.Streaming.Logger
-------------------------------------------------------------------------------



-------------------------------------------------------------------------------
-- | A packaged MapReduce step
data MapReduce a m b = forall v. MapReduce {
      mrOptions :: MROptions v
    , mrMapper  :: Mapper a m v
    , mrReducer :: Reducer v m b
    }


-- | The hadoop-understandable location of a datasource
type Location = String

-- | Tap is a data source definition that *knows* how to serve records
-- of tupe 'a'.
--
-- It comes with knowledge on how to serialize ByteString
-- to that type and can be used both as a sink (to save data form MR
-- output) or source (to feed MR programs).
data Tap m a = Tap
    { location :: Location
    , proto    :: Protocol' m a
    }


-- | It is often just fine to use IO as the base monad for MapReduce ops.
type Tap' a = Tap IO a


-- | Construct a 'DataDef'
tap :: Location -> Protocol' m a -> Tap m a
tap = Tap


data ContState = ContState {
      _csMRCount :: Int
    }

instance Default ContState where
    def = ContState 0


makeLenses ''ContState



data ConI a where
    Connect :: forall i o. MapReduce i IO o
            -> [Tap IO i] -> Tap IO o
            -> ConI ()


    ConIO :: IO a -> ConI a


-- | All MapReduce steps are integrated in the 'Controller' monad.
newtype Controller a = Controller { unController :: Program ConI a }
    deriving (Functor, Applicative, Monad)



-------------------------------------------------------------------------------
-- | Connect a typed MapReduce application you will supply with a list
-- of sources and a destination.
connect :: MapReduce a IO b -> [Tap IO a] -> Tap IO b -> Controller ()
connect mr inp outp = Controller $ singleton $ Connect mr inp outp


-- | LIft IO into 'Controller'. Note that this is a NOOP for when the
-- Mappers/Reducers are running; it only executes in the main
-- controller application during job-flow orchestration.
io :: IO a -> Controller a
io f = Controller $ singleton $ ConIO f


newMRKey :: MonadState ContState m => m String
newMRKey = do
    i <- gets _csMRCount
    csMRCount %= (+1)
    return $! show i



-------------------------------------------------------------------------------
-- | Interpreter for the central job control process
orchestrate
    :: (MonadIO m, MonadLogger m)
    => Controller a
    -> HadoopSettings
    -> ContState
    -> m (Either String a)
orchestrate (Controller p) set s = evalStateT (runEitherT (go p)) s
    where
      go = eval . O.view

      eval (Return a) = return a
      eval (i :>>= f) = eval' i >>= go . f

      eval' :: (MonadLogger m, MonadIO m) => ConI a -> EitherT String (StateT ContState m) a

      eval' (ConIO f) = liftIO f

      eval' (Connect mr inp outp) = go'
          where
            go' = do
                mrKey <- newMRKey
                launchMapReduce set mrKey
                  (mrSettings (map location inp) (location outp))



data Phase = Map | Reduce


-------------------------------------------------------------------------------
-- | The main entry point. Use this function to produce a command line
-- program that encapsulates everything.
hadoopMain
    :: forall m a. (MonadThrow m, MonadIO m, MonadLogger m)
    => Controller a
    -> HadoopSettings
    -> m ()
hadoopMain c@(Controller p) hs = do
    args <- liftIO getArgs
    case args of
      [] -> do
        res <- orchestrate c hs def
        liftIO $ either print (const $ putStrLn "Success.") res
      [arg] -> do
        evalStateT (interpretWithMonad (go arg) p) def
        return ()
      _ -> error "Usage: No arguments for job control or a phase name."
    where

      mkArgs mrKey = [ (Map, "map_" ++ mrKey)
                     , (Reduce, "reduce_" ++ mrKey) ]


      go :: String -> ConI b -> StateT ContState m b

      go arg (ConIO _) = error "You tried to use the result of an IO action during Map-Reduce operation"

      go arg (Connect (MapReduce mro mp rd ) inp outp) = do
          mrKey <- newMRKey
          case find ((== arg) . snd) $ mkArgs mrKey of
            Just (Map, _) -> do
              let inSer = proto $ head inp
              lift $ $(logInfo) $ T.concat ["Mapper ", T.pack mrKey, " initializing."]
              liftIO $ (mapperWith (mroPrism mro) $ protoDec inSer =$= mp)
              lift $ $(logInfo) $ T.concat ["Mapper ", T.pack mrKey, " finished."]
            Just (Reduce, _) -> do
              lift $ $(logInfo) $ T.concat ["Reducer ", T.pack mrKey, " initializing."]
              liftIO $ (reducerMain mro rd (protoEnc $ proto outp))
              lift $ $(logInfo) $ T.concat ["Reducer ", T.pack mrKey, " finished."]
            Nothing -> return ()





-------------------------------------------------------------------------------
-- | A convenient way to express multi-way join operations into a
-- single data type.
joinStep
    :: (Show b, MonadThrow m, Monoid b, MonadIO m,
        Serialize b)
    => [(DataSet, JoinType)]
    -- ^ Dataset definitions
    -> (String -> DataSet)
    -- ^ A function to identify current dataset from input filename
    -> (DataSet -> Conduit a m (JoinKey, b))
    -- ^ A custom function for each dataset, mapping its data to a
    -- uniform record format 'b' that we know how to 'mconcat'
    -- together.
    -> MapReduce a m b
joinStep fs getDS mkMap = MapReduce joinOpts mp rd
    where
      mp = joinMapper getDS mkMap
      rd = joinReducer fs
