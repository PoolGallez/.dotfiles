# Every NixOS module in this repo. Importing this file adds options only —
# nothing is turned on until a host sets the matching my.* option (or a
# profile does it for it). Options, by group:
#
#   my.profiles.workstation.enable     core bundle for desktop hosts (below)
#
#   my.system.nix.enable               flakes, GC, emacs-overlay, unfree
#   my.system.locale.enable            Europe/Rome, en_US + it_IT formats
#   my.system.networking.enable        NetworkManager
#   my.system.audio.enable             PipeWire
#   my.system.boot.enable              systemd-boot (+ .latestKernel)
#   my.system.user.enable              the "pool" account (+ .name)
#
#   my.desktop.environment             null | "plasma" | "gnome" (exclusive)
#   my.desktop.gnome.extraApps/.games  GNOME app selection
#
#   my.apps.comms.enable               chat apps + Spotify
#   my.apps.gaming.enable              Steam + Proton-GE
#   my.apps.emacs.enable               Emacs + native-comp deps
#   my.apps.virtualisation.enable      libvirt/QEMU + virt-manager
#   my.apps.wireshark.enable           Wireshark + usbmon
#   my.apps.nextcloud-client.enable    Nextcloud client + DE online accounts
#
#   my.services.syncthing.enable       Syncthing for the personal user
#
#   my.hardware.tablet-switch.enable   virtual tablet-mode switch (convertibles)
#   my.hardware.focaltech-fingerprint.enable  fprintd + FocalTech blob (2808:0752)
#
#   my.server.enable                   home-server base system (rocky)
#   my.server.services.<name>.enable   nextcloud, pihole, immich, calibre,
#                                      wireguard, nginx, duckdns
{ ... }:

{
  imports = [
    ./system/locale.nix
    ./system/networking.nix
    ./system/audio.nix
    ./system/nix.nix
    ./system/boot.nix
    ./system/user.nix

    ./desktop

    ./apps/gaming.nix
    ./apps/comms.nix
    ./apps/emacs.nix
    ./apps/virtualisation.nix
    ./apps/wireshark.nix
    ./apps/nextcloud-client.nix

    ./services/syncthing.nix

    ./hardware/tablet-switch.nix
    ./hardware/focaltech-fingerprint.nix

    ./server

    ./profiles/workstation.nix
  ];
}
