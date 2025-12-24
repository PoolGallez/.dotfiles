{confi, pkgs, ...} : 
{ 
   environment.systemPackages = with pkgs; [ 
      emacs
      ## Emacs itself
      binutils            # native-comp needs 'as', provided by this

      ## Doom dependencies
      ripgrep
      gnutls              # for TLS connectivity

      ## Optional dependencies
      fd                  # faster projectile indexing
      imagemagick         # for image-dired

      emacs-all-the-icons-fonts

      # Couldn't manage to install doom emacs with nix package management, therefore temporarily do the imperative install 
   ];
   services.emacs.package = pkgs.emacs-unstable;
   services.emacs.enable = true;
}
