;; Some functionality uses this to identify you, e.g. GPG configuration, email
;; clients, file templates and snippets. It is optional.
(setq user-full-name "Paolo Galletta"
      user-mail-address "galletta.paolo98@gmail.com")

;; This determines the style of line numbers in effect. If set to `nil', line
;; numbers are disabled. For relative line numbers, set this to `relative'.
(setq display-line-numbers-type 'relative)

;; There are two ways to load a theme. Both assume the theme is installed and
;; available. You can either set `doom-theme' or manually load a theme with the
;; `load-theme' function. This is the default:
(setq doom-theme 'doom-nord)

(setq org-directory "~/Documents/PKDB_Org/Notes")

(setq org-roam-directory "~/Documents/PKDB_Org/Zettlekasten")

;
; Setup org-roam-ui
;
(use-package! websocket
  :after org-roam)
(use-package! org-roam-ui
  :after org-roam
  :config
  (setq org-roam-ui-sync-theme t
        org-roam-ui-follow t
        org-roam-ui-update-on-save t
        org-roam-uiopen-on-start t))

;; Automatically tangle our Emacs.org config file when we save it
(defun glz/org-babel-tangle-config ()
  (when (string-equal (buffer-file-name)
                      (expand-file-name "~/.config/doom/config.org"))

    (let ((org-confirm-babel-evaluate nil))
      (org-babel-tangle))))

(add-hook 'org-mode-hook (lambda () (add-hook 'after-save-hook #'glz/org-babel-tangle-config)))

(setq shell-file-name (executable-find
      "bash"))
