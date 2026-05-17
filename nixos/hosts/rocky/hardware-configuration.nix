# ─────────────────────────────────────────────────────────────────────────────
# hardware-configuration.nix — ROCKPro64
#
# HOW TO GENERATE:
#   1. Boot a NixOS ARM64 installer on the ROCKPro64.
#   2. Mount your root / boot partitions under /mnt.
#   3. Run: nixos-generate-config --root /mnt
#   4. Replace this file with the generated /mnt/etc/nixos/hardware-configuration.nix
#
# The stub below captures the most common ROCKPro64 specifics so you have a
# starting point if you prefer to write it by hand.
# ─────────────────────────────────────────────────────────────────────────────

{ config, lib, pkgs, modulesPath, ... }:

{
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
  ];

  # ── Boot ─────────────────────────────────────────────────────────────────
  # ROCKPro64 typically uses U-Boot + extlinux (no GRUB).
  boot.loader.grub.enable = false;
  boot.loader.generic-extlinux-compatible.enable = true;

  # Mainline kernel works well on ROCKPro64 since ~6.1.
  boot.kernelPackages = pkgs.linuxPackages_latest;

  # Needed for the RK3399 SoC
  boot.initrd.availableKernelModules = [
    "xhci_pci" "ahci" "usbhid" "usb_storage" "sd_mod"
  ];
  boot.kernelModules = [ "kvm-aarch64" ];

  # ── Filesystems ───────────────────────────────────────────────────────────
  # Replace UUIDs with the real ones from `blkid` on the target machine.
  #
  # fileSystems."/" = {
  #   device = "/dev/disk/by-uuid/XXXX-XXXX";
  #   fsType = "ext4";
  # };
  #
  # fileSystems."/boot" = {
  #   device = "/dev/disk/by-uuid/XXXX-XXXX";
  #   fsType = "vfat";
  # };
  #
  # Mount the existing 4 TB HDD at /data so all services can reach it:
  # fileSystems."/data" = {
  #   device = "/dev/disk/by-uuid/XXXX-XXXX";   # or by-label/by-id
  #   fsType = "ext4";                           # adjust to your actual fs
  #   options = [ "defaults" "nofail" ];         # nofail = boot even if disk absent
  # };
  #
  # swapDevices = [ ];   # ROCKPro64 has 4 GB RAM; add swap on HDD if desired

  # ── Platform ──────────────────────────────────────────────────────────────
  nixpkgs.hostPlatform = lib.mkDefault "aarch64-linux";
}
