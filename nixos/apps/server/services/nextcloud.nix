{ config, pkgs, lib, ... }:

# ── Nextcloud ──────────────────────────────────────────────────────────────
#
# DATA MIGRATION NOTE:
#   Your existing Nextcloud data lives on the 4 TB HDD.  As long as the HDD
#   is mounted at /data (see hardware-configuration.nix) and datadir below
#   points to the same directory that your previous install used, Nextcloud
#   will pick it up automatically after running:
#
#     sudo -u nextcloud nextcloud-occ maintenance:mode --on
#     sudo -u nextcloud nextcloud-occ files:scan --all
#     sudo -u nextcloud nextcloud-occ maintenance:mode --off
#
#   If the database was also on the HDD (e.g. a sqlite file inside datadir),
#   it will be reused too.  If you had PostgreSQL, restore the dump and point
#   the dbPasswordFile + database settings below at it.
# ─────────────────────────────────────────────────────────────────────────────

{
  # ── PostgreSQL (recommended over SQLite for Nextcloud) ────────────────────
  services.postgresql = {
    enable      = true;
    package     = pkgs.postgresql_15;
    dataDir     = "/data/postgresql";    # keep DB on the HDD
    ensureDatabases = [ "nextcloud" ];
    ensureUsers = [{
      name              = "nextcloud";
      ensureDBOwnership = true;
    }];
  };

  # ── Nextcloud ─────────────────────────────────────────────────────────────
  services.nextcloud = {
    enable  = true;
    package = pkgs.nextcloud30;

    hostName = "nextcloud.YOUR_SUBDOMAIN.duckdns.org";  # ← match nginx.nix

    datadir  = "/data/nextcloud";
    home     = "/data/nextcloud";

    # HTTPS — nginx terminates TLS; nextcloud must know it's behind HTTPS
    https = true;

    config = {
      adminuser       = "admin";
      adminpassFile   = config.sops.secrets."nextcloud/adminPassword".path;

      dbtype          = "pgsql";
      dbhost          = "/run/postgresql";
      dbname          = "nextcloud";
      dbuser          = "nextcloud";
      dbpassFile      = config.sops.secrets."nextcloud/dbPassword".path;
    };

    settings = {
      "php_value[memory_limit]"        = "512M";
      "php_value[upload_max_filesize]" = "10G";
      "php_value[post_max_size]"       = "10G";
      trusted_domains  = [ "nextcloud.YOUR_SUBDOMAIN.duckdns.org" ];
      trusted_proxies  = [ "127.0.0.1" ];   # nginx proxy
      overwriteprotocol = "https";
      default_phone_region = "DE";           # ← your country code
    };

    caching.redis = false;
  };

  # nginx is enabled and configured in nginx.nix — Nextcloud module merges into it.
  services.nginx.enable = true;

  # Ports 80/443 are NOT opened broadly — nginx.nix opens 443 on wg0 only.
  # Port 80 stays open on loopback for nextcloud's internal redirect logic.

  # ── Ensure postgres starts before nextcloud ───────────────────────────────
  systemd.services.nextcloud-setup = {
    requires = [ "postgresql.service" ];
    after    = [ "postgresql.service" ];
  };
}
