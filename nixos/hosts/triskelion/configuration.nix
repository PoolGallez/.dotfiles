# Desktop PC.
{ config, lib, pkgs, ... }:

{
  imports =
    [ # Include the results of the hardware scan.
      ./hardware-configuration.nix
      ../../modules/nixos
    ];

  my.profiles.workstation.enable = true;

  # "plasma" or "gnome" — the one desktop (and app suite) this host gets.
  my.desktop.environment = "plasma";

  my.apps = {
    gaming.enable = true;
    comms.enable = true;
    emacs.enable = true;
  };

  boot.initrd.luks.devices."luks-b66bc40c-4e17-458f-98b6-239bb12f6bd1".device = "/dev/disk/by-uuid/b66bc40c-4e17-458f-98b6-239bb12f6bd1";
  networking.hostName = "triskelion"; # Define your hostname.

  # KDE app: only alongside Plasma (GNOME brings its own Text Editor).
  users.users.pool.packages = lib.optionals (config.my.desktop.environment == "plasma") [
    pkgs.kdePackages.kate
  ];

  programs.nix-ld.enable = true;
  programs.nix-ld.libraries = with pkgs; [
    # Add any missing dynamic libraries for unpackaged programs
    # here, NOT in environment.systemPackages
  ];

 system.stateVersion = "25.05"; # Did you read the comment?

}
