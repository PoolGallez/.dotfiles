;;; pre-early-init.el --- Pre Early Init -*- no-byte-compile: t; lexical-binding: t; -*-

(setq minimal-emacs-gc-cons-threshold (* 2 1000 1000))

(when (eq system-type 'android)
  (setq minimal-emacs-ui-features '(menu-bar tool-bar context-menu dialogs)))

(when (eq system-type 'android)
  (ignore-errors
    (let ((termux-bin "/data/data/com.termux/files/usr/bin"))
      (when (file-directory-p termux-bin)
        (setenv "PATH" (concat (getenv "PATH") ":" termux-bin))
        (setq exec-path (append exec-path (list termux-bin))))))

  (unless (gnutls-available-p)
    (setq tls-program '("gnutls-cli -p %p %h"
                         "gnutls-cli -p %p %h --protocols ssl3"))))
