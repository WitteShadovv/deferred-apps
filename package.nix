# Deferred Apps - Package Builder
#
# Creates lightweight wrappers that appear as installed apps but only
# download the actual package on first launch via `nix shell`.
#
# Key feature: Automatically detects executable names from nixpkgs metadata.
# Example: obs-studio -> "obs", discord -> "discord", vscode -> "code"
#
# Nested Packages: Supports dot-notation for nested package sets.
# Example: python313Packages.numpy, haskellPackages.pandoc, nodePackages.typescript
#
# Terminal commands are normalized to lowercase for Unix convention.
# The actual binary name (from meta.mainProgram) is used internally.
#
# Usage:
#   mkDeferredApp { pname = "spotify"; }                            # Auto-detect exe
#   mkDeferredApp { pname = "python313Packages.numpy"; }            # Nested package
#   mkDeferredApp { pname = "my-app"; exe = "custom"; }             # Manual override
#   mkDeferredApps [ "spotify" "discord" "python313Packages.numpy" ] # Multiple apps
#
# Icon Resolution:
#   Icons are resolved at BUILD TIME (inside derivations) to absolute paths
#   from the configured icon theme (Papirus-Dark by default). This ensures:
#   1. CI/CD compatibility - no derivation references at evaluation time
#   2. Icons work regardless of user's DE icon theme (e.g., Yaru lacks Spotify)
#
#   The desktop file gets an absolute path to the icon in the Nix store.
#   This bypasses DE theme lookup, guaranteeing the icon displays correctly.
#
# Security:
#   - Free packages: Use pure `nix shell` (no environment variable influence)
#   - Unfree packages: Require explicit opt-in via `allowUnfree = true`
#   - GC roots: Created automatically to prevent unexpected re-downloads
#
# Note for overlay/library users:
#   The wrapper script uses `notify-send` for download notifications.
#   If you're not using the NixOS module (which includes libnotify),
#   ensure libnotify is available in your environment for notifications to work.
#   The wrapper gracefully degrades if notify-send is unavailable.
{
  pkgs,
  lib,
  iconThemePackage ? pkgs.papirus-icon-theme,
  iconThemeName ? "Papirus-Dark",
}:

