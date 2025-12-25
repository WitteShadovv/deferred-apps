# Deferred Apps - NixOS Module
#
# Apps appear in your launcher but only download when first launched.
#
# Example:
#   programs.deferredApps = {
#     enable = true;
#     apps = [ "spotify" "obs-studio" "discord" "blender" ];
#     allowUnfree = true;  # Required for spotify, discord
#   };
#
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
  deferredAppsLib = import ./package.nix {
    inherit pkgs lib;
    iconThemePackage = cfg.iconTheme.package;
    iconThemeName = cfg.iconTheme.name;
  };

in
{
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
        flakeRef = "github:NixOS/nixpkgs/nixos-24.11";
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

          Disable this if you already have an icon theme configured system-wide.
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

    extraApps = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
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
              '';
            };
          };
        }
      );
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
        }
      '';
      description = ''
        Additional deferred apps with manual configuration.

        Use this for:
        - Packages not in nixpkgs (use `flakeRef` to specify the source)
        - Overriding auto-detected executable names
        - Custom icons or categories

        If a package appears in both `apps` and `extraApps`, the
        `extraApps` configuration takes precedence.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    environment = {
      systemPackages =
        let
          # Names configured in extraApps (these take precedence)
          extraNames = lib.attrNames cfg.extraApps;

          # Filter out apps that have extraApps overrides
          filteredApps = lib.filter (name: !(lib.elem name extraNames)) cfg.apps;

          # Build config list for collision detection
          # Standard apps default to createTerminalCommand = true
          allAppConfigs =
            (map (pname: {
              inherit pname;
              createTerminalCommand = true;
            }) filteredApps)
            ++ (lib.mapAttrsToList (pname: opts: {
              inherit pname;
              inherit (opts) exe createTerminalCommand;
            }) cfg.extraApps);

          # Check for terminal command collisions across ALL apps
          collision = deferredAppsLib.detectTerminalCollisions allAppConfigs;

          # Build standard apps (auto-detected metadata)
          standardApps = map (
            pname:
            deferredAppsLib.mkDeferredApp {
              inherit pname;
              inherit (cfg) flakeRef allowUnfree gcRoot;
            }
          ) filteredApps;

          # Build extra apps (manual configuration)
          extraAppsList = lib.mapAttrsToList (
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
          ) cfg.extraApps;

          # Icon theme package (if enabled)
          iconThemePackages = lib.optional cfg.iconTheme.enable cfg.iconTheme.package;

        in
        # Assert no terminal command collisions before building
        assert lib.assertMsg (collision == null) collision;
        standardApps
        ++ extraAppsList
        ++ iconThemePackages
        ++ [
          pkgs.libnotify # Required for notifications
        ];

      # Link desktop entries and icons
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
  };
}
