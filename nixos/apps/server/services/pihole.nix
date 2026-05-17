{ config, pkgs, lib, ... }:

# ── Pi-hole + Unbound (recursive DNS-over-HTTPS) ─────────────────────────────
#
# Architecture:
#   LAN clients → Pi-hole (:53, ad-blocking)
#              → Unbound (:5335, recursive resolver with DoH upstream)
#              → Cloudflare / Quad9 over HTTPS
#
# Pi-hole is run via Docker (the upstream nixpkgs package is the most
# maintained path).  Unbound runs natively via the NixOS module.
#
# Port layout (to avoid conflicts with other services):
#   53   — Pi-hole DNS (TCP+UDP, exposed to LAN)
#   80   — Pi-hole web UI (if nginx isn't using it; adjust as needed)
#   5335 — Unbound (localhost only, Pi-hole upstream)
# ─────────────────────────────────────────────────────────────────────────────

{
  # ── Docker (required for Pi-hole) ─────────────────────────────────────────
  virtualisation.docker = {
    enable            = true;
    autoPrune.enable  = true;
  };

  # ── Pi-hole via Docker ────────────────────────────────────────────────────
  # Uses systemd to manage the container so it integrates with the service graph.
  systemd.services.pihole = {
    description    = "Pi-hole DNS / ad-blocking";
    wantedBy       = [ "multi-user.target" ];
    after          = [ "docker.service" "network-online.target" ];
    requires       = [ "docker.service" ];

    serviceConfig = {
      Restart          = "always";
      RestartSec       = "10s";
      ExecStartPre     = "${pkgs.docker}/bin/docker pull pihole/pihole:latest";
      ExecStart = let
        webPwd = config.sops.secrets."pihole/webPassword".path;
      in ''
        ${pkgs.bash}/bin/bash -c '${pkgs.docker}/bin/docker run \
          --name pihole \
          --rm \
          --network host \
          -e TZ="Europe/Berlin" \
          -e WEBPASSWORD="$(cat ${webPwd})" \
          -e DNSMASQ_LISTENING=all \
          -e PIHOLE_DNS_="127.0.0.1#5335" \
          -e DNSSEC="false" \
          -v /data/pihole/etc:/etc/pihole \
          -v /data/pihole/dnsmasq:/etc/dnsmasq.d \
          pihole/pihole:latest'
      '';
      ExecStop = "${pkgs.docker}/bin/docker stop pihole";
    };
  };

  # ── Unbound — recursive resolver with DoH upstream ────────────────────────
  services.unbound = {
    enable = true;
    settings = {
      server = {
        # Listen only on loopback so Pi-hole is the only entry point
        interface           = [ "127.0.0.1" ];
        port                = 5335;
        do-ip4              = "yes";
        do-ip6              = "no";
        do-udp              = "yes";
        do-tcp              = "yes";

        # Harden
        harden-glue                   = "yes";
        harden-dnssec-stripped         = "yes";
        use-caps-for-id               = "no";
        harden-large-queries          = "yes";
        harden-referral-path          = "no";  # can cause issues with some zones
        unwanted-reply-threshold      = 10000;
        edns-buffer-size              = 1232;

        # Performance
        prefetch                      = "yes";
        num-threads                   = 2;
        so-rcvbuf                     = "1m";
        msg-cache-slabs               = 2;
        rrset-cache-slabs             = 2;
        infra-cache-slabs             = 2;
        key-cache-slabs               = 2;
        rrset-cache-size              = "100m";
        msg-cache-size                = "50m";

        # Privacy
        hide-identity                 = "yes";
        hide-version                  = "yes";
        qname-minimisation            = "yes";
        private-address               = [
          "192.168.0.0/16"
          "169.254.0.0/16"
          "172.16.0.0/12"
          "10.0.0.0/8"
          "fd00::/8"
          "fe80::/10"
        ];
      };

      # DNS-over-HTTPS upstream forwarders (Cloudflare + Quad9)
      # Unbound uses dns-over-https via the forward-tls-upstream mechanism.
      forward-zone = [
        {
          name           = ".";
          forward-tls-upstream = "yes";
          # Cloudflare
          forward-addr   = [
            "1.1.1.1@853#cloudflare-dns.com"
            "1.0.0.1@853#cloudflare-dns.com"
            # Quad9 (uncomment to add)
            # "9.9.9.9@853#dns.quad9.net"
            # "149.112.112.112@853#dns.quad9.net"
          ];
        }
      ];
    };
  };

  # ── Firewall — expose Pi-hole DNS to LAN ──────────────────────────────────
  networking.firewall = {
    allowedTCPPorts = [ 53 ];
    allowedUDPPorts = [ 53 ];
    # Pi-hole web UI on port 8053 (avoids clash with Nextcloud's :80)
    # Adjust in the docker run command above if you want a different port.
    allowedTCPPorts = lib.mkMerge [ config.networking.firewall.allowedTCPPorts [ 8053 ] ];
  };
}
