{config, pkgs, ... } : 

{
   environment.systemPackages = with pkgs; [
      spotify
      telegram-desktop
      neovim
      git
      openssh
      discord
 ];

  # git configuration
  programs.git.enable = true;  
}
