# Baseline shared by every desktop host (triskelion, getriebe) — what
# hosts/common/common.nix used to import, plus the bootloader and user
# account both hosts defined inline. Everything is mkDefault, so a host
# can still switch off any single piece.
{ config, lib, ... }:

{
  options.my.profiles.workstation.enable = lib.mkEnableOption "the desktop-host baseline";

  config = lib.mkIf config.my.profiles.workstation.enable {
    my.system = {
      locale.enable = lib.mkDefault true;
      networking.enable = lib.mkDefault true;
      audio.enable = lib.mkDefault true;
      nix.enable = lib.mkDefault true;
      boot.enable = lib.mkDefault true;
      user.enable = lib.mkDefault true;
    };
  };
}
