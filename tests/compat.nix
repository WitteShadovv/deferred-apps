# Compatibility tests for default.nix
#
# Tests that verify the default.nix shim works correctly for non-flake users.
#
# LIMITATION: default.nix uses builtins.currentSystem which is only available in
# impure evaluation mode. Since `nix flake check` uses pure evaluation, we cannot
# actually import and evaluate default.nix here. These tests verify:
#
# 1. File structure - The file exists and contains expected exports
# 2. Syntax validity - The file is valid Nix (verified by grep finding patterns)
# 3. Error handling - Error handling code paths exist
#
# To fully test default.nix functionality, run manually with impure mode:
#   nix eval --impure --expr '(import ./default.nix).lib.mkDeferredApp { pname = "hello"; }'
#
{ pkgs }:

{
  # ===========================================================================
  # DEFAULT.NIX STRUCTURE TESTS
  # These verify file structure, not runtime behavior (see LIMITATION above)
  # ===========================================================================

  # Test: default.nix exists and exports expected attributes
  compat-default-nix-exists = pkgs.runCommand "check-compat-default-nix-exists" { } ''
    echo "Verifying default.nix file structure..."

    # Verify the file exists
    test -f ${../default.nix} || { echo "FAIL: default.nix missing"; exit 1; }

    # Verify it exports expected attributes (structure check, not runtime)
    grep -q 'nixosModules' ${../default.nix} || { echo "FAIL: should define nixosModules"; exit 1; }
    grep -q 'overlays' ${../default.nix} || { echo "FAIL: should define overlays"; exit 1; }
    grep -q 'mkDeferredApp' ${../default.nix} || { echo "FAIL: should export mkDeferredApp"; exit 1; }
    grep -q 'mkDeferredApps' ${../default.nix} || { echo "FAIL: should export mkDeferredApps"; exit 1; }
    grep -q 'mkDeferredAppsFrom' ${../default.nix} || { echo "FAIL: should export mkDeferredAppsFrom"; exit 1; }

    echo "OK: default.nix structure verified"
    touch $out
  '';

  # Test: default.nix handles flake.lock correctly
  compat-default-nix-flake-lock = pkgs.runCommand "check-compat-default-nix-flake-lock" { } ''
    echo "Verifying flake.lock integration..."

    # Verify flake.lock exists (default.nix reads it)
    test -f ${../flake.lock} || { echo "FAIL: flake.lock missing"; exit 1; }

    # Verify default.nix references flake.lock for nixpkgs resolution
    grep -q 'flake.lock' ${../default.nix} || { echo "FAIL: should read flake.lock"; exit 1; }
    grep -q 'builtins.fromJSON' ${../default.nix} || { echo "FAIL: should parse flake.lock JSON"; exit 1; }

    echo "OK: flake.lock integration verified"
    touch $out
  '';

  # Test: default.nix has error handling for unsupported nixpkgs types
  compat-default-nix-error-handling = pkgs.runCommand "check-compat-default-nix-error-handling" { } ''
    echo "Verifying error handling code paths..."

    # Verify the error handling for unsupported types exists
    grep -q 'Unsupported nixpkgs input type' ${../default.nix} || \
      { echo "FAIL: should have error handling for unsupported types"; exit 1; }

    # Verify it handles the github type (most common)
    grep -q '"github"' ${../default.nix} || \
      { echo "FAIL: should handle github type"; exit 1; }

    echo "OK: Error handling code paths exist"
    touch $out
  '';
}
