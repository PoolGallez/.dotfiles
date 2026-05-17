{ config, pkgs, ... }:

{
  # ── Primary admin user ────────────────────────────────────────────────────
  users.users.admin = {
    isNormalUser   = true;
    description    = "Primary admin";
    extraGroups    = [ "wheel" "networkmanager" "docker" ];
    shell          = pkgs.bash;

    # SSH public key(s) — add your own here.
    # The private key must be added to your SSH agent on your workstation.
    openssh.authorizedKeys.keys = [
      # "ssh-ed25519 AAAAC3... you@workstation"
    ];

    # Password is disabled; use SSH keys only.
    # To set a hashed password: `mkpasswd -m sha-512`
    hashedPassword = "!";   # "!" = locked password
  };

  # ── Root locked ───────────────────────────────────────────────────────────
  users.users.root.hashedPassword = "!";

  # ── Sudo ──────────────────────────────────────────────────────────────────
  security.sudo = {
    enable         = true;
    wheelNeedsPassword = true;  # set false for passwordless sudo if preferred
  };
}
