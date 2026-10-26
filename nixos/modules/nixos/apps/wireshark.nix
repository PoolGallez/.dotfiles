# Wireshark GUI with USB capture (usbmon), and the personal user in the
# wireshark group so captures don't need root.
{ config, lib, pkgs, ... }:

{
  options.my.apps.wireshark.enable = lib.mkEnableOption "Wireshark with USB capture";

  config = lib.mkIf config.my.apps.wireshark.enable {
    environment.systemPackages = [ pkgs.wireshark ];

    programs.wireshark.enable = true;
    programs.wireshark.usbmon.enable = true;
    users.groups.wireshark.members = [ config.my.system.user.name ];
  };
}
