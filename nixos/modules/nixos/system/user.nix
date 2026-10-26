# The personal login account shared by the desktop hosts. Hosts add their
# own extraGroups/packages on top (they merge with the ones here); other
# modules read my.system.user.name instead of hardcoding "pool".
{ config, lib, ... }:

let
  cfg = config.my.system.user;
in
{
  options.my.system.user = {
    enable = lib.mkEnableOption "the personal user account";
    name = lib.mkOption {
      type = lib.types.str;
      default = "pool";
      description = "Login name of the personal user.";
    };
    description = lib.mkOption {
      type = lib.types.str;
      default = "Paolo Galletta";
    };
  };

  config = lib.mkIf cfg.enable {
    # Define a user account. Don't forget to set a password with ‘passwd’.
    users.users.${cfg.name} = {
      isNormalUser = true;
      description = cfg.description;
      extraGroups = [ "networkmanager" "wheel" ];
    };
  };
}
