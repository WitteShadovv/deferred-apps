# Batch function tests
#
# Tests for mkDeferredApps, mkDeferredAppsFrom, and mkDeferredAppsAdvanced.
# These functions create multiple deferred apps at once.
#
{ pkgs, helpers }:

let
  inherit (helpers) deferredAppsLib;
in
{
  # ===========================================================================
  # MK_DEFERRED_APPS TESTS
  # ===========================================================================

  # Test: Multiple apps via mkDeferredApps
  lib-mkDeferredApps = pkgs.symlinkJoin {
    name = "check-mkDeferredApps";
    paths = deferredAppsLib.mkDeferredApps [
      "hello"
      "cowsay"
      "tree"
    ];
    postBuild = ''
      # Verify all apps are present
      test -L "$out/bin/hello" || { echo "FAIL: hello missing"; exit 1; }
      test -L "$out/bin/cowsay" || { echo "FAIL: cowsay missing"; exit 1; }
      test -L "$out/bin/tree" || { echo "FAIL: tree missing"; exit 1; }
      echo "All apps present"
    '';
  };

  # ===========================================================================
  # MK_DEFERRED_APPS_FROM TESTS
  # ===========================================================================

  # Test: mkDeferredAppsFrom with custom flakeRef
  lib-mkDeferredAppsFrom = pkgs.symlinkJoin {
    name = "check-mkDeferredAppsFrom";
    paths = deferredAppsLib.mkDeferredAppsFrom "github:NixOS/nixpkgs/nixos-24.11" [
      "hello"
      "cowsay"
    ];
    postBuild = ''
      grep -q 'FLAKE_REF="github:NixOS/nixpkgs/nixos-24.11"' "$out/libexec/deferred-hello" || \
        { echo "FAIL: custom flakeRef not applied"; exit 1; }
    '';
  };

  # ===========================================================================
  # MK_DEFERRED_APPS_ADVANCED TESTS
  # ===========================================================================

  # Test: mkDeferredAppsAdvanced with mixed configs
  lib-mkDeferredAppsAdvanced = pkgs.symlinkJoin {
    name = "check-mkDeferredAppsAdvanced";
    paths = deferredAppsLib.mkDeferredAppsAdvanced [
      { pname = "hello"; }
      {
        pname = "cowsay";
        createTerminalCommand = false;
      }
      {
        pname = "tree";
        exe = "custom-tree";
      }
    ];
    postBuild = ''
      # hello should have terminal command
      test -L "$out/bin/hello" || { echo "FAIL: hello should have terminal"; exit 1; }

      # cowsay should NOT have terminal command
      test ! -L "$out/bin/cowsay" || { echo "FAIL: cowsay should not have terminal"; exit 1; }

      # tree should have custom terminal command
      test -L "$out/bin/custom-tree" || { echo "FAIL: tree should have custom terminal 'custom-tree'"; exit 1; }
    '';
  };
}
