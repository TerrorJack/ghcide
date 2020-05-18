-- Copyright (c) 2019 The DAML Authors. All rights reserved.
-- SPDX-License-Identifier: Apache-2.0
{-# OPTIONS_GHC -Wno-dodgy-imports #-} -- GHC no longer exports def in GHC 8.6 and above
{-# LANGUAGE CPP #-} -- To get precise GHC version
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}

module Main(main) where

import Data.Time.Clock (UTCTime)
import Linker (initDynLinker)
import Data.IORef
import NameCache
import Packages
import Module
import Arguments
import Data.Maybe
import Data.List.Extra
import Data.Function
import System.FilePath
import Control.Concurrent.Extra
import Control.Exception
import Control.Monad.Extra
import Control.Monad.IO.Class
import Data.Default
import System.Time.Extra
import Development.IDE.Core.Debouncer
import Development.IDE.Core.FileStore
import Development.IDE.Core.OfInterest
import Development.IDE.Core.Service
import Development.IDE.Core.Rules
import Development.IDE.Core.Shake
import Development.IDE.Core.RuleTypes
import Development.IDE.LSP.Protocol
import Development.IDE.Types.Location
import Development.IDE.Types.Diagnostics
import Development.IDE.Types.Options
import Development.IDE.Types.Logger
import Development.IDE.GHC.Util
import Development.IDE.Plugin
import Development.IDE.Plugin.Completions as Completions
import Development.IDE.Plugin.CodeAction as CodeAction
import qualified Data.Text as T
import qualified Data.Text.IO as T
import qualified Language.Haskell.LSP.Core as LSP
import Language.Haskell.LSP.Messages
import Language.Haskell.LSP.Types (LspId(IdInt))
import Data.Version
import Development.IDE.LSP.LanguageServer
import qualified System.Directory.Extra as IO
import System.Environment
import System.IO
import System.Exit
import HIE.Bios.Environment (addCmdOpts)
import Paths_ghcide
import Development.GitRev
import Development.Shake (Action,  action)
import qualified Data.HashSet as HashSet
import qualified Data.HashMap.Strict as HM
import qualified Data.Map.Strict as Map
import Data.Either
import qualified Crypto.Hash.SHA1               as H
import qualified Data.ByteString.Char8          as B
import Data.ByteString.Base16         (encode)
import Control.Concurrent.Async

import           DynFlags                       (gopt_set, gopt_unset,
                                                 updOptLevel)

import GhcMonad
import HscTypes (HscEnv(..), ic_dflags)
import DynFlags (PackageFlag(..), PackageArg(..))
import GHC hiding (def)
import           GHC.Check                      ( VersionCheck(..), makeGhcVersionChecker )

import           HIE.Bios.Cradle
import           HIE.Bios.Types
import System.Directory

import Utils

ghcideVersion :: IO String
ghcideVersion = do
  path <- getExecutablePath
  let gitHashSection = case $(gitHash) of
        x | x == "UNKNOWN" -> ""
        x -> " (GIT hash: " <> x <> ")"
  return $ "ghcide version: " <> showVersion version
             <> " (GHC: " <> VERSION_ghc
             <> ") (PATH: " <> path <> ")"
             <> gitHashSection

main :: IO ()
main = do
    -- WARNING: If you write to stdout before runLanguageServer
    --          then the language server will not work
    Arguments{..} <- getArguments

    if argsVersion then ghcideVersion >>= putStrLn >> exitSuccess
    else hPutStrLn stderr {- see WARNING above -} =<< ghcideVersion

    -- lock to avoid overlapping output on stdout
    lock <- newLock
    let logger p = Logger $ \pri msg -> when (pri >= p) $ withLock lock $
            T.putStrLn $ T.pack ("[" ++ upper (show pri) ++ "] ") <> msg

    whenJust argsCwd IO.setCurrentDirectory

    dir <- IO.getCurrentDirectory
    command <- makeLspCommandId "typesignature.add"

    let plugins = Completions.plugin <> CodeAction.plugin
        onInitialConfiguration = const $ Right ()
        onConfigurationChange  = const $ Right ()
        options = def { LSP.executeCommandCommands = Just [command]
                      , LSP.completionTriggerCharacters = Just "."
                      }

    if argLSP then do
        t <- offsetTime
        hPutStrLn stderr "Starting LSP server..."
        hPutStrLn stderr "If you are seeing this in a terminal, you probably should have run ghcide WITHOUT the --lsp option!"
        runLanguageServer options (pluginHandler plugins) onInitialConfiguration onConfigurationChange $ \getLspId event vfs caps -> do
            t <- t
            hPutStrLn stderr $ "Started LSP server in " ++ showDuration t
            let options = (defaultIdeOptions $ loadSession dir)
                    { optReportProgress = clientSupportsProgress caps
                    , optShakeProfiling = argsShakeProfiling
                    , optTesting        = argsTesting
                    , optThreads        = argsThreads
                    , optInterfaceLoadingDiagnostics = argsTesting
                    }
            debouncer <- newAsyncDebouncer
            initialise caps (mainRule >> pluginRules plugins >> action kick)
                getLspId event (logger minBound) debouncer options vfs
    else do
        -- GHC produces messages with UTF8 in them, so make sure the terminal doesn't error
        hSetEncoding stdout utf8
        hSetEncoding stderr utf8

        putStrLn $ "Ghcide setup tester in " ++ dir ++ "."
        putStrLn "Report bugs at https://github.com/digital-asset/ghcide/issues"

        putStrLn $ "\nStep 1/6: Finding files to test in " ++ dir
        files <- expandFiles (argFiles ++ ["." | null argFiles])
        -- LSP works with absolute file paths, so try and behave similarly
        files <- nubOrd <$> mapM IO.canonicalizePath files
        putStrLn $ "Found " ++ show (length files) ++ " files"

        putStrLn "\nStep 2/6: Looking for hie.yaml files that control setup"
        cradles <- mapM findCradle files
        let ucradles = nubOrd cradles
        let n = length ucradles
        putStrLn $ "Found " ++ show n ++ " cradle" ++ ['s' | n /= 1]
        putStrLn "\nStep 3/6: Initializing the IDE"
        vfs <- makeVFSHandle
        debouncer <- newAsyncDebouncer
        ide <- initialise def mainRule (pure $ IdInt 0) (showEvent lock) (logger Info) debouncer (defaultIdeOptions $ loadSession dir) vfs

        putStrLn "\nStep 4/6: Type checking the files"
        setFilesOfInterest ide $ HashSet.fromList $ map toNormalizedFilePath' files
        _ <- runActionSync ide $ uses TypeCheck (map toNormalizedFilePath' files)
        return ()

expandFiles :: [FilePath] -> IO [FilePath]
expandFiles = concatMapM $ \x -> do
    b <- IO.doesFileExist x
    if b then return [x] else do
        let recurse "." = True
            recurse x | "." `isPrefixOf` takeFileName x = False -- skip .git etc
            recurse x = takeFileName x `notElem` ["dist","dist-newstyle"] -- cabal directories
        files <- filter (\x -> takeExtension x `elem` [".hs",".lhs"]) <$> IO.listFilesInside (return . recurse) x
        when (null files) $
            fail $ "Couldn't find any .hs/.lhs files inside directory: " ++ x
        return files


kick :: Action ()
kick = do
    files <- getFilesOfInterest
    void $ uses TypeCheck $ HashSet.toList files

-- | Print an LSP event.
showEvent :: Lock -> FromServerMessage -> IO ()
showEvent _ (EventFileDiagnostics _ []) = return ()
showEvent lock (EventFileDiagnostics (toNormalizedFilePath' -> file) diags) =
    withLock lock $ T.putStrLn $ showDiagnosticsColored $ map (file,ShowDiag,) diags
showEvent lock e = withLock lock $ print e


cradleToSessionOpts :: Cradle a -> FilePath -> IO (Either [CradleError] ComponentOptions)
cradleToSessionOpts cradle file = do
    let showLine s = putStrLn ("> " ++ s)
    cradleRes <- runCradle (cradleOptsProg cradle) showLine file
    opts <- case cradleRes of
        CradleSuccess r -> pure (Right r)
        CradleFail err -> return (Left [err])
        -- For the None cradle perhaps we still want to report an Info
        -- message about the fact that the file is being ignored.
        CradleNone -> return (Left [])
    pure opts

emptyHscEnv :: IO HscEnv
emptyHscEnv = do
    libdir <- getLibdir
    env <- runGhc (Just libdir) getSession
    initDynLinker env
    pure env

-- Convert a target to a list of potential absolute paths.
-- A TargetModule can be anywhere listed by the supplied include
-- directories
-- A target file is a relative path but with a specific prefix so just need
-- to canonicalise it.
targetToFile :: [FilePath] -> TargetId -> IO [NormalizedFilePath]
targetToFile is (TargetModule mod) = do
    let fps = [i </> (moduleNameSlashes mod) -<.> ext | ext <- exts, i <- is ]
        exts = ["hs", "hs-boot", "lhs"]
    mapM (fmap toNormalizedFilePath' . canonicalizePath) fps
targetToFile _ (TargetFile f _) = do
  f' <- canonicalizePath f
  return [(toNormalizedFilePath' f')]

setNameCache :: IORef NameCache -> HscEnv -> HscEnv
setNameCache nc hsc = hsc { hsc_NC = nc }

-- This is the key function which implements multi-component support. All
-- components mapping to the same hie,yaml file are mapped to the same
-- HscEnv which is updated as new components are discovered.
loadSession :: FilePath -> Action (FilePath -> Action (IdeResult HscEnvEq))
loadSession dir = do
  ShakeExtras{logger} <- getShakeExtras
  liftIO $ do
    -- Mapping from hie.yaml file to HscEnv, one per hie.yaml file
    hscEnvs <- newVar Map.empty :: IO (Var HieMap)
    -- Mapping from a filepath to HscEnv
    fileToFlags <- newVar Map.empty :: IO (Var FlagsMap)

    -- This caches the mapping from Mod.hs -> hie.yaml
    cradleLoc <- memoIO $ \v -> do
        res <- findCradle v
        -- Sometimes we get C:, sometimes we get c:, and sometimes we get a relative path
        -- try and normalise that
        -- e.g. see https://github.com/digital-asset/ghcide/issues/126
        res' <- traverse IO.makeAbsolute res
        return $ normalise <$> res'

    -- Create a new HscEnv from a hieYaml root and a set of options
    -- If the hieYaml file already has an HscEnv, the new component is
    -- combined with the components in the old HscEnv into a new HscEnv
    -- which contains both.
    packageSetup <- return $ \(hieYaml, cfp, opts) -> do
        -- Parse DynFlags for the newly discovered component
        hscEnv <- emptyHscEnv
        (df, targets) <- evalGhcEnv hscEnv $
                          setOptions opts (hsc_dflags hscEnv)
        dep_info <- getDependencyInfo (componentDependencies opts)
        -- Now lookup to see whether we are combining with an exisiting HscEnv
        -- or making a new one. The lookup returns the HscEnv and a list of
        -- information about other components loaded into the HscEnv
        -- (unitId, DynFlag, Targets)
        modifyVar hscEnvs $ \m -> do
            -- Just deps if there's already an HscEnv
            -- Nothing is it's the first time we are making an HscEnv
            let oldDeps = Map.lookup hieYaml m
            let -- Add the raw information about this component to the list
                -- We will modify the unitId and DynFlags used for
                -- compilation but these are the true source of
                -- information.
                new_deps = (RawComponentInfo (thisInstalledUnitId df) df targets cfp opts dep_info)
                              : maybe [] snd oldDeps
                -- Get all the unit-ids for things in this component
                inplace = map rawComponentUnitId new_deps

            -- Note [Avoiding bad interface files]
            new_deps' <- forM new_deps $ \RawComponentInfo{..} -> do
                -- Remove all inplace dependencies from package flags for
                -- components in this HscEnv
                let (df2, uids) = removeInplacePackages inplace rawComponentDynFlags
                let prefix = show rawComponentUnitId
                df <- setCacheDir prefix (sort $ map show uids) opts df2
                -- All deps, but without any packages which are also loaded
                -- into memory
                pure $ ComponentInfo rawComponentUnitId
                                     df
                                     uids
                                     rawComponentTargets
                                     rawComponentFP
                                     rawComponentCOptions
                                     rawComponentDependencyInfo
            -- Make a new HscEnv, we have to recompile everything from
            -- scratch again (for now)
            -- It's important to keep the same NameCache though for reasons
            -- that I do not fully understand
            logInfo logger (T.pack ("Making new HscEnv" ++ (show inplace)))
            hscEnv <- case oldDeps of
                        Nothing -> emptyHscEnv
                        Just (old_hsc, _) -> setNameCache (hsc_NC old_hsc) <$> emptyHscEnv
            newHscEnv <-
              -- Add the options for the current component to the HscEnv
              evalGhcEnv hscEnv $ do
                _ <- setSessionDynFlags df
                getSession
            -- Modify the map so the hieYaml now maps to the newly created
            -- HscEnv
            -- Returns
            -- . the new HscEnv so it can be used to modify the
            --   FilePath -> HscEnv map (fileToFlags)
            -- . The information for the new component which caused this cache miss
            -- . The modified information (without -inplace flags) for
            --   existing packages
            pure (Map.insert hieYaml (newHscEnv, new_deps) m, (newHscEnv, head new_deps', tail new_deps'))


    session <- return $ \(hieYaml, cfp, opts) -> do
        (hscEnv, new, old_deps) <- packageSetup (hieYaml, cfp, opts)
        -- Make a map from unit-id to DynFlags, this is used when trying to
        -- resolve imports.
        let uids = map (\ci -> (componentUnitId ci, componentDynFlags ci)) (new : old_deps)

        -- For each component, now make a new HscEnvEq which contains the
        -- HscEnv for the hie.yaml file but the DynFlags for that component
        --
        -- Then look at the targets for each component and create a map
        -- from FilePath to the HscEnv
        let new_cache ci =  do
              let df = componentDynFlags ci
              let hscEnv' = hscEnv { hsc_dflags = df
                                   , hsc_IC = (hsc_IC hscEnv) { ic_dflags = df } }

              versionMismatch <- checkGhcVersion
              henv <- case versionMismatch of
                        Just mismatch -> return mismatch
                        Nothing -> newHscEnvEq hscEnv' uids
              let res = (([], Just henv), componentDependencyInfo ci)
              liftIO $ logDebug logger (T.pack (show res))

              let is = importPaths df
              ctargets <- concatMapM (targetToFile is  . targetId) (componentTargets ci)
              -- A special target for the file which caused this wonderful
              -- component to be created. In case the cradle doesn't list all the targets for
              -- the component, in which case things will be horribly broken anyway.
              let special_target = (cfp, res)
              let xs = map (,res) ctargets
              return (special_target:xs, res)

        -- New HscEnv for the component in question
        (cs, res) <- new_cache new
        -- Modified cache targets for everything else in the hie.yaml file
        -- which now uses the same EPS and so on
        cached_targets <- concatMapM (fmap fst . new_cache) old_deps
        modifyVar_ fileToFlags $ \var -> do
            pure $ Map.insert hieYaml (HM.fromList (cs ++ cached_targets)) var

        return (cs, res)

    lock <- newLock

    -- This caches the mapping from hie.yaml + Mod.hs -> [String]
    sessionOpts <- return $ \(hieYaml, file) -> do


        fm <- readVar fileToFlags
        let mv = Map.lookup hieYaml fm
        let v = fromMaybe HM.empty mv
        cfp <- liftIO $ canonicalizePath file
        case HM.lookup (toNormalizedFilePath' cfp) v of
          Just (_, old_di) -> do
            deps_ok <- checkDependencyInfo old_di
            unless deps_ok $ do
              modifyVar_ fileToFlags (const (return Map.empty))
              -- Keep the same name cache
              modifyVar_ hscEnvs (return . Map.adjust (\(h, _) -> (h, [])) hieYaml )
          Nothing -> return ()
        case HM.lookup (toNormalizedFilePath' cfp) v of
            Just opts -> do
                --putStrLn $ "Cached component of " <> show file
                pure ([], fst opts)
            Nothing-> do
                putStrLn $ "Consulting the cradle for " <> show file
                cradle <- maybe (loadImplicitCradle $ addTrailingPathSeparator dir) loadCradle hieYaml
                eopts <- cradleToSessionOpts cradle cfp
                print eopts
                case eopts of
                  Right opts -> do
                    (cs, res) <- session (hieYaml, toNormalizedFilePath' cfp, opts)
                    return (cs, fst res)
                  Left err -> do
                    dep_info <- getDependencyInfo ([fp | Just fp <- [hieYaml]])
                    let ncfp = toNormalizedFilePath' cfp
                    let res = (map (renderCradleError ncfp) err, Nothing)
                    modifyVar_ fileToFlags $ \var -> do
                      pure $ Map.insertWith HM.union hieYaml (HM.singleton ncfp (res, dep_info)) var
                    return ([(ncfp, (res, dep_info) )], res)

    dummyAs <- async $ return (error "Uninitialised")
    runningCradle <- newIORef dummyAs
    -- The main function which gets options for a file. We only want one of these running
    -- at a time.
    let getOptions file = do
            hieYaml <- cradleLoc file
            sessionOpts (hieYaml, file)
    -- The lock is on the `runningCradle` resource
    return $ \file -> do
      (_cs, opts) <- liftIO $ withLock lock $ do
        as <- readIORef runningCradle
        finished <- poll as
        case finished of
            Just {} -> do
                mask_ $ do
                  as <- async $ getOptions file
                  writeIORef runningCradle as
                wait as
             -- If it's not finished then wait and then get options, this could of course be killed still
            Nothing -> do
                _ <- wait as
                getOptions file
      return opts

{- Note [Avoiding bad interface files]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Originally, we set the cache directory for the various components once
on the first occurrence of the component.
This works fine if these components have no references to each other,
but you have components that depend on each other, the interface files are
updated for each component.
After restarting the session and only opening the component that depended
on the other, suddenly the interface files of this component are stale.
However, from the point of view of `ghcide`, they do not look stale,
thus, not regenerated and the IDE shows weird errors such as:
```
typecheckIface
Declaration for Rep_ClientRunFlags
Axiom branches Rep_ClientRunFlags:
  Failed to load interface for ‘Distribution.Simple.Flag’
  Use -v to see a list of the files searched for.
```
and
```
expectJust checkFamInstConsistency
CallStack (from HasCallStack):
  error, called at compiler\\utils\\Maybes.hs:55:27 in ghc:Maybes
  expectJust, called at compiler\\typecheck\\FamInst.hs:461:30 in ghc:FamInst
```

To mitigate this, we set the cache directory for each component dependent
on the components of the current `HscEnv`, additionally to the component options
of the respective components.
Assume two components, c1, c2, where c2 depends on c1, and the options of the
respective components are co1, co2.
If we want to load component c2, followed by c1, we set the cache directory for
each component in this way:

  * Load component c2
    * (Cache Directory State)
        - name of c2 + co2
  * Load component c1
    * (Cache Directory State)
        - name of c2 + name of c1 + co2
        - name of c2 + name of c1 + co1

Overall, we created three cache directories. If we opened c1 first, then we
create a fourth cache directory.
This makes sure that interface files are always correctly updated.

Since this causes a lot of recompilation, we only update the cache-directory,
if the dependencies of a component have really changed.
E.g. when you load two executables, they can not depend on each other. They
should be filtered out, such that we dont have to re-compile everything.
-}


setCacheDir :: MonadIO m => String -> [String] -> ComponentOptions -> DynFlags -> m DynFlags
setCacheDir prefix hscComponents comps dflags = do
    cacheDir <- liftIO $ getCacheDir prefix (hscComponents ++ componentOptions comps)
    pure $ dflags
          & setHiDir cacheDir
          & setDefaultHieDir cacheDir


renderCradleError :: NormalizedFilePath -> CradleError -> FileDiagnostic
renderCradleError nfp (CradleError _ec t) =
  ideErrorText nfp (T.unlines (map T.pack t))



type DependencyInfo = Map.Map FilePath (Maybe UTCTime)
type HieMap = Map.Map (Maybe FilePath) (HscEnv, [RawComponentInfo])
type FlagsMap = Map.Map (Maybe FilePath) (HM.HashMap NormalizedFilePath (IdeResult HscEnvEq, DependencyInfo))

-- This is unmodified
data RawComponentInfo = RawComponentInfo { rawComponentUnitId :: InstalledUnitId
                                   , rawComponentDynFlags :: DynFlags
                                   , rawComponentTargets :: [Target]
                                   , rawComponentFP :: NormalizedFilePath
                                   , rawComponentCOptions :: ComponentOptions
                                   , rawComponentDependencyInfo :: DependencyInfo }

data ComponentInfo = ComponentInfo { componentUnitId :: InstalledUnitId
                                   , componentDynFlags :: DynFlags
                                   , componentInternalUnits :: [InstalledUnitId]
                                   , componentTargets :: [Target]
                                   , componentFP :: NormalizedFilePath
                                   , componentCOptions :: ComponentOptions
                                   , componentDependencyInfo :: DependencyInfo }

checkDependencyInfo :: DependencyInfo -> IO Bool
checkDependencyInfo old_di = do
  di <- getDependencyInfo (Map.keys old_di)
  return (di == old_di)



getDependencyInfo :: [FilePath] -> IO DependencyInfo
getDependencyInfo fs = Map.fromList <$> mapM do_one fs

  where
    tryIO :: IO a -> IO (Either IOException a)
    tryIO = try

    do_one :: FilePath -> IO (FilePath, Maybe UTCTime)
    do_one fp = (fp,) . either (const Nothing) Just <$> tryIO (getModificationTime fp)

-- This function removes all the -package flags which refer to packages we
-- are going to deal with ourselves. For example, if a executable depends
-- on a library component, then this function will remove the library flag
-- from the package flags for the executable
--
-- There are several places in GHC (for example the call to hptInstances in
-- tcRnImports) which assume that all modules in the HPT have the same unit
-- ID. Therefore we create a fake one and give them all the same unit id.
removeInplacePackages :: [InstalledUnitId] -> DynFlags -> (DynFlags, [InstalledUnitId])
removeInplacePackages us df = (df { packageFlags = ps
                                  , thisInstalledUnitId = fake_uid }, uids)
  where
    (uids, ps) = partitionEithers (map go (packageFlags df))
    fake_uid = toInstalledUnitId (stringToUnitId "fake_uid")
    go p@(ExposePackage _ (UnitIdArg u) _) = if (toInstalledUnitId u `elem` us) then Left (toInstalledUnitId u) else Right p
    go p = Right p

-- | Memoize an IO function, with the characteristics:
--
--   * If multiple people ask for a result simultaneously, make sure you only compute it once.
--
--   * If there are exceptions, repeatedly reraise them.
--
--   * If the caller is aborted (async exception) finish computing it anyway.
memoIO :: Ord a => (a -> IO b) -> IO (a -> IO b)
memoIO op = do
    ref <- newVar Map.empty
    return $ \k -> join $ mask_ $ modifyVar ref $ \mp ->
        case Map.lookup k mp of
            Nothing -> do
                res <- onceFork $ op k
                return (Map.insert k res mp, res)
            Just res -> return (mp, res)

setOptions :: GhcMonad m => ComponentOptions -> DynFlags -> m (DynFlags, [Target])
setOptions (ComponentOptions theOpts _) dflags = do
    (dflags', targets) <- addCmdOpts theOpts dflags
    let dflags'' =
          -- disabled, generated directly by ghcide instead
          flip gopt_unset Opt_WriteInterface $
          -- disabled, generated directly by ghcide instead
          -- also, it can confuse the interface stale check
          dontWriteHieFiles $
          setIgnoreInterfacePragmas $
          setLinkerOptions $
          disableOptimisation dflags'
    -- initPackages parses the -package flags and
    -- sets up the visibility for each component.
    (final_df, _) <- liftIO $ initPackages dflags''
--    let df'' = gopt_unset df' Opt_WarnIsError
    return (final_df, targets)


-- we don't want to generate object code so we compile to bytecode
-- (HscInterpreted) which implies LinkInMemory
-- HscInterpreted
setLinkerOptions :: DynFlags -> DynFlags
setLinkerOptions df = df {
    ghcLink   = LinkInMemory
  , hscTarget = HscNothing
  , ghcMode = CompManager
  }

setIgnoreInterfacePragmas :: DynFlags -> DynFlags
setIgnoreInterfacePragmas df =
    gopt_set (gopt_set df Opt_IgnoreInterfacePragmas) Opt_IgnoreOptimChanges

disableOptimisation :: DynFlags -> DynFlags
disableOptimisation df = updOptLevel 0 df

setHiDir :: FilePath -> DynFlags -> DynFlags
setHiDir f d =
    -- override user settings to avoid conflicts leading to recompilation
    d { hiDir      = Just f}

getCacheDir :: String -> [String] -> IO FilePath
getCacheDir prefix opts = IO.getXdgDirectory IO.XdgCache (cacheDir </> prefix ++ "-" ++ opts_hash)
    where
        -- Create a unique folder per set of different GHC options, assuming that each different set of
        -- GHC options will create incompatible interface files.
        opts_hash = B.unpack $ encode $ H.finalize $ H.updates H.init $ (map B.pack opts)

-- Prefix for the cache path
cacheDir :: String
cacheDir = "ghcide"

ghcVersionChecker :: IO VersionCheck
ghcVersionChecker = $$(makeGhcVersionChecker (pure <$> getLibdir))

checkGhcVersion :: IO (Maybe HscEnvEq)
checkGhcVersion = do
    res <- ghcVersionChecker
    case res of
        Failure err -> do
          putStrLn $ "Error while checking GHC version: " ++ show err
          return Nothing
        Mismatch {..} ->
          return $ Just GhcVersionMismatch {..}
        _ ->
          return Nothing
