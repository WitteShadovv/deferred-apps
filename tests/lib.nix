# Shared test helpers for deferred-apps test suite
#
# This module provides common utilities used across all test files.
#
{
  pkgs,
  lib,
  self,
  system,
}:

let
  # Import the library for direct testing
  deferredAppsLib = import ../package.nix { inherit pkgs lib; };

  # ===========================================================================
  # NixOS Module Testing
  # ===========================================================================

  # Minimal NixOS config boilerplate for module tests
  minimalNixosConfig = {
    boot.loader.grub.enable = false;
    fileSystems."/".device = "none";
    system.stateVersion = "25.11";
  };

  # Helper to create a NixOS evaluation with deferred-apps
  evalModule =
    config:
    lib.nixosSystem {
      inherit system;
      modules = [
        self.nixosModules.default
        minimalNixosConfig
        config
      ];
    };

  # Helper to force evaluation of systemPackages (catches eval-time errors)
  # We use seq with length to force the list structure, and then map to force
  # the .name attribute of each package (which triggers most eval-time errors)
  # We can't use deepSeq because packages have circular references
  forceEvalPackages =
    eval:
    let
      pkgList = eval.config.environment.systemPackages;
      # Force the list by getting its length
      forcedLength = builtins.length pkgList;
      # Force each package's name attribute (this triggers most validation)
      forcedNames = map (pkg: pkg.name or "unnamed") pkgList;
    in
    builtins.seq forcedLength (builtins.seq (builtins.length forcedNames) true);

  # ===========================================================================
  # Home Manager Module Testing
  # ===========================================================================

  # Minimal Home Manager config boilerplate for module tests
  minimalHomeConfig = {
    home = {
      username = "testuser";
      homeDirectory = "/home/testuser";
      stateVersion = "25.11";
    };
  };

  # Helper to create a Home Manager evaluation with deferred-apps
  # Note: This creates a standalone evaluation without the full home-manager
  # infrastructure. It's sufficient for testing option evaluation and package
  # generation, but not for testing actual home activation.
  evalHomeModule =
    config:
    lib.evalModules {
      modules = [
        self.homeManagerModules.default
        minimalHomeConfig
        config
        # Provide required Home Manager infrastructure stubs
        (
          { lib, ... }:
          {
            options = {
              home = {
                packages = lib.mkOption {
                  type = lib.types.listOf lib.types.package;
                  default = [ ];
                };
                sessionVariables = lib.mkOption {
                  type = lib.types.attrsOf lib.types.str;
                  default = { };
                };
                username = lib.mkOption { type = lib.types.str; };
                homeDirectory = lib.mkOption { type = lib.types.str; };
                stateVersion = lib.mkOption { type = lib.types.str; };
              };
            };
          }
        )
      ];
      specialArgs = { inherit pkgs lib; };
    };

  # Helper to force evaluation of home.packages (catches eval-time errors)
  forceEvalHomePackages =
    eval:
    let
      pkgList = eval.config.home.packages;
      forcedLength = builtins.length pkgList;
      forcedNames = map (pkg: pkg.name or "unnamed") pkgList;
    in
    builtins.seq forcedLength (builtins.seq (builtins.length forcedNames) true);

  # ===========================================================================
  # Generic Test Helpers
  # ===========================================================================

  # Helper to create a simple check derivation
  mkCheck =
    name: assertion:
    assert assertion;
    pkgs.runCommand "check-${name}" { } ''
      echo "Check passed: ${name}"
      touch $out
    '';

  # Helper to verify a derivation builds and has expected structure
  mkBuildCheck =
    name: drv: checks:
    pkgs.runCommand "check-${name}"
      {
        buildInputs = [ drv ];
        drvPath = drv;
      }
      ''
        echo "Checking: ${name}"
        ${checks}
        echo "All checks passed!"
        touch $out
      '';

  # Helper to test that an expression fails when evaluated
  # This forces drvPath evaluation which triggers most validation errors
  testShouldFail =
    name: expr:
    let
      # Force drvPath specifically - this triggers requirePackage and assertions
      forced = builtins.tryEval (builtins.deepSeq expr.drvPath expr.drvPath);
    in
    mkCheck name (!forced.success);

  # Helper to test that a LIST-producing expression fails
  # For functions like mkDeferredApps that return lists
  testListShouldFail =
    name: expr:
    let
      # Force evaluation of the list and all derivation paths within
      forcedList = builtins.tryEval (
        builtins.deepSeq (map (d: d.drvPath) expr) (map (d: d.drvPath) expr)
      );
    in
    mkCheck name (!forcedList.success);

  # Helper to verify mkCheck itself works (meta-test)
  # This validates that our test infrastructure is sound using tryEval
  # to verify both that true passes and false fails at evaluation time
  mkCheckValidator =
    name:
    let
      # Test that true assertion succeeds
      trueResult = builtins.tryEval (mkCheck "validator-true" true);
      # Test that false assertion fails (the assert should throw)
      falseResult = builtins.tryEval (mkCheck "validator-false" false);
      # Infrastructure is valid if true succeeds AND false fails
      infrastructureValid = trueResult.success && !falseResult.success;
    in
    mkCheck name infrastructureValid;

in
{
  inherit
    # Library
    deferredAppsLib
    # NixOS helpers
    minimalNixosConfig
    evalModule
    forceEvalPackages
    # Home Manager helpers
    minimalHomeConfig
    evalHomeModule
    forceEvalHomePackages
    # Generic helpers
    mkCheck
    mkBuildCheck
    testShouldFail
    testListShouldFail
    mkCheckValidator
    ;
}
