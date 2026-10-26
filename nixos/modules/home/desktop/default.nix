# Which desktop's user settings to manage — always the host's own
# my.desktop.environment (flake.nix passes it into pool@<host>), so it's
# never set by hand. Only the matching module below writes anything;
# the other desktop's existing settings stay on disk untouched until you
# switch back.
#
# A few settings are shared by both desktops even though each wants its
# own: Plasma's GTK sync (kde-gtk-config) writes its cursor, fonts, icon
# theme and scaling into the same dconf keys GNOME uses for itself, plus
# gtk.css/colors.css/settings.ini that force Breeze colours on GTK apps.
# Left alone, GNOME inherits a cursor theme that isn't installed (white
# square) and Plasma's fonts. So whenever the desktop changes, the
# activation step below stashes the outgoing desktop's copy of those under
# ~/.local/state/desktop-switch/<de>/ and restores the incoming one's —
# or, the first time GNOME is used, resets them to GNOME's defaults.
{ config, lib, pkgs, ... }:

let
  de = config.my.home.desktop.environment;
  dconf = "${pkgs.dconf}/bin/dconf";

  # dconf dirs and ~/.config files that both desktops write.
  sharedDconfDirs = [
    "/org/gnome/desktop/interface/"
    "/org/gnome/desktop/wm/preferences/"
  ];
  sharedFiles = lib.concatMap (d: map (f: "${d}/${f}") [ "gtk.css" "colors.css" "settings.ini" ])
    [ "gtk-3.0" "gtk-4.0" ];
in
{
  imports = [
    ./plasma.nix
    ./gnome.nix
  ];

  options.my.home.desktop = {
    environment = lib.mkOption {
      type = lib.types.nullOr (lib.types.enum [ "plasma" "gnome" ]);
      default = null;
      description = "Desktop environment of the host this home configuration is for.";
    };
    tabletSwitch = lib.mkEnableOption ''
      desktop integration of the host's virtual tablet-mode switch
      (my.hardware.tablet-switch; set from the host by flake.nix)'';
  };

  config = lib.mkIf (de != null) {
    # Manual override for the tablet-mode heuristic, searchable in both
    # desktops' launchers (replaces the old osk-toggle entry).
    xdg.desktopEntries.tablet-mode-toggle = lib.mkIf config.my.home.desktop.tabletSwitch {
      name = "Toggle Tablet Mode";
      comment = "Switch between laptop and tablet mode (on-screen keyboard)";
      exec = "tablet-mode toggle";
      icon = "input-keyboard-virtual";
      terminal = false;
      categories = [ "Utility" ];
    };

    home.activation.swapDesktopState = lib.hm.dag.entryBetween [ "dconfSettings" ] [ "writeBoundary" ] ''
      state="${config.xdg.stateHome}/desktop-switch"
      # No marker yet means this home predates the switch, which was Plasma-only.
      prev=$(cat "$state/current" 2>/dev/null || echo plasma)
      next=${de}

      if [ "$prev" != "$next" ] && [[ ! -v DRY_RUN ]]; then
        noteEcho "Desktop changed $prev -> $next: swapping shared GTK/dconf settings"

        # Stash the outgoing desktop's copy.
        rm -rf "$state/$prev"
        mkdir -p "$state/$prev/config"
        ${lib.concatMapStrings (d: ''
          ${dconf} dump ${d} > "$state/$prev/${lib.replaceStrings [ "/" ] [ "_" ] d}.ini" || true
          ${dconf} reset -f ${d}
        '') sharedDconfDirs}
        ${lib.concatMapStrings (f: ''
          if [ -e "${config.xdg.configHome}/${f}" ]; then
            mkdir -p "$state/$prev/config/${dirOf f}"
            mv "${config.xdg.configHome}/${f}" "$state/$prev/config/${f}"
          fi
        '') sharedFiles}

        # Restore the incoming desktop's copy, if it has one (otherwise the
        # resets above leave the desktop's own defaults).
        if [ -d "$state/$next" ]; then
          ${lib.concatMapStrings (d: ''
            f="$state/$next/${lib.replaceStrings [ "/" ] [ "_" ] d}.ini"
            [ -s "$f" ] && ${dconf} load ${d} < "$f"
          '') sharedDconfDirs}
          ${lib.concatMapStrings (f: ''
            if [ -e "$state/$next/config/${f}" ] && [ ! -e "${config.xdg.configHome}/${f}" ]; then
              mkdir -p "${config.xdg.configHome}/${dirOf f}"
              mv "$state/$next/config/${f}" "${config.xdg.configHome}/${f}"
            fi
          '') sharedFiles}
        fi

        mkdir -p "$state"
        echo "$next" > "$state/current"
      fi
    '';
  };
}
