{-# language BlockArguments #-}
{-# language LambdaCase #-}
{-# language NamedFieldPuns #-}
{-# language OverloadedStrings #-}
{-# language ViewPatterns #-}

module Main ( main ) where

import Paths_ghc_nix ( getDataFileName )

import Control.Applicative ( empty )
import Control.Concurrent.Async
import Control.Concurrent.MVar
import Control.Exception.Safe ( tryAny )
import qualified Control.Foldl
import Control.Monad ( void )
import Control.Monad.IO.Class ( liftIO )
import qualified Data.Aeson as JSON
import Data.Foldable
import qualified Data.HashMap.Strict as HashMap
import Data.Map.Strict ( Map )
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.String ( fromString )
import qualified Data.Text
import qualified Data.Text.Encoding
import Data.Traversable ( for )
import Digraph
import DynFlags
import Finder
import GHC
import GHC.Paths ( libdir )
import HscTypes
import System.Environment ( getArgs )
import System.FilePath ( takeExtension, takeFileName )
import qualified Turtle

main :: IO ()
main = do
  commandLineArguments <-
    getArgs

  case commandLineArguments of
    "--numeric-version" : _ ->
      void ( Turtle.proc "ghc" ( map fromString commandLineArguments ) empty )

    "--supported-languages" : _ ->
      void ( Turtle.proc "ghc" ( map fromString commandLineArguments ) empty )

    "--info" : _ ->
      void ( Turtle.proc "ghc" ( map fromString commandLineArguments ) empty )

    "--print-global-package-db" : _ ->
      void ( Turtle.proc "ghc" ( map fromString commandLineArguments ) empty )

    "--print-libdir" : _ ->
      void ( Turtle.proc "ghc" ( map fromString commandLineArguments ) empty )

    _ ->
      main2


main2 :: IO ()
main2 = runGhc ( Just libdir ) do
  files <-
    interpretCommandLine

  commandLineArguments <-
    liftIO getArgs

  if ".c" `elem` map takeExtension files || ".o" `elem` map takeExtension files || ".dyn_o" `elem` map takeExtension files
    then void ( Turtle.proc "ghc" ( map fromString commandLineArguments ) empty )
    else main3 ( filter ( `notElem` [ "--make" ] ) files )


main3 :: [ FilePath ] -> Ghc ()
main3 files = do
  hsBuilder <-
    liftIO ( getDataFileName "compile-hs.nix" )

  targets <-
    traverse ( \filePath -> guessTarget filePath Nothing ) files

  setTargets targets

  moduleGraph <-
    depanal [] True

  let
    modSummaryMap = Map.fromList do
      ms@ModSummary{ ms_location = ModLocation{ ml_hs_file = Just srcFile } } <-
        mgModSummaries moduleGraph

      return ( srcFile, ms )

  hsc_env <-
    getSession

  targets <-
    getTargets

  let
    stronglyConnectedComponents =
      topSortModuleGraph False moduleGraph Nothing

  dependencyGraph <-
    fmap ( Map.unionsWith mappend ) do
      for stronglyConnectedComponents \case
        AcyclicSCC ms@ModSummary{ ms_location = ModLocation{ ml_hs_file = Just srcFile }, ms_srcimps } -> do
          dependencies <-
            for ( ms_imps ms ) \( package, L _ moduleName ) -> liftIO do
              findImportedModule hsc_env moduleName package >>= \case
                Found ModLocation{ ml_hs_file = Just hsFile } _ ->
                  return [ hsFile ]

                _ ->
                  return []

          return ( Map.singleton srcFile ( concat dependencies ) )

  outputs <- liftIO do
    buildResults <-
      for dependencyGraph \_ -> ( newEmptyMVar :: IO ( MVar Data.Text.Text )  )

    forConcurrently_ ( Map.toList dependencyGraph ) \( srcFile, sourceDependencies ) -> do
      dependencies <-
        transitiveDependencies dependencyGraph buildResults srcFile

      Just ( Turtle.lineToText -> drv ) <-
        Turtle.fold
          ( Turtle.inproc
              "nix-instantiate"
              [ fromString hsBuilder
              , "--arg", "hs-path", fromString srcFile
              , "--arg", "dependencies", "[" <> Data.Text.intercalate " " ( Set.toList dependencies ) <> "]"
              , "--argstr", "moduleName", fromString ( moduleNameString ( moduleName ( ms_mod ( modSummaryMap Map.! srcFile ) ) ) )
              , "--no-build-output"
              , "--quiet"
              ]
              empty
          )
          Control.Foldl.head

      buildResult <- tryAny do
        Just ( Turtle.lineToText -> out ) <-
          Turtle.fold
            ( Turtle.inproc
                "nix-store"
                [ "-r", drv
                ]
                empty
            )
            Control.Foldl.head

        return out

      case buildResult of
        Left _ -> do
          putStrLn ( "Build for " ++ srcFile ++ " failed:" )

          Turtle.proc "nix" [ "log", drv ] empty

          fail "TODO"

        Right out -> do
          Just ( Turtle.lineToText -> contentAddressableJSON ) <-
            Turtle.fold
              ( Turtle.inproc
                  "nix"
                  [ "make-content-addressable"
                  , "--json"
                  , out
                  ]
                  empty
              )
              Control.Foldl.head

          contentAddressableBuildResult <-
            case JSON.decodeStrict ( Data.Text.Encoding.encodeUtf8 contentAddressableJSON ) of
              Just ( JSON.Object keys ) ->
                case HashMap.lookup "rewrites" keys of
                  Just ( JSON.Object keys ) ->
                    case HashMap.lookup out keys of
                      Just ( JSON.String path ) ->
                        return path

                      _ -> do
                        print contentAddressableJSON
                        fail "Could not find path in CA result"

              _ ->
                fail "Unexpected JSON structure"

          putMVar
            ( buildResults Map.! srcFile )
            contentAddressableBuildResult


    traverse readMVar buildResults

  DynFlags{ objectDir, hiDir } <-
    getSessionDynFlags

  for_ objectDir \dir ->
    Turtle.proc
      "rsync"
      ( concat
          [ [ "--recursive"
            , "--include=*/"
            , "--include=*.o"
            , "--include=*.dyn_o"
            , "--exclude=*"
            , "--chmod=u+w"
            ]
          , foldMap ( \output -> [ output <> "/" ] ) outputs
          , [ fromString dir ]
          ]
      )
      empty

  for_ hiDir \dir ->
    Turtle.proc
      "rsync"
      ( concat
          [ [ "--recursive"
            , "--include=*/"
            , "--include=*.hi"
            , "--include=*.dyn_hi"
            , "--exclude=*"
            , "--chmod=u+w"
            ]
          , foldMap ( \output -> [ output <> "/" ] ) outputs
          , [ fromString dir ]
          ]
      )
      empty

transitiveDependencies dependencyGraph buildResults srcFile = do
  let
    sourceDependencies =
      fold ( Map.lookup srcFile dependencyGraph )

  immediateDependencies <-
    fmap concat do
      for sourceDependencies \dep ->
        case Map.lookup dep buildResults of
          Nothing ->
            return []

          Just mvar ->
            return <$> readMVar mvar

  Set.union ( Set.fromList immediateDependencies ) . Set.unions
    <$> traverse
          ( transitiveDependencies dependencyGraph buildResults )
          sourceDependencies


interpretCommandLine :: Ghc [ FilePath ]
interpretCommandLine = do
  commandLineArguments <-
    fmap ( filter ( `notElem` [ "-c" ] ) ) ( liftIO getArgs )

  ( dynFlags, files ) <- do
    initialDynFlags <-
      getSessionDynFlags

    ( newDynFlags, leftOver, _ ) <-
      parseDynamicFlagsCmdLine initialDynFlags ( map noLoc commandLineArguments )

    return ( newDynFlags, leftOver )

  setSessionDynFlags dynFlags

  return ( map unLoc files )
