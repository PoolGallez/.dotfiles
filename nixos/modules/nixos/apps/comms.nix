# Desktop communication/chat apps.
{ config, lib, pkgs, ... }:

{
  options.my.apps.comms.enable = lib.mkEnableOption "chat/communication apps (Telegram, Discord, Signal, Teams, Spotify)";

  config = lib.mkIf config.my.apps.comms.enable {
    environment.systemPackages = with pkgs; [
      spotify
      telegram-desktop
      discord
      signal-desktop
      teams-for-linux
    ];
  };
}
