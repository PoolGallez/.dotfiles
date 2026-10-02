# Shared config for every desktop host (triskelion, getriebe). Each concern
# lives in its own file under modules/nixos/common/ — this is just the
# aggregator so hosts keep a single import line.
{ ... }:

{
  imports = [
    ../../modules/nixos/common/locale.nix
    ../../modules/nixos/common/networking.nix
    ../../modules/nixos/common/audio.nix
    ../../modules/nixos/common/nix.nix
  ];
}