let
  inherit (pkgs) runCommand writeText makeDesktopItem;

  # ===========================================================================
  # Input Validation
  # ===========================================================================

  # Validate a single segment of pname (between dots)
  validatePnameSegment =
    segment: pname:
    assert lib.assertMsg (segment != "") "deferred-apps: pname segment cannot be empty (got: ${pname})";
    assert lib.assertMsg (
      !(lib.hasInfix "/" segment)
    ) "deferred-apps: pname cannot contain '/' (got: ${pname})";
    assert lib.assertMsg (
      !(lib.hasInfix " " segment)
    ) "deferred-apps: pname cannot contain spaces (got: ${pname})";
    assert lib.assertMsg (
      !(lib.hasPrefix "-" segment)
    ) "deferred-apps: pname segment cannot start with '-' (got: ${pname})";
    segment;

  # Validate pname to catch common errors early
  # Supports both simple names ("hello") and nested packages ("python313Packages.numpy")
  validatePname =
    pname:
    let
      # Split by dots to validate each segment
      segments = lib.splitString "." pname;
      # Validate each segment
      validatedSegments = map (seg: validatePnameSegment seg pname) segments;
    in
    assert lib.assertMsg (pname != "") "deferred-apps: pname cannot be empty";
    assert lib.assertMsg (
      !(lib.hasPrefix "." pname)
    ) "deferred-apps: pname cannot start with '.' (got: ${pname})";
    assert lib.assertMsg (
      !(lib.hasSuffix "." pname)
    ) "deferred-apps: pname cannot end with '.' (got: ${pname})";
    # Force evaluation of all segment validations
    builtins.seq (builtins.deepSeq validatedSegments validatedSegments) pname;

  # ===========================================================================
  # Metadata Extraction (from nixpkgs, no build required)
  # ===========================================================================

  # Parse pname into attribute path segments
  # "python313Packages.numpy" -> ["python313Packages" "numpy"]
  # "hello" -> ["hello"]
  parsePname = pname: lib.splitString "." pname;

  # Get package by navigating nested attributes
  # Supports both simple ("hello") and nested ("python313Packages.numpy") paths
  getPackage =
    pname:
    let
      path = parsePname pname;
    in
    lib.attrByPath path null pkgs;

  # Validate package exists with helpful error
  requirePackage =
    pname:
    let
      pkg = getPackage pname;
      isNested = lib.hasInfix "." pname;
    in
    if pkg == null then
      throw ''
        deferred-apps: Package '${pname}' not found in nixpkgs.
        ${
          if isNested then
            "Nested package path checked: ${lib.concatStringsSep " -> " (parsePname pname)}"
          else
            "Check the spelling or use 'extraApps' with manual configuration."
        }
      ''
    else
      pkg;

  # Extract mainProgram from package meta (e.g., obs-studio -> "obs")
  # This is evaluated lazily - no package build is triggered
  getMainProgram = pname: (requirePackage pname).meta.mainProgram or pname;

  # Extract description from package meta
  getDescription =
    pname:
    let
      pkg = getPackage pname;
    in
    if pkg == null then "Application" else pkg.meta.description or "Application";

  # Check if a package is unfree (requires --impure with NIXPKGS_ALLOW_UNFREE)
  # Handles packages with single license or list of licenses (dual-licensed)
  isPackageUnfree =
    pname:
    let
      pkg = getPackage pname;
      # Normalize to list - some packages have single license, some have a list
      licenses = lib.toList (pkg.meta.license or [ ]);
      # Package is unfree if ANY license is unfree
      hasUnfreeLicense = lib.any (l: !(l.free or true)) licenses;
    in
    if pkg == null then
      false # Assume free for unknown packages
    else
      hasUnfreeLicense;

  # ===========================================================================
  # String Utilities
  # ===========================================================================

  # "foo" -> "Foo"
  capitalize =
    s:
    let
      first = lib.substring 0 1 s;
      rest = lib.substring 1 (-1) s;
    in
    lib.toUpper first + rest;

  # "obs-studio" -> "Obs Studio"
  toDisplayName =
    pname:
    lib.pipe pname [
      (lib.splitString "-")
      (map capitalize)
      (lib.concatStringsSep " ")
    ];

  # ===========================================================================
  # Build-time Icon Resolution
  # ===========================================================================

  # Icon sizes to search, in order of preference
  # 64x64 is ideal for app launchers, scalable SVGs are good too
  iconSizesList = "64x64 scalable 48x48 128x128 96x96 256x256 32x32 24x24 22x22 16x16";

  # ===========================================================================
  # Public API
  # ===========================================================================

  # Create a single deferred application
  #
  # Required:
  #   pname       - nixpkgs attribute name (e.g., "spotify", "obs-studio")
  #                 Supports nested packages with dot notation:
  #                 "python313Packages.numpy", "haskellPackages.pandoc", etc.
  #
  # Optional (auto-detected from nixpkgs metadata):
  #   exe                   - executable name (from meta.mainProgram)
  #   desktopName           - display name (generated from pname)
  #   description           - app description (from meta.description)
  #   icon                  - icon name or path for desktop entry (auto-resolved from theme)
  #   categories            - freedesktop.org categories (defaults to ["Application"])
  #   flakeRef              - flake reference for nix shell (defaults to "nixpkgs")
  #   createTerminalCommand - create terminal command symlink (defaults to true)
  #   allowUnfree           - allow unfree packages (enables --impure, defaults to false)
  #   gcRoot                - create GC root to prevent garbage collection (defaults to false)
  #
  # Icon Resolution:
  #   Icons are resolved at BUILD TIME to absolute paths from the configured
  #   icon theme (Papirus-Dark by default). This ensures icons display correctly
  #   regardless of the user's selected icon theme (e.g., Yaru doesn't include
  #   third-party app icons like Spotify, Discord, etc.).
  #
  mkDeferredApp =
    {
      pname,
      exe ? null,
      desktopName ? null,
      description ? null,
      icon ? null,
      categories ? [ "Application" ],
      flakeRef ? "nixpkgs",
      createTerminalCommand ? true,
      allowUnfree ? false,
      gcRoot ? false,
    }:
    let
      # Validate pname first
      validatedPname = validatePname pname;

      # Resolve with auto-detection fallbacks
      # finalExe is the actual binary name inside the package (used with nix shell --command)
      # This must match exactly what the package provides (e.g., "Discord" not "discord")
      finalExe = if exe != null then exe else getMainProgram validatedPname;

      # Terminal command is the user-facing symlink name
      # Normalized to lowercase for Unix convention (users expect to type "discord" not "Discord")
      terminalCommand = lib.toLower finalExe;

      finalDesktopName = if desktopName != null then desktopName else toDisplayName validatedPname;
      finalDescription = if description != null then description else getDescription validatedPname;

      # Security: Check if package is unfree and validate allowUnfree
      packageIsUnfree = isPackageUnfree validatedPname;
      needsImpure = packageIsUnfree && allowUnfree;

      # Icon name to search for (user override or package name)
      # Also try mainProgram as fallback (e.g., obs-studio -> obs)
      iconName = if icon != null then icon else validatedPname;
      iconNameFallback = finalExe;

      # Check if user provided an absolute path
      iconIsAbsolutePath = icon != null && lib.hasPrefix "/" icon;

      # Create the wrapper script content
      # Using @-style placeholders for substitute
      wrapperScript = writeText "deferred-${validatedPname}-wrapper" ''
        #!/usr/bin/env bash
        set -euo pipefail

        PNAME="@pname@"
        FLAKE_REF="@flakeRef@"
        EXE="@exe@"
        ICON="@icon@"
        NEEDS_IMPURE="@needsImpure@"
        GC_ROOT="@gcRoot@"

        # GC root directory for this user
        GC_ROOT_DIR="''${XDG_DATA_HOME:-$HOME/.local/share}/deferred-apps/gcroots"

        # Show notification (only if not already cached)
        # We check for the GC root as a proxy for "already downloaded"
        maybe_notify() {
          if [ "$GC_ROOT" = "1" ] && [ -L "$GC_ROOT_DIR/$PNAME" ]; then
            return  # Already have GC root, skip notification
          fi
          if command -v notify-send &>/dev/null; then
            notify-send \
              --app-name="Deferred Apps" \
              --urgency=low \
              --icon="$ICON" \
              "Starting $PNAME..." \
              "Downloading application (first run only)..." &
          fi
        }

        # Ensure package is downloaded and create GC root
        # nix build is smart about caching - it won't re-download if already present
        ensure_downloaded() {
          local build_args=("$FLAKE_REF#$PNAME" "--no-link" "--print-out-paths")

          if [ "$NEEDS_IMPURE" = "1" ]; then
            export NIXPKGS_ALLOW_UNFREE=1
            build_args=("--impure" "''${build_args[@]}")
          fi

          local store_path
          store_path=$(nix build "''${build_args[@]}" 2>/dev/null) || return 0

          # Create GC root to prevent garbage collection
          if [ "$GC_ROOT" = "1" ] && [ -n "$store_path" ]; then
            mkdir -p "$GC_ROOT_DIR"
            nix-store --add-root "$GC_ROOT_DIR/$PNAME" --indirect -r "$store_path" &>/dev/null || true
          fi
        }

        # Main execution
        maybe_notify
        ensure_downloaded

        # Run the application
        if [ "$NEEDS_IMPURE" = "1" ]; then
          export NIXPKGS_ALLOW_UNFREE=1
          exec nix shell --impure "$FLAKE_REF#$PNAME" --command "$EXE" "$@"
        else
          exec nix shell "$FLAKE_REF#$PNAME" --command "$EXE" "$@"
        fi
      '';

      # Create the .desktop file using nixpkgs' makeDesktopItem for proper escaping
      desktopItem = makeDesktopItem {
        name = validatedPname;
        exec = "@out@/libexec/deferred-${validatedPname} %U";
        icon = "@icon@"; # Placeholder, will be substituted
        comment = finalDescription;
        desktopName = finalDesktopName;
        inherit categories;
        terminal = false;
        startupNotify = true;
        startupWMClass = finalExe;
      };

    in
    # Error if unfree package without explicit opt-in
    assert lib.assertMsg (!packageIsUnfree || allowUnfree)
      "deferred-apps: Package '${validatedPname}' is unfree. Set 'allowUnfree = true' to enable it (uses --impure).";
    runCommand "deferred-${validatedPname}"
      {
        inherit
          validatedPname
          finalExe
          flakeRef
          iconName
          iconNameFallback
          wrapperScript
          desktopItem
          terminalCommand
          ;
        iconThemePath = "${iconThemePackage}/share/icons/${iconThemeName}";
        iconSizes = iconSizesList;
        userIcon = if iconIsAbsolutePath then icon else "";
        createTerminal = if createTerminalCommand then "1" else "";
        needsImpureStr = if needsImpure then "1" else "0";
        gcRootStr = if gcRoot then "1" else "0";
      }
      ''
        # ===========================================================================
        # Build-time icon resolution
        # ===========================================================================

        # Function to find icon in theme
        find_icon() {
          local name="$1"
          local theme_path="$iconThemePath"

          # Search in each size directory
          for size in $iconSizes; do
            local icon_path="$theme_path/$size/apps/$name.svg"
            if [ -e "$icon_path" ]; then
              # Resolve symlinks to get the real path
              readlink -f "$icon_path"
              return 0
            fi
          done
          return 1
        }

        # Resolve the icon
        if [ -n "$userIcon" ]; then
          # User provided absolute path - use it directly
          RESOLVED_ICON="$userIcon"
        else
          # Try to find icon in theme
          if RESOLVED_ICON=$(find_icon "$iconName"); then
            : # Found with primary name
          elif RESOLVED_ICON=$(find_icon "$iconNameFallback"); then
            : # Found with fallback name (mainProgram)
          else
            # Fallback to icon name (let DE resolve it)
            echo "WARNING: Icon '$iconName' not found in theme. Desktop may show missing icon." >&2
            RESOLVED_ICON="$iconName"
          fi
        fi

        # Create output directories
        mkdir -p "$out/libexec" "$out/share/applications"

        # ===========================================================================
        # Create the wrapper script (in libexec, not directly in bin)
        # ===========================================================================
        substitute "$wrapperScript" "$out/libexec/deferred-$validatedPname" \
          --replace-fail '@icon@' "$RESOLVED_ICON" \
          --replace-fail '@pname@' "$validatedPname" \
          --replace-fail '@flakeRef@' "$flakeRef" \
          --replace-fail '@exe@' "$finalExe" \
          --replace-fail '@needsImpure@' "$needsImpureStr" \
          --replace-fail '@gcRoot@' "$gcRootStr"

        chmod +x "$out/libexec/deferred-$validatedPname"

        # ===========================================================================
        # Create the .desktop file (copy from makeDesktopItem and substitute)
        # ===========================================================================
        cp "$desktopItem/share/applications/$validatedPname.desktop" \
           "$out/share/applications/$validatedPname.desktop"

        substitute "$out/share/applications/$validatedPname.desktop" \
                   "$out/share/applications/$validatedPname.desktop.tmp" \
          --replace-fail '@out@' "$out" \
          --replace-fail '@icon@' "$RESOLVED_ICON"

        mv "$out/share/applications/$validatedPname.desktop.tmp" \
           "$out/share/applications/$validatedPname.desktop"

        # ===========================================================================
        # Create terminal command symlink (optional)
        # Only creates bin/ directory and symlinks when terminal commands are enabled
        # ===========================================================================
        if [ -n "$createTerminal" ]; then
          mkdir -p "$out/bin"
          ln -s "$out/libexec/deferred-$validatedPname" "$out/bin/$terminalCommand"
        fi
      '';

  # Detect duplicate terminal commands in a list of apps
  # Returns an error message if duplicates found, null otherwise
  #
  # Each app in the list can be:
  #   - A string (package name)
  #   - An attrset with { pname, exe?, createTerminalCommand? }
  #
  # Note: exe can be null (from module submodule defaults), which means "auto-detect"
  detectTerminalCollisions =
    apps:
    let
      # Get all (pname, terminalCommand) pairs where terminal command is enabled
      terminalApps = builtins.filter (app: app.createTerminalCommand or true) apps;
      terminalCommands = map (
        app:
        let
          pname = app.pname or app;
          # Handle both missing exe AND null exe (from module submodule defaults)
          # app.exe or ... only triggers if exe is missing, not if it's null
          appExe = app.exe or null;
          exe = if appExe != null then appExe else getMainProgram pname;
          # Terminal command is lowercase for Unix convention
          terminalCommand = lib.toLower exe;
        in
        {
          inherit pname terminalCommand;
        }
      ) terminalApps;

      # Group by terminal command name
      grouped = builtins.groupBy (x: x.terminalCommand) terminalCommands;

      # Find duplicates
      duplicates = lib.filterAttrs (_: v: builtins.length v > 1) grouped;
    in
    if duplicates == { } then
      null
    else
      let
        formatDup = cmd: apps': "  '${cmd}' -> ${lib.concatMapStringsSep ", " (a: "'${a.pname}'") apps'}";
        dupList = lib.mapAttrsToList formatDup duplicates;
      in
      ''
        deferred-apps: Terminal command collision detected!
        Multiple packages would create the same terminal command:
        ${lib.concatStringsSep "\n" dupList}
        Fix: Set 'createTerminalCommand = false' for some packages, or use 'exe' to override.
      '';

in
{
  inherit mkDeferredApp detectTerminalCollisions;

  # Create multiple deferred apps from a list of package names
  # Validates that no terminal command collisions exist
  mkDeferredApps =
    pnames:
    let
      appConfigs = map (pname: { inherit pname; }) pnames;
      collision = detectTerminalCollisions appConfigs;
    in
    assert lib.assertMsg (collision == null) collision;
    map (pname: mkDeferredApp { inherit pname; }) pnames;

  # Create multiple deferred apps with a custom flake reference
  mkDeferredAppsFrom =
    flakeRef: pnames:
    let
      appConfigs = map (pname: { inherit pname; }) pnames;
      collision = detectTerminalCollisions appConfigs;
    in
    assert lib.assertMsg (collision == null) collision;
    map (pname: mkDeferredApp { inherit pname flakeRef; }) pnames;

  # Create multiple deferred apps with full configuration
  # Takes a list of attribute sets, each with pname and optional overrides
  mkDeferredAppsAdvanced =
    appConfigs:
    let
      collision = detectTerminalCollisions appConfigs;
    in
    assert lib.assertMsg (collision == null) collision;
    map mkDeferredApp appConfigs;
}
