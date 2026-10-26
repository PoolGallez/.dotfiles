# Home-server role (rocky, a ROCKPro64). my.server.enable turns on the base
# server system — base.nix (nix/ssh/firewall/packages), networking.nix
# (static IP + avahi), users.nix (admin user, locked root) and sops.nix
# (secret definitions); each service below is then enabled on its own
# with my.server.services.<name>.enable.
{ lib, ... }:

{
  imports = [
    ./base.nix
    ./networking.nix
    ./users.nix
    ./sops.nix

    ./services/nextcloud.nix
    ./services/pihole.nix
    ./services/immich.nix
    ./services/calibre.nix
    ./services/wireguard.nix
    ./services/nginx.nix
    ./services/duckdns.nix
  ];

  options.my.server.enable = lib.mkEnableOption "the base home-server system";
}
