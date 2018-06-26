{-# LANGUAGE QuasiQuotes #-}
module Cachix.Client.InstallationMode
  ( InstallationMode(..)
  , NixEnv(..)
  , CachixException(..)
  , getInstallationMode
  , addBinaryCache
  , isTrustedUser
  , getUser
  ) where

import           Protolude
import           Data.String.Here
import qualified Data.Text as T
import qualified Cachix.Client.NixConf as NixConf
import           Cachix.Client.NixVersion ( NixMode(..) )
import           Cachix.Api as Api
import           System.Directory               ( getPermissions, writable )
import           System.Environment             ( lookupEnv )

data CachixException
  = UnsupportedNixVersion Text
  | UserEnvNotSet Text
  | MustBeRoot Text
  | NixOSInstructions Text
  | AmbiguousInput Text
  | NoInput Text
  | NoConfig Text
  deriving (Show, Typeable)

instance Exception CachixException

data NixEnv = NixEnv
  { nixMode :: NixMode
  , isTrusted :: Bool
  , isRoot :: Bool
  , isNixOS :: Bool
  }

data InstallationMode
  = Install NixConf.NixConfLoc
  | UnsupportedNix1X
  | EchoNixOS
  | EchoNixOSWithTrustedUser
  | UntrustedRequiresSudo
  | Nix20RequiresSudo
  deriving (Show, Eq)

getInstallationMode :: NixEnv -> InstallationMode
getInstallationMode NixEnv{..}
  | nixMode == Nix1XX = UnsupportedNix1X
  | isNixOS && isRoot = EchoNixOS
  | isNixOS && (not isTrusted) = EchoNixOSWithTrustedUser
  | (not isNixOS) && isRoot = Install NixConf.Global
  | nixMode == Nix20 = Nix20RequiresSudo
  | isTrusted = Install NixConf.Local
  | not isTrusted = UntrustedRequiresSudo


-- | Add a Binary cache to nix.conf, print nixos config or fail
addBinaryCache :: Api.BinaryCache -> InstallationMode -> IO ()
addBinaryCache _ UnsupportedNix1X = throwIO $
  UnsupportedNixVersion "Nix 1.x is not supported, please upgrade to Nix 2.0.1 or greater"
addBinaryCache Api.BinaryCache{..} EchoNixOS = do
  putText [iTrim|
nix = {
  binaryCaches = [
    "${uri}"
  ];
  binaryCachePublicKeys = [
    ${T.intercalate " " (map (\s -> "\"" <> s <> "\"") publicSigningKeys)}
  ];
};
  |]
  throwIO $ NixOSInstructions "Add above lines to your NixOS configuration file"
addBinaryCache Api.BinaryCache{..} EchoNixOSWithTrustedUser = do
  -- TODO: DRY
  user <- getUser
  putText [iTrim|
nix = {
  binaryCaches = [
    "${uri}"
  ];
  binaryCachePublicKeys = [
    ${T.intercalate " " (map (\s -> "\"" <> s <> "\"") publicSigningKeys)}
  ];
  trustedUsers = [ "root" "${user}" ];
};
  |]
  throwIO $ NixOSInstructions "Add above lines to your NixOS configuration file"
addBinaryCache _ UntrustedRequiresSudo = throwIO $
  MustBeRoot "Run command as root OR execute: $ echo \"trusted-users = root $USER\" | sudo tee -a /etc/nix/nix.conf && sudo pkill nix-daemon"
addBinaryCache _ Nix20RequiresSudo = throwIO $
  MustBeRoot "Run command as root OR upgrade to latest Nix - to be able to use it without root (recommended)"
addBinaryCache bc@Api.BinaryCache{..} (Install ncl) = do
  -- TODO: might need locking one day
  gnc <- NixConf.read NixConf.Global
  lnc <- NixConf.read NixConf.Local
  let final = if ncl == NixConf.Global then gnc else lnc
      input = if ncl == NixConf.Global then [gnc] else [gnc, lnc]
  NixConf.write ncl $ NixConf.add bc (catMaybes input) (fromMaybe (NixConf.NixConf []) final)
  filename <- NixConf.getFilename ncl
  putStrLn $ "Configured " <> uri <> " binary cache in " <> toS filename

isTrustedUser :: [Text] -> IO Bool
isTrustedUser users = do
  user <- getUser
  -- to detect single user installations
  permissions <- getPermissions "/nix/store"
  unless (groups == []) $ do
    -- TODO: support Nix group syntax
    putText "Warn: cachix doesn't yet support checking if user is trusted via groups, so it will recommend sudo"
    putStrLn $ "Warn: groups found " <> T.intercalate "," groups
  return $ (writable permissions) || (user `elem` users)
  where
    groups = filter (\u -> T.head u == '@') users

getUser :: IO Text
getUser = do
  maybeUser <- lookupEnv "USER"
  case maybeUser of
    Nothing -> throwIO $ UserEnvNotSet "$USER must be set"
    Just user -> return $ toS user