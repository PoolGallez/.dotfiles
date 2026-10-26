# Desktop environment selector — the single switch between Plasma and
# GNOME:
#
#   my.desktop.environment = "plasma";   # or "gnome", or null (headless)
#
# The two are mutually exclusive: a generation contains exactly one DE
# and its app suite (plasma.nix or gnome.nix), never both, so their apps,
# portals and services can't clash. Changing the value and rebuilding
# swaps one for the other.
#
# The home-manager configuration for this host (pool@<host> in flake.nix)
# reads the same value, so user-level settings follow the switch too.
# Switching back loses nothing: Plasma's ~/.config/*rc files and GNOME's
# dconf database are left on disk while the other DE is active.
{ config, lib, ... }:

{
  imports = [
    ./plasma.nix
    ./gnome.nix
  ];

  options.my.desktop.environment = lib.mkOption {
    type = lib.types.nullOr (lib.types.enum [ "plasma" "gnome" ]);
    default = null;
    example = "gnome";
    description = "Desktop environment to install, or null for a headless host.";
  };

  config = lib.mkIf (config.my.desktop.environment != null) {
    # Configure keymap in X11
    services.xserver.xkb = {
      layout = "us";
      variant = "";
    };

    # Enable CUPS to print documents.
    services.printing.enable = true;

    # Install firefox.
    programs.firefox.enable = true;
  };
}
