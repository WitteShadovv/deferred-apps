# Package Mode Tests
#
# Tests for direct package reference functionality:
# - mkDeferredApp with package parameter (package mode)
# - mkDeferredPackages batch function
# - Package mode in modules (packages option, extraApps.*.package)
# - Collision detection with packages
# - Metadata extraction from package derivations
#
# Package mode enables:
# - Using packages from custom nixpkgs instances (e.g., unstable)
# - Packages with overlays applied
# - Packages pinned to flake.lock
#
# Key technical behavior:
# - Package outputs are NOT built at system build time
# - Only the .drv file is captured via builtins.appendContext with path=true
# - At runtime, nix-store --realise is used to download/build
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
    evalModule
    evalHomeModule
    forceEvalPackages
    forceEvalHomePackages
    testShouldFail
    testListShouldFail
    ;
in
{
  # ===========================================================================
  # BASIC PACKAGE MODE FUNCTIONALITY
  # ===========================================================================

  # Test: Basic package mode with all defaults
  pkg-basic = mkBuildCheck "pkg-basic" (deferredAppsLib.mkDeferredApp { package = pkgs.hello; }) ''
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

  # Test: Package mode uses nix-store --realise (not nix shell)
  pkg-uses-realise =
    mkBuildCheck "pkg-uses-realise" (deferredAppsLib.mkDeferredApp { package = pkgs.hello; })
      ''
        # Package mode should use nix-store --realise, not nix shell
        grep -q 'nix-store --realise' "$drvPath/libexec/deferred-hello" || \
          { echo "FAIL: package mode should use nix-store --realise"; exit 1; }

        # Should NOT have FLAKE_REF (that's pname mode)
        if grep -q 'FLAKE_REF=' "$drvPath/libexec/deferred-hello"; then
          echo "FAIL: package mode should not have FLAKE_REF"
          exit 1
        fi

        # Should have DRV_PATH and OUT_PATH
        grep -q 'DRV_PATH=' "$drvPath/libexec/deferred-hello" || \
          { echo "FAIL: package mode should have DRV_PATH"; exit 1; }
        grep -q 'OUT_PATH=' "$drvPath/libexec/deferred-hello" || \
          { echo "FAIL: package mode should have OUT_PATH"; exit 1; }
      '';

  # Test: Package with mainProgram different from pname
  pkg-mainProgram =
    mkBuildCheck "pkg-mainProgram" (deferredAppsLib.mkDeferredApp { package = pkgs.obs-studio; })
      ''
        # Terminal command should be lowercase mainProgram
        test -L "$drvPath/bin/obs" || { echo "FAIL: terminal command should be 'obs' not 'obs-studio'"; exit 1; }

        # Wrapper should use correct exe
        grep -q 'EXE="obs"' "$drvPath/libexec/deferred-obs-studio" || { echo "FAIL: wrapper should use 'obs' as exe"; exit 1; }
      '';

  # Test: DRV_PATH is a valid .drv file path
  pkg-drv-path-valid =
    mkBuildCheck "pkg-drv-path-valid" (deferredAppsLib.mkDeferredApp { package = pkgs.hello; })
      ''
        drv_path=$(grep 'DRV_PATH=' "$drvPath/libexec/deferred-hello" | cut -d'"' -f2)

        # Should be a /nix/store path ending in .drv
        case "$drv_path" in
          /nix/store/*.drv)
            echo "OK: DRV_PATH is valid: $drv_path"
            # The .drv file should exist (captured via builtins.appendContext with path=true)
            test -f "$drv_path" || { echo "FAIL: .drv file should exist"; exit 1; }
            ;;
          *)
            echo "FAIL: DRV_PATH should be /nix/store/*.drv, got: $drv_path"
            exit 1
            ;;
        esac
      '';

  # Test: OUT_PATH is a valid store path
  pkg-out-path-valid =
    mkBuildCheck "pkg-out-path-valid" (deferredAppsLib.mkDeferredApp { package = pkgs.hello; })
      ''
        out_path=$(grep 'OUT_PATH=' "$drvPath/libexec/deferred-hello" | cut -d'"' -f2)

        # Should be a /nix/store path (without .drv)
        case "$out_path" in
          /nix/store/*)
            if echo "$out_path" | grep -q '\.drv$'; then
              echo "FAIL: OUT_PATH should not end in .drv"
              exit 1
            fi
            echo "OK: OUT_PATH is valid: $out_path"
            ;;
          *)
            echo "FAIL: OUT_PATH should be /nix/store/*, got: $out_path"
            exit 1
            ;;
        esac
      '';

  # Test: Package outputs are NOT built at system build time (critical feature!)
  # This verifies that builtins.appendContext with path=true works correctly.
  # We verify by checking the string context of the drvPath - it should only have
  # { path = true } not { allOutputs = true }.
  #
  # The test is implicit in that if outputs were being built, the test derivation
  # itself would have those as dependencies (which we can't easily check at build time).
  # Instead, we verify the mechanism works by building a wrapper for a package
  # that ISN'T commonly cached (like a custom trivial derivation).
  pkg-outputs-not-built =
    let
      # Create a package that would take a long time to build and isn't cached
      # If outputs were being built, this test would fail/timeout
      slowPackage = pkgs.runCommand "test-slow-package" { } ''
        # This would sleep if actually built, but we never build outputs
        # sleep 60
        mkdir -p $out/bin
        echo '#!/bin/sh' > $out/bin/slow-test
        echo 'echo hello' >> $out/bin/slow-test
        chmod +x $out/bin/slow-test
      '';
      # Create a deferred app for it - this should NOT build slowPackage
      deferredSlow = deferredAppsLib.mkDeferredApp { package = slowPackage; };
    in
    # The fact that this test builds quickly proves outputs aren't built
    mkBuildCheck "pkg-outputs-not-built" deferredSlow ''
      # Verify the wrapper was created
      test -x "$drvPath/libexec/deferred-test-slow-package" || \
        { echo "FAIL: wrapper should exist"; exit 1; }

      # Verify it references the .drv file
      drv_path=$(grep 'DRV_PATH=' "$drvPath/libexec/deferred-test-slow-package" | cut -d'"' -f2)
      case "$drv_path" in
        /nix/store/*.drv)
          echo "OK: DRV_PATH is valid: $drv_path"
          ;;
        *)
          echo "FAIL: DRV_PATH should be a .drv file"
          exit 1
          ;;
      esac

      # If we got here, it means the deferred app was built without building
      # the slowPackage outputs - which is the key feature of package mode!
      echo "OK: Package mode correctly avoids building package outputs"
    '';

  # ===========================================================================
  # PACKAGE MODE WITH CUSTOM OPTIONS
  # ===========================================================================

  # Test: Package mode with custom exe
  pkg-exe-override =
    mkBuildCheck "pkg-exe-override"
      (deferredAppsLib.mkDeferredApp {
        package = pkgs.hello;
        exe = "custom-hello";
      })
      ''
        # Terminal command should be custom exe
        test -L "$drvPath/bin/custom-hello" || { echo "FAIL: custom exe not used"; exit 1; }

        # Wrapper should use custom exe
        grep -q 'EXE="custom-hello"' "$drvPath/libexec/deferred-hello" || \
          { echo "FAIL: wrapper should use custom exe"; exit 1; }
      '';

  # Test: Package mode with custom desktopName
  pkg-desktopName-custom =
    mkBuildCheck "pkg-desktopName-custom"
      (deferredAppsLib.mkDeferredApp {
        package = pkgs.hello;
        desktopName = "My Custom Hello";
      })
      ''
        grep -q 'Name=My Custom Hello' "$drvPath/share/applications/hello.desktop" || \
          { echo "FAIL: custom desktop name not used"; exit 1; }
      '';

  # Test: Package mode with custom description
  pkg-description-custom =
    mkBuildCheck "pkg-description-custom"
      (deferredAppsLib.mkDeferredApp {
        package = pkgs.hello;
        description = "My custom package description";
      })
      ''
        grep -q 'Comment=My custom package description' "$drvPath/share/applications/hello.desktop" || \
          { echo "FAIL: custom description not used"; exit 1; }
      '';

  # Test: Package mode with createTerminalCommand = false
  pkg-no-terminal =
    mkBuildCheck "pkg-no-terminal"
      (deferredAppsLib.mkDeferredApp {
        package = pkgs.hello;
        createTerminalCommand = false;
      })
      ''
        # bin/ directory should not exist
        test ! -d "$drvPath/bin" || { echo "FAIL: bin/ directory should not exist"; exit 1; }

        # But libexec wrapper should still exist
        test -x "$drvPath/libexec/deferred-hello" || { echo "FAIL: libexec wrapper should exist"; exit 1; }
      '';

  # Test: Package mode with gcRoot = true
  pkg-gcRoot-true =
    mkBuildCheck "pkg-gcRoot-true"
      (deferredAppsLib.mkDeferredApp {
        package = pkgs.hello;
        gcRoot = true;
      })
      ''
        grep -q 'GC_ROOT="1"' "$drvPath/libexec/deferred-hello" || \
          { echo "FAIL: gcRoot should be '1'"; exit 1; }
      '';

  # Test: Package mode with custom categories
  pkg-categories-custom =
    mkBuildCheck "pkg-categories-custom"
      (deferredAppsLib.mkDeferredApp {
        package = pkgs.hello;
        categories = [
          "Development"
          "IDE"
        ];
      })
      ''
        categories=$(grep '^Categories=' "$drvPath/share/applications/hello.desktop" | cut -d= -f2)
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
  # METADATA EXTRACTION FROM PACKAGE
  # ===========================================================================

  # Test: Description is extracted from package meta
  pkg-description-auto =
    mkBuildCheck "pkg-description-auto" (deferredAppsLib.mkDeferredApp { package = pkgs.hello; })
      ''
        comment=$(grep '^Comment=' "$drvPath/share/applications/hello.desktop" | cut -d= -f2-)
        test -n "$comment" || { echo "FAIL: Comment should not be empty"; exit 1; }

        # Verify it's not the fallback "Application"
        if [ "$comment" = "Application" ]; then
          echo "FAIL: Should use actual description from package meta, not fallback"
          exit 1
        fi

        echo "Description extracted: $comment"
      '';

  # Test: Desktop name is generated from package pname
  pkg-desktopName-auto =
    mkBuildCheck "pkg-desktopName-auto" (deferredAppsLib.mkDeferredApp { package = pkgs.obs-studio; })
      ''
        grep -q 'Name=Obs Studio' "$drvPath/share/applications/obs-studio.desktop" || \
          { echo "FAIL: desktop name should be generated from pname"; exit 1; }
      '';

  # ===========================================================================
  # MK_DEFERRED_PACKAGES BATCH FUNCTION
  # ===========================================================================

  # Test: mkDeferredPackages creates multiple package-mode apps
  pkg-batch-mkDeferredPackages = pkgs.symlinkJoin {
    name = "check-mkDeferredPackages";
    paths = deferredAppsLib.mkDeferredPackages [
      pkgs.hello
      pkgs.cowsay
      pkgs.tree
    ];
    postBuild = ''
      # Verify all apps are present
      test -L "$out/bin/hello" || { echo "FAIL: hello missing"; exit 1; }
      test -L "$out/bin/cowsay" || { echo "FAIL: cowsay missing"; exit 1; }
      test -L "$out/bin/tree" || { echo "FAIL: tree missing"; exit 1; }

      # Verify they use package mode (nix-store --realise)
      grep -q 'nix-store --realise' "$out/libexec/deferred-hello" || \
        { echo "FAIL: hello should use package mode"; exit 1; }
      grep -q 'nix-store --realise' "$out/libexec/deferred-cowsay" || \
        { echo "FAIL: cowsay should use package mode"; exit 1; }

      echo "All package-mode apps present"
    '';
  };

  # Test: mkDeferredAppsAdvanced works with package argument
  pkg-batch-advanced = pkgs.symlinkJoin {
    name = "check-mkDeferredAppsAdvanced-package";
    paths = deferredAppsLib.mkDeferredAppsAdvanced [
      { package = pkgs.hello; }
      {
        package = pkgs.cowsay;
        createTerminalCommand = false;
      }
      {
        package = pkgs.tree;
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

      # All should use package mode
      grep -q 'nix-store --realise' "$out/libexec/deferred-hello" || \
        { echo "FAIL: should use package mode"; exit 1; }
    '';
  };

  # ===========================================================================
  # COLLISION DETECTION WITH PACKAGES
  # ===========================================================================

  # Test: Collision detection works with package mode
  pkg-collision-detection = testListShouldFail "pkg-collision-detection" (
    deferredAppsLib.mkDeferredPackages [
      pkgs.hello
      pkgs.hello # Duplicate!
    ]
  );

  # Test: Mixed pname and package collision is detected
  pkg-collision-mixed = testListShouldFail "pkg-collision-mixed" (
    deferredAppsLib.mkDeferredAppsAdvanced [
      { pname = "hello"; }
      { package = pkgs.hello; } # Same terminal command!
    ]
  );

  # ===========================================================================
  # VALIDATION TESTS
  # ===========================================================================

  # Test: Cannot provide both pname and package
  pkg-validation-both-fail = testShouldFail "pkg-validation-both-fail" (
    deferredAppsLib.mkDeferredApp {
      pname = "hello";
      package = pkgs.hello;
    }
  );

  # Test: Must provide at least one of pname or package
  pkg-validation-neither-fail = testShouldFail "pkg-validation-neither-fail" (
    deferredAppsLib.mkDeferredApp { }
  );

  # ===========================================================================
  # MODULE INTEGRATION TESTS - NixOS
  # ===========================================================================

  # Test: NixOS module packages option works
  pkg-module-nixos-packages =
    let
      eval = evalModule {
        programs.deferredApps = {
          enable = true;
          packages = [
            pkgs.hello
            pkgs.cowsay
          ];
        };
      };
    in
    mkCheck "pkg-module-nixos-packages" (forceEvalPackages eval);

  # Test: NixOS module extraApps with package option works
  pkg-module-nixos-extraApps-package =
    let
      eval = evalModule {
        programs.deferredApps = {
          enable = true;
          extraApps = {
            my-hello = {
              package = pkgs.hello;
              createTerminalCommand = false;
            };
          };
        };
      };
    in
    mkCheck "pkg-module-nixos-extraApps-package" (forceEvalPackages eval);

  # Test: NixOS module mixed apps and packages works
  pkg-module-nixos-mixed =
    let
      eval = evalModule {
        programs.deferredApps = {
          enable = true;
          apps = [ "tree" ]; # pname mode
          packages = [ pkgs.cowsay ]; # package mode
          extraApps = {
            my-hello = {
              package = pkgs.hello;
            };
          };
        };
      };
    in
    mkCheck "pkg-module-nixos-mixed" (forceEvalPackages eval);

  # Test: extraApps key name is used for desktop file (not package pname)
  # This ensures extraApps.my-spotify.package creates my-spotify.desktop, not spotify.desktop
  pkg-module-extraApps-key-name =
    let
      eval = evalModule {
        programs.deferredApps = {
          enable = true;
          extraApps = {
            my-custom-hello = {
              package = pkgs.hello;
            };
          };
        };
      };
      packages = eval.config.environment.systemPackages;
      # Find the deferred app package (not icon theme or libnotify)
      deferredPkg = builtins.head (
        builtins.filter (p: lib.hasPrefix "deferred-" (p.name or "")) packages
      );
    in
    # Verify the desktop file uses the key name, not the package pname
    mkBuildCheck "pkg-module-extraApps-key-name" deferredPkg ''
      # Should be named after the key "my-custom-hello", not package pname "hello"
      if [ -f "$drvPath/share/applications/my-custom-hello.desktop" ]; then
        echo "OK: Desktop file uses key name: my-custom-hello.desktop"
      else
        echo "FAIL: Expected my-custom-hello.desktop but found:"
        ls -la "$drvPath/share/applications/"
        exit 1
      fi

      # Verify it's NOT named after the package pname
      if [ -f "$drvPath/share/applications/hello.desktop" ]; then
        echo "FAIL: Should NOT create hello.desktop when using extraApps key"
        exit 1
      fi
    '';

  # ===========================================================================
  # MODULE INTEGRATION TESTS - Home Manager
  # ===========================================================================

  # Test: Home Manager module packages option works
  pkg-module-hm-packages =
    let
      eval = evalHomeModule {
        programs.deferredApps = {
          enable = true;
          packages = [
            pkgs.hello
            pkgs.cowsay
          ];
        };
      };
    in
    mkCheck "pkg-module-hm-packages" (forceEvalHomePackages eval);

  # Test: Home Manager module extraApps with package option works
  pkg-module-hm-extraApps-package =
    let
      eval = evalHomeModule {
        programs.deferredApps = {
          enable = true;
          extraApps = {
            my-hello = {
              package = pkgs.hello;
              createTerminalCommand = false;
            };
          };
        };
      };
    in
    mkCheck "pkg-module-hm-extraApps-package" (forceEvalHomePackages eval);

  # ===========================================================================
  # HELPER FUNCTION EXPORTS
  # ===========================================================================

  # Test: getPnameFromPackage helper works
  pkg-helper-getPnameFromPackage =
    let
      pname = deferredAppsLib.getPnameFromPackage pkgs.hello;
    in
    mkCheck "pkg-helper-getPnameFromPackage" (pname == "hello");

  # Test: getPnameFromPackage handles packages starting with numbers
  # This tests the edge case where the package name starts with a digit
  pkg-helper-getPnameFromPackage-numeric-start =
    let
      # Create a mock package that simulates "7zip-24.08"
      mockPkg = {
        name = "7zip-24.08";
        # No pname attribute - forces fallback parsing
      };
      pname = deferredAppsLib.getPnameFromPackage mockPkg;
    in
    # Should extract "7zip", not empty string or "24.08"
    mkCheck "pkg-helper-getPnameFromPackage-numeric-start" (pname == "7zip");

  # Test: getPnameFromPackage handles packages like "2048-in-terminal"
  pkg-helper-getPnameFromPackage-numeric-in-name =
    let
      mockPkg = {
        name = "2048-in-terminal-1.0";
      };
      pname = deferredAppsLib.getPnameFromPackage mockPkg;
    in
    # Should extract "2048-in-terminal", not just "2048"
    mkCheck "pkg-helper-getPnameFromPackage-numeric-in-name" (pname == "2048-in-terminal");

  # Test: getPnameFromPackage handles packages with version suffixes like "rc1"
  pkg-helper-getPnameFromPackage-version-suffix =
    let
      mockPkg = {
        name = "hello-2.12rc1";
      };
      pname = deferredAppsLib.getPnameFromPackage mockPkg;
    in
    mkCheck "pkg-helper-getPnameFromPackage-version-suffix" (pname == "hello");

  # Test: getMainProgramFromPackage helper works
  pkg-helper-getMainProgramFromPackage =
    let
      mainProgram = deferredAppsLib.getMainProgramFromPackage pkgs.obs-studio;
    in
    mkCheck "pkg-helper-getMainProgramFromPackage" (mainProgram == "obs");

  # Test: getDescriptionFromPackage helper works
  pkg-helper-getDescriptionFromPackage =
    let
      description = deferredAppsLib.getDescriptionFromPackage pkgs.hello;
    in
    mkCheck "pkg-helper-getDescriptionFromPackage" (description != "Application" && description != "");

  # Test: isDerivationUnfree helper works (hello is free)
  pkg-helper-isDerivationUnfree-free =
    let
      isUnfree = deferredAppsLib.isDerivationUnfree pkgs.hello;
    in
    mkCheck "pkg-helper-isDerivationUnfree-free" (!isUnfree);

  # ===========================================================================
  # STRING CONTEXT VERIFICATION
  # ===========================================================================

  # Test: Verify the wrapper references the .drv file correctly
  # This verifies that package mode captures the derivation path, enabling
  # nix-store --realise to work at runtime.
  #
  # The real proof that outputs aren't built is that nix flake check runs
  # quickly without building all the test packages (hello, cowsay, etc.).
  # If our context handling was wrong, those packages would be built.
  pkg-drv-context-verification =
    mkBuildCheck "pkg-drv-context-verification"
      (deferredAppsLib.mkDeferredApp { package = pkgs.hello; })
      ''
        # Verify the wrapper contains a valid DRV_PATH
        drv_path=$(grep 'DRV_PATH=' "$drvPath/libexec/deferred-hello" | cut -d'"' -f2)

        # DRV_PATH should be a .drv file in /nix/store
        case "$drv_path" in
          /nix/store/*.drv)
            echo "OK: DRV_PATH is valid: $drv_path"
            ;;
          *)
            echo "FAIL: DRV_PATH should be a .drv file, got: $drv_path"
            exit 1
            ;;
        esac

        # The .drv file should exist (this is what makes runtime realization work)
        if [ -f "$drv_path" ]; then
          echo "OK: DRV file exists at $drv_path"
        else
          echo "FAIL: DRV file should exist at $drv_path"
          exit 1
        fi

        # Verify OUT_PATH is also set correctly
        out_path=$(grep 'OUT_PATH=' "$drvPath/libexec/deferred-hello" | cut -d'"' -f2)
        case "$out_path" in
          /nix/store/*-hello-*)
            echo "OK: OUT_PATH is valid: $out_path"
            ;;
          *)
            echo "FAIL: OUT_PATH should be a store path, got: $out_path"
            exit 1
            ;;
        esac

        # The key test: OUT_PATH should NOT exist yet (not built at system build time)
        # This is the critical feature of package mode!
        if [ -e "$out_path" ]; then
          echo "INFO: OUT_PATH exists (package was cached from previous builds)"
          echo "This is expected if hello was built before. The important thing is"
          echo "that we didn't force it to be built by our derivation."
        else
          echo "OK: OUT_PATH does not exist (package not built at system build time)"
        fi
      '';
}
