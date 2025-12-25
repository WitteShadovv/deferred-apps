# Nested package tests
#
# Tests for dot-notation support (e.g., python313Packages.numpy).
# Includes basic functionality, validation, and batch function integration.
#
{
  pkgs,
  lib,
  helpers,
}:

let
  inherit (helpers)
    deferredAppsLib
    mkBuildCheck
    mkCheck
    testShouldFail
    ;
in
{
  # ===========================================================================
  # BASIC NESTED PACKAGE FUNCTIONALITY
  # ===========================================================================

  # Test: Basic nested package creates deferred app correctly
  nested-basic =
    mkBuildCheck "nested-basic" (deferredAppsLib.mkDeferredApp { pname = "python313Packages.numpy"; })
      ''
        # Wrapper script exists in libexec
        test -x "$drvPath/libexec/deferred-python313Packages.numpy" || { echo "FAIL: wrapper not executable"; exit 1; }

        # Desktop file exists
        test -f "$drvPath/share/applications/python313Packages.numpy.desktop" || { echo "FAIL: desktop file missing"; exit 1; }

        # Terminal command symlink exists
        test -d "$drvPath/bin" || { echo "FAIL: bin directory missing"; exit 1; }
      '';

  # Test: Nested package with mainProgram detection
  nested-mainProgram-detection =
    mkBuildCheck "nested-mainProgram-detection"
      (deferredAppsLib.mkDeferredApp { pname = "python313Packages.numpy"; })
      ''
        # The wrapper should contain the package name in PNAME
        grep -q 'PNAME="python313Packages.numpy"' "$drvPath/libexec/deferred-python313Packages.numpy" || \
          { echo "FAIL: PNAME should be 'python313Packages.numpy'"; exit 1; }

        # The flake reference should be correct
        grep -q 'FLAKE_REF="nixpkgs"' "$drvPath/libexec/deferred-python313Packages.numpy" || \
          { echo "FAIL: default flakeRef should be 'nixpkgs'"; exit 1; }
      '';

  # Test: Deeply nested package (2 levels)
  nested-deep =
    mkBuildCheck "nested-deep" (deferredAppsLib.mkDeferredApp { pname = "haskellPackages.pandoc"; })
      ''
        # Wrapper should exist with the full nested name
        test -x "$drvPath/libexec/deferred-haskellPackages.pandoc" || { echo "FAIL: wrapper not executable"; exit 1; }

        # PNAME should be the full path
        grep -q 'PNAME="haskellPackages.pandoc"' "$drvPath/libexec/deferred-haskellPackages.pandoc" || \
          { echo "FAIL: PNAME should be 'haskellPackages.pandoc'"; exit 1; }
      '';

  # ===========================================================================
  # DESKTOP NAME AND DESCRIPTION TESTS
  # ===========================================================================

  # Test: Nested package desktop name auto-generation
  # Note: toDisplayName only splits on '-', not '.', so the full pname is capitalized
  # "python313Packages.numpy" -> "Python313Packages.numpy" (only first char capitalized)
  nested-desktopName-auto =
    mkBuildCheck "nested-desktopName-auto"
      (deferredAppsLib.mkDeferredApp { pname = "python313Packages.numpy"; })
      ''
        name=$(grep '^Name=' "$drvPath/share/applications/python313Packages.numpy.desktop" | cut -d= -f2)

        # toDisplayName splits on '-' only, so "python313Packages.numpy" becomes
        # "Python313Packages.numpy" (capitalize first letter of each dash-segment)
        test "$name" = "Python313Packages.numpy" || \
          { echo "FAIL: Expected 'Python313Packages.numpy', got: $name"; exit 1; }

        echo "OK: Desktop name correctly generated as '$name'"
      '';

  # Test: Nested package with custom desktopName
  nested-desktopName-custom =
    mkBuildCheck "nested-desktopName-custom"
      (deferredAppsLib.mkDeferredApp {
        pname = "python313Packages.numpy";
        desktopName = "NumPy Calculator";
      })
      ''
        grep -q 'Name=NumPy Calculator' "$drvPath/share/applications/python313Packages.numpy.desktop" || \
          { echo "FAIL: custom desktop name not used"; exit 1; }
      '';

  # Test: Nested package description auto-detection
  nested-description-auto =
    mkBuildCheck "nested-description-auto"
      (deferredAppsLib.mkDeferredApp { pname = "python313Packages.numpy"; })
      ''
        comment=$(grep '^Comment=' "$drvPath/share/applications/python313Packages.numpy.desktop" | cut -d= -f2-)
        test -n "$comment" || { echo "FAIL: Comment should not be empty"; exit 1; }

        # Should not be the fallback "Application"
        if [ "$comment" = "Application" ]; then
          echo "FAIL: Should use actual description from package meta, not fallback"
          exit 1
        fi

        echo "Description: $comment"
      '';

  # ===========================================================================
  # NESTED PACKAGE WITH ALL OPTIONS
  # ===========================================================================

  # Test: Nested package with custom exe
  nested-exe-custom =
    mkBuildCheck "nested-exe-custom"
      (deferredAppsLib.mkDeferredApp {
        pname = "python313Packages.numpy";
        exe = "f2py";
      })
      ''
        # Terminal command should be custom exe (lowercased)
        test -L "$drvPath/bin/f2py" || { echo "FAIL: custom exe terminal command missing"; exit 1; }

        # Wrapper should use custom exe
        grep -q 'EXE="f2py"' "$drvPath/libexec/deferred-python313Packages.numpy" || \
          { echo "FAIL: wrapper should use custom exe"; exit 1; }
      '';

  # Test: Nested package with createTerminalCommand = false
  nested-terminal-false =
    mkBuildCheck "nested-terminal-false"
      (deferredAppsLib.mkDeferredApp {
        pname = "python313Packages.numpy";
        createTerminalCommand = false;
      })
      ''
        # bin/ directory should not exist
        test ! -d "$drvPath/bin" || { echo "FAIL: bin/ directory should not exist"; exit 1; }

        # But libexec wrapper should still exist
        test -x "$drvPath/libexec/deferred-python313Packages.numpy" || \
          { echo "FAIL: libexec wrapper should exist"; exit 1; }
      '';

  # Test: Nested package with custom flakeRef
  nested-flakeRef-custom =
    mkBuildCheck "nested-flakeRef-custom"
      (deferredAppsLib.mkDeferredApp {
        pname = "python313Packages.numpy";
        flakeRef = "github:NixOS/nixpkgs/nixos-24.11";
      })
      ''
        grep -q 'FLAKE_REF="github:NixOS/nixpkgs/nixos-24.11"' \
          "$drvPath/libexec/deferred-python313Packages.numpy" || \
          { echo "FAIL: custom flakeRef not used"; exit 1; }
      '';

  # Test: Nested package with gcRoot = true
  nested-gcRoot-true =
    mkBuildCheck "nested-gcRoot-true"
      (deferredAppsLib.mkDeferredApp {
        pname = "python313Packages.numpy";
        gcRoot = true;
      })
      ''
        grep -q 'GC_ROOT="1"' "$drvPath/libexec/deferred-python313Packages.numpy" || \
          { echo "FAIL: gcRoot should be '1'"; exit 1; }
      '';

  # ===========================================================================
  # NESTED PACKAGES IN BATCH FUNCTIONS
  # ===========================================================================

  # Test: mkDeferredApps with nested packages
  nested-mkDeferredApps = pkgs.symlinkJoin {
    name = "check-nested-mkDeferredApps";
    paths = deferredAppsLib.mkDeferredApps [
      "hello"
      "python313Packages.numpy"
      "haskellPackages.pandoc"
    ];
    postBuild = ''
      # Verify all apps are present
      test -d "$out/bin" || { echo "FAIL: bin directory missing"; exit 1; }

      # Verify libexec wrappers exist for all
      test -x "$out/libexec/deferred-hello" || { echo "FAIL: hello wrapper missing"; exit 1; }
      test -x "$out/libexec/deferred-python313Packages.numpy" || { echo "FAIL: numpy wrapper missing"; exit 1; }
      test -x "$out/libexec/deferred-haskellPackages.pandoc" || { echo "FAIL: pandoc wrapper missing"; exit 1; }

      echo "All nested apps present"
    '';
  };

  # Test: mkDeferredAppsFrom with nested packages
  nested-mkDeferredAppsFrom = pkgs.symlinkJoin {
    name = "check-nested-mkDeferredAppsFrom";
    paths = deferredAppsLib.mkDeferredAppsFrom "github:NixOS/nixpkgs/nixos-24.11" [
      "python313Packages.numpy"
    ];
    postBuild = ''
      grep -q 'FLAKE_REF="github:NixOS/nixpkgs/nixos-24.11"' \
        "$out/libexec/deferred-python313Packages.numpy" || \
        { echo "FAIL: custom flakeRef not applied to nested package"; exit 1; }
    '';
  };

  # Test: mkDeferredAppsAdvanced with nested packages
  nested-mkDeferredAppsAdvanced = pkgs.symlinkJoin {
    name = "check-nested-mkDeferredAppsAdvanced";
    paths = deferredAppsLib.mkDeferredAppsAdvanced [
      { pname = "python313Packages.numpy"; }
      {
        pname = "python313Packages.requests";
        createTerminalCommand = false;
      }
    ];
    postBuild = ''
      # numpy should have terminal command
      test -d "$out/bin" || { echo "FAIL: bin directory should exist"; exit 1; }

      # requests should NOT have terminal command (but desktop file should exist)
      test -f "$out/share/applications/python313Packages.requests.desktop" || \
        { echo "FAIL: requests desktop file missing"; exit 1; }
    '';
  };

  # ===========================================================================
  # COLLISION DETECTION WITH NESTED PACKAGES
  # ===========================================================================

  # Test: No collision between nested and top-level with different names
  collision-nested-none =
    let
      result = deferredAppsLib.detectTerminalCollisions [
        { pname = "hello"; }
        { pname = "python313Packages.numpy"; }
      ];
    in
    mkCheck "collision-nested-none" (result == null);

  # Test: Collision when nested package exe matches top-level
  collision-nested-detected =
    let
      result = deferredAppsLib.detectTerminalCollisions [
        {
          pname = "hello";
          exe = "conflict";
        }
        {
          pname = "python313Packages.numpy";
          exe = "conflict";
        }
      ];
    in
    mkCheck "collision-nested-detected" (result != null && lib.hasInfix "conflict" result);

  # Test: No collision when one nested package has createTerminalCommand = false
  collision-nested-disabled =
    let
      result = deferredAppsLib.detectTerminalCollisions [
        {
          pname = "app1";
          exe = "same";
        }
        {
          pname = "python313Packages.numpy";
          exe = "same";
          createTerminalCommand = false;
        }
      ];
    in
    mkCheck "collision-nested-disabled" (result == null);

  # ===========================================================================
  # EDGE CASES AND REAL-WORLD PACKAGES
  # ===========================================================================

  # Test: Single-segment pname still works (regression test)
  nested-single-segment =
    mkBuildCheck "nested-single-segment" (deferredAppsLib.mkDeferredApp { pname = "hello"; })
      ''
        # Should work exactly as before
        test -x "$drvPath/libexec/deferred-hello" || { echo "FAIL: single-segment broken"; exit 1; }
        test -L "$drvPath/bin/hello" || { echo "FAIL: terminal command missing"; exit 1; }
      '';

  # Test: Nested package with numbers in segment
  nested-numbers =
    mkBuildCheck "nested-numbers" (deferredAppsLib.mkDeferredApp { pname = "python313Packages.numpy"; })
      ''
        # python313Packages has numbers, should work fine
        test -x "$drvPath/libexec/deferred-python313Packages.numpy" || \
          { echo "FAIL: nested package with numbers failed"; exit 1; }
      '';

  # Test: Real-world nested package - rubyPackages
  nested-ruby =
    mkBuildCheck "nested-ruby" (deferredAppsLib.mkDeferredApp { pname = "rubyPackages.rake"; })
      ''
        test -x "$drvPath/libexec/deferred-rubyPackages.rake" || \
          { echo "FAIL: ruby package wrapper missing"; exit 1; }

        grep -q 'PNAME="rubyPackages.rake"' "$drvPath/libexec/deferred-rubyPackages.rake" || \
          { echo "FAIL: PNAME should be full nested path"; exit 1; }
      '';

  # Test: Real-world nested package - nodePackages
  nested-node =
    mkBuildCheck "nested-node" (deferredAppsLib.mkDeferredApp { pname = "nodePackages.typescript"; })
      ''
        test -x "$drvPath/libexec/deferred-nodePackages.typescript" || \
          { echo "FAIL: node package wrapper missing"; exit 1; }
      '';

  # Test: Real-world nested package - perlPackages
  nested-perl =
    mkBuildCheck "nested-perl" (deferredAppsLib.mkDeferredApp { pname = "perlPackages.JSON"; })
      ''
        test -x "$drvPath/libexec/deferred-perlPackages.JSON" || \
          { echo "FAIL: perl package wrapper missing"; exit 1; }
      '';

  # ===========================================================================
  # NESTED PACKAGE VALIDATION ERRORS
  # ===========================================================================

  # Test: Nested package with invalid segment (starts with dash)
  error-nested-segment-dash = testShouldFail "error-nested-segment-dash" (
    deferredAppsLib.mkDeferredApp { pname = "python313Packages.-invalid"; }
  );

  # Test: Nested package with empty segment (double dot)
  error-nested-double-dot = testShouldFail "error-nested-double-dot" (
    deferredAppsLib.mkDeferredApp { pname = "python313Packages..numpy"; }
  );

  # Test: Nested package ending with dot
  error-nested-trailing-dot = testShouldFail "error-nested-trailing-dot" (
    deferredAppsLib.mkDeferredApp { pname = "python313Packages.numpy."; }
  );

  # Test: Nested package starting with dot
  error-nested-leading-dot = testShouldFail "error-nested-leading-dot" (
    deferredAppsLib.mkDeferredApp { pname = ".python313Packages.numpy"; }
  );

  # Test: Nonexistent nested package throws error
  error-nested-nonexistent = testShouldFail "error-nested-nonexistent" (
    deferredAppsLib.mkDeferredApp { pname = "python313Packages.thisPackageDoesNotExist12345"; }
  );

  # Test: Nonexistent parent in nested path
  error-nested-nonexistent-parent = testShouldFail "error-nested-nonexistent-parent" (
    deferredAppsLib.mkDeferredApp { pname = "nonExistentPackageSet12345.somePackage"; }
  );
}
