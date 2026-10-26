# User-level Plasma settings through plasma-manager. programs.plasma.enable
# only writes the keys declared by the modules (e.g. the Emacs hotkeys in
# ../emacs.nix); without overrideConfig (not used) it never touches
# unrelated Plasma settings (panels, widgets, theme), so whatever is set by
# hand in System Settings survives every switch.
{ config, lib, pkgs, ... }:

let
  # KWin shows its virtual keyboard on any touch, tablet mode or not, so
  # tablet mode alone isn't enough: the input method itself is set only
  # while KWin is in tablet mode (what the old osk-toggle did by hand),
  # following the virtual switch from my.hardware.tablet-switch.
  oskFollowTabletMode = pkgs.writeShellScript "osk-follow-tablet-mode" ''
    osk=/run/current-system/sw/share/applications/org.kde.plasma.keyboard.desktop
    apply() {
      [ "$1" = true ] && im=$osk || im=
      ${pkgs.kdePackages.kconfig}/bin/kwriteconfig6 --notify --file kwinrc --group Wayland --key InputMethod "$im"
    }
    apply "$(busctl --user get-property org.kde.KWin /org/kde/KWin org.kde.KWin.TabletModeManager tabletMode | cut -d' ' -f2)"
    ${pkgs.glib}/bin/gdbus monitor --session --dest org.kde.KWin --object-path /org/kde/KWin |
      while read -r line; do
        case "$line" in
          *TabletModeManager.tabletModeChanged*true*) apply true ;;
          *TabletModeManager.tabletModeChanged*false*) apply false ;;
        esac
      done
  '';
in
{
  config = lib.mkIf (config.my.home.desktop.environment == "plasma") {
    programs.plasma.enable = true;

    systemd.user.services.osk-follow-tablet-mode = lib.mkIf config.my.home.desktop.tabletSwitch {
      Unit = {
        Description = "Enable the Plasma on-screen keyboard only in tablet mode";
        PartOf = [ "graphical-session.target" ];
        After = [ "graphical-session.target" ];
      };
      Service = {
        ExecStart = "${oskFollowTabletMode}";
        Restart = "always";
        RestartSec = 3;
      };
      Install.WantedBy = [ "graphical-session.target" ];
    };
  };
}
