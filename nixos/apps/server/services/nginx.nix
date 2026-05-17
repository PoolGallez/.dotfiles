{ config, pkgs, lib, ... }:

# ── nginx reverse proxy + Let's Encrypt (DNS-01 via DuckDNS) ─────────────────
#
# All services sit behind nginx with HTTPS.  Certificates are issued by
# Let's Encrypt using the DNS-01 challenge via DuckDNS — no inbound port
# 80/443 required, works perfectly with VPN-only access.
#
# Domain layout (replace YOUR_SUBDOMAIN with your actual DuckDNS subdomain):
#   https://nextcloud.YOUR_SUBDOMAIN.duckdns.org
#   https://immich.YOUR_SUBDOMAIN.duckdns.org
#   https://pihole.YOUR_SUBDOMAIN.duckdns.org
#   https://calibre.YOUR_SUBDOMAIN.duckdns.org
#
# HOW DNS-01 WORKS HERE:
#   1. The ACME client (on this server) calls DuckDNS API to set a TXT record.
#   2. Let's Encrypt reads the TXT record to verify domain ownership.
#   3. Certificate is issued and stored in /var/lib/acme/.
#   4. nginx picks up the cert automatically (reloads on renewal).
#   No inbound ports needed. WireGuard clients reach nginx on the VPN IP.
#
# FIREWALL NOTE:
#   Port 443 is only opened on the WireGuard interface (wg0).
#   The public internet cannot reach nginx directly.
# ─────────────────────────────────────────────────────────────────────────────

let
  # ── Configuration — edit these ────────────────────────────────────────────
  duckdnsDomain  = "YOUR_SUBDOMAIN.duckdns.org";  # ← your full DuckDNS domain

  # Virtual host names — subdomains of your DuckDNS domain
  nextcloudHost  = "nextcloud.${duckdnsDomain}";
  immichHost     = "immich.${duckdnsDomain}";
  piholeHost     = "pihole.${duckdnsDomain}";
  calibreHost    = "calibre.${duckdnsDomain}";

  # ACME contact email (for Let's Encrypt expiry notices)
  acmeEmail      = "you@example.com";             # ← your email

  # WireGuard VPN IP of this server — nginx listens here for VPN clients
  vpnIp          = "10.10.0.1";
in
{
  # ── ACME / Let's Encrypt ──────────────────────────────────────────────────
  security.acme = {
    acceptTerms = true;
    defaults = {
      email       = acmeEmail;
      dnsProvider = "duckdns";

      # DuckDNS token injected from sops at runtime
      # lego (the ACME client NixOS uses) reads this env var automatically
      credentialsFile = config.sops.secrets."acme/duckdnsToken".path;

      # DNS-01 propagation wait — DuckDNS is fast but give it a moment
      dnsPropagationCheck = true;
    };

    certs = {
      # One wildcard cert covers all subdomains
      "${duckdnsDomain}" = {
        domain      = "*.${duckdnsDomain}";
        extraDomainNames = [ duckdnsDomain ];
        group       = "nginx";   # nginx can read the cert
      };
    };
  };

  # ── nginx ─────────────────────────────────────────────────────────────────
  services.nginx = {
    enable = true;

    # Security defaults
    recommendedTlsSettings    = true;
    recommendedOptimisation   = true;
    recommendedGzipSettings   = true;
    recommendedProxySettings  = true;

    # Global TLS hardening
    sslCiphers   = "ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256";
    sslProtocols = "TLSv1.2 TLSv1.3";

    # ── Nextcloud ────────────────────────────────────────────────────────────
    # The NixOS nextcloud module generates its own nginx vhost automatically.
    # We override it here to add the wildcard cert and restrict to VPN IP.
    # (The nextcloud module sets services.nginx.virtualHosts."${hostName}" —
    #  we merge into it via mkForce on the SSL fields.)
    virtualHosts.${nextcloudHost} = {
      listen = [
        { addr = vpnIp; port = 443; ssl = true; }
        { addr = "127.0.0.1"; port = 443; ssl = true; }
      ];
      forceSSL   = true;
      sslCertificate    = "/var/lib/acme/${duckdnsDomain}/cert.pem";
      sslCertificateKey = "/var/lib/acme/${duckdnsDomain}/key.pem";
      # Nextcloud module adds its own locations; we just set SSL here.
    };

    # ── Immich ───────────────────────────────────────────────────────────────
    virtualHosts.${immichHost} = {
      listen = [{ addr = vpnIp; port = 443; ssl = true; }];
      forceSSL          = true;
      sslCertificate    = "/var/lib/acme/${duckdnsDomain}/cert.pem";
      sslCertificateKey = "/var/lib/acme/${duckdnsDomain}/key.pem";

      locations."/" = {
        proxyPass       = "http://127.0.0.1:2283";
        proxyWebsockets = true;   # Immich uses WebSockets for live updates
        extraConfig = ''
          client_max_body_size 50G;   # large video uploads
          proxy_read_timeout   600s;
          proxy_send_timeout   600s;
        '';
      };
    };

    # ── Pi-hole ──────────────────────────────────────────────────────────────
    virtualHosts.${piholeHost} = {
      listen = [{ addr = vpnIp; port = 443; ssl = true; }];
      forceSSL          = true;
      sslCertificate    = "/var/lib/acme/${duckdnsDomain}/cert.pem";
      sslCertificateKey = "/var/lib/acme/${duckdnsDomain}/key.pem";

      locations."/" = {
        proxyPass = "http://127.0.0.1:8053";
        extraConfig = ''
          proxy_set_header Host $host;
        '';
      };
    };

    # ── Calibre-Web ──────────────────────────────────────────────────────────
    virtualHosts.${calibreHost} = {
      listen = [{ addr = vpnIp; port = 443; ssl = true; }];
      forceSSL          = true;
      sslCertificate    = "/var/lib/acme/${duckdnsDomain}/cert.pem";
      sslCertificateKey = "/var/lib/acme/${duckdnsDomain}/key.pem";

      locations."/" = {
        proxyPass = "http://127.0.0.1:8083";
        extraConfig = ''
          proxy_set_header Host $host;
          client_max_body_size 500M;   # ebook uploads
        '';
      };
    };
  };

  # ── Firewall — HTTPS on VPN interface only ────────────────────────────────
  # Port 443 is reachable from WireGuard clients (10.10.0.0/24) only.
  # The public internet hits the WireGuard UDP port (51820) and nothing else.
  networking.firewall.interfaces."wg0".allowedTCPPorts = [ 443 ];

  # HTTP redirect — only needed locally (nextcloud module uses it internally)
  networking.firewall.interfaces."lo".allowedTCPPorts = [ 80 ];

  # ── ACME needs outbound HTTPS to Let's Encrypt + DuckDNS API ─────────────
  # (outbound is allowed by default; no extra firewall rule needed)

  # ── Ensure nginx reloads when certs renew ────────────────────────────────
  # NixOS ACME module does this automatically via systemd post-run hooks.
  # Nothing extra needed.
}
