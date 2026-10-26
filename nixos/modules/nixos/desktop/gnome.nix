# Configuration for the GNOME desktop environment and its app suite —
# the GNOME counterpart of plasma.nix (GDM instead of SDDM, same autologin).
#
# services.gnome.core-apps (on by default with GNOME) pulls in the
# standard GNOME apps: Files, Text Editor, Console, Calendar, Contacts,
# Maps, Weather, Clocks, Music, Loupe, Papers, Snapshot, Software, …
# my.desktop.gnome.extraApps adds the power-user tools on top.
{ config, lib, pkgs, ... }:

let
  cfg = config.my.desktop.gnome;
in
{
  options.my.desktop.gnome = {
    extraApps = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = with pkgs; [
        gnome-tweaks            # fonts, titlebar buttons, startup apps
        dconf-editor            # browse/edit every GNOME setting
        gnome-extension-manager # install/configure Shell extensions
      ];
      defaultText = lib.literalExpression "with pkgs; [ gnome-tweaks dconf-editor gnome-extension-manager ]";
      description = "Extra GNOME apps installed on top of the core GNOME suite.";
    };

    games = lib.mkEnableOption "the GNOME games collection";
  };

  config = lib.mkIf (config.my.desktop.environment == "gnome") {
    services.displayManager.gdm.enable = true;
    services.desktopManager.gnome.enable = true;

    services.gnome.core-apps.enable = true;
    services.gnome.games.enable = cfg.games;

    # Don't export GTK_IM_MODULE=ibus: with it GTK apps (and Firefox) talk
    # to ibus directly instead of through Wayland's text-input protocol, so
    # GNOME Shell never learns a text field got focus and the on-screen
    # keyboard only ever opens for the Shell's own entries. ibus keeps
    # working through mutter.
    i18n.inputMethod.ibus.waylandFrontend = true;

    # Same autologin as SDDM under Plasma.
    services.displayManager.autoLogin = {
      enable = true;
      user = config.my.system.user.name;
    };
    # GDM autologin races getty on tty1 otherwise (NixOS wiki, "GNOME").
    systemd.services."getty@tty1".enable = false;
    systemd.services."autovt@tty1".enable = false;

    environment.systemPackages = cfg.extraApps ++ [
      pkgs.wl-clipboard # Wayland clipboard CLI, same as under Plasma
    ];
  };
}
