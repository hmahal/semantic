{-# LANGUAGE ConstraintKinds, GADTs, GeneralizedNewtypeDeriving, KindSignatures, LambdaCase, ScopedTypeVariables, TypeOperators, UndecidableInstances #-}
module Semantic.Resolution
  ( Resolution (..)
  , nodeJSResolutionMap
  , resolutionMap
  , runResolution
  , ResolutionC(..)
  ) where

import           Control.Effect
import           Control.Effect.Carrier
import           Control.Effect.Sum
import           Data.Aeson
import           Data.Aeson.Types (parseMaybe)
import           Data.Blob
import           Data.Coerce
import           Data.File
import           Data.Project
import qualified Data.Map as Map
import           Data.Source
import           Data.Language
import           Prologue
import           Semantic.Task.Files
import           System.FilePath.Posix


nodeJSResolutionMap :: (Member Files sig, Carrier sig m) => FilePath -> Text -> [FilePath] -> m (Map FilePath FilePath)
nodeJSResolutionMap rootDir prop excludeDirs = do
  files <- findFiles rootDir [".json"] excludeDirs
  let packageFiles = file <$> filter ((==) "package.json" . takeFileName) files
  blobs <- readBlobs (Right packageFiles)
  pure $ fold (mapMaybe (lookup prop) blobs)
  where
    lookup :: Text -> Blob -> Maybe (Map FilePath FilePath)
    lookup k Blob{..} = decodeStrict (sourceBytes blobSource) >>= lookupProp blobPath k

    lookupProp :: FilePath -> Text -> Object -> Maybe (Map FilePath FilePath)
    lookupProp path k res = flip parseMaybe res $ \obj -> Map.singleton relPkgDotJSONPath . relEntryPath <$> obj .: k
      where relPkgDotJSONPath = makeRelative rootDir path
            relEntryPath x = takeDirectory relPkgDotJSONPath </> x

resolutionMap :: (Member Resolution sig, Carrier sig m) => Project -> m (Map FilePath FilePath)
resolutionMap Project{..} = case projectLanguage of
  TypeScript -> send (NodeJSResolution projectRootDir "types" projectExcludeDirs pure)
  JavaScript -> send (NodeJSResolution projectRootDir "main"  projectExcludeDirs pure)
  _          -> send (NoResolution pure)

data Resolution (m :: * -> *) k
  = NodeJSResolution FilePath Text [FilePath] (Map FilePath FilePath -> k)
  | NoResolution                              (Map FilePath FilePath -> k)
  deriving (Functor)

instance HFunctor Resolution where
  hmap _ = coerce

instance Effect Resolution where
  handle state handler (NodeJSResolution path key paths k) = NodeJSResolution path key paths (handler . (<$ state) . k)
  handle state handler (NoResolution k) = NoResolution (handler . (<$ state) . k)

runResolution :: ResolutionC m a -> m a
runResolution = runResolutionC

newtype ResolutionC m a = ResolutionC { runResolutionC :: m a }
  deriving (Applicative, Functor, Monad, MonadIO)

instance (Member Files sig, Carrier sig m) => Carrier (Resolution :+: sig) (ResolutionC m) where
  eff (R other) = ResolutionC . eff . handleCoercible $ other
  eff (L op) = case op of
    NodeJSResolution dir prop excludeDirs k -> nodeJSResolutionMap dir prop excludeDirs >>= k
    NoResolution                          k -> k Map.empty
