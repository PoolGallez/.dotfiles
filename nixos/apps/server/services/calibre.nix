{ config, pkgs, lib, ... }:

# ── Calibre-Web — ebook library management ───────────────────────────────────
#
# calibre-web serves a Calibre library via a web UI.
# calibre (the desktop app) is also installed so you can use calibredb on the
# server for CLI imports / metadata updates.
#
# Your existing Calibre library (metadata.db + book folders) should live at
# /data/calibre/library — point calibre-web at that path on first run.
#
# Default credentials (change immediately after first login):
#   username: admin
#   password: admin123
# ─────────────────────────────────────────────────────────────────────────────

{
  # ── Calibre-Web ───────────────────────────────────────────────────────────
  services.calibre-web = {
    enable  = true;
    listen = {
      ip   = "127.0.0.1";            # nginx fronts this; no direct LAN exposure
      port = 8083;
    };
    options = {
      # Point at the existing Calibre library on the HDD
      calibreLibrary = "/data/calibre/library";

      # Enable the Calibre Content Server (OPDS feed for e-readers)
      enableBookConversion = true;
      enableBookUploading  = true;
    };
  };

  # ── Calibre (CLI tools — useful for calibredb operations on the server) ───
  environment.systemPackages = [ pkgs.calibre ];

  # Port 8083 is NOT opened in the firewall — nginx proxies it over HTTPS.

  # ── Ensure library dir exists on the HDD ──────────────────────────────────
  systemd.tmpfiles.rules = [
    "d /data/calibre/library 0755 calibre-web calibre-web -"
  ];
}
