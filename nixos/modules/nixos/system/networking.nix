{ config, lib, ... }:

{
  options.my.system.networking.enable = lib.mkEnableOption "NetworkManager";

  config = lib.mkIf config.my.system.networking.enable {
    # Enable networking
    networking.networkmanager.enable = true;
  };
}
