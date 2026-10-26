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
  # The ACPI mount matrix of the accelerometer follows the panel's native
  # portrait axes, not the landscape ones after panel_orientation, so the
  # desktop saw "right-up" with the lid open normally. Rotated by 90°, as
  # 60-sensor.hwdb asks for rotated panels.
  services.udev.extraHwdb = ''
    sensor:modalias:acpi:MXC6655*:dmi:*:svnGPD:pnG1628-04:*
     ACCEL_MOUNT_MATRIX=-1, 0, 0; 0, 1, 0; 0, 0, -1
  '';

  # No hardware tablet-mode switch on the GPD: derive one from the
  # accelerometer, so GNOME/Plasma know when to offer the on-screen keyboard.
  my.hardware.tablet-switch = {
    enable = true;
    flatSeconds = 1.5; # lying flat this long switches to tablet mode
  };

  # The Novatek I2C-HID touchscreen sometimes comes back dead from s2idle
  # (it stays bound but never sends reports). Rebinding the driver on
  # every resume re-initialises it; it takes about a second.
  powerManagement.resumeCommands = ''
    dev=i2c-NVTK0603:00
    drv=/sys/bus/i2c/drivers/i2c_hid_acpi
    if [ -e /sys/bus/i2c/devices/$dev ]; then
      [ -e $drv/$dev ] && echo $dev > $drv/unbind
      sleep 0.5
      echo $dev > $drv/bind || echo "touchscreen rebind failed" >&2
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
