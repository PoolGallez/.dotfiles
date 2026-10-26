# Virtual tablet-mode switch for convertibles whose firmware exposes none
# (getriebe, a GPD Pocket 4: only a lid switch). Without one, both desktops
# guess wrong about the on-screen keyboard — mutter keeps GNOME's touch mode
# off while the built-in touchpad exists (so the OSK never shows on tap),
# and KWin can't leave laptop mode either.
#
# This service creates a uinput device with SW_TABLET_MODE, which libinput,
# mutter and KWin treat exactly like a hardware switch, and drives it with
# the heuristic of the old ~/.local/bin/osk-auto script:
#   - tablet ON  when the screen lies flat for `flatSeconds`
#   - tablet OFF when the physical keyboard is used (`typeKeys` presses
#     within `typeWindow` seconds); it then stays off until the device is
#     lifted and laid flat again
# `tablet-mode on|off|toggle|status` overrides it by hand.
{ config, lib, pkgs, ... }:

let
  cfg = config.my.hardware.tablet-switch;
  runDir = "/run/tablet-mode";

  daemon = pkgs.writeScript "tablet-switch" ''
    #!${pkgs.python3.withPackages (ps: [ ps.evdev ])}/bin/python3
    import grp, os, select, sys, time
    import evdev
    from evdev import UInput, ecodes as e

    ACCEL = ${builtins.toJSON cfg.accelerometer}
    KBD = ${builtins.toJSON cfg.keyboard}
    FLAT_Y, FLAT_Z = ${toString cfg.flatMaxTilt}, ${toString cfg.flatMinZ}
    HOLD, TYPE_KEYS, TYPE_WINDOW, POLL = ${toString cfg.flatSeconds}, ${toString cfg.typeKeys}, ${toString cfg.typeWindow}, 0.5
    RUN = "${runDir}"

    def log(*a): print(*a, flush=True)

    def find_accel():
        base = "/sys/bus/iio/devices"
        for d in sorted(os.listdir(base)):
            try:
                if open(f"{base}/{d}/name").read().strip() == ACCEL:
                    return f"{base}/{d}"
            except OSError:
                pass
        sys.exit(f"accelerometer {ACCEL!r} not found")

    def open_kbd():
        for path in evdev.list_devices():
            try:
                d = evdev.InputDevice(path)
            except OSError:
                continue
            if d.name == KBD and e.KEY_A in d.capabilities().get(e.EV_KEY, []):
                log(f"watching keyboard {path}")
                return d
            d.close()
        return None

    accel = find_accel()
    def raw(axis): return int(open(f"{accel}/in_accel_{axis}_raw").read())

    fifo_path = f"{RUN}/control"
    if not os.path.exists(fifo_path):
        os.mkfifo(fifo_path)
    os.chown(fifo_path, 0, grp.getgrnam(${builtins.toJSON cfg.group}).gr_gid)
    os.chmod(fifo_path, 0o660)
    fifo = os.open(fifo_path, os.O_RDWR | os.O_NONBLOCK)  # RDWR: never sees EOF

    ui = UInput({e.EV_SW: [e.SW_TABLET_MODE]}, name="Virtual tablet-mode switch", bustype=e.BUS_HOST)
    state = False
    def set_mode(on, why):
        global state
        state = on
        ui.write(e.EV_SW, e.SW_TABLET_MODE, int(on)); ui.syn()
        open(f"{RUN}/state", "w").write("tablet\n" if on else "laptop\n")
        log(f"{'tablet' if on else 'laptop'} mode ({why})")
    set_mode(False, "startup")

    kbd, kbd_retry, keys = None, 0.0, []
    flat, armed, last_sample = 0, True, 0.0
    while True:
        now = time.monotonic()
        if kbd is None and now >= kbd_retry:
            kbd, kbd_retry = open_kbd(), now + 5
        fds = [fifo] + ([kbd.fd] if kbd else [])
        ready, _, _ = select.select(fds, [], [], POLL)

        if kbd and kbd.fd in ready:
            try:
                keys += [time.monotonic() for ev in kbd.read() if ev.type == e.EV_KEY and ev.value == 1]
            except OSError:
                kbd = None
        if fifo in ready:
            for cmd in os.read(fifo, 256).decode(errors="ignore").split():
                want = {"on": True, "off": False, "toggle": not state}.get(cmd)
                if want is not None and want != state:
                    set_mode(want, "manual")
                    armed, keys = False, []

        now = time.monotonic()
        keys = [t for t in keys if now - t <= TYPE_WINDOW]
        if now - last_sample >= POLL:
            last_sample = now
            try:
                is_flat = -FLAT_Y < raw("y") < FLAT_Y and raw("z") < FLAT_Z
            except OSError:
                is_flat = False
            if is_flat:
                flat += 1
            else:
                flat, armed = 0, True

        if state and len(keys) >= TYPE_KEYS:
            set_mode(False, "typing on the keyboard")
            armed, keys = False, []
        elif not state and armed and flat * POLL >= HOLD:
            set_mode(True, "lying flat")
            armed = False
  '';

  tabletMode = pkgs.writeShellScriptBin "tablet-mode" ''
    case "''${1:-status}" in
      on|off|toggle) echo "$1" > ${runDir}/control ;;
      status) cat ${runDir}/state ;;
      *) echo "usage: tablet-mode [on|off|toggle|status]" >&2; exit 1 ;;
    esac
  '';
in
{
  options.my.hardware.tablet-switch = {
    enable = lib.mkEnableOption "a virtual tablet-mode switch driven by the accelerometer and keyboard use";

    accelerometer = lib.mkOption {
      type = lib.types.str;
      default = "mxc4005";
      description = "IIO name of the accelerometer in the display half.";
    };
    keyboard = lib.mkOption {
      type = lib.types.str;
      default = "HAILUCK CO.,LTD USB KEYBOARD";
      description = "evdev name of the built-in keyboard whose use means laptop mode.";
    };
    flatMaxTilt = lib.mkOption {
      type = lib.types.int;
      default = 400;
      description = "Raw |y| below which the screen counts as level.";
    };
    flatMinZ = lib.mkOption {
      type = lib.types.int;
      default = -1200;
      description = "Raw z below which the screen counts as facing up.";
    };
    flatSeconds = lib.mkOption {
      type = lib.types.number;
      default = 3;
      description = "How long the screen must lie flat before tablet mode turns on.";
    };
    typeKeys = lib.mkOption {
      type = lib.types.int;
      default = 4;
      description = "Key presses within typeWindow seconds that switch back to laptop mode.";
    };
    typeWindow = lib.mkOption {
      type = lib.types.number;
      default = 3;
    };
    group = lib.mkOption {
      type = lib.types.str;
      default = "users";
      description = "Group allowed to override the mode with `tablet-mode`.";
    };
  };

  config = lib.mkIf cfg.enable {
    hardware.uinput.enable = true;

    environment.systemPackages = [ tabletMode ];

    systemd.services.tablet-switch = {
      description = "Virtual tablet-mode switch (accelerometer + keyboard heuristic)";
      wantedBy = [ "multi-user.target" ];
      after = [ "systemd-udev-settle.service" "systemd-modules-load.service" ];
      serviceConfig = {
        ExecStart = daemon;
        Restart = "always";
        RestartSec = 2;
        RuntimeDirectory = "tablet-mode";
        RuntimeDirectoryMode = "0755";
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
      };
    };
  };
}
