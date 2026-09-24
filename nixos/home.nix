{ config, pkgs, ... }:

let
  mkOutOfStoreSymlink = path: config.lib.file.mkOutOfStoreSymlink path;
  configDir = "${config.home.homeDirectory}/.dotfiles";
in
{

  imports = [
     ./configs/neovim/neovim.nix

  ];
  # Home Manager needs a bit of information about you and the paths it should
  # manage.
  home.username = "pool";
  home.homeDirectory = "/home/pool";

  # This value determines the Home Manager release that your configuration is
  # compatible with. This helps avoid breakage when a new Home Manager release
  # introduces backwards incompatible changes.
  #
  # You should not change this value, even if you update Home Manager. If you do
  # want to update the value, then make sure to first check the Home Manager
  # release notes.
  home.stateVersion = "25.11"; # Please read the comment before changing.

  # The home.packages option allows you to install Nix packages into your
  # environment.
  home.packages = with pkgs; [
    # # Adds the 'hello' command to your environment. It prints a friendly
    # # "Hello, world!" when run.
    # pkgs.hello

    # # It is sometimes useful to fine-tune packages, for example, by applying
    # # overrides. You can do that directly here, just don't forget the
    # # parentheses. Maybe you want to install Nerd Fonts with a limited number of
    # # fonts?
    # (pkgs.nerdfonts.override { fonts = [ "FantasqueSansMono" ]; })

    # # You can also create simple shell scripts directly inside your
    # # configuration. For example, this adds a command 'my-hello' to your
    # # environment:
    # (pkgs.writeShellScriptBin "my-hello" ''
    #   echo "Hello, ${config.home.username}!"
    # '')
    ripgrep
    fd

    # Org-mode LaTeX equation preview (org-latex-preview, dvisvgm backend).
    # dvisvgm isn't a standalone nixpkgs package - it's bundled inside
    # texlive's own bin/ directory, so this alone is enough.
    texlive.combined.scheme-medium

    # pdf-tools build deps (Emacs package itself is installed via elpa/straight
    # in post-init.el; these are just what its epdfinfo server compiles against).
    # Only the .dev output (headers/pkg-config) is needed here - the bare
    # `poppler` package aliases to the poppler-glib derivation, whose `out`
    # output collides with the libpoppler-glib.so that poppler-utils below
    # already bundles, breaking `home-manager switch` with a buildEnv
    # conflicting-paths error.
    poppler.dev
    pkg-config
    gcc

    # `dot` binary, for the #+begin_src dot diagram blocks in the course notes
    graphviz

    # `pdftoppm`/`pdftocairo`/`pdfimages`, for cropping a scan of the
    # original handwritten sketch out of a source PDF page
    poppler-utils
  ];

  # Home Manager is pretty good at managing dotfiles. The primary way to manage
  # plain files is through 'home.file'.
  home.file = {
    # # Building this configuration will create a copy of 'dotfiles/screenrc' in
    # # the Nix store. Activating the configuration will then make '~/.screenrc' a
    # # symlink to the Nix store copy.
    # ".screenrc".source = dotfiles/screenrc;

    # # You can also set the file content immediately.
    # ".gradle/gradle.properties".text = ''
    #   org.gradle.console=verbose
    #   org.gradle.daemon.idletimeout=3600000
    # '';
     
  };

  # Home Manager can also manage your environment variables through
  # 'home.sessionVariables'. These will be explicitly sourced when using a
  # shell provided by Home Manager. If you don't want to manage your shell
  # through Home Manager then you have to manually source 'hm-session-vars.sh'
  # located at either
  #
  #  ~/.nix-profile/etc/profile.d/hm-session-vars.sh
  #
  # or
  #
  #  ~/.local/state/nix/profiles/profile/etc/profile.d/hm-session-vars.sh
  #
  # or
  #
  #  /etc/profiles/per-user/pool/etc/profile.d/hm-session-vars.sh
  #
  home.sessionVariables = {
    # EDITOR = "emacs";
  };

  # Let Home Manager install and manage itself.
  programs.home-manager.enable = true;
}

