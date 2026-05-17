{ config, pkgs, ... }:

{
  # ── Nix / Flakes ──────────────────────────────────────────────────────────
  nix = {
    settings = {
      experimental-features = [ "nix-command" "flakes" ];
      auto-optimise-store   = true;
      # Allow the primary admin user to manage nix without sudo
      trusted-users = [ "root" "@wheel" ];
    };
    gc = {
      automatic = true;
      dates     = "weekly";
      options   = "--delete-older-than 30d";
    };
  };

  nixpkgs.config.allowUnfree = false;

  # ── Boot ──────────────────────────────────────────────────────────────────
  # Actual bootloader settings live in hardware-configuration.nix
  boot.tmp.cleanOnBoot = true;

  # ── Locale / Time ─────────────────────────────────────────────────────────
  time.timeZone = "Europe/Berlin";   # ← change to your timezone

  i18n.defaultLocale  = "en_US.UTF-8";
  console.keyMap      = "us";

  # ── Global packages ───────────────────────────────────────────────────────
  environment.systemPackages = with pkgs; [
    # Essentials
    vim
    git
    curl
    wget
    htop
    btop
    lsof
    file
    unzip
    tmux

    # Disk / filesystem
    smartmontools
    hdparm
    parted
    e2fsprogs
    btrfs-progs

    # Networking
    iproute2
    nftables
    nmap
    tcpdump

    # Sops / secrets
    sops
    age
    ssh-to-age
  ];

  # ── SSH ───────────────────────────────────────────────────────────────────
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      PermitRootLogin        = "no";
      X11Forwarding          = false;
    };
    # Host key used by sops-nix for decryption — do NOT delete this key
    hostKeys = [
      { type = "ed25519"; path = "/etc/ssh/ssh_host_ed25519_key"; }
      { type = "rsa";     bits = 4096; path = "/etc/ssh/ssh_host_rsa_key"; }
    ];
  };

  # ── Firewall base ─────────────────────────────────────────────────────────
  # Individual service modules open their own ports.
  networking.firewall = {
    enable = true;
    allowPing = true;
  };

  # ── System state version ─────────────────────────────────────────────────
  system.stateVersion = "24.11";
}
