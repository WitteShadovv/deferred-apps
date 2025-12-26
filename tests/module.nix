# NixOS module integration tests
#
# Tests for the NixOS module with content verification.
# Uses symlinkJoin with postBuild to verify actual derivation content.
#
{
  pkgs,
  lib,
  helpers,
}:

let
  inherit (helpers) evalModule forceEvalPackages mkCheck;
in
{
  # ===========================================================================
  # BASIC MODULE TESTS
  # ===========================================================================

  # Test: Module with apps only - verify content
  module-apps-only =
    let
      eval = evalModule {
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
      ) eval.config.environment.systemPackages;
    in
    pkgs.symlinkJoin {
      name = "check-module-apps-only";
      paths = deferredPkgs;
      postBuild = ''
        # Verify both apps are present
        test -L "$out/bin/hello" || { echo "FAIL: hello missing"; exit 1; }
        test -L "$out/bin/cowsay" || { echo "FAIL: cowsay missing"; exit 1; }

        # Verify desktop files exist
        test -f "$out/share/applications/hello.desktop" || { echo "FAIL: hello.desktop missing"; exit 1; }
        test -f "$out/share/applications/cowsay.desktop" || { echo "FAIL: cowsay.desktop missing"; exit 1; }

        echo "Module apps-only test passed"
      '';
    };

  # ===========================================================================
  # EXTRA APPS TESTS
  # ===========================================================================

  # Test: Module with extraApps - verify createTerminalCommand = false works
  module-extraApps-content =
    let
      eval = evalModule {
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
      ) eval.config.environment.systemPackages;
    in
    pkgs.symlinkJoin {
      name = "check-module-extraApps-content";
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

  # Test: extraApps takes precedence over apps - with verification
  module-extraApps-precedence =
    let
      eval = evalModule {
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
      ) eval.config.environment.systemPackages;
    in
    pkgs.symlinkJoin {
      name = "check-module-extraApps-precedence";
      paths = deferredPkgs;
      postBuild = ''
        # hello should NOT have terminal command (extraApps overrides apps)
        test ! -L "$out/bin/hello" || { echo "FAIL: extraApps should override apps"; exit 1; }

        # Desktop file should still exist
        test -f "$out/share/applications/hello.desktop" || { echo "FAIL: hello.desktop missing"; exit 1; }
      '';
    };

  # Test: extraApps with all null values (the bug we fixed!)
  module-extraApps-all-nulls =
    let
      eval = evalModule {
        programs.deferredApps = {
          enable = true;
          extraApps = {
            hello = { }; # All defaults (exe=null, etc.)
            cowsay = {
              exe = null;
              desktopName = null;
              description = null;
              icon = null;
            };
          };
        };
      };
      deferredPkgs = builtins.filter (
        pkg: lib.hasPrefix "deferred-" (pkg.name or "")
      ) eval.config.environment.systemPackages;
    in
    pkgs.symlinkJoin {
      name = "check-module-extraApps-all-nulls";
      paths = deferredPkgs;
      postBuild = ''
        # Both should work with auto-detection
        test -L "$out/bin/hello" || { echo "FAIL: hello missing"; exit 1; }
        test -L "$out/bin/cowsay" || { echo "FAIL: cowsay missing"; exit 1; }
      '';
    };

  # ===========================================================================
  # PER-APP OVERRIDE TESTS
  # ===========================================================================

  # Test: Per-app flakeRef override - verify in wrapper
  module-per-app-flakeRef =
    let
      eval = evalModule {
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
      ) eval.config.environment.systemPackages;
    in
    pkgs.symlinkJoin {
      name = "check-module-per-app-flakeRef";
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

  # Test: Per-app gcRoot override - verify in wrapper
  module-per-app-gcRoot =
    let
      eval = evalModule {
        programs.deferredApps = {
          enable = true;
          gcRoot = false; # Global default
          extraApps = {
            hello = {
              gcRoot = true;
            }; # Override
            cowsay = { }; # Uses global
          };
        };
      };
      deferredPkgs = builtins.filter (
        pkg: lib.hasPrefix "deferred-" (pkg.name or "")
      ) eval.config.environment.systemPackages;
    in
    pkgs.symlinkJoin {
      name = "check-module-per-app-gcRoot";
      paths = deferredPkgs;
      postBuild = ''
        # hello should have gcRoot = true
        grep -q 'GC_ROOT="1"' "$out/libexec/deferred-hello" || \
          { echo "FAIL: hello should have gcRoot=1"; exit 1; }

        # cowsay should have gcRoot = false (global)
        grep -q 'GC_ROOT="0"' "$out/libexec/deferred-cowsay" || \
          { echo "FAIL: cowsay should have gcRoot=0"; exit 1; }
      '';
    };

  # Test: Per-app allowUnfree override scenarios
  module-per-app-allowUnfree =
    let
      eval = evalModule {
        programs.deferredApps = {
          enable = true;
          allowUnfree = true; # Global allows unfree
          extraApps = {
            hello = {
              allowUnfree = false;
            }; # Override to require free
            cowsay = { }; # Uses global (true)
          };
        };
      };
      deferredPkgs = builtins.filter (
        pkg: lib.hasPrefix "deferred-" (pkg.name or "")
      ) eval.config.environment.systemPackages;
    in
    pkgs.symlinkJoin {
      name = "check-module-per-app-allowUnfree";
      paths = deferredPkgs;
      postBuild = ''
        # hello is free, so NEEDS_IMPURE should be 0 regardless of allowUnfree setting
        grep -q 'NEEDS_IMPURE="0"' "$out/libexec/deferred-hello" || \
          { echo "FAIL: free package should not need impure"; exit 1; }

        # cowsay is also free, should also be 0
        grep -q 'NEEDS_IMPURE="0"' "$out/libexec/deferred-cowsay" || \
          { echo "FAIL: free package should not need impure"; exit 1; }
      '';
    };

  # ===========================================================================
  # ICON THEME TESTS
  # ===========================================================================

  # Test: iconTheme.enable = false
  module-iconTheme-disabled =
    let
      eval = evalModule {
        programs.deferredApps = {
          enable = true;
          apps = [ "hello" ];
          iconTheme.enable = false;
        };
      };
      # Check that papirus is NOT in systemPackages
      hasPapirus = lib.any (
        pkg: lib.hasInfix "papirus" (pkg.name or "")
      ) eval.config.environment.systemPackages;
    in
    mkCheck "module-iconTheme-disabled" (forceEvalPackages eval && !hasPapirus);

  # Test: Custom iconTheme name
  module-iconTheme-custom-name =
    let
      eval = evalModule {
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
    mkCheck "module-iconTheme-custom-name" (forceEvalPackages eval);

  # Test: Custom iconTheme package
  module-iconTheme-custom-package =
    let
      eval = evalModule {
        programs.deferredApps = {
          enable = true;
          apps = [ "hello" ];
          iconTheme = {
            enable = true;
            package = pkgs.adwaita-icon-theme;
            name = "Adwaita";
          };
        };
      };
      # Check that adwaita IS in systemPackages (not papirus)
      hasAdwaita = lib.any (
        pkg: lib.hasInfix "adwaita" (pkg.name or "")
      ) eval.config.environment.systemPackages;
      hasPapirus = lib.any (
        pkg: lib.hasInfix "papirus" (pkg.name or "")
      ) eval.config.environment.systemPackages;
    in
    mkCheck "module-iconTheme-custom-package" (forceEvalPackages eval && hasAdwaita && !hasPapirus);

  # ===========================================================================
  # MODULE ENABLE/DISABLE TESTS
  # ===========================================================================

  # Test: Module disabled (enable = false)
  module-disabled =
    let
      eval = evalModule {
        programs.deferredApps = {
          enable = false;
          apps = [ "hello" ];
        };
      };
      # systemPackages should not contain deferred-hello
      hasDeferred = lib.any (
        pkg: lib.hasInfix "deferred-hello" (pkg.name or "")
      ) eval.config.environment.systemPackages;
    in
    mkCheck "module-disabled" (!hasDeferred);

  # ===========================================================================
  # MODULE COLLISION AND ERROR TESTS
  # ===========================================================================

  # Test: Module THROWS on collision
  module-collision-throws =
    let
      tryEval = builtins.tryEval (
        let
          eval = evalModule {
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
        builtins.deepSeq eval.config.environment.systemPackages true
      );
    in
    mkCheck "module-collision-throws" (!tryEval.success);

  # Test: Module with nonexistent package in apps should throw
  module-error-nonexistent-package =
    let
      tryEval = builtins.tryEval (
        let
          eval = evalModule {
            programs.deferredApps = {
              enable = true;
              apps = [ "this-package-definitely-does-not-exist-xyz123" ];
            };
          };
        in
        builtins.deepSeq eval.config.environment.systemPackages true
      );
    in
    mkCheck "module-error-nonexistent-package" (!tryEval.success);

  # Test: Module collision between apps and extraApps should throw
  module-error-apps-extraApps-collision =
    let
      tryEval = builtins.tryEval (
        let
          eval = evalModule {
            programs.deferredApps = {
              enable = true;
              apps = [ "hello" ];
              extraApps = {
                cowsay = {
                  exe = "hello"; # Collides with hello from apps
                };
              };
            };
          };
        in
        builtins.deepSeq eval.config.environment.systemPackages true
      );
    in
    mkCheck "module-error-apps-extraApps-collision" (!tryEval.success);

  # ===========================================================================
  # INTEGRATION TEST - Full build verification
  # ===========================================================================

  # Test: Full module build with output verification
  integration-full-build =
    let
      eval = evalModule {
        programs.deferredApps = {
          enable = true;
          apps = [ "hello" ];
          extraApps = {
            cowsay = {
              createTerminalCommand = false;
            };
            tree = {
              exe = "my-custom-tree"; # Use a DIFFERENT exe to actually test override
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
      ) eval.config.environment.systemPackages;
    in
    pkgs.symlinkJoin {
      name = "integration-full-build";
      paths = deferredPkgs;
      postBuild = ''
        echo "Verifying full module build..."

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

        echo "All integration checks passed!"
      '';
    };

  # ===========================================================================
  # MODULE WITH NESTED PACKAGES
  # ===========================================================================

  # Test: Module with nested packages in apps list
  module-nested-apps =
    let
      eval = evalModule {
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
      ) eval.config.environment.systemPackages;
    in
    pkgs.symlinkJoin {
      name = "check-module-nested-apps";
      paths = deferredPkgs;
      postBuild = ''
        # Verify both apps are present
        test -x "$out/libexec/deferred-hello" || { echo "FAIL: hello missing"; exit 1; }
        test -x "$out/libexec/deferred-python313Packages.numpy" || { echo "FAIL: numpy missing"; exit 1; }

        # Verify desktop files
        test -f "$out/share/applications/hello.desktop" || { echo "FAIL: hello.desktop missing"; exit 1; }
        test -f "$out/share/applications/python313Packages.numpy.desktop" || \
          { echo "FAIL: numpy.desktop missing"; exit 1; }

        echo "Module nested apps test passed"
      '';
    };

  # Test: Module with nested packages in extraApps
  module-nested-extraApps =
    let
      eval = evalModule {
        programs.deferredApps = {
          enable = true;
          extraApps = {
            "python313Packages.numpy" = {
              desktopName = "NumPy";
              createTerminalCommand = false;
            };
          };
        };
      };
      deferredPkgs = builtins.filter (
        pkg: lib.hasPrefix "deferred-" (pkg.name or "")
      ) eval.config.environment.systemPackages;
    in
    pkgs.symlinkJoin {
      name = "check-module-nested-extraApps";
      paths = deferredPkgs;
      postBuild = ''
        # numpy should NOT have terminal command
        test ! -L "$out/bin/numpy" 2>/dev/null || { echo "FAIL: numpy should not have bin"; exit 1; }

        # But should have desktop file with custom name
        test -f "$out/share/applications/python313Packages.numpy.desktop" || \
          { echo "FAIL: numpy.desktop missing"; exit 1; }

        grep -q 'Name=NumPy' "$out/share/applications/python313Packages.numpy.desktop" || \
          { echo "FAIL: custom desktop name not applied"; exit 1; }
      '';
    };

  # Test: Module nested package with per-app flakeRef
  module-nested-per-app-flakeRef =
    let
      eval = evalModule {
        programs.deferredApps = {
          enable = true;
          flakeRef = "nixpkgs";
          extraApps = {
            "python313Packages.numpy" = {
              flakeRef = "github:NixOS/nixpkgs/nixos-25.11";
            };
          };
        };
      };
      deferredPkgs = builtins.filter (
        pkg: lib.hasPrefix "deferred-" (pkg.name or "")
      ) eval.config.environment.systemPackages;
    in
    pkgs.symlinkJoin {
      name = "check-module-nested-per-app-flakeRef";
      paths = deferredPkgs;
      postBuild = ''
        grep -q 'FLAKE_REF="github:NixOS/nixpkgs/nixos-25.11"' \
          "$out/libexec/deferred-python313Packages.numpy" || \
          { echo "FAIL: custom flakeRef not applied"; exit 1; }
      '';
    };
}
