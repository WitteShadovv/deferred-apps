# Compatibility shim for non-flake usage
#
# This allows importing deferred-apps in traditional Nix setups:
#
#   let
#     deferred-apps = import (fetchTarball {
#       url = "https://github.com/WitteShadovv/deferred-apps/archive/v0.1.0.tar.gz";
#       sha256 = "...";
#     });
#   in
#   # Use as NixOS module:
#   imports = [ deferred-apps.nixosModules.default ];
#
#   # Or as Home Manager module:
#   imports = [ deferred-apps.homeManagerModules.default ];
#
#   # Or use the library directly:
#   deferred-apps.lib.${system}.mkDeferredApp { pname = "spotify"; }
#
(import (
  let
    lock = builtins.fromJSON (builtins.readFile ./flake.lock);
    nodeName = lock.nodes.root.inputs.nixpkgs;
    nixpkgsLock = lock.nodes.${nodeName}.locked;
    urlBase =
      if nixpkgsLock.type == "github" then
        "https://github.com/${nixpkgsLock.owner}/${nixpkgsLock.repo}"
      else
        throw "Unsupported nixpkgs input type: ${nixpkgsLock.type}";
  in
  fetchTarball {
    url = "${urlBase}/archive/${nixpkgsLock.rev}.tar.gz";
    sha256 = nixpkgsLock.narHash;
  }
) { }).callPackage
  (
    { pkgs, lib }:
    let
      # Import the library
      deferredAppsLib = import ./package.nix { inherit pkgs lib; };

      # Define overlays without recursion
      overlayImpl = final: _prev: {
        deferredApps = import ./package.nix {
          pkgs = final;
          inherit (final) lib;
        };
      };
    in
    {
      # Expose the same interface as the flake
      nixosModules = {
        deferredApps = ./modules/nixos.nix;
        default = ./modules/nixos.nix;
      };

      homeManagerModules = {
        deferredApps = ./modules/home-manager.nix;
        default = ./modules/home-manager.nix;
      };

      overlays = {
        deferredApps = overlayImpl;
        default = overlayImpl;
      };

      # Library functions for direct use
      lib = {
        ${pkgs.system} = deferredAppsLib;
      };

      # Re-export the raw library for convenience
      inherit (deferredAppsLib) mkDeferredApp mkDeferredApps mkDeferredAppsFrom;
    }
  )
  { }
