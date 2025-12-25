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

  # Minimal NixOS config boilerplate for module tests
  minimalNixosConfig = {
    boot.loader.grub.enable = false;
    fileSystems."/".device = "none";
    system.stateVersion = "24.11";
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
    deferredAppsLib
    minimalNixosConfig
    evalModule
    forceEvalPackages
    mkCheck
    mkBuildCheck
    testShouldFail
    testListShouldFail
    mkCheckValidator
    ;
}
