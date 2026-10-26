# Restored from an uncommitted stash ("syncthing + zoom", stash@{0}) that
# had configured this on getriebe until a Sep 21 rebuild dropped it,
# silently stopping the daemon (confirmed via journalctl + comparing
# NixOS generations system-57/system-58). zoom-us from that same stash is
# NOT restored here — only syncthing was asked for.
{ config, lib, pkgs, ... }:

let
  user = config.my.system.user.name;
  home = "/home/${user}";
in
{
  options.my.services.syncthing.enable = lib.mkEnableOption "Syncthing for the personal user";

  config = lib.mkIf config.my.services.syncthing.enable {
    environment.systemPackages = with pkgs; [
      syncthing
    ];

    services.syncthing = {
      enable = true;
      openDefaultPorts = true; # Opens the sync ports in the firewall; does NOT expose the GUI port.
      inherit user;
      dataDir = home; # Base data directory — syncs the whole home directory, as before.
      configDir = "${home}/.config/syncthing"; # Where keys and config live.
    };
  };
}
