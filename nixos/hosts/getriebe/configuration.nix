# GPD Pocket 4 laptop/convertible.
{ config, pkgs, ... }:

{
  imports =
    [ # Include the results of the hardware scan.
      ./hardware-configuration.nix
      ../../modules/nixos
    ];

  my.profiles.workstation.enable = true;

  # "plasma" or "gnome" — the one desktop (and app suite) this host gets.
  my.desktop.environment = "gnome";

  my.apps = {
    gaming.enable = true;
    comms.enable = true;
    emacs.enable = true;
    virtualisation.enable = true;
    wireshark.enable = true;
    nextcloud-client.enable = true;
  };

  my.services.syncthing.enable = true;

  # To cross compile and perform updates on rock64
  boot.binfmt.emulatedSystems = [ "aarch64-linux" ];

  # For Gpd, package to enable automatic screen rotation
  hardware.sensor.iio.enable = true;
  # No ACCEL_MOUNT_MATRIX override: the ACPI one (0,1,0; 1,0,0; 0,0,-1)
  # follows the panel's native portrait axes, which is what 60-sensor.hwdb
  # asks for with rotated panels — the sensor reads "right-up" with the lid
  # open normally, and mutter adds the panel_orientation on top. A
  # landscape-axes matrix here makes tablet-mode rotation 90° off.

  # No hardware tablet-mode switch on the GPD: derive one from the
  # accelerometer, so GNOME/Plasma know when to offer the on-screen keyboard.
  my.hardware.tablet-switch = {
    enable = true;
    flatSeconds = 1.5; # lying flat this long switches to tablet mode
  };

  # The Novatek I2C-HID touchscreen sometimes comes back dead from s2idle
  # (it stays bound but never sends reports). Rebinding the driver on
  # every resume re-initialises it. Right after resume the controller can
  # still be waking up and the probe reads a garbage HID descriptor, so
  # retry with a growing delay until the bind sticks.
  powerManagement.resumeCommands = ''
    dev=i2c-NVTK0603:00
    drv=/sys/bus/i2c/drivers/i2c_hid_acpi
    if [ -e /sys/bus/i2c/devices/$dev ]; then
      [ -e $drv/$dev ] && echo $dev > $drv/unbind
      for delay in 1 2 3 5 8; do
        sleep $delay
        echo $dev > $drv/bind 2>/dev/null && [ -e $drv/$dev ] && break
        echo "touchscreen rebind failed, retrying" >&2
      done
      [ -e $drv/$dev ] || echo "touchscreen rebind gave up" >&2
    fi
  '';

  # FocalTech FT9362 fingerprint reader (2808:0752): fprintd for GDM/SDDM,
  # the lock screens and sudo. Enroll with `fprintd-enroll` or in Settings.
  my.hardware.focaltech-fingerprint.enable = true;

  hardware.bluetooth.enable = true;

  boot.initrd.luks.devices."luks-58f51fba-fd89-4cae-99e3-e453154fdd8e".device = "/dev/disk/by-uuid/58f51fba-fd89-4cae-99e3-e453154fdd8e";
  networking.hostName = "getriebe"; # Define your hostname.

  # Power saving for portable machine
  networking.networkmanager.wifi.powersave = true;

  users.users.pool.extraGroups = [ "input" ];

  environment.systemPackages = with pkgs; [
    usbutils
    claude-code
    wireguard-tools
  ];

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It‘s perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = "25.05"; # Did you read the comment?

}
