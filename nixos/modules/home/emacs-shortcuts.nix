# Linux/home-manager equivalents of the Windows Emacs-Shortcuts/*.lnk files
# (see ~/.dotfiles/emacs/.config/emacs/Emacs-Shortcuts and the "Emacs client
# popup frames" section of Config.org). Those .lnk files had no wrapper
# script either — Target was emacsclientw.exe and Arguments carried the
# flags directly. Same here: each emacsclient invocation is inlined
# straight into the desktop entry's Exec= line (Desktop Entry Spec quoting:
# double quotes, with an embedded literal quote escaped as \"), no
# separate binary needed.
#
# The daemon itself ("Emacs Daemon.lnk") is not duplicated here — it's
# already covered at the system level by services.emacs.enable in
# modules/nixos/emacs.nix, imported on every desktop host directly.
#
# Two independent, non-overlapping invocation paths for the same three
# commands:
#   - xdg.desktopEntries: searchable in KRunner/Kickoff, the direct
#     equivalent of the Windows Start Menu shortcuts (which had no
#     assigned hotkey either — checked the .lnk headers, all zero).
#   - programs.plasma.hotkeys.commands: actual global keypresses, new
#     functionality the Windows side never had. plasma-manager wires
#     this through a hidden multi-action desktop entry + kglobalshortcutsrc,
#     so `command` uses the same Desktop Entry Exec-key quoting as
#     xdg.desktopEntries' `exec` below, not shell quoting — the two
#     strings for each action are intentionally identical.
# programs.plasma.enable only writes the keys declared here; without
# overrideConfig (not used) it never touches unrelated Plasma settings
# (panels, widgets, theme).
{ pkgs, ... }:

let
  # Focus the main frame, or create one from the client side when none
  # exists: make-frame inside the daemon has no display and fails with
  # "Unknown terminal type", leaving a failed app-emacs@ systemd unit
  # that makes home-manager's reloadSystemd report a degraded session.
  emacsFocus = pkgs.writeShellScript "emacs-focus" ''
    out=$(emacsclient -a "" -n -e '(if (glz/focus-main-frame) "focused" "none")')
    case "$out" in
      *focused*) ;;
      *) exec emacsclient -n -c ;;
    esac
  '';
in
{
  programs.plasma.enable = true;

  programs.plasma.hotkeys.commands = {
    emacs-focus = {
      name = "Emacs Focus";
      comment = "Open or focus the Emacs window";
      key = "Meta+Shift+E";
      command = "${emacsFocus}";
    };
    emacs-capture = {
      name = "Emacs Capture";
      comment = "Org capture popup";
      key = "Meta+Shift+C";
      command = ''emacsclient -n -u -c -F "((glz-popup . t) (width . 100) (height . 25))" -e "(run-at-time 0 nil (quote org-capture))"'';
    };
    emacs-agenda = {
      name = "Emacs Agenda";
      comment = "Org agenda dashboard popup";
      key = "Meta+Shift+A";
      command = ''emacsclient -n -u -c -F "((glz-popup . t))" -e "(run-at-time 0 nil (quote org-agenda) nil \"d\")"'';
    };
  };

  xdg.desktopEntries = {
    emacs = {
      name = "Emacs";
      comment = "Open or focus the Emacs window";
      exec = "${emacsFocus}";
      icon = "emacs";
      terminal = false;
      categories = [ "Development" "TextEditor" ];
    };
    emacs-capture = {
      name = "Emacs Capture";
      comment = "Org capture popup";
      exec = ''emacsclient -n -u -c -F "((glz-popup . t) (width . 100) (height . 25))" -e "(run-at-time 0 nil (quote org-capture))"'';
      icon = "emacs";
      terminal = false;
      categories = [ "Development" "Office" ];
    };
    emacs-agenda = {
      name = "Emacs Agenda";
      comment = "Org agenda dashboard popup";
      exec = ''emacsclient -n -u -c -F "((glz-popup . t))" -e "(run-at-time 0 nil (quote org-agenda) nil \"d\")"'';
      icon = "emacs";
      terminal = false;
      categories = [ "Development" "Office" ];
    };
  };
}
