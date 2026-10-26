# User-level GNOME settings, written into dconf on every home-manager
# switch. Like plasma-manager, dconf.settings only sets the keys declared
# here (e.g. the Emacs hotkeys in ../emacs.nix); everything else changed
# in GNOME Settings stays in ~/.config/dconf/user untouched — and never
# overlaps with Plasma's ~/.config/*rc files, so both desktops keep their
# own configuration across switches.
{ config, lib, pkgs, ... }:

let
  # With a tablet-mode switch present, mutter auto-rotates only in tablet
  # mode ("PanelOrientationManaged"), and on leaving it simply stops
  # following the accelerometer — the panel stays in whatever rotation it
  # had. Put the built-in panel back to normal whenever that happens.
  resetRotationOnLaptopMode = pkgs.writeScript "reset-rotation-on-laptop-mode" ''
    #!${pkgs.python3.withPackages (ps: [ ps.jeepney ])}/bin/python3
    from jeepney import DBusAddress, MatchRule, new_method_call
    from jeepney.bus_messages import message_bus
    from jeepney.io.blocking import open_dbus_connection

    dc = DBusAddress("/org/gnome/Mutter/DisplayConfig",
                     bus_name="org.gnome.Mutter.DisplayConfig",
                     interface="org.gnome.Mutter.DisplayConfig")
    conn = open_dbus_connection(bus="SESSION")

    def reset():
        serial, monitors, logical, _ = conn.send_and_get_reply(
            new_method_call(dc, "GetCurrentState")).body
        builtin, mode = set(), {}
        for (connector, *_), modes, props in monitors:
            if props.get("is-builtin", ("b", False))[1]:
                builtin.add(connector)
            for m in modes:
                if m[6].get("is-current", ("b", False))[1]:
                    mode[connector] = m[0]
        config, changed = [], False
        for x, y, scale, transform, primary, mons, _ in logical:
            if transform != 0 and any(c in builtin for c, *_ in mons):
                transform, changed = 0, True
            config.append((x, y, scale, transform, primary,
                           [(c, mode[c], {}) for c, *_ in mons if c in mode]))
        if changed:
            reply = conn.send_and_get_reply(new_method_call(
                dc, "ApplyMonitorsConfig", "uua(iiduba(ssa{sv}))a{sv}",
                (serial, 1, config, {})))  # 1 = temporary, like mutter's own rotation
            print("reset panel rotation:", reply.header.message_type.name, flush=True)

    rule = MatchRule(type="signal", interface="org.freedesktop.DBus.Properties",
                     member="PropertiesChanged", path=dc.object_path)
    conn.send_and_get_reply(message_bus.AddMatch(rule))
    with conn.filter(rule) as queue:
        while True:
            iface, changed, _ = conn.recv_until_filtered(queue).body
            if iface == dc.interface and changed.get("PanelOrientationManaged", ("b", True))[1] is False:
                reset()
  '';
in
{
  config = lib.mkIf (config.my.home.desktop.environment == "gnome") {
    dconf.settings = {
      "org/gnome/desktop/interface".color-scheme = "prefer-dark";

      # Offer fractional scaling (125/150/175 %) in Settings → Displays —
      # GNOME only exposes 100/200 % otherwise, and getriebe's panel runs
      # at ~230 % under Plasma. xwayland-native-scaling keeps X11 apps
      # (Steam, …) sharp instead of upscaled.
      "org/gnome/mutter".experimental-features = [
        "scale-monitor-framebuffer"
        "xwayland-native-scaling"
      ];
    };

    systemd.user.services.reset-rotation-on-laptop-mode = lib.mkIf config.my.home.desktop.tabletSwitch {
      Unit = {
        Description = "Reset the panel rotation when GNOME leaves tablet mode";
        PartOf = [ "graphical-session.target" ];
        After = [ "graphical-session.target" ];
      };
      Service = {
        ExecStart = "${resetRotationOnLaptopMode}";
        Restart = "always";
        RestartSec = 3;
      };
      Install.WantedBy = [ "graphical-session.target" ];
    };
  };
}
