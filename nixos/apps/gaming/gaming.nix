{ config, pkgs, ...} : 

{
    environment.systemPackages = with pkgs; [
      steam
      steam-run # Allows FHS file hierarchy for steam games (Nix is not FHS compliant)
    ];


    #steam options
    programs.steam = {
      enable = true;
      remotePlay.openFirewall = true; # Open ports in the firewall for Steam Remote Play
      dedicatedServer.openFirewall = true; # Open ports in the firewall for Source Dedicated Server
    };

     programs.steam.extraCompatPackages = with pkgs; [
        proton-ge-bin # Enable proton compatibility for Windows games
     ];

    # Allowing steam to install its unfree packages
    nixpkgs.config.allowUnfreePredicate = {pkg, lib}: builtins.elem (lib.getName pkg) [
    "steam"
    "steam-original"
    "steam-unwrapped"
    "steam-run"
    ];

 
}
