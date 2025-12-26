# Deferred Apps

[![CI](https://github.com/WitteShadovv/deferred-apps/actions/workflows/ci.yml/badge.svg)](https://github.com/WitteShadovv/deferred-apps/actions/workflows/ci.yml)
[![License: AGPL-3.0](https://img.shields.io/badge/License-AGPL--3.0-blue.svg)](LICENSE)

**Apps appear in your launcher but only download when first launched.**

Deferred Apps creates lightweight wrapper scripts that look like installed applications but only download the actual package on first use. Perfect for apps you rarely use but want available, without bloating your system closure.

## Features

- **Instant availability** — Apps appear in your launcher immediately
- **Zero overhead** — No disk space used until first launch
- **Flake.lock pinning** — Packages pinned to exact versions from your flake
- **Overlay support** — Use packages from custom nixpkgs instances with your overlays
- **Proper icons** — Automatically resolves icons from Papirus theme
- **Auto-detection** — Detects executable names from package metadata
- **NixOS & Home Manager** — Works with both system-wide and per-user configurations

## Quick Start

### NixOS

Add to your `flake.nix`:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    deferred-apps.url = "github:WitteShadovv/deferred-apps";
  };

  outputs = { nixpkgs, deferred-apps, ... }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      modules = [
        deferred-apps.nixosModules.default
        ({ pkgs, ... }: {
          programs.deferredApps = {
            enable = true;
            packages = with pkgs; [
              spotify
              discord
              obs-studio
              blender
              gimp
            ];
          };
        })
      ];
    };
  };
}
```

> **Note**: For unfree packages like `spotify` and `discord`, your nixpkgs must have `config.allowUnfree = true`. See [Unfree Packages](#unfree-packages).

Run `nixos-rebuild switch` and the apps appear in your launcher.

### Home Manager

#### Standalone Home Manager

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    home-manager.url = "github:nix-community/home-manager";
    deferred-apps.url = "github:WitteShadovv/deferred-apps";
  };

  outputs = { nixpkgs, home-manager, deferred-apps, ... }: {
    homeConfigurations.myuser = home-manager.lib.homeManagerConfiguration {
      pkgs = import nixpkgs {
        system = "x86_64-linux";
        config.allowUnfree = true;
      };
      modules = [
        deferred-apps.homeManagerModules.default
        ({ pkgs, ... }: {
          programs.deferredApps = {
            enable = true;
            packages = with pkgs; [ spotify discord obs-studio ];
          };
        })
      ];
    };
  };
}
```

