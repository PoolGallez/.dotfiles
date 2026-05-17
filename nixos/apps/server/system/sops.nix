{ config, pkgs, ... }:

# ── sops-nix secrets management ──────────────────────────────────────────────
#
# SETUP STEPS (one-time, on your workstation):
#
#   1. Get the host SSH key fingerprint after first boot:
#        ssh-keyscan rock-pro64 | ssh-to-age
#      This prints the age public key for the host.
#
#   2. Add it to secrets/.sops.yaml alongside your own age key:
#        keys:
#          - &admin  age1yourpersonalagekey...
#          - &rock64 age1hostagekey...
#        creation_rules:
#          - path_regex: secrets/.*
#            key_groups:
#              - age: [*admin, *rock64]
#
#   3. Create / edit secret files:
#        sops secrets/rock-pro64.yaml
#
#   4. Rebuild the host — sops-nix decrypts secrets at activation time using
#      /etc/ssh/ssh_host_ed25519_key (present on the host).
#
# ─────────────────────────────────────────────────────────────────────────────

{
  sops = {
    defaultSopsFile = ../../secrets/rock-pro64.yaml;

    # Use the host's SSH ed25519 key as the age identity for decryption.
    age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];

    # ── Secret definitions ─────────────────────────────────────────────────
    # Each key maps to a path under /run/secrets/ at runtime.
    # The owner/group/mode fields control file permissions.
    #
    # Nextcloud admin password
    secrets."nextcloud/adminPassword" = {
      owner = "nextcloud";
      group = "nextcloud";
      mode  = "0400";
    };

    # Nextcloud database password (if using external postgres)
    secrets."nextcloud/dbPassword" = {
      owner = "nextcloud";
      group = "nextcloud";
      mode  = "0400";
    };

    # Pi-hole web password
    secrets."pihole/webPassword" = {
      owner = "root";
      mode  = "0400";
    };

    # Immich database password
    secrets."immich/dbPassword" = {
      owner = "immich";
      group = "immich";
      mode  = "0400";
    };

    # DuckDNS token — used by both ACME (cert issuance) and the DuckDNS updater
    # File must contain a line in lego env-var format:
    #   DUCKDNS_TOKEN=your-token-here
    secrets."acme/duckdnsToken" = {
      owner = "acme";
      group = "acme";
      mode  = "0400";
    };

    # WireGuard server private key
    secrets."wireguard/serverPrivateKey" = {
      owner = "root";
      mode  = "0400";
    };

    # Per-peer preshared keys
    secrets."wireguard/peers/phone/presharedKey" = {
      owner = "root";
      mode  = "0400";
    };

    secrets."wireguard/peers/laptop/presharedKey" = {
      owner = "root";
      mode  = "0400";
    };

    # Add a block here for every new peer you add in wireguard.nix:
    # secrets."wireguard/peers/tablet/presharedKey" = {
    #   owner = "root";
    #   mode  = "0400";
    # };

    # Add more secrets here as needed, e.g.:
    # secrets."calibre/someToken" = { ... };
  };
}
