# The Emacs daemon (services.emacs) and native-compilation/build
# dependencies for the personal config at emacs/.config/emacs (a
# minimal-emacs.d based setup — see that directory's Config.org).
#
# Not Doom-specific, despite this module's previous name/location
# (apps/doom-emacs/doom.nix): Doom Emacs itself was abandoned (git history,
# Dec 2025: "gave up on doom through nix packages, installed manually") in
# favor of the config above. ripgrep/fd moved to modules/home/cli-tools.nix
# — home-manager user packages, not duplicated here.
{ pkgs, ... }:

{
  environment.systemPackages = with pkgs; [
    emacs
    binutils            # native-comp needs 'as', provided by this
    gnutls              # for TLS connectivity
    imagemagick         # for image-dired
    emacs-all-the-icons-fonts
  ];

  services.emacs.package = pkgs.emacs-unstable;
  services.emacs.enable = true;
}
