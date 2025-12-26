# Deferred Apps - Shared Module Factory
#
# This module factory generates NixOS or Home Manager modules from a single
# source of truth. Options are defined once; only the config implementation
# differs between targets.
#
# Usage:
#   # For NixOS:
#   import ./shared.nix { target = "nixos"; }
#
#   # For Home Manager:
#   import ./shared.nix { target = "home-manager"; }
#
# This pattern ensures:
#   - Options are defined exactly once (no drift between NixOS/HM)
#   - Adding new options requires editing only this file
#   - Target-specific behavior is explicit and localized
#   - Future targets (nix-darwin?) need only a new thin wrapper
#
{ target }:

assert builtins.elem target [
  "nixos"
  "home-manager"
];

{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.programs.deferredApps;

  # Import the deferred apps library with icon theme configuration
  # Icon resolution happens at BUILD TIME (inside derivations) to:
  # 1. Avoid derivation references at evaluation time (CI/CD compatible)
  # 2. Produce absolute icon paths that work regardless of user's DE theme
  deferredAppsLib = import ../package.nix {
    inherit pkgs lib;
    iconThemePackage = cfg.iconTheme.package;
    iconThemeName = cfg.iconTheme.name;
  };

  # ===========================================================================
  # Shared Options (identical for NixOS and Home Manager)
  # ===========================================================================

  # Submodule for extraApps configuration
  extraAppModule = lib.types.submodule {
    options = {
      package = lib.mkOption {
        type = lib.types.nullOr lib.types.package;
        default = null;
        example = lib.literalExpression "pkgs-unstable.spotify";
        description = ''
          Direct package derivation to use for this app.

          When provided, the package is used directly instead of looking up
          by attribute name. This enables:
          - Using packages from custom nixpkgs instances (e.g., unstable)
          - Packages with overlays applied
          - Packages pinned to your flake.lock

          The package is NOT built at system build time. Only the derivation
          file (.drv) is captured, and the actual package is realized on
          first launch.

          Note: When `package` is provided, `flakeRef` and `allowUnfree` are
          ignored since the package source is already determined.
        '';
      };

      exe = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Executable name (overrides auto-detection).";
      };

      desktopName = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Display name in launcher (overrides auto-generation).";
      };

      description = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Application description (overrides auto-detection).";
      };

      icon = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Icon name for desktop entry (defaults to package name).";
      };

      categories = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ "Application" ];
        example = [
          "AudioVideo"
          "Audio"
        ];
        description = "Freedesktop.org desktop entry categories.";
      };

      createTerminalCommand = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Whether to create a terminal command for this application.

          When enabled (default), you can launch the app by typing its
          executable name in a terminal (e.g., "spotify").

          Disable this if you only want the application accessible via
          the desktop launcher/GUI, not from the command line.
        '';
      };

      allowUnfree = lib.mkOption {
        type = lib.types.nullOr lib.types.bool;
        default = null;
        description = ''
          Override the global `allowUnfree` setting for this specific app.

          If null (default), uses the global `allowUnfree` option.
          Set to `true` to allow this specific unfree package.
          Set to `false` to require this package to be free.

          Note: This is ignored when `package` is provided.
        '';
      };

      gcRoot = lib.mkOption {
        type = lib.types.nullOr lib.types.bool;
        default = null;
        description = ''
          Override the global `gcRoot` setting for this specific app.

          If null (default), uses the global `gcRoot` option.
        '';
      };

      flakeRef = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "github:user/repo";
        description = ''
          Flake reference for this specific app.

          Use this when the package comes from a different flake than
          the default. For example, packages from your own flake's
          overlay (like sandboxed apps) need to reference your flake
          instead of nixpkgs.

          If null (default), uses the global `flakeRef` option.

          Note: This is ignored when `package` is provided.
        '';
      };
    };
  };

  # ===========================================================================
  # Shared Package Building Logic
  # ===========================================================================

  # Build the list of deferred app packages (shared between NixOS and HM)
  buildDeferredPackages =
    let
      # Names configured in extraApps (these take precedence over apps list)
      extraNames = lib.attrNames cfg.extraApps;

      # Filter out apps that have extraApps overrides
      filteredApps = lib.filter (name: !(lib.elem name extraNames)) cfg.apps;

      # Separate extraApps into pname-mode and package-mode entries
      extraAppsWithPackage = lib.filterAttrs (_: opts: opts.package != null) cfg.extraApps;
      extraAppsWithPname = lib.filterAttrs (_: opts: opts.package == null) cfg.extraApps;

      # Build config list for collision detection
      # Includes: apps (pname), packages (direct), extraApps (both modes)
      allAppConfigs =
        # Standard apps (pname mode)
        (map (pname: {
          inherit pname;
          createTerminalCommand = true;
        }) filteredApps)
        # Global packages list (package mode)
        ++ (map (package: {
          inherit package;
          createTerminalCommand = true;
        }) cfg.packages)
        # extraApps with pname mode
        ++ (lib.mapAttrsToList (pname: opts: {
          inherit pname;
          inherit (opts) exe createTerminalCommand;
        }) extraAppsWithPname)
        # extraApps with package mode - use key name as pnameOverride
        ++ (lib.mapAttrsToList (name: opts: {
          inherit (opts) package exe createTerminalCommand;
          pnameOverride = name;  # Use key name for collision detection
        }) extraAppsWithPackage);

      # Check for terminal command collisions across ALL apps
      collision = deferredAppsLib.detectTerminalCollisions allAppConfigs;

      # Build standard apps (pname mode, auto-detected metadata)
      standardApps = map (
        pname:
        deferredAppsLib.mkDeferredApp {
          inherit pname;
          inherit (cfg) flakeRef allowUnfree gcRoot;
        }
      ) filteredApps;

      # Build global packages list (package mode)
      packageApps = map (
        package:
        deferredAppsLib.mkDeferredApp {
          inherit package;
          inherit (cfg) gcRoot;
        }
      ) cfg.packages;

      # Build extra apps with pname mode (manual configuration)
      extraAppsListPname = lib.mapAttrsToList (
        pname: opts:
        deferredAppsLib.mkDeferredApp {
          inherit pname;
          inherit (opts)
            exe
            desktopName
            description
            icon
            categories
            createTerminalCommand
            ;
          # Use per-app settings if specified, otherwise fall back to global
          flakeRef = if opts.flakeRef != null then opts.flakeRef else cfg.flakeRef;
          allowUnfree = if opts.allowUnfree != null then opts.allowUnfree else cfg.allowUnfree;
          gcRoot = if opts.gcRoot != null then opts.gcRoot else cfg.gcRoot;
        }
      ) extraAppsWithPname;

      # Build extra apps with package mode (direct package reference)
      # Note: We pass the key name as pnameOverride so the desktop file uses
      # the user's chosen name (e.g., "spotify-unstable") instead of the
      # package's pname (e.g., "spotify"). This prevents collisions when
      # the same package is referenced with different keys.
      extraAppsListPackage = lib.mapAttrsToList (
        name: opts:
        deferredAppsLib.mkDeferredApp {
          inherit (opts)
            package
            exe
            desktopName
            description
            icon
            categories
            createTerminalCommand
            ;
          # Use the key name as pname for desktop file naming
          # This prevents collisions like apps=["spotify"] + extraApps.spotify-unstable.package
          pnameOverride = name;
          # gcRoot can still be overridden per-app
          gcRoot = if opts.gcRoot != null then opts.gcRoot else cfg.gcRoot;
          # Note: flakeRef and allowUnfree are ignored in package mode
        }
      ) extraAppsWithPackage;

      # Icon theme package (if enabled)
      iconThemePackages = lib.optional cfg.iconTheme.enable cfg.iconTheme.package;

    in
    # Assert no terminal command collisions before building
    assert lib.assertMsg (collision == null) collision;
    standardApps
    ++ packageApps
    ++ extraAppsListPname
    ++ extraAppsListPackage
    ++ iconThemePackages
    ++ [
      pkgs.libnotify # Required for notifications
    ];

