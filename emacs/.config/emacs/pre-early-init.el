;;; pre-early-init.el --- Pre Early Init -*- no-byte-compile: t; lexical-binding: t; -*-

(setq minimal-emacs-gc-cons-threshold (* 2 1000 1000))

(when (eq system-type 'android)
  (setq minimal-emacs-ui-features '(menu-bar tool-bar context-menu dialogs)))

(when (eq system-type 'android)
  ;; No file-directory-p guard: it returned nil this early on the phone even
  ;; though the directory is usable, which silently skipped the PATH setup.
  (let ((termux-bin "/data/data/com.termux/files/usr/bin"))
    (setenv "PATH" (concat termux-bin ":" (getenv "PATH")))
    (push termux-bin exec-path))

  (unless (gnutls-available-p)
    (setq tls-program '("gnutls-cli -p %p %h"
                         "gnutls-cli -p %p %h --protocols ssl3"))))
