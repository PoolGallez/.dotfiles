# systemd-boot on EFI plus the latest kernel — identical on every desktop
# host, so it moved out of the per-host configuration.nix files.
{ config, lib, pkgs, ... }:

let
  cfg = config.my.system.boot;
in
{
  options.my.system.boot = {
    enable = lib.mkEnableOption "systemd-boot EFI bootloader";
    latestKernel = lib.mkEnableOption "the latest kernel instead of the LTS default" // { default = true; };
  };

  config = lib.mkIf cfg.enable {
    # Bootloader.
    boot.loader.systemd-boot.enable = true;
    boot.loader.efi.canTouchEfiVariables = true;

    # Use latest kernel.
    boot.kernelPackages = lib.mkIf cfg.latestKernel pkgs.linuxPackages_latest;
  };
}
