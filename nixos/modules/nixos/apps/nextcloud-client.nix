# Nextcloud desktop sync client, plus the desktop's own online-accounts
# integration: KDE needs the kaccounts stack installed explicitly (it
# backs the Nextcloud login in System Settings → Online Accounts), GNOME
# ships gnome-online-accounts with Nextcloud support out of the box.
{ config, lib, pkgs, ... }:

{
  options.my.apps.nextcloud-client.enable = lib.mkEnableOption "the Nextcloud desktop client and online-accounts integration";

  config = lib.mkIf config.my.apps.nextcloud-client.enable {
    environment.systemPackages = with pkgs;
      lib.optionals (config.my.desktop.environment == "plasma") [
        kdePackages.kaccounts-integration
        kdePackages.kaccounts-providers
        kdePackages.signond
        kdePackages.accounts-qt # or libsForQt5 if you are on Plasma 5
        kdePackages.qtwebengine # required backend for the Nextcloud login webview in the accounts wizard
      ]
      ++ [
        nextcloud-client # syncs a local folder + shows up as a Dolphin/Files Places entry
      ];
  };
}
