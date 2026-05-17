{ config, pkgs, lib, ... }:

# ── WireGuard VPN server ──────────────────────────────────────────────────────
#
# The ROCKPro64 acts as a WireGuard server (road-warrior / split-tunnel model).
# Clients connect from anywhere on the internet and get routed through the
# server, giving them access to your home LAN and Pi-hole DNS.
#
# Network layout:
#   WireGuard subnet : 10.10.0.0/24
#   Server (rock64)  : 10.10.0.1
#   Phone            : 10.10.0.2
#   Laptop           : 10.10.0.3
#   … add peers as needed
#
# Port: 51820/UDP  — open this on your router (port-forward to 192.168.1.10)
#
# ── KEY GENERATION (run once per peer, on your workstation) ───────────────────
#
#   # Server keypair
#   wg genkey | tee /tmp/server.key | wg pubkey > /tmp/server.pub
#   # Store server.key in sops:  wireguard/serverPrivateKey
#
#   # Per-client keypair
#   wg genkey | tee /tmp/phone.key | wg pubkey > /tmp/phone.pub
#   # Store phone.key in sops:   wireguard/peers/phone/privateKey  (optional,
#   #   only needed if you generate client configs from the server)
#
#   # Preshared key (extra layer, one per peer pair — recommended)
#   wg genpsk > /tmp/phone.psk
#   # Store in sops: wireguard/peers/phone/presharedKey
#
# ── CLIENT CONFIG TEMPLATE ────────────────────────────────────────────────────
#
#   [Interface]
#   PrivateKey = <contents of phone.key>
#   Address    = 10.10.0.2/24
#   DNS        = 10.10.0.1        # routes DNS through Pi-hole on the server
#
#   [Peer]
#   PublicKey           = <contents of server.pub>
#   PresharedKey        = <contents of phone.psk>
#   Endpoint            = YOUR_PUBLIC_IP_OR_DDNS:51820
#   AllowedIPs          = 0.0.0.0/0   # full-tunnel (all traffic via VPN)
#   # AllowedIPs        = 10.10.0.0/24, 192.168.1.0/24  # split-tunnel (LAN only)
#   PersistentKeepalive = 25
#
# ─────────────────────────────────────────────────────────────────────────────

let
  # WireGuard subnet
  vpnSubnet    = "10.10.0.0/24";
  serverVpnIp  = "10.10.0.1";
  vpnInterface = "wg0";
  listenPort   = 51820;

  # LAN subnet — used for routing / firewall rules
  lanSubnet    = "192.168.1.0/24";
  lanInterface = "eth0";
in
{
  # ── Kernel modules ────────────────────────────────────────────────────────
  boot.kernelModules = [ "wireguard" ];

  # ── WireGuard interface ───────────────────────────────────────────────────
  networking.wireguard.interfaces.${vpnInterface} = {
    ips        = [ "${serverVpnIp}/24" ];
    listenPort = listenPort;

    # Private key injected from sops at runtime
    privateKeyFile = config.sops.secrets."wireguard/serverPrivateKey".path;

    # IP forwarding + NAT so VPN clients can reach the LAN and internet
    postSetup = ''
      ${pkgs.iptables}/bin/iptables -t nat -A POSTROUTING \
        -s ${vpnSubnet} -o ${lanInterface} -j MASQUERADE
    '';
    postShutdown = ''
      ${pkgs.iptables}/bin/iptables -t nat -D POSTROUTING \
        -s ${vpnSubnet} -o ${lanInterface} -j MASQUERADE || true
    '';

    # ── Peers ───────────────────────────────────────────────────────────────
    # Add one block per client device.
    # publicKey  : from the client's keypair (wg pubkey < client.key)
    # presharedKeyFile : optional but recommended extra layer of security
    peers = [
      # ── Phone ──────────────────────────────────────────────────────────
      {
        name                    = "phone";
        publicKey               = "REPLACE_WITH_PHONE_PUBLIC_KEY";
        presharedKeyFile        = config.sops.secrets."wireguard/peers/phone/presharedKey".path;
        allowedIPs              = [ "10.10.0.2/32" ];
        # persistentKeepalive   = 25;  # uncomment if client is behind strict NAT
      }

      # ── Laptop ─────────────────────────────────────────────────────────
      {
        name                    = "laptop";
        publicKey               = "REPLACE_WITH_LAPTOP_PUBLIC_KEY";
        presharedKeyFile        = config.sops.secrets."wireguard/peers/laptop/presharedKey".path;
        allowedIPs              = [ "10.10.0.3/32" ];
      }

      # ── Add more peers here ────────────────────────────────────────────
      # {
      #   name             = "tablet";
      #   publicKey        = "REPLACE_WITH_TABLET_PUBLIC_KEY";
      #   presharedKeyFile = config.sops.secrets."wireguard/peers/tablet/presharedKey".path;
      #   allowedIPs       = [ "10.10.0.4/32" ];
      # }
    ];
  };

  # ── IP forwarding ─────────────────────────────────────────────────────────
  boot.kernel.sysctl = {
    "net.ipv4.ip_forward"             = 1;
    "net.ipv4.conf.all.forwarding"    = 1;
    # IPv6 forwarding — uncomment if you add IPv6 WireGuard addresses
    # "net.ipv6.conf.all.forwarding"  = 1;
  };

  # ── Firewall ──────────────────────────────────────────────────────────────
  networking.firewall = {
    # WireGuard listen port
    allowedUDPPorts = [ listenPort ];

    # Allow forwarded traffic from the VPN interface to LAN and back
    # (NixOS firewall drops forwarded packets by default)
    extraCommands = ''
      # Accept traffic forwarded from wg0 → eth0 (VPN clients → LAN/internet)
      iptables -A FORWARD -i ${vpnInterface} -o ${lanInterface} -j ACCEPT
      # Accept established/related return traffic
      iptables -A FORWARD -i ${lanInterface} -o ${vpnInterface} \
        -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
    '';
    extraStopCommands = ''
      iptables -D FORWARD -i ${vpnInterface} -o ${lanInterface} \
        -j ACCEPT 2>/dev/null || true
      iptables -D FORWARD -i ${lanInterface} -o ${vpnInterface} \
        -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
    '';
  };

  # ── Pi-hole DNS reachable from VPN clients ────────────────────────────────
  # Pi-hole binds to all interfaces (--network host in docker run), so
  # VPN clients sending DNS queries to 10.10.0.1:53 will hit Pi-hole.
  # No extra config needed beyond the firewall rules above.
}
