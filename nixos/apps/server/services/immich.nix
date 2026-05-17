{ config, pkgs, lib, ... }:

# ── Immich — self-hosted photo/video management ──────────────────────────────
#
# NixOS has a native Immich module (nixpkgs ≥ 24.05).
# Library / upload data is stored on the HDD under /data/immich.
#
# First-run:
#   After deployment, open http://rock-pro64.local:2283 and create the admin
#   account.  Existing photos can be bulk-imported via the "External Libraries"
#   feature in the Immich web UI — point it at /data/immich/library (or
#   wherever your photos actually live on the HDD).
# ─────────────────────────────────────────────────────────────────────────────

{
  services.immich = {
    enable        = true;
    mediaLocation = "/data/immich";         # all uploads / originals stored here
    host          = "127.0.0.1";            # nginx fronts this; no direct LAN exposure
    port          = 2283;

    # Database — Immich module manages its own postgres instance by default.
    # If you want to share the postgres cluster from nextcloud.nix, set:
    #   database.createDB = false;
    # and create the DB manually, then set database.name / user accordingly.

    # Machine-learning is RAM-heavy; disable on 4 GB boards if needed:
    # machine-learning.enable = false;
  };

  # Port 2283 is NOT opened in the firewall — nginx proxies it over HTTPS.

  # ── Ensure /data/immich exists with correct ownership ─────────────────────
  systemd.tmpfiles.rules = [
    "d /data/immich            0750 immich immich -"
    "d /data/immich/library    0750 immich immich -"
    "d /data/immich/thumbs     0750 immich immich -"
    "d /data/immich/encoded    0750 immich immich -"
    "d /data/immich/profile    0750 immich immich -"
  ];
}
