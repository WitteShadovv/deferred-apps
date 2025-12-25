# Deferred Apps - Home Manager Module
#
# Thin wrapper around the shared module factory.
# See ./shared.nix for the implementation.
#
# Example:
#   programs.deferredApps = {
#     enable = true;
#     apps = [ "spotify" "obs-studio" "discord" "blender" ];
#     allowUnfree = true;  # Required for spotify, discord
#   };
#
import ./shared.nix { target = "home-manager"; }
