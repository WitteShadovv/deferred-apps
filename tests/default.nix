# Deferred Apps - Comprehensive Test Suite
#
# This is the main entry point that combines all test modules.
# Tests are organized into logical categories for maintainability.
#
# Run with: nix flake check
#
# Test Categories:
#   internal     - Internal function tests (capitalize, isPackageUnfree)
#   library      - mkDeferredApp parameter tests (pname mode)
#   package-mode - mkDeferredApp with direct package references
#   batch        - mkDeferredApps, mkDeferredAppsFrom, mkDeferredAppsAdvanced
#   collision    - Terminal command collision detection
#   module       - NixOS module integration tests
#   home-manager - Home Manager module integration tests
#   nested       - Nested package support (python313Packages.numpy, etc.)
#   error        - Error case validation
#   compat       - default.nix compatibility tests (structure only, see limitations)
#
# =============================================================================
# TESTING LIMITATIONS
# =============================================================================
#
# The following behaviors are NOT tested by `nix flake check` and require
# manual testing or NixOS VM tests:
#
# 1. WRAPPER SCRIPT RUNTIME BEHAVIOR
#    - maybe_notify() notification display
#    - ensure_downloaded() GC root creation
#    - Actual `nix shell` invocation
#    - Error handling during download
#    Test manually: Run a deferred app and observe behavior
#
# 2. PATHS_TO_LINK INTEGRATION
#    The NixOS module sets pathsToLink = [ "/share/applications" "/share/icons" ]
#    to ensure desktop files and icons are linked into the system profile.
#    This cannot be verified without a full NixOS system build.
#    Test with: Build a NixOS VM with the module and check /run/current-system/sw/
#
# 3. DEFAULT.NIX IMPURE EVALUATION
#    default.nix uses builtins.currentSystem which requires --impure mode.
#    See tests/compat.nix for available structure tests.
#    Test manually: nix eval --impure --expr '(import ./default.nix).lib.mkDeferredApp {pname="hello";}'
#
# 4. UNFREE PACKAGE BEHAVIOR
#    Testing actual unfree packages would require NIXPKGS_ALLOW_UNFREE=1
#    We test the detection logic, but not the actual --impure invocation.
#
# 5. HOME MANAGER ACTIVATION
#    The Home Manager module tests verify package generation but not
#    actual home activation (which requires a full home-manager setup).
#    Test manually: Use the module in a real Home Manager configuration.
#
#
{
  pkgs,
  lib,
  self,
  system,
}:

let
  # Import shared test helpers
  helpers = import ./lib.nix {
    inherit
      pkgs
      lib
      self
      system
      ;
  };

  # Import all test modules
  internalTests = import ./internal.nix { inherit helpers; };
  libraryTests = import ./library.nix { inherit helpers; };
  packageModeTests = import ./package-mode.nix { inherit pkgs lib helpers; };
  batchTests = import ./batch.nix { inherit pkgs helpers; };
  collisionTests = import ./collision.nix { inherit lib helpers; };
  moduleTests = import ./module.nix { inherit pkgs lib helpers; };
  homeManagerTests = import ./home-manager.nix { inherit pkgs lib helpers; };
  nestedTests = import ./nested.nix { inherit pkgs lib helpers; };
  errorTests = import ./error.nix { inherit helpers; };
  compatTests = import ./compat.nix { inherit pkgs; };

in
# Meta test for infrastructure validation
{
  meta-test-infrastructure = helpers.mkCheckValidator "test-infrastructure";
}
# Combine all test modules
// internalTests
// libraryTests
// packageModeTests
// batchTests
// collisionTests
// moduleTests
// homeManagerTests
// nestedTests
// errorTests
// compatTests