#### Home Manager as NixOS Module

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    home-manager.url = "github:nix-community/home-manager";
    deferred-apps.url = "github:WitteShadovv/deferred-apps";
  };

  outputs = { nixpkgs, home-manager, deferred-apps, ... }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      modules = [
        home-manager.nixosModules.home-manager
        {
          home-manager.users.myuser = { pkgs, ... }: {
            imports = [ deferred-apps.homeManagerModules.default ];
            programs.deferredApps = {
              enable = true;
              packages = with pkgs; [ spotify discord obs-studio ];
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

1. **At build time**: Captures only the `.drv` file (~50KB), NOT the package outputs
2. **At first launch**: Realizes the derivation via `nix-store --realise`
3. **Subsequent launches**: Uses the Nix store cache (near-instant)

Packages are pinned to exact versions from your `flake.lock`, and custom overlays are respected since you're passing actual package references.

> **Note**: By default, downloaded packages may be removed by `nix-collect-garbage`. Enable `gcRoot = true` to prevent this (see [Garbage Collection](#garbage-collection)).

## Unfree Packages

For unfree packages (spotify, discord, steam, etc.), your nixpkgs instance must have `config.allowUnfree = true`:

```nix
# In your flake.nix
nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
  modules = [
    {
      nixpkgs.config.allowUnfree = true;
    }
    # ... your other modules
  ];
};
```

The license check happens at flake evaluation time. If you reference an unfree package without enabling `allowUnfree`, you'll get an error during `nix flake check` or `nixos-rebuild`, not at runtime.

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

### Basic

```nix
programs.deferredApps = {
  enable = true;
  packages = with pkgs; [ obs-studio blender gimp ];
};
```

### With Custom nixpkgs

Use packages from a different nixpkgs channel or with overlays:

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
    packages = [
      pkgs-unstable.spotify
      pkgs-unstable.discord
      inputs.some-flake.packages.${pkgs.system}.custom-app
    ];
  };
}
```

### Advanced with extraApps

Use `extraApps` for packages needing custom configuration:

```nix
programs.deferredApps = {
  enable = true;
  packages = with pkgs; [ blender gimp ];
  
  # Custom icon theme (optional)
  iconTheme = {
    package = pkgs.papirus-icon-theme;
    name = "Papirus-Light";
  };
  
  extraApps = {
    # Package with custom options
    my-spotify = {
      package = pkgs.spotify;
      createTerminalCommand = false;  # GUI only, no terminal command
    };
    
    # Override auto-detected values
    some-package = {
      package = pkgs.some-package;
      exe = "custom-binary-name";
      desktopName = "My Custom Name";
      icon = "custom-icon";
      categories = [ "Development" ];
    };
  };
};
```

### Alternative: Package Names (apps option)

For simpler setups, you can use package names instead of direct references:

```nix
programs.deferredApps = {
  enable = true;
  apps = [ "obs-studio" "blender" "gimp" ];
};
```

This uses `nix shell` at runtime to fetch packages from the flake registry. However, this approach:
- Requires `allowUnfree = true` option for unfree packages (uses `--impure` mode)
- Uses flake registry versions instead of your `flake.lock`
- Doesn't support custom overlays

**We recommend using `packages` instead** for better reproducibility and cleaner unfree handling.

<details>
<summary>Apps mode configuration examples</summary>

#### With Unfree Packages

```nix
programs.deferredApps = {
  enable = true;
  apps = [ "spotify" "discord" "obs-studio" ];
  allowUnfree = true;  # Required for spotify, discord (uses --impure)
};
```

#### Pin to Specific nixpkgs

```nix
programs.deferredApps = {
  enable = true;
  apps = [ "obs-studio" "blender" ];
  flakeRef = "github:NixOS/nixpkgs/nixos-24.11";
};
```

#### With extraApps (pname mode)

```nix
programs.deferredApps = {
  enable = true;
  apps = [ "obs-studio" ];
  extraApps = {
    some-package = {
      exe = "custom-binary-name";
      desktopName = "My Custom Name";
    };
  };
};
```

</details>

### Using the Library Directly

```nix
{
  nixpkgs.overlays = [ deferred-apps.overlays.default ];
  
  environment.systemPackages = 
    pkgs.deferredApps.mkDeferredPackages [ pkgs.spotify pkgs.discord ];
}
```

For package names via library:
```nix
environment.systemPackages = 
  pkgs.deferredApps.mkDeferredApps [ "hello" "cowsay" ];
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
  programs.deferredApps.packages = with pkgs; [ hello ];
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
  programs.deferredApps.packages = with pkgs; [ hello ];
}
```

## Module Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `enable` | bool | `false` | Enable deferred apps |
| `packages` | list of package | `[]` | Package derivations to defer (recommended) |
| `apps` | list of str | `[]` | Package names to defer (uses `nix shell` at runtime) |
| `flakeRef` | str | `"nixpkgs"` | Flake reference for `apps` option |
| `allowUnfree` | bool | `false` | Allow unfree packages in `apps` (uses `--impure`) |
| `gcRoot` | bool | `false` | Create GC roots to prevent cleanup |
| `iconTheme.enable` | bool | `true` | Install Papirus icon theme |
| `iconTheme.package` | package | `pkgs.papirus-icon-theme` | Icon theme package |
| `iconTheme.name` | str | `"Papirus-Dark"` | Icon theme name |
| `extraApps` | attrs | `{}` | Apps with custom configuration |
| `extraApps.<name>.package` | package | `null` | Direct package reference |
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
| `mkDeferredApp { package }` | Create a single deferred app from a package derivation |
| `mkDeferredApp { pname }` | Create a single deferred app by package name |
| `mkDeferredPackages [ pkg1 pkg2 ]` | Create multiple deferred apps from derivations |
| `mkDeferredApps [ "pkg1" "pkg2" ]` | Create multiple deferred apps by names |
| `mkDeferredAppsAdvanced [ { ... } ]` | Create multiple apps with full configuration |

## FAQ

**Q: Why not just use `nix shell -p`?**

It achieves the same thing, but doesn't give you desktop icons or launcher integration.

**Q: Will this work offline?**

Only if Nix has already cached the package from a previous run.

**Q: Should I use the NixOS module or Home Manager module?**

- Use **NixOS module** if you want deferred apps available system-wide for all users
- Use **Home Manager module** if you want per-user configuration or don't have root access

Both modules have identical options and behavior.

**Q: My downloaded package disappeared after `nix-collect-garbage`?**

This is expected by default. Enable `gcRoot = true` to protect downloaded packages from garbage collection. See [Garbage Collection](#garbage-collection).

**Q: Should I use `packages` or `apps`?**

**Use `packages`** (recommended) for:
- Exact version pinning from your `flake.lock`
- Packages from custom nixpkgs instances or overlays
- Cleaner unfree handling (checked at eval time, not runtime)

**Use `apps`** for:
- Quick, simple configuration with just package names
- When you want packages from the flake registry (dynamic versions)

**Q: Does this work with multi-output packages?**

The module assumes binaries are in `$out/bin/`. For packages where the binary is in a different output (rare), you can use the `exe` option with a custom path.

**Q: Why not use [comma](https://github.com/nix-community/comma)?**

Comma is excellent for CLI users who want to run arbitrary commands on-demand from the terminal. Deferred Apps solves a different problem: making GUI applications appear in your desktop launcher *before* they're downloaded.

| | Comma | Deferred Apps |
|---|---|---|
| **Use case** | Run CLI commands on-demand | GUI apps in launcher |
| **Interface** | Terminal (`, cowsay hello`) | Desktop files & app launchers |
| **Discovery** | nix-index database | Explicit package list |
| **Icons** | N/A | Auto-resolved from Papirus |
| **Version pinning** | Uses nix-index results | Pinned to your `flake.lock` |

Use comma for CLI tools; use Deferred Apps for GUI applications you want in your launcher without the upfront download.

## See Also

- [nixpkgs](https://github.com/NixOS/nixpkgs) — Where the packages come from
- [Papirus Icon Theme](https://github.com/PapirusDevelopmentTeam/papirus-icon-theme) — Default icon source
- [Home Manager](https://github.com/nix-community/home-manager) — User environment management

## License

[AGPL-3.0-or-later](LICENSE)
