# Configuration for plasma desktop environment
{ config, lib, pkgs, ... } :

{
  config = lib.mkIf (config.my.desktop.environment == "plasma") {
    # Plasma 6
    services.desktopManager.plasma6.enable = true;

    # Configuration sddm display manager
    # SDDM Display Manager
    services.displayManager.sddm = {
      enable = true;
      theme = "breeze";
      wayland.enable = true;
      settings = {
        Autologin = {
          enable = true;
          Session = "plasma.desktop";
          User = config.my.system.user.name;
        };
      };
      enableHidpi = true;
    };

    environment.systemPackages = with pkgs; [
      wl-clipboard # Wayland clipboard CLI, used by the Plasma Wayland session
    ];
  };
}
