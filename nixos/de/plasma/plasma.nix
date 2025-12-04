# Configuration for plasma desktop environment
{ config, pkgs, ... } : 

{
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
            User = "pool";
        }; 
    };
    enableHidpi = true;
  };

}
