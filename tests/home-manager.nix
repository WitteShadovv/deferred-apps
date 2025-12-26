# Home Manager module integration tests
#
# Tests for the Home Manager module with content verification.
# Mirrors the NixOS module tests but targets home.packages instead.
#
{
  pkgs,
  lib,
  helpers,
}:

let
  inherit (helpers)
    evalHomeModule
    forceEvalHomePackages
    mkCheck
    ;
in
{
  # ===========================================================================
  # BASIC HOME MANAGER MODULE TESTS
  # ===========================================================================

  # Test: HM module with apps only - verify content
  hm-module-apps-only =
    let
      eval = evalHomeModule {
        programs.deferredApps = {
          enable = true;
          apps = [
            "hello"
            "cowsay"
          ];
        };
      };
      deferredPkgs = builtins.filter (
        pkg: lib.hasPrefix "deferred-" (pkg.name or "")
      ) eval.config.home.packages;
    in
    pkgs.symlinkJoin {
      name = "check-hm-module-apps-only";
      paths = deferredPkgs;
      postBuild = ''
        # Verify both apps are present
        test -L "$out/bin/hello" || { echo "FAIL: hello missing"; exit 1; }
        test -L "$out/bin/cowsay" || { echo "FAIL: cowsay missing"; exit 1; }

        # Verify desktop files exist
        test -f "$out/share/applications/hello.desktop" || { echo "FAIL: hello.desktop missing"; exit 1; }
        test -f "$out/share/applications/cowsay.desktop" || { echo "FAIL: cowsay.desktop missing"; exit 1; }

        echo "HM module apps-only test passed"
      '';
    };

  # ===========================================================================
  # EXTRA APPS TESTS
  # ===========================================================================

  # Test: HM module with extraApps - verify createTerminalCommand = false works
  hm-module-extraApps-content =
    let
      eval = evalHomeModule {
        programs.deferredApps = {
          enable = true;
          extraApps = {
            hello = { };
            cowsay = {
              createTerminalCommand = false;
            };
          };
        };
      };
      deferredPkgs = builtins.filter (
        pkg: lib.hasPrefix "deferred-" (pkg.name or "")
      ) eval.config.home.packages;
    in
    pkgs.symlinkJoin {
      name = "check-hm-module-extraApps-content";
      paths = deferredPkgs;
      postBuild = ''
        # hello should have terminal command
        test -L "$out/bin/hello" || { echo "FAIL: hello should have bin"; exit 1; }

        # cowsay should NOT have terminal command
        test ! -L "$out/bin/cowsay" || { echo "FAIL: cowsay should not have bin"; exit 1; }

        # But both should have desktop files
        test -f "$out/share/applications/hello.desktop" || { echo "FAIL: hello.desktop missing"; exit 1; }
        test -f "$out/share/applications/cowsay.desktop" || { echo "FAIL: cowsay.desktop missing"; exit 1; }
      '';
    };

  # Test: extraApps takes precedence over apps in HM module
  hm-module-extraApps-precedence =
    let
      eval = evalHomeModule {
        programs.deferredApps = {
          enable = true;
          apps = [ "hello" ]; # Listed in apps
          extraApps = {
            hello = {
              createTerminalCommand = false;
            }; # Override in extraApps
          };
        };
      };
      deferredPkgs = builtins.filter (
        pkg: lib.hasPrefix "deferred-" (pkg.name or "")
      ) eval.config.home.packages;
    in
    pkgs.symlinkJoin {
      name = "check-hm-module-extraApps-precedence";
      paths = deferredPkgs;
      postBuild = ''
        # hello should NOT have terminal command (extraApps overrides apps)
        test ! -L "$out/bin/hello" || { echo "FAIL: extraApps should override apps"; exit 1; }

        # Desktop file should still exist
        test -f "$out/share/applications/hello.desktop" || { echo "FAIL: hello.desktop missing"; exit 1; }
      '';
    };

  # ===========================================================================
  # PER-APP OVERRIDE TESTS
  # ===========================================================================

  # Test: Per-app flakeRef override in HM module
  hm-module-per-app-flakeRef =
    let
      eval = evalHomeModule {
        programs.deferredApps = {
          enable = true;
          flakeRef = "nixpkgs"; # Global default
          extraApps = {
            hello = {
              flakeRef = "github:NixOS/nixpkgs/nixos-25.11"; # Override
            };
            cowsay = { }; # Uses global
          };
        };
      };
      deferredPkgs = builtins.filter (
        pkg: lib.hasPrefix "deferred-" (pkg.name or "")
      ) eval.config.home.packages;
    in
    pkgs.symlinkJoin {
      name = "check-hm-module-per-app-flakeRef";
      paths = deferredPkgs;
      postBuild = ''
        # hello should have custom flakeRef
        grep -q 'FLAKE_REF="github:NixOS/nixpkgs/nixos-25.11"' "$out/libexec/deferred-hello" || \
          { echo "FAIL: hello should have custom flakeRef"; exit 1; }

        # cowsay should have global flakeRef
        grep -q 'FLAKE_REF="nixpkgs"' "$out/libexec/deferred-cowsay" || \
          { echo "FAIL: cowsay should have global flakeRef"; exit 1; }
      '';
    };

  # ===========================================================================
  # ICON THEME TESTS
  # ===========================================================================

  # Test: iconTheme.enable = false in HM module
  hm-module-iconTheme-disabled =
    let
      eval = evalHomeModule {
        programs.deferredApps = {
          enable = true;
          apps = [ "hello" ];
          iconTheme.enable = false;
        };
      };
      # Check that papirus is NOT in home.packages
      hasPapirus = lib.any (pkg: lib.hasInfix "papirus" (pkg.name or "")) eval.config.home.packages;
    in
    mkCheck "hm-module-iconTheme-disabled" (forceEvalHomePackages eval && !hasPapirus);

  # Test: Custom iconTheme name in HM module
  hm-module-iconTheme-custom-name =
    let
      eval = evalHomeModule {
        programs.deferredApps = {
          enable = true;
          apps = [ "hello" ];
          iconTheme = {
            enable = true;
            name = "Papirus-Light";
          };
        };
      };
    in
    mkCheck "hm-module-iconTheme-custom-name" (forceEvalHomePackages eval);

  # ===========================================================================
  # SESSION VARIABLES TEST
  # ===========================================================================

  # Test: GTK_ICON_THEME is set in home.sessionVariables when iconTheme enabled
  hm-module-session-variables =
    let
      eval = evalHomeModule {
        programs.deferredApps = {
          enable = true;
          apps = [ "hello" ];
          iconTheme = {
            enable = true;
            name = "Papirus-Dark";
          };
        };
      };
      hasIconThemeVar = eval.config.home.sessionVariables ? GTK_ICON_THEME;
      iconThemeValue = eval.config.home.sessionVariables.GTK_ICON_THEME or "";
    in
    mkCheck "hm-module-session-variables" (hasIconThemeVar && iconThemeValue == "Papirus-Dark");

  # Test: No GTK_ICON_THEME when iconTheme disabled
  hm-module-no-session-variables =
    let
      eval = evalHomeModule {
        programs.deferredApps = {
          enable = true;
          apps = [ "hello" ];
          iconTheme.enable = false;
        };
      };
      hasIconThemeVar = eval.config.home.sessionVariables ? GTK_ICON_THEME;
    in
    mkCheck "hm-module-no-session-variables" (!hasIconThemeVar);

  # ===========================================================================
  # MODULE ENABLE/DISABLE TESTS
  # ===========================================================================

  # Test: HM module disabled (enable = false)
  hm-module-disabled =
    let
      eval = evalHomeModule {
        programs.deferredApps = {
          enable = false;
          apps = [ "hello" ];
        };
      };
      # home.packages should not contain deferred-hello
      hasDeferred = lib.any (
        pkg: lib.hasInfix "deferred-hello" (pkg.name or "")
      ) eval.config.home.packages;
    in
    mkCheck "hm-module-disabled" (!hasDeferred);

  # ===========================================================================
  # COLLISION AND ERROR TESTS
  # ===========================================================================

  # Test: HM module THROWS on collision
  hm-module-collision-throws =
    let
      tryEval = builtins.tryEval (
        let
          eval = evalHomeModule {
            programs.deferredApps = {
              enable = true;
              extraApps = {
                app1 = {
                  exe = "conflict";
                };
                app2 = {
                  exe = "conflict";
                };
              };
            };
          };
        in
        builtins.deepSeq eval.config.home.packages true
      );
    in
    mkCheck "hm-module-collision-throws" (!tryEval.success);

  # Test: HM module with nonexistent package should throw
  hm-module-error-nonexistent-package =
    let
      tryEval = builtins.tryEval (
        let
          eval = evalHomeModule {
            programs.deferredApps = {
              enable = true;
              apps = [ "this-package-definitely-does-not-exist-xyz123" ];
            };
          };
        in
        builtins.deepSeq eval.config.home.packages true
      );
    in
    mkCheck "hm-module-error-nonexistent-package" (!tryEval.success);

  # ===========================================================================
  # NESTED PACKAGES TEST
  # ===========================================================================

  # Test: HM module with nested packages
  hm-module-nested-apps =
    let
      eval = evalHomeModule {
        programs.deferredApps = {
          enable = true;
          apps = [
            "hello"
            "python313Packages.numpy"
          ];
        };
      };
      deferredPkgs = builtins.filter (
        pkg: lib.hasPrefix "deferred-" (pkg.name or "")
      ) eval.config.home.packages;
    in
    pkgs.symlinkJoin {
      name = "check-hm-module-nested-apps";
      paths = deferredPkgs;
      postBuild = ''
        # Verify both apps are present
        test -x "$out/libexec/deferred-hello" || { echo "FAIL: hello missing"; exit 1; }
        test -x "$out/libexec/deferred-python313Packages.numpy" || { echo "FAIL: numpy missing"; exit 1; }

        # Verify desktop files
        test -f "$out/share/applications/hello.desktop" || { echo "FAIL: hello.desktop missing"; exit 1; }
        test -f "$out/share/applications/python313Packages.numpy.desktop" || \
          { echo "FAIL: numpy.desktop missing"; exit 1; }

        echo "HM module nested apps test passed"
      '';
    };

  # ===========================================================================
  # INTEGRATION TEST - Full build verification
  # ===========================================================================

  # Test: Full HM module build with output verification
  hm-integration-full-build =
    let
      eval = evalHomeModule {
        programs.deferredApps = {
          enable = true;
          apps = [ "hello" ];
          extraApps = {
            cowsay = {
              createTerminalCommand = false;
            };
            tree = {
              exe = "my-custom-tree";
              desktopName = "Tree Viewer";
              categories = [
                "Utility"
                "FileManager"
              ];
            };
          };
        };
      };
      deferredPkgs = builtins.filter (
        pkg: lib.hasPrefix "deferred-" (pkg.name or "")
      ) eval.config.home.packages;
    in
    pkgs.symlinkJoin {
      name = "hm-integration-full-build";
      paths = deferredPkgs;
      postBuild = ''
        echo "Verifying full HM module build..."

        # hello should have terminal command
        test -L "$out/bin/hello" || { echo "FAIL: hello bin missing"; exit 1; }

        # cowsay should NOT have terminal command
        test ! -L "$out/bin/cowsay" || { echo "FAIL: cowsay should not have bin"; exit 1; }

        # tree should have CUSTOM terminal command (my-custom-tree, not tree)
        test -L "$out/bin/my-custom-tree" || { echo "FAIL: tree should have custom bin 'my-custom-tree'"; exit 1; }
        test ! -L "$out/bin/tree" || { echo "FAIL: tree should NOT have default bin name"; exit 1; }

        # All desktop files should exist
        test -f "$out/share/applications/hello.desktop" || { echo "FAIL: hello.desktop missing"; exit 1; }
        test -f "$out/share/applications/cowsay.desktop" || { echo "FAIL: cowsay.desktop missing"; exit 1; }
        test -f "$out/share/applications/tree.desktop" || { echo "FAIL: tree.desktop missing"; exit 1; }

        # tree should have custom desktop name
        grep -q 'Name=Tree Viewer' "$out/share/applications/tree.desktop" || \
          { echo "FAIL: tree custom name missing"; exit 1; }

        # tree should have custom categories
        grep -q 'Utility' "$out/share/applications/tree.desktop" || \
          { echo "FAIL: tree Utility category missing"; exit 1; }

        echo "All HM integration checks passed!"
      '';
    };
}
