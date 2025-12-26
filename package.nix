# Deferred Apps - Package Builder
#
# Creates lightweight wrappers that appear as installed apps but only
# download the actual package on first launch via `nix shell` or `nix-store --realise`.
#
# Key feature: Automatically detects executable names from nixpkgs metadata.
# Example: obs-studio -> "obs", discord -> "discord", vscode -> "code"
#
# Nested Packages: Supports dot-notation for nested package sets.
# Example: python313Packages.numpy, haskellPackages.pandoc, nodePackages.typescript
#
# Direct Package References: Pass actual package derivations instead of names.
# This enables using packages from custom nixpkgs instances with overlays,
# or packages pinned to your flake.lock.
#
# Terminal commands are normalized to lowercase for Unix convention.
# The actual binary name (from meta.mainProgram) is used internally.
#
# Usage:
#   mkDeferredApp { pname = "spotify"; }                            # Auto-detect exe
#   mkDeferredApp { pname = "python313Packages.numpy"; }            # Nested package
#   mkDeferredApp { pname = "my-app"; exe = "custom"; }             # Manual override
#   mkDeferredApp { package = pkgs.spotify; }                       # Direct package
#   mkDeferredApps [ "spotify" "discord" "python313Packages.numpy" ] # Multiple apps
#   mkDeferredPackages [ pkgs.spotify pkgs.discord ]                # Direct packages
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

  # Check if a direct package derivation is unfree
  isDerivationUnfree =
    pkg:
    let
      licenses = lib.toList (pkg.meta.license or [ ]);
      hasUnfreeLicense = lib.any (l: !(l.free or true)) licenses;
    in
    hasUnfreeLicense;

  # ===========================================================================
  # Package Derivation Helpers (for direct package references)
  # ===========================================================================

  # Helper: takeWhile implementation (not in nixpkgs lib)
  # Takes elements from a list while predicate is true
  takeWhile =
    pred: list:
    let
      go =
        acc: xs:
        if xs == [ ] then
          acc
        else
          let
            head = builtins.head xs;
            tail = builtins.tail xs;
          in
          if pred head then go (acc ++ [ head ]) tail else acc;
    in
    go [ ] list;

  # Extract pname from a package derivation
  # Falls back to name parsing if pname is not available
  #
  # Handles edge cases:
  # - Packages with pname attribute (most common)
  # - Packages where name = "hello-2.12.1" → "hello"
  # - Packages where name starts with number like "7zip-24.08" → "7zip"
  # - Packages like "2048-in-terminal-1.0" → "2048-in-terminal"
  getPnameFromPackage =
    pkg:
    pkg.pname or (
      let
        name = pkg.name or "unknown";
        # Split on "-" and take parts that don't look like versions
        # A version part is one that:
        # - Contains a dot and starts with digits (e.g., "2.12.1", "24.08")
        # - OR starts with digits followed by version suffix (e.g., "2rc1", "1alpha")
        # Note: Bare numbers like "2048" are NOT considered versions
        parts = lib.splitString "-" name;
        isVersionPart =
          p:
          builtins.match "[0-9]+[.][0-9]+(.*)" p != null
          || builtins.match "[0-9]+(rc|alpha|beta|pre|post)[0-9]*" p != null;
        nonVersionParts = takeWhile (p: !isVersionPart p) parts;
        result = lib.concatStringsSep "-" nonVersionParts;
      in
      # Fallback to full name if no non-version parts found
      # This handles edge cases like a package named just "1.0" (unlikely but safe)
      if result == "" then name else result
    );

  # Extract mainProgram from a package derivation
  getMainProgramFromPackage = pkg: pkg.meta.mainProgram or (getPnameFromPackage pkg);

  # Extract description from a package derivation
  getDescriptionFromPackage = pkg: pkg.meta.description or "Application";

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
  # Two modes of operation:
  #
  # MODE 1: By package name (pname)
  #   Looks up the package in the module's nixpkgs and uses `nix shell` at runtime.
  #   Best for: Simple cases where you want packages from the default nixpkgs.
  #
  #   Required:
  #     pname       - nixpkgs attribute name (e.g., "spotify", "obs-studio")
  #                   Supports nested packages with dot notation:
  #                   "python313Packages.numpy", "haskellPackages.pandoc", etc.
  #
  # MODE 2: Direct package reference (package)
  #   Uses the provided package derivation directly. At runtime, realizes the
  #   derivation using `nix-store --realise`. The package is NOT built at system
  #   build time - only the .drv file is captured.
  #   Best for: Packages from custom nixpkgs instances, overlays, or flake.lock pinning.
  #
  #   Required:
  #     package     - A package derivation (e.g., pkgs-unstable.spotify)
  #
  # Optional (auto-detected from package metadata):
  #   exe                   - executable name (from meta.mainProgram)
  #   desktopName           - display name (generated from pname)
  #   description           - app description (from meta.description)
  #   icon                  - icon name or path for desktop entry (auto-resolved from theme)
  #   categories            - freedesktop.org categories (defaults to ["Application"])
  #   flakeRef              - flake reference for nix shell (only used with pname, defaults to "nixpkgs")
  #   createTerminalCommand - create terminal command symlink (defaults to true)
  #   allowUnfree           - allow unfree packages (enables --impure for pname mode, defaults to false)
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
      pname ? null,
      package ? null,
      pnameOverride ? null, # Override the derived pname (for extraApps with package mode)
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
      # ===========================================================================
      # Mode Detection and Validation
      # ===========================================================================

      # Determine which mode we're in
      hasPackage = package != null;
      hasPname = pname != null;

      # Validate: must have exactly one of pname or package
      # The `mode` variable is used in the derivation to force assertion evaluation
      mode =
        assert lib.assertMsg (
          hasPackage || hasPname
        ) "deferred-apps: Must provide either 'pname' or 'package'";
        assert lib.assertMsg (
          !(hasPackage && hasPname)
        ) "deferred-apps: Cannot provide both 'pname' and 'package'. Use one or the other.";
        if hasPackage then "package" else "pname";

      # ===========================================================================
      # Package Mode: Direct derivation reference
      # ===========================================================================

      # Extract metadata from the package derivation
      # Guard these to avoid errors when package is null
      pkgPname = if hasPackage then getPnameFromPackage package else "";
      pkgExe =
        if hasPackage then (if exe != null then exe else getMainProgramFromPackage package) else "";
      pkgDescription =
        if hasPackage then
          (if description != null then description else getDescriptionFromPackage package)
        else
          "";
      pkgIsUnfree = if hasPackage then isDerivationUnfree package else false;

      # Capture paths for runtime realization
      # We need the .drv file to exist at runtime so nix-store --realise works.
      #
      # CRITICAL: We must NOT trigger building the package outputs at system build time.
      # The challenge is that `package.drvPath` has string context with `allOutputs = true`,
      # which would cause Nix to build all outputs when used in a derivation.
      #
      # Solution: Use `builtins.appendContext` to create a new reference to the .drv file
      # with `path = true` context instead of `allOutputs = true`. This tells Nix
      # "I need this path to exist" without implying "build the derivation's outputs".
      #
      # Note: builtins.storePath would also work but requires impure mode.
      # builtins.appendContext works in pure mode (flake check).
      #
      # The flow is:
      # 1. Extract the raw path string from package.drvPath (discarding original context)
      # 2. Use builtins.appendContext to add `path = true` context for just the .drv
      # 3. This makes the .drv file a dependency of our wrapper, but NOT its outputs
      #
      # How .drv files work:
      # A .drv file is a complete build recipe that contains references to all its
      # input derivations. When Nix copies a .drv to the store, it recursively ensures
      # all referenced input .drv files also exist. This is standard Nix behavior.
      # At runtime, `nix-store --realise` uses these .drv files to build/download
      # the package and all its dependencies.
      #
      # Runtime note: Manual testing is recommended to verify `nix-store --realise`
      # works correctly for your specific packages, especially for packages with
      # complex dependency graphs.
      pkgDrvPathRaw = if hasPackage then builtins.unsafeDiscardStringContext package.drvPath else "";
      pkgDrvPath =
        if hasPackage then
          # appendContext adds a dependency on the .drv file existing, but with
          # path = true (not allOutputs = true), so outputs won't be built
          builtins.appendContext pkgDrvPathRaw {
            "${pkgDrvPathRaw}" = {
              path = true;
            };
          }
        else
          "";
      pkgOutPath =
        # The outPath is embedded as a plain string (no context) so the script
        # knows where to find the binary after realization
        if hasPackage then builtins.unsafeDiscardStringContext package.outPath else "";

      # ===========================================================================
      # Pname Mode: Lookup by attribute name
      # ===========================================================================

      # Validate pname if provided
      # For package mode with pnameOverride, use the override for desktop file naming
      # This allows extraApps.spotify-unstable.package to create spotify-unstable.desktop
      validatedPname =
        if pnameOverride != null then
          validatePname pnameOverride
        else if hasPname then
          validatePname pname
        else
          pkgPname;

      # Get metadata from nixpkgs lookup
      pnameExe = if exe != null then exe else getMainProgram validatedPname;
      pnameDescription = if description != null then description else getDescription validatedPname;
      pnameIsUnfree = if hasPname then isPackageUnfree validatedPname else false;

      # ===========================================================================
      # Common Logic (both modes)
      # ===========================================================================

      # Select the right values based on mode
      finalExe = if hasPackage then pkgExe else pnameExe;
      finalDescription = if hasPackage then pkgDescription else pnameDescription;
      packageIsUnfree = if hasPackage then pkgIsUnfree else pnameIsUnfree;

      # Terminal command is the user-facing symlink name
      # Normalized to lowercase for Unix convention
      terminalCommand = lib.toLower finalExe;

      # Desktop name generation
      finalDesktopName = if desktopName != null then desktopName else toDisplayName validatedPname;

      # Security: Check unfree status
      # For package mode: unfree packages work directly (no --impure needed for nix-store --realise)
      # For pname mode: unfree packages need --impure with NIXPKGS_ALLOW_UNFREE
      needsImpure = if hasPackage then false else (packageIsUnfree && allowUnfree);

      # Icon name to search for
      iconName = if icon != null then icon else validatedPname;
      iconNameFallback = finalExe;
      iconIsAbsolutePath = icon != null && lib.hasPrefix "/" icon;

      # ===========================================================================
      # Wrapper Scripts
      # ===========================================================================

      # Wrapper for PNAME mode (uses nix shell)
      wrapperScriptPname = writeText "deferred-${validatedPname}-wrapper-pname" ''
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
        maybe_notify() {
          if [ "$GC_ROOT" = "1" ] && [ -L "$GC_ROOT_DIR/$PNAME" ]; then
            return
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
        ensure_downloaded() {
          local build_args=("$FLAKE_REF#$PNAME" "--no-link" "--print-out-paths")

          if [ "$NEEDS_IMPURE" = "1" ]; then
            export NIXPKGS_ALLOW_UNFREE=1
            build_args=("--impure" "''${build_args[@]}")
          fi

          local store_path
          store_path=$(nix build "''${build_args[@]}" 2>/dev/null) || return 0

          if [ "$GC_ROOT" = "1" ] && [ -n "$store_path" ]; then
            mkdir -p "$GC_ROOT_DIR"
            nix-store --add-root "$GC_ROOT_DIR/$PNAME" --indirect -r "$store_path" &>/dev/null || true
          fi
        }

        maybe_notify
        ensure_downloaded

        if [ "$NEEDS_IMPURE" = "1" ]; then
          export NIXPKGS_ALLOW_UNFREE=1
          exec nix shell --impure "$FLAKE_REF#$PNAME" --command "$EXE" "$@"
        else
          exec nix shell "$FLAKE_REF#$PNAME" --command "$EXE" "$@"
        fi
      '';

      # Wrapper for PACKAGE mode (uses nix-store --realise)
      #
      # Note on multi-output packages:
      # This assumes the binary is in $out/bin/. For packages with multiple outputs
      # where the binary is in a different output (rare), users can override with
      # the `exe` option providing a path relative to the package or use pname mode.
      wrapperScriptPackage = writeText "deferred-${validatedPname}-wrapper-package" ''
        #!/usr/bin/env bash
        set -euo pipefail

        PNAME="@pname@"
        DRV_PATH="@drvPath@"
        OUT_PATH="@outPath@"
        EXE="@exe@"
        ICON="@icon@"
        GC_ROOT="@gcRoot@"

        # GC root directory for this user
        GC_ROOT_DIR="''${XDG_DATA_HOME:-$HOME/.local/share}/deferred-apps/gcroots"

        # Check if package is already available (cached or realized)
        is_available() {
          # If GC root is enabled and exists, package is available
          if [ "$GC_ROOT" = "1" ] && [ -L "$GC_ROOT_DIR/$PNAME" ]; then
            return 0
          fi
          # Otherwise check if output directory exists in store
          [ -d "$OUT_PATH" ]
        }

        # Show notification (only if not already available)
        maybe_notify() {
          if is_available; then
            return
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

        # Ensure package is realized
        ensure_realized() {
          if [ ! -d "$OUT_PATH" ]; then
            # Realize the derivation (downloads/builds as needed)
            # Show errors to user for debugging (don't suppress stderr)
            if ! nix-store --realise "$DRV_PATH" >/dev/null; then
              echo "deferred-apps: Failed to realize $PNAME from $DRV_PATH" >&2
              echo "deferred-apps: Try running: nix-store --realise $DRV_PATH" >&2
              exit 1
            fi
          fi

          # Create GC root if enabled
          if [ "$GC_ROOT" = "1" ] && [ ! -L "$GC_ROOT_DIR/$PNAME" ]; then
            mkdir -p "$GC_ROOT_DIR"
            nix-store --add-root "$GC_ROOT_DIR/$PNAME" --indirect -r "$OUT_PATH" &>/dev/null || true
          fi
        }

        maybe_notify
        ensure_realized

        # Run the application directly from the store path
        # Note: Assumes binary is in $out/bin/. For multi-output packages where
        # the binary is in a different output, use the exe option with a full path.
        exec "$OUT_PATH/bin/$EXE" "$@"
      '';

      # Select the right wrapper based on mode
      wrapperScript = if hasPackage then wrapperScriptPackage else wrapperScriptPname;

      # Create the .desktop file
      desktopItem = makeDesktopItem {
        name = validatedPname;
        exec = "@out@/libexec/deferred-${validatedPname} %U";
        icon = "@icon@";
        comment = finalDescription;
        desktopName = finalDesktopName;
        inherit categories;
        terminal = false;
        startupNotify = true;
        startupWMClass = finalExe;
      };

    in
    # Validation: unfree check for pname mode
    assert lib.assertMsg (hasPackage || !packageIsUnfree || allowUnfree)
      "deferred-apps: Package '${validatedPname}' is unfree. Set 'allowUnfree = true' to enable it (uses --impure).";
    runCommand "deferred-${validatedPname}"
      {
        inherit
          validatedPname
          finalExe
          wrapperScript
          desktopItem
          terminalCommand
          mode # Force evaluation of mode (triggers validation assertions)
          ;
        # Mode-specific variables
        isPackageMode = if hasPackage then "1" else "";
        flakeRef = if hasPackage then "" else flakeRef;
        drvPath = pkgDrvPath;
        outPath = pkgOutPath;
        # Common variables
        iconThemePath = "${iconThemePackage}/share/icons/${iconThemeName}";
        iconSizes = iconSizesList;
        userIcon = if iconIsAbsolutePath then icon else "";
        createTerminal = if createTerminalCommand then "1" else "";
        needsImpureStr = if needsImpure then "1" else "0";
        gcRootStr = if gcRoot then "1" else "0";
        inherit iconName iconNameFallback;
      }
      ''
        # ===========================================================================
        # Build-time icon resolution
        # ===========================================================================

        find_icon() {
          local name="$1"
          local theme_path="$iconThemePath"

          for size in $iconSizes; do
            local icon_path="$theme_path/$size/apps/$name.svg"
            if [ -e "$icon_path" ]; then
              readlink -f "$icon_path"
              return 0
            fi
          done
          return 1
        }

        if [ -n "$userIcon" ]; then
          RESOLVED_ICON="$userIcon"
        else
          if RESOLVED_ICON=$(find_icon "$iconName"); then
            :
          elif RESOLVED_ICON=$(find_icon "$iconNameFallback"); then
            :
          else
            echo "WARNING: Icon '$iconName' not found in theme. Desktop may show missing icon." >&2
            RESOLVED_ICON="$iconName"
          fi
        fi

        mkdir -p "$out/libexec" "$out/share/applications"

        # ===========================================================================
        # Create the wrapper script
        # ===========================================================================
        if [ -n "$isPackageMode" ]; then
          # Package mode: substitute package-specific variables
          substitute "$wrapperScript" "$out/libexec/deferred-$validatedPname" \
            --replace-fail '@icon@' "$RESOLVED_ICON" \
            --replace-fail '@pname@' "$validatedPname" \
            --replace-fail '@drvPath@' "$drvPath" \
            --replace-fail '@outPath@' "$outPath" \
            --replace-fail '@exe@' "$finalExe" \
            --replace-fail '@gcRoot@' "$gcRootStr"
        else
          # Pname mode: substitute flake-specific variables
          substitute "$wrapperScript" "$out/libexec/deferred-$validatedPname" \
            --replace-fail '@icon@' "$RESOLVED_ICON" \
            --replace-fail '@pname@' "$validatedPname" \
            --replace-fail '@flakeRef@' "$flakeRef" \
            --replace-fail '@exe@' "$finalExe" \
            --replace-fail '@needsImpure@' "$needsImpureStr" \
            --replace-fail '@gcRoot@' "$gcRootStr"
        fi

        chmod +x "$out/libexec/deferred-$validatedPname"

        # ===========================================================================
        # Create the .desktop file
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
  #   - An attrset with { pname?, package?, pnameOverride?, exe?, createTerminalCommand? }
  #
  # Note: exe can be null (from module submodule defaults), which means "auto-detect"
  detectTerminalCollisions =
    apps:
    let
      # Get all (pname, terminalCommand, source) tuples where terminal command is enabled
      terminalApps = builtins.filter (app: app.createTerminalCommand or true) apps;
      terminalCommands = map (
        app:
        let
          # Handle both pname and package modes
          hasPackage = (app.package or null) != null;
          hasPnameOverride = (app.pnameOverride or null) != null;
          # pname for display: pnameOverride > pname > derived from package
          pname =
            if hasPnameOverride then
              app.pnameOverride
            else if hasPackage then
              getPnameFromPackage app.package
            else
              app.pname or app;
          # Get exe from: explicit > package metadata > pname lookup
          appExe = app.exe or null;
          exe =
            if appExe != null then
              appExe
            else if hasPackage then
              getMainProgramFromPackage app.package
            else
              getMainProgram pname;
          # Terminal command is lowercase for Unix convention
          terminalCommand = lib.toLower exe;
          # Track source for better error messages
          source =
            if hasPnameOverride then
              "extraApps (package)"
            else if hasPackage then
              "package"
            else
              "pname";
        in
        {
          inherit pname terminalCommand source;
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
        # Format each app with its source type for clarity
        formatApp = a: "'${a.pname}' (${a.source})";
        formatDup = cmd: apps': "  '${cmd}' -> ${lib.concatMapStringsSep ", " formatApp apps'}";
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
  inherit
    mkDeferredApp
    detectTerminalCollisions
    # Export helper functions for advanced use cases
    getPnameFromPackage
    getMainProgramFromPackage
    getDescriptionFromPackage
    isDerivationUnfree
    ;

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
  # Takes a list of attribute sets, each with pname/package and optional overrides
  mkDeferredAppsAdvanced =
    appConfigs:
    let
      collision = detectTerminalCollisions appConfigs;
    in
    assert lib.assertMsg (collision == null) collision;
    map mkDeferredApp appConfigs;

  # Create multiple deferred apps from a list of package derivations
  # This is the package-mode equivalent of mkDeferredApps
  # Validates that no terminal command collisions exist
  mkDeferredPackages =
    packages:
    let
      appConfigs = map (package: { inherit package; }) packages;
      collision = detectTerminalCollisions appConfigs;
    in
    assert lib.assertMsg (collision == null) collision;
    map (package: mkDeferredApp { inherit package; }) packages;
}
