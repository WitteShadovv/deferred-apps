# Deferred Apps

[![CI](https://github.com/WitteShadovv/deferred-apps/actions/workflows/ci.yml/badge.svg)](https://github.com/WitteShadovv/deferred-apps/actions/workflows/ci.yml)
[![License: AGPL-3.0](https://img.shields.io/badge/License-AGPL--3.0-blue.svg)](LICENSE)

**Apps appear in your launcher but only download when first launched.**

Deferred Apps creates lightweight wrapper scripts that look like installed applications but only download the actual package on first use. Perfect for apps you rarely use but want available, without bloating your system closure.

## Features

- **Instant availability** — Apps appear in your launcher immediately
- **Zero overhead** — No disk space used until first launch
- **Two modes** — Use package names *or* direct package references
- **Overlay support** — Use packages from custom nixpkgs instances with your overlays
- **Flake.lock pinning** — Packages pinned to exact versions from your flake
- **Proper icons** — Automatically resolves icons from Papirus theme
- **Auto-detection** — Detects executable names from package metadata
- **Security-aware** — Only unfree packages use `--impure`, free packages stay pure
- **NixOS & Home Manager** — Works with both system-wide and per-user configurations

## Quick Start

### NixOS

Add to your `flake.nix`:

```nix
{
  inputs.deferred-apps.url = "github:WitteShadovv/deferred-apps";

  outputs = { nixpkgs, deferred-apps, ... }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      modules = [
        deferred-apps.nixosModules.default
        {
          programs.deferredApps = {
            enable = true;
            apps = [ "spotify" "discord" "obs-studio" "blender" "gimp" ];
            allowUnfree = true;  # Required for spotify, discord
          };
        }
      ];
    };
  };
}
```

Run `nixos-rebuild switch` and the apps appear in your launcher.

### Home Manager

#### Standalone Home Manager

```nix
{
  inputs.deferred-apps.url = "github:WitteShadovv/deferred-apps";

  outputs = { home-manager, deferred-apps, ... }: {
    homeConfigurations.myuser = home-manager.lib.homeManagerConfiguration {
      modules = [
        deferred-apps.homeManagerModules.default
        {
          programs.deferredApps = {
            enable = true;
            apps = [ "spotify" "discord" "obs-studio" ];
            allowUnfree = true;
          };
        }
      ];
    };
  };
}
```

#### Home Manager as NixOS Module

```nix
{
  inputs.deferred-apps.url = "github:WitteShadovv/deferred-apps";

  outputs = { nixpkgs, home-manager, deferred-apps, ... }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      modules = [
        home-manager.nixosModules.home-manager
        {
          home-manager.users.myuser = {
            imports = [ deferred-apps.homeManagerModules.default ];
            programs.deferredApps = {
              enable = true;
              apps = [ "spotify" "discord" "obs-studio" ];
              allowUnfree = true;
            };
          };
        }
      ];
    };
  };
}
```

Run `home-manager switch` (standalone) or `nixos-rebuild switch` (NixOS module) and the apps appear in your launcher.

## How It Works

Deferred Apps supports two modes:

### Pname Mode (Package Names)

```
apps = [ "spotify" "discord" ];
```

1. **At build time**: Creates tiny wrapper scripts (~1KB) with proper `.desktop` files
2. **At first launch**: Downloads the package via `nix shell nixpkgs#spotify`
3. **Subsequent launches**: Uses the Nix store cache (near-instant)

### Package Mode (Direct References)

```
packages = [ pkgs-unstable.spotify ];
```

1. **At build time**: Captures only the `.drv` file (~50KB), NOT the package outputs
2. **At first launch**: Realizes the derivation via `nix-store --realise`
3. **Subsequent launches**: Uses the Nix store cache (near-instant)

Package mode is ideal when you need packages from custom nixpkgs instances (with overlays) or want exact version pinning from your `flake.lock`.

> **Note**: By default, downloaded packages may be removed by `nix-collect-garbage`. Enable `gcRoot = true` to prevent this (see [Garbage Collection](#garbage-collection)).

## Security Model

> [!WARNING]
> **Unfree packages require `--impure` mode**, which allows environment variables to affect the build. This is because `NIXPKGS_ALLOW_UNFREE=1` must be set at evaluation time.

Deferred Apps uses a **hybrid security approach**:

| Package Type | Mode | Security |
|--------------|------|----------|
| **Free** (hello, gimp, blender) | Pure | ✅ Full reproducibility |
| **Unfree** (spotify, discord) | Impure | ⚠️ Requires `allowUnfree = true` |

**Best practice**: If you only use free packages, leave `allowUnfree = false` (the default).

### Flake Registry

By default, `flakeRef = "nixpkgs"` uses your system's flake registry, which typically points to the nixpkgs version from your system flake. For reproducibility, pin to a specific nixpkgs:

```nix
programs.deferredApps.flakeRef = "github:NixOS/nixpkgs/nixos-25.11";
```

## Garbage Collection

By default, downloaded packages are **not** protected from garbage collection. This means after `nix-collect-garbage`, apps may need to re-download on next launch.

To enable GC protection:
```nix
programs.deferredApps.gcRoot = true;
```

When enabled, GC roots are stored in `~/.local/share/deferred-apps/gcroots/`.

To clean up protected packages:
```bash
rm -rf ~/.local/share/deferred-apps/gcroots/
nix-collect-garbage
```

## Configuration

### Simple

```nix
programs.deferredApps = {
  enable = true;
  apps = [ "obs-studio" "blender" "gimp" ];  # Free packages only
};
```

### With Unfree Packages

```nix
programs.deferredApps = {
  enable = true;
  apps = [ "spotify" "discord" "obs-studio" ];
  allowUnfree = true;  # Required for spotify, discord
};
```

### Advanced

```nix
programs.deferredApps = {
  enable = true;
  apps = [ "spotify" "discord" ];
  allowUnfree = true;
  
  # Pin to a specific nixpkgs
  flakeRef = "github:NixOS/nixpkgs/nixos-25.11";
  
  # Custom icon theme (optional)
  iconTheme = {
    package = pkgs.papirus-icon-theme;
    name = "Papirus-Light";
  };
  
  # Apps needing manual configuration
  extraApps = {
    some-package = {
      exe = "custom-binary-name";
      desktopName = "My Custom Name";
      icon = "custom-icon";
      categories = [ "Development" ];
    };
    
    # GUI-only app (no terminal command)
    spotify = {
      createTerminalCommand = false;
    };
  };
};
```

### Package Mode (Overlays & Custom nixpkgs)

Use `packages` when you need packages from custom nixpkgs instances, with overlays applied, or pinned to your `flake.lock`:

```nix
{ inputs, pkgs, ... }:

let
  # Example: unstable nixpkgs with your overlays
  pkgs-unstable = import inputs.nixpkgs-unstable {
    inherit (pkgs) system;
    config.allowUnfree = true;
    overlays = [ myOverlay ];
  };
in {
  programs.deferredApps = {
    enable = true;
    
    # Direct package references - versions pinned to your flake.lock
    packages = [
      pkgs-unstable.spotify
      pkgs-unstable.discord
      inputs.some-flake.packages.${pkgs.system}.custom-app
    ];
    
    # Can also use package mode in extraApps for custom options
    extraApps = {
      my-spotify = {
        package = pkgs-unstable.spotify;
        createTerminalCommand = false;  # GUI only
      };
    };
  };
}
```

**Key differences from pname mode:**
- Packages are pinned to exact versions in your `flake.lock`
- Custom overlays are respected
- No `allowUnfree` needed (license is checked when you reference the package)
- Uses `nix-store --realise` at runtime instead of `nix shell`

### Using the Library Directly

```nix
{
  nixpkgs.overlays = [ deferred-apps.overlays.default ];
  
  environment.systemPackages = 
    pkgs.deferredApps.mkDeferredApps [ "hello" "cowsay" ];
}
```

For unfree packages via library:
```nix
environment.systemPackages = [
  (pkgs.deferredApps.mkDeferredApp {
    pname = "spotify";
    allowUnfree = true;
  })
];
```

For direct package references via library:
```nix
environment.systemPackages = 
  pkgs.deferredApps.mkDeferredPackages [ pkgs-unstable.spotify pkgs-unstable.discord ];
```

> **Note**: Library/overlay users should ensure `libnotify` is available for download notifications.

## Installation Without Flakes

### NixOS

```nix
let
  deferred-apps = import (fetchTarball {
    url = "https://github.com/WitteShadovv/deferred-apps/archive/refs/tags/v0.2.0.tar.gz";
    sha256 = "1r8arg8aclq1fwg6rfksbrs7jrgzi2fkbm4aibnif5mcnqxnijbi";
  });
in {
  imports = [ deferred-apps.nixosModules.default ];
  programs.deferredApps.enable = true;
  programs.deferredApps.apps = [ "hello" ];
}
```

### Home Manager

```nix
let
  deferred-apps = import (fetchTarball {
    url = "https://github.com/WitteShadovv/deferred-apps/archive/refs/tags/v0.2.0.tar.gz";
    sha256 = "1r8arg8aclq1fwg6rfksbrs7jrgzi2fkbm4aibnif5mcnqxnijbi";
  });
in {
  imports = [ deferred-apps.homeManagerModules.default ];
  programs.deferredApps.enable = true;
  programs.deferredApps.apps = [ "hello" ];
}
```

## Module Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `enable` | bool | `false` | Enable deferred apps |
| `apps` | list of str | `[]` | Package names to defer (uses `nix shell` at runtime) |
| `packages` | list of package | `[]` | Package derivations to defer (uses `nix-store --realise` at runtime) |
| `flakeRef` | str | `"nixpkgs"` | Flake reference for packages (only for `apps`) |
| `allowUnfree` | bool | `false` | Allow unfree packages (uses `--impure`, only for `apps`) |
| `gcRoot` | bool | `false` | Create GC roots to prevent cleanup |
| `iconTheme.enable` | bool | `true` | Install Papirus icon theme |
| `iconTheme.package` | package | `pkgs.papirus-icon-theme` | Icon theme package |
| `iconTheme.name` | str | `"Papirus-Dark"` | Icon theme name |
| `extraApps` | attrs | `{}` | Apps with custom configuration |
| `extraApps.<name>.package` | package | `null` | Direct package reference (alternative to pname lookup) |
| `extraApps.<name>.exe` | str | `null` | Override executable name |
| `extraApps.<name>.createTerminalCommand` | bool | `true` | Create terminal command symlink |

## Flake Outputs

| Output | Description |
|--------|-------------|
| `nixosModules.default` | NixOS module for `programs.deferredApps` |
| `homeManagerModules.default` | Home Manager module for `programs.deferredApps` |
| `overlays.default` | Adds `pkgs.deferredApps` library |
| `lib.<system>` | Direct library access |

### Library Functions

| Function | Description |
|----------|-------------|
| `mkDeferredApp { pname }` | Create a single deferred app by package name |
| `mkDeferredApp { package }` | Create a single deferred app from a package derivation |
| `mkDeferredApps [ "pkg1" "pkg2" ]` | Create multiple deferred apps by names |
| `mkDeferredPackages [ pkg1 pkg2 ]` | Create multiple deferred apps from derivations |
| `mkDeferredAppsAdvanced [ { pname; exe; ... } ]` | Create multiple apps with full configuration |

## FAQ

**Q: Why not just use `nix shell -p`?**

It achieves the same thing, but doesn't give you desktop icons or launcher integration.

**Q: Will this work offline?**

Only if Nix has already cached the package from a previous run.

**Q: Why do unfree packages need `allowUnfree = true`?**

Unfree packages require `NIXPKGS_ALLOW_UNFREE=1` at Nix evaluation time, which requires `--impure` mode. This is a Nix limitation, not ours. Free packages use pure mode for better security.

**Q: Should I use the NixOS module or Home Manager module?**

- Use **NixOS module** if you want deferred apps available system-wide for all users
- Use **Home Manager module** if you want per-user configuration or don't have root access

Both modules have identical options and behavior.

**Q: My downloaded package disappeared after `nix-collect-garbage`?**

This is expected by default. Enable `gcRoot = true` to protect downloaded packages from garbage collection. See [Garbage Collection](#garbage-collection).

**Q: Should I use `apps` or `packages`?**

Use **`apps`** (pname mode) when:
- You want simple configuration with just package names
- You're fine with packages from the default nixpkgs in your flake registry
- You need dynamic evaluation (e.g., "always get the latest from nixpkgs-unstable")

Use **`packages`** (package mode) when:
- You need packages from custom nixpkgs instances (e.g., with overlays)
- You want exact version pinning from your `flake.lock`
- You're already importing a custom nixpkgs for other reasons
- The package comes from a custom flake output

Both modes work identically at runtime—apps appear in your launcher and download on first launch. The difference is how the package source is specified.

**Q: Does package mode work with multi-output packages?**

Package mode assumes binaries are in `$out/bin/`. For most packages this works fine. For packages where the binary is in a different output (rare), you can:
1. Use the `exe` option with a custom path
2. Use pname mode instead (which handles output selection automatically via `nix shell`)

## See Also

- [nixpkgs](https://github.com/NixOS/nixpkgs) — Where the packages come from
- [Papirus Icon Theme](https://github.com/PapirusDevelopmentTeam/papirus-icon-theme) — Default icon source
- [Home Manager](https://github.com/nix-community/home-manager) — User environment management

## License

[AGPL-3.0-or-later](LICENSE)
