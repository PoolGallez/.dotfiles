# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).

{ config, pkgs, ... }:

{
  imports =
    [ # Include the results of the hardware scan.
      ../common/common.nix
      ./hardware-configuration.nix
      ../../de/plasma/plasma.nix
      ../../apps/gaming/gaming.nix
      ../../apps/comms/comms.nix
    ];

  # Bootloader.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # Use latest kernel.
  boot.kernelPackages = pkgs.linuxPackages_latest;

  boot.initrd.luks.devices."luks-b66bc40c-4e17-458f-98b6-239bb12f6bd1".device = "/dev/disk/by-uuid/b66bc40c-4e17-458f-98b6-239bb12f6bd1";
  networking.hostName = "triskelion"; # Define your hostname.
  # networking.wireless.enable = true;  # Enables wireless support via wpa_supplicant.

  # Configure network proxy if necessary
  # networking.proxy.default = "http://user:password@proxy:port/";
  # networking.proxy.noProxy = "127.0.0.1,localhost,internal.domain";

  # Set your time zone.
  time.timeZone = "Europe/Rome";

  # Configure keymap in X11
  services.xserver.xkb = {
    layout = "us";
    variant = "";
  };

  # Enable CUPS to print documents.
  services.printing.enable = true;


  # Define a user account. Don't forget to set a password with ‘passwd’.
  users.users.pool = {
    isNormalUser = true;
    description = "Paolo Galletta";
    extraGroups = [ "networkmanager" "wheel" ];
    packages = with pkgs; [
      kdePackages.kate
      emacs
    ];
  };


    # Install firefox.
  programs.firefox.enable = true;

 system.stateVersion = "25.05"; # Did you read the comment?

}
