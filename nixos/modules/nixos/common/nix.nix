# Nix the package manager/daemon (nix.*) and nixpkgs itself (nixpkgs.*) —
# flakes, garbage collection, the emacs-overlay, and allowing unfree
# packages. Replaces the old pkgs-db/pkgs.nix; merged with the nix.gc
# settings that used to live inline in hosts/common/common.nix.
{ inputs, ... }:

{
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
}
