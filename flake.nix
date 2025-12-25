{
  description = "Deferred Apps - Lightweight application launchers that download packages on first use";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    { self, nixpkgs, ... }:
    let
      inherit (nixpkgs) lib;

      # Systems where deferred-apps makes sense (Linux only - desktop apps)
      supportedSystems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      forAllSystems = lib.genAttrs supportedSystems;

      # Create the deferred-apps library for a given pkgs
      mkLib =
        pkgs:
        import ./package.nix {
          inherit pkgs;
          inherit (pkgs) lib;
        };
    in
    {
      # =======================================================================
      # NixOS Module
      # =======================================================================
      # Usage in flake-based NixOS configuration:
      #
      #   inputs.deferred-apps.url = "github:your-username/deferred-apps";
      #
      #   nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      #     modules = [
      #       deferred-apps.nixosModules.default
      #       {
      #         programs.deferredApps = {
      #           enable = true;
      #           apps = [ "spotify" "discord" "obs-studio" ];
      #         };
      #       }
      #     ];
      #   };
      #
      nixosModules = {
        deferredApps = ./module.nix;
        default = self.nixosModules.deferredApps;
      };

      # =======================================================================
      # Overlay
      # =======================================================================
      # Adds `pkgs.deferredApps` with mkDeferredApp and mkDeferredApps functions
      #
      # Usage:
      #   nixpkgs.overlays = [ deferred-apps.overlays.default ];
      #
      #   # Then in your config:
      #   environment.systemPackages = pkgs.deferredApps.mkDeferredApps [ "spotify" ];
      #
      overlays = {
        deferredApps = final: _prev: {
          deferredApps = mkLib final;
        };
        default = self.overlays.deferredApps;
      };

      # =======================================================================
      # Library
      # =======================================================================
      # Direct access to the deferred-apps functions per system
      #
      # Usage in nix repl or expressions:
      #   deferred-apps.lib.x86_64-linux.mkDeferredApp { pname = "spotify"; }
      #
      lib = forAllSystems (system: mkLib nixpkgs.legacyPackages.${system});

      # =======================================================================
      # Development
      # =======================================================================
      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixfmt-rfc-style);

      # Development shells for local development and CI
      devShells = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          # Default shell for development
          default = pkgs.mkShell {
            name = "deferred-apps-dev";
            packages = with pkgs; [
              # Formatting
              nixfmt-rfc-style
              # Linting
              statix
              deadnix
              # Nix tools
              nix-diff
            ];
            shellHook = ''
              echo "deferred-apps development shell"
              echo ""
              echo "Available commands:"
              echo "  nix flake check    - Run all checks"
              echo "  nix fmt            - Format all Nix files"
              echo "  statix check .     - Run Nix linter"
              echo "  deadnix -L .       - Check for unused code"
              echo ""
            '';
          };

          # Minimal shell for CI (only tools needed for checks)
          ci = pkgs.mkShell {
            name = "deferred-apps-ci";
            packages = with pkgs; [
              nixfmt-rfc-style
              statix
              deadnix
            ];
          };
        }
      );

      # Comprehensive test suite
      # Run with: nix flake check
      # See tests/default.nix for full documentation of test cases
      checks = forAllSystems (
        system:
        import ./tests {
          pkgs = nixpkgs.legacyPackages.${system};
          inherit lib self system;
        }
      );
    };
}
