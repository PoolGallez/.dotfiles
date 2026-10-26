# Every home-manager module in this repo, each behind a my.home.* option:
#
#   my.home.cli.enable              ripgrep, fd, ssh, 7z, age, git
#   my.home.neovim.enable           Neovim as default editor
#   my.home.emacs.enable            Emacs daemon, launchers, DE hotkeys
#   my.home.org-toolchain.enable    LaTeX/pdf-tools/graphviz/typst for org
#   my.home.desktop.environment     plasma-manager or GNOME dconf settings,
#                                   set from the host by flake.nix
{ ... }:

{
  imports = [
    ./neovim.nix
    ./emacs.nix
    ./cli-tools.nix
    ./org-toolchain.nix
    ./desktop
  ];
}
