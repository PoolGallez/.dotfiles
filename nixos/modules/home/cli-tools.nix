# Personal CLI toolbelt — user-scoped (home-manager), not duplicated at the
# NixOS system level. git/openssh/p7zip/age moved here from the old
# apps/comms/comms.nix grab-bag; ripgrep/fd moved here from the old
# apps/doom-emacs/doom.nix system package list.
{ config, lib, pkgs, ... }:

{
  options.my.home.cli.enable = lib.mkEnableOption "the personal CLI toolbelt";

  config = lib.mkIf config.my.home.cli.enable {
    home.packages = with pkgs; [
      ripgrep
      fd
      openssh
      p7zip
      age
    ];

    programs.git.enable = true;
  };
}
