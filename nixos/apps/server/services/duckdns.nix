{ config, pkgs, lib, ... }:

# ── DuckDNS dynamic DNS updater ───────────────────────────────────────────────
#
# Runs every 5 minutes as a systemd timer.  Calls the DuckDNS API with your
# current public IP so your domain always points at home.
#
# The DuckDNS token is shared with the ACME module (same secret).
# ─────────────────────────────────────────────────────────────────────────────

let
  duckdnsSubdomain = "YOUR_SUBDOMAIN";   # ← just the subdomain, not the full domain
in
{
  systemd.services.duckdns-update = {
    description = "DuckDNS dynamic DNS update";
    after       = [ "network-online.target" ];
    wants       = [ "network-online.target" ];

    serviceConfig = {
      Type            = "oneshot";
      User            = "root";

      # Read token from sops secret file at runtime
      ExecStart = pkgs.writeShellScript "duckdns-update" ''
        TOKEN=$(cat ${config.sops.secrets."acme/duckdnsToken".path} \
                | grep DUCKDNS_TOKEN | cut -d= -f2)

        RESULT=$(${pkgs.curl}/bin/curl -fsSL \
          "https://www.duckdns.org/update?domains=${duckdnsSubdomain}&token=$TOKEN&ip=")

        if [ "$RESULT" = "OK" ]; then
          echo "DuckDNS update successful"
        else
          echo "DuckDNS update failed: $RESULT" >&2
          exit 1
        fi
      '';

      # Restart on failure but don't hammer the API
      Restart    = "on-failure";
      RestartSec = "60s";
    };
  };

  systemd.timers.duckdns-update = {
    description   = "DuckDNS dynamic DNS update timer";
    wantedBy      = [ "timers.target" ];
    after         = [ "network-online.target" ];
    timerConfig = {
      OnBootSec        = "2min";    # first run 2 min after boot
      OnUnitActiveSec  = "5min";    # then every 5 minutes
      Persistent       = true;      # run missed timers after downtime
    };
  };
}