in
{
  # ===========================================================================
  # Options (shared between NixOS and Home Manager)
  # ===========================================================================

  options.programs.deferredApps = {
    enable = lib.mkEnableOption "deferred applications that download on first launch";

    apps = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [
        "spotify"
        "obs-studio"
        "discord"
        "blender"
        "python313Packages.numpy"
      ];
      description = ''
        List of nixpkgs package names to create deferred launchers for.

        These applications appear in your desktop launcher immediately,
        but only download when you first click them.

        Supports nested packages with dot notation:
        - `python313Packages.numpy`
        - `haskellPackages.pandoc`
        - `nodePackages.typescript`

        Executable names are automatically detected from package metadata.
        For example, "obs-studio" correctly launches "obs", and "discord"
        correctly launches "Discord" (with capital D).

        Note: For unfree packages (spotify, discord, etc.), you must set
        `allowUnfree = true`.
      '';
    };

    flakeRef = lib.mkOption {
      type = lib.types.str;
      default = "nixpkgs";
      example = "github:NixOS/nixpkgs/nixos-unstable";
      description = ''
        Flake reference used when downloading packages at runtime.

        The default "nixpkgs" uses the registry's nixpkgs (usually the
        system flake's nixpkgs). Pin to a specific revision for reproducibility:

        ```nix
        flakeRef = "github:NixOS/nixpkgs/nixos-25.11";
        ```
      '';
    };

    allowUnfree = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Allow unfree packages (spotify, discord, steam, etc.).

        > **Security Warning**: Enabling this uses `--impure` mode for unfree
        > packages, which allows environment variables to affect the build.
        > This is required because `NIXPKGS_ALLOW_UNFREE=1` must be set at
        > evaluation time.
        >
        > Free packages always use pure mode regardless of this setting.

        If you only use free packages, leave this disabled for better security.
      '';
    };

    gcRoot = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Create GC roots for downloaded packages.

        When enabled, packages downloaded by deferred apps are protected
        from garbage collection. This prevents re-downloads after
        `nix-collect-garbage`, but requires manual cleanup.

        GC roots are stored in `~/.local/share/deferred-apps/gcroots/`.
        To clean up: `rm -rf ~/.local/share/deferred-apps/gcroots/`
      '';
    };

    iconTheme = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Whether to install an icon theme that includes icons for common applications.

          Deferred apps don't install the actual packages (that's the point!), so their
          icons aren't available by default. This option installs Papirus icon theme
          which includes icons for most popular applications like Spotify, Discord, OBS, etc.

          Disable this if you already have an icon theme configured${
            if target == "home-manager" then " via Home Manager's gtk.iconTheme" else " system-wide"
          }.
        '';
      };

      package = lib.mkOption {
        type = lib.types.package;
        default = pkgs.papirus-icon-theme;
        defaultText = lib.literalExpression "pkgs.papirus-icon-theme";
        description = ''
          The icon theme package to install.

          Must be a freedesktop.org-compliant icon theme that includes
          application icons in share/icons/*/apps/.
        '';
      };

      name = lib.mkOption {
        type = lib.types.str;
        default = "Papirus-Dark";
        example = "Papirus";
        description = ''
          The icon theme name to use.

          This should match a directory name in the icon theme package.
          Common values for Papirus: "Papirus", "Papirus-Dark", "Papirus-Light".
        '';
      };
    };

    packages = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [ ];
      example = lib.literalExpression ''
        [
          pkgs-unstable.spotify
          myOverlay.discord
          inputs.some-flake.packages.''${system}.custom-app
        ]
      '';
      description = ''
        List of package derivations to create deferred launchers for.

        Unlike `apps` (which takes package names and uses `nix shell` at runtime),
        `packages` takes actual package derivations directly. This enables:

        - **Custom nixpkgs instances**: Use packages from nixpkgs-unstable or
          other nixpkgs variants with your overlays applied.
        - **Flake.lock pinning**: Packages are pinned to the exact versions in
          your flake.lock, ensuring reproducibility.
        - **Overlays**: Your custom overlays are respected since you're passing
          the actual package.

        At system build time, only the derivation file (.drv) is captured - the
        package outputs are NOT built. On first launch, `nix-store --realise` is
        used to download/build the package.

        Note: `allowUnfree` is not needed for packages passed here, as the
        license check happens when you reference the package in your flake.
      '';
    };

    extraApps = lib.mkOption {
      type = lib.types.attrsOf extraAppModule;
      default = { };
      example = lib.literalExpression ''
        {
          # Package with non-standard executable
          my-custom-app = {
            exe = "custom-binary";
            desktopName = "My Custom App";
            description = "A custom application";
            categories = [ "Development" ];
          };

          # Override auto-detected values
          some-package = {
            icon = "custom-icon-name";
          };

          # GUI-only app (no terminal command)
          spotify = {
            createTerminalCommand = false;
          };

          # Package from a custom flake (e.g., sandboxed apps from your config)
          spotify-sandboxed = {
            flakeRef = "/path/to/your/flake";
          };

          # Direct package reference with custom options
          spotify-unstable = {
            package = pkgs-unstable.spotify;
            createTerminalCommand = false;
          };
        }
      '';
      description = ''
        Additional deferred apps with manual configuration.

        Use this for:
        - Packages not in nixpkgs (use `flakeRef` to specify the source)
        - Overriding auto-detected executable names
        - Custom icons or categories
        - Direct package references with custom options (use `package`)

        If a package appears in both `apps` and `extraApps`, the
        `extraApps` configuration takes precedence.

        When `package` is provided, `flakeRef` and `allowUnfree` are ignored.
      '';
    };
  };

  # ===========================================================================
  # Config (target-specific implementation)
  # ===========================================================================

  config = lib.mkIf cfg.enable (
    if target == "nixos" then
      # -------------------------------------------------------------------------
      # NixOS Configuration
      # -------------------------------------------------------------------------
      {
        environment = {
          systemPackages = buildDeferredPackages;

          # Link desktop entries and icons into system profile
          pathsToLink = [
            "/share/applications"
            "/share/icons"
          ];

          # Set the icon theme via environment variable as fallback
          # Desktop environments typically have their own settings, but this helps
          # applications that read XDG_CURRENT_DESKTOP or use gtk-icon-theme-name
          variables = lib.mkIf cfg.iconTheme.enable {
            # This is a hint for applications; DE settings take precedence
            GTK_ICON_THEME = lib.mkDefault cfg.iconTheme.name;
          };
        };
      }
    else
      # -------------------------------------------------------------------------
      # Home Manager Configuration
      # -------------------------------------------------------------------------
      {
        home.packages = buildDeferredPackages;

        # Home Manager automatically links share/applications and share/icons
        # from packages in home.packages, so no pathsToLink equivalent needed.

        # Set GTK icon theme via session variable
        # Users may prefer to use gtk.iconTheme instead for better integration
        home.sessionVariables = lib.mkIf cfg.iconTheme.enable {
          GTK_ICON_THEME = lib.mkDefault cfg.iconTheme.name;
        };
      }
  );
}
