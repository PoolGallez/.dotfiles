{ config, pkgs, ... }:

{
  # ── Network manager ───────────────────────────────────────────────────────
  # Use systemd-networkd for a server; no NetworkManager needed.
  networking = {
    useDHCP = false;   # we set a static IP below

    # ── Static IP ─────────────────────────────────────────────────────────
    # Adjust interface name (check `ip link` on the board) and address.
    interfaces."eth0" = {
      ipv4.addresses = [{
        address      = "192.168.1.10";   # ← your desired static IP
        prefixLength = 24;
      }];
    };

    defaultGateway = "192.168.1.1";     # ← your router

    nameservers = [
      "127.0.0.1"   # Pi-hole on localhost handles DNS
      "1.1.1.1"     # fallback if Pi-hole is down during boot
    ];
  };

  # ── mDNS / Avahi ──────────────────────────────────────────────────────────
  # Lets other machines on LAN reach rock-pro64.local
  services.avahi = {
    enable   = true;
    nssmdns4 = true;
    publish  = {
      enable      = true;
      addresses   = true;
      workstation = true;
    };
  };
}
