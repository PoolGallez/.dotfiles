{config, pkgs, inputs,  ... } : 
{ 

  imports = [
      ../doom-emacs/doom.nix
  ]; 
  environment.systemPackages = with pkgs; [ 
      spotify 
      telegram-desktop 
      neovim
      git
      openssh
      discord
      signal-desktop 
      p7zip
      qemu
      quickemu
      libpcap
      wl-clipboard
      age
  ];

  # git configuration
  programs.git.enable = true;  
  
}
