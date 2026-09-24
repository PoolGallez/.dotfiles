;;; pre-early-init.el --- Pre Early Init -*- no-byte-compile: t; lexical-binding: t; -*-

(setq minimal-emacs-gc-cons-threshold (* 2 1000 1000))

(when (eq system-type 'android)
  (setq minimal-emacs-ui-features '(menu-bar tool-bar context-menu dialogs)))
