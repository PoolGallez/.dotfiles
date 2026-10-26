# Nix the package manager/daemon (nix.*) and nixpkgs itself (nixpkgs.*) —
# flakes, garbage collection, the emacs-overlay, and allowing unfree
# packages.
{ config, lib, inputs, ... }:

{
  options.my.system.nix.enable = lib.mkEnableOption "flakes, weekly GC, emacs-overlay and unfree packages";

  config = lib.mkIf config.my.system.nix.enable {
    # Enable flakes experimental feature (in replacement for channels)
    nix.settings.experimental-features = [ "nix-command" "flakes" ];

    # Enable garbage collector
    nix.gc.dates = "weekly";
    nix.gc.options = "--delete-older-than 15d";

    nixpkgs = {
      overlays = [
        inputs.emacs-overlay.overlays.default
      ];

      config = {
        allowUnfree = true;
        allowUnfreePredicate = _: true;
      };
    };
  };
}
