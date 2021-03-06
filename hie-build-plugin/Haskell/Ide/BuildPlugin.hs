{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE PartialTypeSignatures #-}
{-# LANGUAGE RankNTypes #-}
module Haskell.Ide.BuildPlugin where

import qualified Control.Exception as Exception
import           Control.Monad.IO.Class
import           Control.Monad.Trans.Reader
import           Haskell.Ide.Engine.ExtensibleState
import           Haskell.Ide.Engine.MonadFunctions
import           Haskell.Ide.Engine.PluginDescriptor
import           Haskell.Ide.Engine.PluginUtils
import qualified Data.ByteString as B
import           Data.Maybe
import qualified Data.Map as Map
import qualified Data.Text as T
import System.Directory (makeAbsolute, getCurrentDirectory, getDirectoryContents, doesFileExist)
import System.FilePath ((</>), normalise, takeExtension, takeFileName, makeRelative)
import System.Process (readProcess)
import System.IO (openFile, hClose, IOMode(..))
import System.IO.Error

import Distribution.Helper

import Distribution.Simple.Setup (defaultDistPref)
import Distribution.Simple.Configure (localBuildInfoFile)
import Distribution.Simple.Utils (findPackageDesc, withFileContents)
import Distribution.Package (pkgName, unPackageName)
import Distribution.PackageDescription
import Distribution.PackageDescription.Configuration
import Distribution.PackageDescription.Parse
import qualified Distribution.Verbosity as Verb

import Data.Yaml

-- ---------------------------------------------------------------------

buildModeArg = SParamDesc (Proxy :: Proxy "mode") (Proxy :: Proxy "Operation mode: \"stack\" or \"cabal\"") SPtText SRequired
distDirArg = SParamDesc (Proxy :: Proxy "distDir") (Proxy :: Proxy "Directory to search for setup-config file") SPtFile SOptional
toolArgs = SParamDesc (Proxy :: Proxy "cabalExe") (Proxy :: Proxy "Cabal executable") SPtText SOptional
        :& SParamDesc (Proxy :: Proxy "stackExe") (Proxy :: Proxy "Stack executable") SPtText SOptional
        :& RNil

pluginCommonArgs = buildModeArg :& distDirArg :& toolArgs

buildPluginDescriptor :: TaggedPluginDescriptor _
buildPluginDescriptor = PluginDescriptor
  {
    pdUIShortName = "Build plugin"
  , pdUIOverview = "A HIE plugin for building cabal/stack packages"
  , pdCommands =
         buildCommand prepareHelper (Proxy :: Proxy "prepare")
            "Prepares helper executable. The project must be configured first"
            [] (SCtxNone :& RNil)
            (   pluginCommonArgs
            <+> RNil) SaveNone
--       :& buildCommand isHelperPrepared (Proxy :: Proxy "isPrepared")
--             "Checks whether cabal-helper is prepared to work with this project. The project must be configured first"
--             [] (SCtxNone :& RNil)
--             (   pluginCommonArgs
--             <+> RNil) SaveNone
      :& buildCommand isConfigured (Proxy :: Proxy "isConfigured")
            "Checks if project is configured"
            [] (SCtxNone :& RNil)
            (  buildModeArg
            :& distDirArg
            :& RNil) SaveNone
      :& buildCommand configure (Proxy :: Proxy "configure")
            "Configures the project. For stack project with multiple local packages - build it"
            [] (SCtxNone :& RNil)
            (   pluginCommonArgs
            <+> RNil) SaveNone
      :& buildCommand listTargets (Proxy :: Proxy "listTargets")
            "Given a directory with stack/cabal project lists all its targets"
            [] (SCtxNone :& RNil)
            (   pluginCommonArgs
            <+> RNil) SaveNone
      :& buildCommand listFlags (Proxy :: Proxy "listFlags")
            "Lists all flags that can be set when configuring a package"
            [] (SCtxNone :& RNil)
            (  buildModeArg
            :& RNil) SaveNone
      :& buildCommand buildDirectory (Proxy :: Proxy "buildDirectory")
            "Builds all targets that correspond to the specified directory"
            [] (SCtxNone :& RNil)
            (  pluginCommonArgs
            <+> (SParamDesc (Proxy :: Proxy "directory") (Proxy :: Proxy "Directory to build targets from") SPtFile SOptional :& RNil)
            <+> RNil) SaveNone
      :& buildCommand buildTarget (Proxy :: Proxy "buildTarget")
            "Builds specified cabal or stack component"
            [] (SCtxNone :& RNil)
            (  pluginCommonArgs
            <+> (SParamDesc (Proxy :: Proxy "target") (Proxy :: Proxy "Component to build") SPtText SOptional :& RNil)
            <+> (SParamDesc (Proxy :: Proxy "package") (Proxy :: Proxy "Package to search the component in. Only applicable for Stack mode") SPtText SOptional :& RNil)
            <+> (SParamDesc (Proxy :: Proxy "type") (Proxy :: Proxy "Type of the component. Only applicable for Stack mode") SPtText SOptional :& RNil)
            <+> RNil) SaveNone
      :& RNil
  , pdExposedServices = []
  , pdUsedServices    = []
  }

data OperationMode = StackMode | CabalMode

readMode "stack" = Just StackMode
readMode "cabal" = Just CabalMode
readMode _ = Nothing

data CommonArgs = CommonArgs {
         caMode :: OperationMode
        ,caDistDir :: String
        ,caCabal :: String
        ,caStack :: String
    }

withCommonArgs ctx req a = do
  case getParams (IdText "mode" :& RNil) req of
    Left err -> return err
    Right (ParamText mode0 :& RNil) -> do
      case readMode mode0 of
        Nothing -> return $ incorrectParameter "mode" ["stack","cabal"] mode0
        Just mode -> do
          let cabalExe = maybe "cabal" id $
                Map.lookup "cabalExe" (ideParams req) >>= (\(ParamTextP v) -> return $ T.unpack v)
              stackExe = maybe "stack" id $
                Map.lookup "stackExe" (ideParams req) >>= (\(ParamTextP v) -> return $ T.unpack v)
          distDir <- maybe (liftIO $ getDistDir mode stackExe) return $
                Map.lookup "distDir" (ideParams req) >>=
                         uriToFilePath . (\(ParamFileP v) -> v)
          runReaderT a $ CommonArgs {
              caMode = mode,
              caDistDir = distDir,
              caCabal = cabalExe,
              caStack = stackExe
            }

-----------------------------------------------

-- isHelperPrepared :: CommandFunc Bool
-- isHelperPrepared = CmdSync $ \ctx req -> withCommonArgs ctx req $ do
--   distDir <- asks caDistDir
--   ret <- liftIO $ isPrepared (defaultQueryEnv "." distDir)
--   return $ IdeResponseOk ret

-----------------------------------------------

prepareHelper :: CommandFunc ()
prepareHelper = CmdSync $ \ctx req -> withCommonArgs ctx req $ do
  ca <- ask
  liftIO $ case caMode ca of
      StackMode -> do
        slp <- getStackLocalPackages "stack.yaml"
        mapM_ (prepareHelper' (caDistDir ca) (caCabal ca))  slp
      CabalMode -> prepareHelper' (caDistDir ca) (caCabal ca) "."
  return $ IdeResponseOk ()

prepareHelper' distDir cabalExe dir =
  prepare' $ (defaultQueryEnv dir distDir) {qePrograms = defaultPrograms {cabalProgram = cabalExe}}

-----------------------------------------------

isConfigured :: CommandFunc Bool
isConfigured = CmdSync $ \ctx req -> withCommonArgs ctx req $ do
  distDir <- asks caDistDir
  ret <- liftIO $ doesFileExist $ localBuildInfoFile distDir
  return $ IdeResponseOk ret

-----------------------------------------------

configure :: CommandFunc ()
configure = CmdSync $ \ctx req -> withCommonArgs ctx req $ do
  ca <- ask
  liftIO $ case caMode ca of
      StackMode -> configureStack (caStack ca)
      CabalMode -> configureCabal (caCabal ca)
  return $ IdeResponseOk ()

configureStack stackExe = do
  slp <- getStackLocalPackages "stack.yaml"
  -- stack can configure only single local package
  case slp of
    [singlePackage] -> readProcess stackExe ["build", "--only-configure"] ""
    manyPackages -> readProcess stackExe ["build"] ""

configureCabal cabalExe = readProcess cabalExe ["configure"] ""

-----------------------------------------------

listFlags :: CommandFunc Object
listFlags = CmdSync $ \ctx req -> do
  case getParams (IdText "mode" :& RNil) req of
    Left err -> return err
    Right (ParamText mode :& RNil) -> do
      cwd <- liftIO $ getCurrentDirectory
      flags0 <- liftIO $ case mode of
            "stack" -> listFlagsStack cwd
            "cabal" -> fmap (:[]) (listFlagsCabal cwd)
      let flags = flip map flags0 $ \(n,f) ->
                    object ["packageName" .= n, "flags" .= map flagToJSON f]
          (Object ret) = object ["res" .= toJSON flags]
      return $ IdeResponseOk ret

listFlagsStack d = do
    stackPackageDirs <- getStackLocalPackages (d </> "stack.yaml")
    mapM (listFlagsCabal . (d </>)) stackPackageDirs

listFlagsCabal d = do
    [cabalFile] <- filter isCabalFile <$> getDirectoryContents d
    gpd <- readPackageDescription Verb.silent (d </> cabalFile)
    let name = unPackageName $ pkgName $ package $ packageDescription gpd
        flags = genPackageFlags gpd
    return (name, flags)

flagToJSON f = object ["name" .= ((\(FlagName s) -> s) $ flagName f), "description" .= flagDescription f, "default" .= flagDefault f]

-----------------------------------------------

buildDirectory :: CommandFunc ()
buildDirectory = CmdSync $ \ctx req -> withCommonArgs ctx req $ do
  ca <- ask
  liftIO $ case caMode ca of
    CabalMode -> do
      -- for cabal specifying directory have no sense
      readProcess (caCabal ca) ["build"] ""
      return $ IdeResponseOk ()
    StackMode -> do
      let mbDir = Map.lookup "directory" (ideParams req) >>= (\(ParamFileP v) -> return v)
      case mbDir of
        Nothing -> do
          readProcess (caStack ca) ["build"] ""
          return $ IdeResponseOk ()
        Just dir0 -> pluginGetFile "buildDirectory" dir0 $ \dir -> do
          cwd <- getCurrentDirectory
          let relDir = makeRelative cwd $ normalise dir
          readProcess (caStack ca) ["build", relDir] ""
          return $ IdeResponseOk ()

-----------------------------------------------

buildTarget :: CommandFunc ()
buildTarget = CmdSync $ \ctx req -> withCommonArgs ctx req $ do
  ca <- ask
  let component = Map.lookup "target" (ideParams req) >>= (\(ParamTextP v) -> return v)
  liftIO $ case caMode ca of
    CabalMode -> do
      readProcess (caCabal ca) ["build", T.unpack $ maybe "" id component] ""
      return $ IdeResponseOk ()
    StackMode -> do
      let package = Map.lookup "package" (ideParams req) >>= (\(ParamTextP v) -> return v)
          compType = maybe "" (T.cons ':') $
              Map.lookup "type" (ideParams req) >>= (\(ParamTextP v) -> return v)
      case (package, component) of
        (Just p, Nothing) -> do
          readProcess (caStack ca) ["build", T.unpack $ p `T.append` compType] ""
          return $ IdeResponseOk ()
        (Just p, Just c) -> do
          readProcess (caStack ca) ["build", T.unpack $ p `T.append` compType `T.append` (':' `T.cons` c)] ""
          return $ IdeResponseOk ()
        (Nothing, Just c) -> do
          readProcess (caStack ca) ["build", T.unpack $ ':' `T.cons` c] ""
          return $ IdeResponseOk ()
        _ -> do
          readProcess (caStack ca) ["build"] ""
          return $ IdeResponseOk ()

-----------------------------------------------

data Package = Package {
    tPackageName :: String
   ,tDirectory :: String
   ,tTargets :: [ChComponentName]
  }

listTargets :: CommandFunc [Value]
listTargets = CmdSync $ \ctx req -> withCommonArgs ctx req $ do
  ca <- ask
  targets <- liftIO $ case caMode ca of
      CabalMode -> (:[]) <$> listCabalTargets (caDistDir ca) "."
      StackMode -> listStackTargets (caDistDir ca)
  let ret = flip map targets $ \t -> object
        ["name" .= tPackageName t,
         "directory" .= tDirectory t,
         "targets" .= map compToJSON (tTargets t)]
  return $ IdeResponseOk ret

listStackTargets distDir = do
  stackPackageDirs <- getStackLocalPackages "stack.yaml"
  mapM (listCabalTargets distDir) stackPackageDirs

listCabalTargets distDir dir = do
  runQuery (defaultQueryEnv dir distDir) $ do
    pkgName <- fst <$> packageId
    comps <- map (fixupLibraryEntrypoint pkgName) <$> map fst <$> entrypoints
    absDir <- liftIO $ makeAbsolute dir
    return $ Package pkgName absDir comps
  where
    fixupLibraryEntrypoint n (ChLibName "") = (ChLibName n)
    fixupLibraryEntrypoint _ e = e

-----------------------------------------------

data StackYaml = StackYaml [StackPackage]
data StackPackage = LocalOrHTTPPackage { stackPackageName :: String }
                  | Repository

instance FromJSON StackYaml where
  parseJSON (Object o) = StackYaml <$>
    o .: "packages"

instance FromJSON StackPackage where
  parseJSON (Object o) = pure Repository
  parseJSON (String s) = pure $ LocalOrHTTPPackage (T.unpack s)

isLocal (LocalOrHTTPPackage _) = True
isLocal _ = False

getStackLocalPackages stackYaml = withBinaryFileContents stackYaml $ \contents -> do
  let (Just (StackYaml stackYaml)) = decode contents
      stackLocalPackages = map stackPackageName $ filter isLocal stackYaml
  return stackLocalPackages

compToJSON ChSetupHsName = object ["type" .= ("setupHs" :: T.Text)]
compToJSON (ChLibName n) = object ["type" .= ("library" :: T.Text), "name" .= n]
compToJSON (ChExeName n) = object ["type" .= ("executable" :: T.Text), "name" .= n]
compToJSON (ChTestName n) = object ["type" .= ("test" :: T.Text), "name" .= n]
compToJSON (ChBenchName n) = object ["type" .= ("benchmark" :: T.Text), "name" .= n]

-----------------------------------------------

getDistDir CabalMode _ = do
    cwd <- getCurrentDirectory
    return $ cwd </> defaultDistPref
getDistDir StackMode stackExe = do
    cwd <- getCurrentDirectory
    dist <- init <$> readProcess stackExe ["path", "--dist-dir"] ""
    return $ cwd </> dist

isCabalFile :: FilePath -> Bool
isCabalFile f = takeExtension' f == ".cabal"

takeExtension' :: FilePath -> String
takeExtension' p =
    if takeFileName p == takeExtension p
      then "" -- just ".cabal" is not a valid cabal file
      else takeExtension p

withBinaryFileContents name act =
  Exception.bracket (openFile name ReadMode) hClose
                    (\hnd -> B.hGetContents hnd >>= act)
