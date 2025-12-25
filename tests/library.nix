# Library function tests
#
# Tests for mkDeferredApp with all its parameters:
# - Basic functionality
# - Desktop file fields (StartupWMClass, StartupNotify, Terminal)
# - exe, desktopName, description, icon, categories parameters
# - createTerminalCommand, flakeRef, gcRoot, allowUnfree parameters
#
{ helpers }:

let
  inherit (helpers) deferredAppsLib mkBuildCheck;
in
{
  # ===========================================================================
  # BASIC FUNCTIONALITY
  # ===========================================================================

  # Test: Basic app with all defaults
  lib-basic = mkBuildCheck "lib-basic" (deferredAppsLib.mkDeferredApp { pname = "hello"; }) ''
    # Wrapper script exists in libexec
    test -x "$drvPath/libexec/deferred-hello" || { echo "FAIL: wrapper not executable"; exit 1; }

    # Desktop file exists
    test -f "$drvPath/share/applications/hello.desktop" || { echo "FAIL: desktop file missing"; exit 1; }

    # Terminal command symlink exists (default: createTerminalCommand = true)
    test -L "$drvPath/bin/hello" || { echo "FAIL: terminal symlink missing"; exit 1; }

    # Symlink points to correct target
    target=$(readlink "$drvPath/bin/hello")
    test "$target" = "$drvPath/libexec/deferred-hello" || { echo "FAIL: symlink target wrong: $target"; exit 1; }
  '';

  # Test: Package with mainProgram different from pname (obs-studio -> obs)
  lib-mainProgram =
    mkBuildCheck "lib-mainProgram" (deferredAppsLib.mkDeferredApp { pname = "obs-studio"; })
      ''
        # Terminal command should be lowercase mainProgram
        test -L "$drvPath/bin/obs" || { echo "FAIL: terminal command should be 'obs' not 'obs-studio'"; exit 1; }

        # Wrapper should use correct exe
        grep -q 'EXE="obs"' "$drvPath/libexec/deferred-obs-studio" || { echo "FAIL: wrapper should use 'obs' as exe"; exit 1; }
      '';

  # Test: Package without mainProgram (falls back to pname)
  lib-no-mainProgram =
    mkBuildCheck "lib-no-mainProgram" (deferredAppsLib.mkDeferredApp { pname = "tree"; })
      ''
        # Should fall back to pname as terminal command
        test -L "$drvPath/bin/tree" || { echo "FAIL: should fall back to pname"; exit 1; }
      '';

  # ===========================================================================
  # DESKTOP FILE FIELDS VERIFICATION
  # ===========================================================================

  # Test: StartupWMClass is correctly set to finalExe
  lib-desktop-startupWMClass =
    mkBuildCheck "lib-desktop-startupWMClass" (deferredAppsLib.mkDeferredApp { pname = "obs-studio"; })
      ''
        # StartupWMClass should be the exe name (obs for obs-studio)
        grep -q 'StartupWMClass=obs' "$drvPath/share/applications/obs-studio.desktop" || \
          { echo "FAIL: StartupWMClass should be 'obs'"; exit 1; }
      '';

  # Test: StartupNotify=true is present
  lib-desktop-startupNotify =
    mkBuildCheck "lib-desktop-startupNotify" (deferredAppsLib.mkDeferredApp { pname = "hello"; })
      ''
        grep -q 'StartupNotify=true' "$drvPath/share/applications/hello.desktop" || \
          { echo "FAIL: StartupNotify should be true"; exit 1; }
      '';

  # Test: Terminal=false is present (deferred apps are GUI launchers)
  lib-desktop-terminal-false =
    mkBuildCheck "lib-desktop-terminal-false" (deferredAppsLib.mkDeferredApp { pname = "hello"; })
      ''
        grep -q 'Terminal=false' "$drvPath/share/applications/hello.desktop" || \
          { echo "FAIL: Terminal should be false"; exit 1; }
      '';

  # ===========================================================================
  # EXE PARAMETER
  # ===========================================================================

  # Test: Custom exe override
  lib-exe-override =
    mkBuildCheck "lib-exe-override"
      (deferredAppsLib.mkDeferredApp {
        pname = "hello";
        exe = "custom-hello";
      })
      ''
        # Terminal command should be lowercase custom exe
        test -L "$drvPath/bin/custom-hello" || { echo "FAIL: custom exe not used"; exit 1; }

        # Wrapper should use custom exe
        grep -q 'EXE="custom-hello"' "$drvPath/libexec/deferred-hello" || { echo "FAIL: wrapper should use custom exe"; exit 1; }

        # StartupWMClass should also be custom exe
        grep -q 'StartupWMClass=custom-hello' "$drvPath/share/applications/hello.desktop" || \
          { echo "FAIL: StartupWMClass should be custom exe"; exit 1; }
      '';

  # Test: exe with uppercase (terminal command should be lowercase)
  lib-exe-uppercase =
    mkBuildCheck "lib-exe-uppercase"
      (deferredAppsLib.mkDeferredApp {
        pname = "hello";
        exe = "MyApp";
      })
      ''
        # Terminal command should be lowercase
        test -L "$drvPath/bin/myapp" || { echo "FAIL: terminal command should be lowercase"; exit 1; }

        # But wrapper should use original case for the actual binary
        grep -q 'EXE="MyApp"' "$drvPath/libexec/deferred-hello" || { echo "FAIL: wrapper should preserve exe case"; exit 1; }
      '';

  # ===========================================================================
  # DESKTOP NAME PARAMETER
  # ===========================================================================

  # Test: Auto-generated desktop name (obs-studio -> "Obs Studio")
  lib-desktopName-auto =
    mkBuildCheck "lib-desktopName-auto" (deferredAppsLib.mkDeferredApp { pname = "obs-studio"; })
      ''
        grep -q 'Name=Obs Studio' "$drvPath/share/applications/obs-studio.desktop" || \
          { echo "FAIL: desktop name should be 'Obs Studio'"; exit 1; }
      '';

  # Test: Custom desktop name
  lib-desktopName-custom =
    mkBuildCheck "lib-desktopName-custom"
      (deferredAppsLib.mkDeferredApp {
        pname = "hello";
        desktopName = "My Hello App";
      })
      ''
        grep -q 'Name=My Hello App' "$drvPath/share/applications/hello.desktop" || \
          { echo "FAIL: custom desktop name not used"; exit 1; }
      '';

  # ===========================================================================
  # DESCRIPTION PARAMETER
  # ===========================================================================

  # Test: Auto-detected description from meta (verify actual content)
  lib-description-auto =
    mkBuildCheck "lib-description-auto" (deferredAppsLib.mkDeferredApp { pname = "hello"; })
      ''
        # hello's description contains "simple program" or similar
        # Check that Comment= exists and is non-empty
        comment=$(grep '^Comment=' "$drvPath/share/applications/hello.desktop" | cut -d= -f2-)
        test -n "$comment" || { echo "FAIL: Comment should not be empty"; exit 1; }

        # Verify it's not the fallback "Application"
        if [ "$comment" = "Application" ]; then
          echo "FAIL: Should use actual description, not fallback"
          exit 1
        fi

        echo "Description: $comment"
      '';

  # Test: Custom description
  lib-description-custom =
    mkBuildCheck "lib-description-custom"
      (deferredAppsLib.mkDeferredApp {
        pname = "hello";
        description = "My custom description";
      })
      ''
        grep -q 'Comment=My custom description' "$drvPath/share/applications/hello.desktop" || \
          { echo "FAIL: custom description not used"; exit 1; }
      '';

  # ===========================================================================
  # ICON PARAMETER
  # ===========================================================================

  # Test: Icon resolves to absolute Nix store path (deterministic)
  # firefox icon IS in Papirus theme, so this should ALWAYS resolve
  lib-icon-resolved =
    mkBuildCheck "lib-icon-resolved" (deferredAppsLib.mkDeferredApp { pname = "firefox"; })
      ''
        icon=$(grep '^Icon=' "$drvPath/share/applications/firefox.desktop" | cut -d= -f2)

        # Must be a Nix store path - this is deterministic because Papirus has firefox
        case "$icon" in
          /nix/store/*.svg)
            echo "OK: Icon resolved to Nix store path: $icon"
            # Verify the file actually exists
            test -f "$icon" || { echo "FAIL: resolved icon file does not exist"; exit 1; }
            ;;
          *)
            echo "FAIL: firefox icon should resolve to /nix/store path, got: $icon"
            exit 1
            ;;
        esac
      '';

  # Test: Icon with nonexistent name falls back to provided name
  # When icon name doesn't exist in theme, the original name is preserved in the desktop file
  lib-icon-nonexistent-fallback =
    mkBuildCheck "lib-icon-nonexistent-fallback"
      (deferredAppsLib.mkDeferredApp {
        pname = "hello";
        icon = "nonexistent-icon-name-12345";
      })
      ''
        icon=$(grep '^Icon=' "$drvPath/share/applications/hello.desktop" | cut -d= -f2)

        # When icon doesn't exist in theme, the original name should be preserved
        test "$icon" = "nonexistent-icon-name-12345" || \
          { echo "FAIL: Icon should fall back to provided name, got: $icon"; exit 1; }

        echo "OK: Icon correctly fell back to provided name"
      '';

  # Test: Custom icon name that exists in theme resolves to store path
  # utilities-terminal definitely exists in Papirus, so this MUST resolve
  lib-icon-custom-existing =
    mkBuildCheck "lib-icon-custom-existing"
      (deferredAppsLib.mkDeferredApp {
        pname = "hello";
        icon = "utilities-terminal";
      })
      ''
        icon=$(grep '^Icon=' "$drvPath/share/applications/hello.desktop" | cut -d= -f2)

        # utilities-terminal exists in Papirus, MUST resolve to store path
        case "$icon" in
          /nix/store/*.svg)
            echo "OK: utilities-terminal resolved to: $icon"
            test -f "$icon" || { echo "FAIL: resolved icon file does not exist"; exit 1; }
            ;;
          *)
            echo "FAIL: utilities-terminal should resolve to /nix/store path, got: $icon"
            exit 1
            ;;
        esac
      '';

  # Test: Absolute icon path (bypasses theme lookup)
  lib-icon-absolute =
    mkBuildCheck "lib-icon-absolute"
      (deferredAppsLib.mkDeferredApp {
        pname = "hello";
        icon = "/nix/store/fake-path/icon.png";
      })
      ''
        grep -q 'Icon=/nix/store/fake-path/icon.png' "$drvPath/share/applications/hello.desktop" || \
          { echo "FAIL: absolute icon path not preserved"; exit 1; }
      '';

  # Test: Icon WARNING path - when both primary and fallback fail
  lib-icon-warning-fallback =
    mkBuildCheck "lib-icon-warning-fallback"
      (deferredAppsLib.mkDeferredApp {
        pname = "tree";
        icon = "definitely-nonexistent-icon-xyz";
      })
      ''
        icon=$(grep '^Icon=' "$drvPath/share/applications/tree.desktop" | cut -d= -f2)

        # Should fall back to the icon name when not found in theme
        test "$icon" = "definitely-nonexistent-icon-xyz" || \
          { echo "FAIL: Icon should fall back to name when not found, got: $icon"; exit 1; }

        echo "OK: Icon correctly fell back to name when not found in theme"
      '';

  # ===========================================================================
  # CATEGORIES PARAMETER
  # ===========================================================================

  # Test: Default categories with exact format verification
  lib-categories-default =
    mkBuildCheck "lib-categories-default" (deferredAppsLib.mkDeferredApp { pname = "hello"; })
      ''
        # Verify categories field exists and contains Application
        categories=$(grep '^Categories=' "$drvPath/share/applications/hello.desktop" | cut -d= -f2)

        # Should contain Application
        case "$categories" in
          *Application*)
            echo "OK: Contains 'Application' category: $categories"
            ;;
          *)
            echo "FAIL: Should contain 'Application' category, got: $categories"
            exit 1
            ;;
        esac
      '';

  # Test: Custom categories
  lib-categories-custom =
    mkBuildCheck "lib-categories-custom"
      (deferredAppsLib.mkDeferredApp {
        pname = "hello";
        categories = [
          "Development"
          "IDE"
        ];
      })
      ''
        categories=$(grep '^Categories=' "$drvPath/share/applications/hello.desktop" | cut -d= -f2)

        # Check both categories are present
        case "$categories" in
          *Development*IDE* | *IDE*Development*)
            echo "OK: Both categories present: $categories"
            ;;
          *)
            echo "FAIL: Missing expected categories, got: $categories"
            exit 1
            ;;
        esac
      '';

  # ===========================================================================
  # CREATE TERMINAL COMMAND PARAMETER
  # ===========================================================================

  # Test: createTerminalCommand = true (default)
  lib-terminal-true =
    mkBuildCheck "lib-terminal-true"
      (deferredAppsLib.mkDeferredApp {
        pname = "hello";
        createTerminalCommand = true;
      })
      ''
        test -d "$drvPath/bin" || { echo "FAIL: bin/ directory should exist"; exit 1; }
        test -L "$drvPath/bin/hello" || { echo "FAIL: terminal symlink should exist"; exit 1; }
      '';

  # Test: createTerminalCommand = false
  lib-terminal-false =
    mkBuildCheck "lib-terminal-false"
      (deferredAppsLib.mkDeferredApp {
        pname = "hello";
        createTerminalCommand = false;
      })
      ''
        # bin/ directory should not exist at all
        test ! -d "$drvPath/bin" || { echo "FAIL: bin/ directory should not exist"; exit 1; }

        # But libexec wrapper should still exist
        test -x "$drvPath/libexec/deferred-hello" || { echo "FAIL: libexec wrapper should exist"; exit 1; }
      '';

  # ===========================================================================
  # FLAKE REF PARAMETER
  # ===========================================================================

  # Test: Default flakeRef
  lib-flakeRef-default =
    mkBuildCheck "lib-flakeRef-default" (deferredAppsLib.mkDeferredApp { pname = "hello"; })
      ''
        grep -q 'FLAKE_REF="nixpkgs"' "$drvPath/libexec/deferred-hello" || \
          { echo "FAIL: default flakeRef should be 'nixpkgs'"; exit 1; }
      '';

  # Test: Custom flakeRef
  lib-flakeRef-custom =
    mkBuildCheck "lib-flakeRef-custom"
      (deferredAppsLib.mkDeferredApp {
        pname = "hello";
        flakeRef = "github:NixOS/nixpkgs/nixos-24.11";
      })
      ''
        grep -q 'FLAKE_REF="github:NixOS/nixpkgs/nixos-24.11"' "$drvPath/libexec/deferred-hello" || \
          { echo "FAIL: custom flakeRef not used"; exit 1; }
      '';

  # ===========================================================================
  # GC ROOT PARAMETER
  # ===========================================================================

  # Test: gcRoot = false (default)
  lib-gcRoot-false =
    mkBuildCheck "lib-gcRoot-false"
      (deferredAppsLib.mkDeferredApp {
        pname = "hello";
        gcRoot = false;
      })
      ''
        grep -q 'GC_ROOT="0"' "$drvPath/libexec/deferred-hello" || \
          { echo "FAIL: gcRoot should be '0'"; exit 1; }
      '';

  # Test: gcRoot = true
  lib-gcRoot-true =
    mkBuildCheck "lib-gcRoot-true"
      (deferredAppsLib.mkDeferredApp {
        pname = "hello";
        gcRoot = true;
      })
      ''
        grep -q 'GC_ROOT="1"' "$drvPath/libexec/deferred-hello" || \
          { echo "FAIL: gcRoot should be '1'"; exit 1; }
      '';

  # ===========================================================================
  # ALLOW UNFREE PARAMETER
  # ===========================================================================

  # Test: Free package with allowUnfree = false (default)
  lib-allowUnfree-free-false =
    mkBuildCheck "lib-allowUnfree-free-false"
      (deferredAppsLib.mkDeferredApp {
        pname = "hello";
        allowUnfree = false;
      })
      ''
        grep -q 'NEEDS_IMPURE="0"' "$drvPath/libexec/deferred-hello" || \
          { echo "FAIL: free package should not need impure"; exit 1; }
      '';

  # Test: Free package with allowUnfree = true (still pure because package is free)
  lib-allowUnfree-free-true =
    mkBuildCheck "lib-allowUnfree-free-true"
      (deferredAppsLib.mkDeferredApp {
        pname = "hello";
        allowUnfree = true;
      })
      ''
        # Even with allowUnfree=true, free packages stay pure
        grep -q 'NEEDS_IMPURE="0"' "$drvPath/libexec/deferred-hello" || \
          { echo "FAIL: free package should stay pure even with allowUnfree"; exit 1; }
      '';
}
