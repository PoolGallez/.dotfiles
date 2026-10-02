# Desktop communication/chat apps only. git/openssh/p7zip/age moved to
# modules/home/cli-tools.nix (home-manager, user-scoped); qemu/quickemu/
# libpcap moved to modules/nixos/virtualization.nix (getriebe-only);
# wl-clipboard moved to modules/nixos/desktop/plasma.nix. teams-for-linux
# moved in from home.nix for category consistency with the rest of these.
{ pkgs, ... }:

{
  environment.systemPackages = with pkgs; [
    spotify
    telegram-desktop
    discord
    signal-desktop
    teams-for-linux
  ];
}
