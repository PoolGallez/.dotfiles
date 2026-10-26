# VMs (libvirt/QEMU + virt-manager, SPICE USB redirection) and the QEMU/
# quickemu CLI tooling, for hosts that actually do virtualization work.
# The libvirtd/virt-manager half used to sit inline in
# hosts/getriebe/configuration.nix.
{ config, lib, pkgs, ... }:

{
  options.my.apps.virtualisation.enable = lib.mkEnableOption "libvirt/QEMU VMs with virt-manager";

  config = lib.mkIf config.my.apps.virtualisation.enable {
    environment.systemPackages = with pkgs; [
      qemu
      quickemu
      libpcap
    ];

    virtualisation.libvirtd = {
      enable = true;
      qemu.vhostUserPackages = with pkgs; [ virtiofsd ];
    };

    virtualisation.spiceUSBRedirection.enable = true;
    programs.virt-manager.enable = true;
  };
}
