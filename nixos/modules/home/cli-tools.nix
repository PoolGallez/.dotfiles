# Personal CLI toolbelt — user-scoped (home-manager), not duplicated at the
# NixOS system level. git/openssh/p7zip/age moved here from the old
# apps/comms/comms.nix grab-bag; ripgrep/fd moved here from the old
# apps/doom-emacs/doom.nix system package list.
{ pkgs, ... }:

{
  home.packages = with pkgs; [
    ripgrep
    fd
    openssh
    p7zip
    age
  ];

  programs.git.enable = true;
}
