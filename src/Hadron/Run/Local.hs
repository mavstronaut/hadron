{-# LANGUAGE FlexibleContexts          #-}
{-# LANGUAGE MultiParamTypeClasses     #-}
{-# LANGUAGE NoMonomorphismRestriction #-}
{-# LANGUAGE OverloadedStrings         #-}
{-# LANGUAGE RankNTypes                #-}
{-# LANGUAGE RecordWildCards           #-}
{-# LANGUAGE TemplateHaskell           #-}

-----------------------------------------------------------------------------
-- |
-- Module      :
-- Copyright   :
-- License     :
--
-- Maintainer  :
-- Stability   :  experimental
--
-- Emulate all hadoop operations locally
----------------------------------------------------------------------------

module Hadron.Run.Local where

-------------------------------------------------------------------------------
import           Control.Applicative
import           Control.Error
import           Control.Lens
import           Control.Monad.Reader
import qualified Data.ByteString.Char8 as B
import           Data.Default
import           Data.Hashable
import           Data.List
import           Data.Monoid
import           Data.RNG
import           System.Directory
import           System.Environment
import           System.Exit
import           System.FilePath.Lens
import           System.FilePath.Posix
import           System.IO
import qualified System.IO.Streams     as S
import           System.Process
-------------------------------------------------------------------------------
import           Hadron.Logger
import qualified Hadron.Run.Hadoop     as H
import           Hadron.Utils
-------------------------------------------------------------------------------


newtype LocalFile = LocalFile { _unLocalFile :: FilePath }
    deriving (Eq,Show,Read,Ord)
makeLenses ''LocalFile


data LocalRunSettings = LocalRunSettings {
      _lrsTempPath :: FilePath
    -- ^ Root of the "file system" during a localrun
    }
makeLenses ''LocalRunSettings


instance Default LocalRunSettings where
    def = LocalRunSettings "tmp"


type Local = ReaderT LocalRunSettings IO

runLocal :: r -> ReaderT r m a -> m a
runLocal env f = runReaderT f env


-------------------------------------------------------------------------------
path :: (MonadIO m, MonadReader LocalRunSettings m) => LocalFile -> m FilePath
path (LocalFile fp) = do
    root <- view lrsTempPath
    let p = root </> fp
        dir = p ^. directory
    liftIO $ createDirectoryIfMissing True dir
    return p


-------------------------------------------------------------------------------
localMapReduce
    :: MonadIO m
    => LocalRunSettings
    -> String                   -- ^ MapReduceKey
    -> String                   -- ^ RunToken
    -> H.HadoopRunOpts
    -> EitherT String m ()
localMapReduce ls mrKey token H.HadoopRunOpts{..} = do
    exPath <- scriptIO getExecutablePath
    liftIO $ infoM "Hadron.Run.Local" $
      "Launching Hadoop job for MR key: " <> mrKey


    expandedInput <- liftIO $ liftM concat $ forM _mrsInput $ \ inp ->
      withLocalFile ls (LocalFile inp) $ \ fp -> do
        chk <- doesDirectoryExist fp
        case chk of
          False -> return [fp]
          True -> do
            fs <- getDirectoryContents fp
            return $ map (fp </>)
                   $ filter (not . flip elem [".", ".."]) fs


    let enableCompress = case _mrsCompress of
          Nothing -> False
          Just x -> isInfixOf "Gzip" x

        -- Are the input files already compressed?
        inputCompressed file = isInfixOf ".gz" file


    outFile <- liftIO $ withLocalFile ls (LocalFile _mrsOutput) $ \ fp ->
      case fp ^. extension . to null of
        False -> return fp
        True -> do
          createDirectoryIfMissing True fp
          return $ fp </> ("0000.out" ++ if enableCompress then ".gz" else "")


    let pipe = " | "

        maybeCompress = if enableCompress
                        then  pipe <> "gzip"
                        else ""

        maybeGunzip fp = (if inputCompressed fp then ("gunzip" <> pipe) else "")

        maybeReducer = case _mrsNumReduce of
          Just 0 -> ""
          _ -> pipe <> exPath <> " " <> token <> " " <> "reducer_" <> mrKey



        -- map over each file individually and write results into a temp file
        mapFile infile = clearExit . scriptIO . withTmpMapFile infile $ \ fp -> do
            echoInfo ("Running command: " <> (command fp))
            setEnv "mapreduce_map_input_file" infile
            system (command fp)
          where
            command fp =
                "cat " <> infile <> pipe <>
                maybeGunzip infile <>
                exPath <> " " <> token <> " " <> "mapper_" <> mrKey <>
                " > " <> fp


        -- a unique temp file for each input file
        withTmpMapFile infile f = liftIO $
          withLocalFile ls (LocalFile ((show (hash infile)) <> "_mapout")) f


        getTempMapFiles = mapM (flip withTmpMapFile return) expandedInput

        -- concat all processed map output, sort and run through the reducer
        reduceFiles = do
            fs <- getTempMapFiles
            echoInfo ("Running command: " <> (command fs))
            clearExit $ scriptIO $ system (command fs)
          where
            command fs =
                "cat " <> intercalate " " fs <> pipe <>
                ("sort -t$'\t' -k1," <> show (H.numSegs _mrsPart)) <>
                maybeReducer <>
                maybeCompress <>
                " > " <> outFile

        removeTempFiles = scriptIO $ do
            fs <- getTempMapFiles
            mapM_ removeFile fs


    liftIO $ infoM "Hadron.Run.Local" "Mapping over all local files"
    mapM_ mapFile expandedInput

    liftIO $ infoM "Hadron.Run.Local" "Executing reduce stage."
    reduceFiles

    removeTempFiles


-------------------------------------------------------------------------------
echoInfo :: MonadIO m => String -> m ()
echoInfo msg = liftIO $ infoM "Hadron.Run.Local" msg


-------------------------------------------------------------------------------
-- | Fail if command not successful.
clearExit :: MonadIO m => EitherT String m ExitCode -> EitherT [Char] m ()
clearExit f = do
    res <- f
    case res of
      ExitSuccess -> liftIO $ infoM "Hadron.Run.Local" "Command successful."
      e -> do
        liftIO . errorM "Hadron.Run.Local" $ "Command failed: " ++ show e
        hoistEither $ Left $ "Command failed with: " ++ show e


-------------------------------------------------------------------------------
-- | Check if the target file is present.
hdfsFileExists
    :: (MonadIO m, MonadReader LocalRunSettings m)
    => LocalFile
    -> m Bool
hdfsFileExists p = liftIO . chk =<< path p
    where
      chk fp = (||) <$> doesFileExist fp <*> doesDirectoryExist fp


-------------------------------------------------------------------------------
hdfsDeletePath
    :: (MonadIO m, MonadReader LocalRunSettings m)
    => LocalFile
    -> m ()
hdfsDeletePath p = do
    fp <- path p
    liftIO $ do
      chk <- doesDirectoryExist fp
      when chk (removeDirectoryRecursive fp)
      chk2 <- doesFileExist fp
      when chk2 (removeFile fp)


-------------------------------------------------------------------------------
hdfsLs
    :: (MonadIO m, MonadReader LocalRunSettings m)
    => LocalFile -> m [File]
hdfsLs p = do
    fs <- liftIO . getDirectoryContents' =<< path p
    return $ map (File "" 1 "" "") $ map (_unLocalFile p </>) fs


-------------------------------------------------------------------------------
-- | A version that return [] instead of an error when directory does not exit.
getDirectoryContents' :: FilePath -> IO [FilePath]
getDirectoryContents' fp = do
    chk <- doesDirectoryExist fp
    case chk of
      False -> return []
      True -> getDirectoryContents fp

-------------------------------------------------------------------------------
hdfsPut
    :: (MonadIO m, MonadReader LocalRunSettings m)
    => LocalFile
    -> LocalFile
    -> m ()
hdfsPut src dest = do
    src' <- path src
    dest' <- path dest
    liftIO $ copyFile src' dest'


-------------------------------------------------------------------------------
hdfsMkdir
    :: (MonadIO m, MonadReader LocalRunSettings m)
    => LocalFile
    -> m ()
hdfsMkdir p = liftIO . createDirectoryIfMissing True =<< path p


-------------------------------------------------------------------------------
hdfsCat :: LocalFile -> Local (S.InputStream B.ByteString)
hdfsCat p = do
    fp <- (path p)
    h <- liftIO $ openFile fp ReadMode
    liftIO $ S.handleToInputStream h >>= S.atEndOfInput (hClose h)


-------------------------------------------------------------------------------
hdfsGet
    :: (MonadIO m, MonadReader LocalRunSettings m)
    => LocalFile
    -> m LocalFile
hdfsGet fp = do
    target <- randomFileName
    hdfsPut fp target
    return target



hdfsLocalStream :: LocalFile -> Local (S.InputStream B.ByteString)
hdfsLocalStream = hdfsCat


randomFileName :: MonadIO m => m LocalFile
randomFileName = (LocalFile . B.unpack) `liftM` liftIO (mkRNG >>= randomToken 64)



-------------------------------------------------------------------------------
-- | Helper to work with relative paths using Haskell functions like
-- 'readFile' and 'writeFile'.
withLocalFile
    :: MonadIO m
    => LocalRunSettings
    -> LocalFile
    -- ^ A relative path in our working folder
    -> (FilePath -> m b)
    -- ^ What to do with the absolute path.
    -> m b
withLocalFile settings fp f = f =<< runLocal settings (path fp)


