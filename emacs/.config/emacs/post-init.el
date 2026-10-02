;;; post-init.el --- Packages configuration for Minimal Emacs Config -*- no-byte-compile: t; lexical-binding: t; -*-

(defvar glz/platform
  (cond ((eq system-type 'windows-nt) 'windows)
        ((eq system-type 'gnu/linux)  'linux)
        ((eq system-type 'android)    'android)
        (t 'linux))
  "Current platform symbol: windows, linux, or android.")

(defvar glz/enable-org-roam
  (or (memq glz/platform '(linux))
      (and (eq glz/platform 'android)
           (fboundp 'sqlite-available-p)
           (sqlite-available-p)))
  "Org Roam's database wants Emacs's built-in SQLite. On Android the
alternative is a native module that needs a C compiler at runtime, which
isn't available, so this probes for the built-in support instead of
assuming the platform has it.")
(defvar glz/enable-org-roam-ui     (memq glz/platform '(linux)))
(defvar glz/enable-forge           (memq glz/platform '(linux)))
(defvar glz/enable-nix             (memq glz/platform '(linux)))
(defvar glz/enable-testfall        (memq glz/platform '(windows)))
(defvar glz/enable-anforderungen   (memq glz/platform '(windows)))
(defvar glz/enable-canape-par      (memq glz/platform '(windows)))
(defvar glz/enable-lsp-c           (memq glz/platform '(windows linux)))
(defvar glz/enable-latex-preview   (memq glz/platform '(windows linux)))
(defvar glz/enable-open-externally (memq glz/platform '(windows linux)))
(defvar glz/enable-magit
  (or (memq glz/platform '(windows linux))
      (and (eq glz/platform 'android) (executable-find "git")))
  "Needs the real git binary, which on Android only exists via the Termux
PATH bridge (see Pre-Early-Init) once the shared-UID setup is done. Probes
for it instead of assuming, same pattern as the Org Roam sqlite check.")
(defvar glz/enable-pdf-tools       (memq glz/platform '(windows linux)))

(defvar glz/org-directory
  (pcase glz/platform
    ('windows "~/PKDB/")
    ('linux   "~/PKDB/")
    ('android "~/PKDB/"))
  "Root directory for all org files.")

(defvar glz/org-notes-directory (concat glz/org-directory "Notes/")
  "Directory for long, structured notes.")

(defvar glz/org-roam-directory (concat glz/org-directory "roam/")
  "Directory for the org-roam Zettelkasten.")

(defvar glz/org-files
  '(("Tasks.org"     . "#+title: Tasks\n\n* Tasks\n")
    ("Calendar.org"  . "#+title: Calendar\n\n")
    ("Birthdays.org" . "#+title: Birthdays\n\n")
    ("Archive.org"   . "#+title: Archive\n\n"))
  "Org files in `glz/org-directory' with their initial content.")

(defun glz/org-file (name)
  "Return the absolute path of NAME inside `glz/org-directory'."
  (expand-file-name name glz/org-directory))

(defun glz/org-ensure-structure ()
  "Create the PKDB folders and org files if they do not exist yet."
  (dolist (dir (list glz/org-directory glz/org-notes-directory glz/org-roam-directory))
    (make-directory (expand-file-name dir) t))
  (dolist (file glz/org-files)
    (let ((path (glz/org-file (car file))))
      (unless (file-exists-p path)
        (with-temp-file path (insert (cdr file)))))))

(glz/org-ensure-structure)

;; On Windows, Emacs GUI does not inherit the system PATH.
;; Add Git's unix tools so diff, grep, find, etc. are available to all packages.
(when (eq glz/platform 'windows)
  (let ((git-bin "C:/Program Files/Git/usr/bin"))
    (when (file-directory-p git-bin)
      (add-to-list 'exec-path git-bin)
      (setenv "PATH" (concat git-bin ";" (getenv "PATH"))))))

;; clangd for C/C++ LSP — adjust the path if your clangd.exe lives elsewhere.
(let ((clangd-bin "C:/Tools/clangd_22.1.6/bin"))
  (when (file-directory-p clangd-bin)
    (add-to-list 'exec-path clangd-bin)
    (setenv "PATH" (concat clangd-bin ";" (getenv "PATH")))))

(when (eq glz/platform 'android)
  (when (fboundp 'modifier-bar-mode)
    (modifier-bar-mode 1))
  (when (fboundp 'pixel-scroll-precision-mode)
    (pixel-scroll-precision-mode 1))
  (set-face-attribute 'default nil :height 130))

(defun glz/display-startup-time ()
  (message "Emacs loaded in %s with %d garbage collections."
           (format "%.2f seconds"
                   (float-time (time-subtract after-init-time before-init-time)))
           gcs-done))

(add-hook 'emacs-startup-hook #'glz/display-startup-time)

(column-number-mode 1)

(setq visible-bell t)

(setq-default indent-tabs-mode nil
              tab-width 2)

(defun glz/prog-mode-configs ()
  "Personal adjustments for programming modes."
  (display-line-numbers-mode))

(add-hook 'prog-mode-hook #'glz/prog-mode-configs)

(setq initial-major-mode 'lisp-interaction-mode)
(setq initial-scratch-message
      ";; This buffer is for text that is not saved, and for Lisp evaluation.\n;; To create a file, visit it with `\\[find-file]' and enter text in its buffer.\n\n")

;; Meow overrides select-enable-clipboard with its own variable inside meow-save.
;; Setting meow-use-clipboard is the correct way to enable clipboard sync with Meow.
(setq meow-use-clipboard t)

(global-set-key (kbd "<escape>") 'keyboard-escape-quit)

(use-package mwheel
  :ensure nil
  :custom
  (mouse-wheel-tilt-scroll t))

(use-package compile-angel
  :demand t
  :config
  (setq package-native-compile nil)
  (setq compile-angel-verbose t)

  ;; Exclude init files from compilation to avoid subtle issues
  (push "/init.el" compile-angel-excluded-files)
  (push "/early-init.el" compile-angel-excluded-files)
  (push "/pre-init.el" compile-angel-excluded-files)
  (push "/post-init.el" compile-angel-excluded-files)
  (push "/pre-early-init.el" compile-angel-excluded-files)
  (push "/post-early-init.el" compile-angel-excluded-files)
  ;; customs.el is generated by Custom and has no lexical-binding directive
  (push "/customs.el" compile-angel-excluded-files)

  ;; compile-angel has no option to redirect .elc output elsewhere — byte
  ;; compilation always writes next to the source. These three are small,
  ;; load-once personal modes (loaded via load-file, not use-package), so
  ;; the native-comp speedup isn't worth the .elc clutter sitting beside
  ;; them in the dotfiles-tracked directory.
  (push "/canape-par-mode.el" compile-angel-excluded-files)
  (push "/testfall-mode.el" compile-angel-excluded-files)
  (push "/anforderungen-mode.el" compile-angel-excluded-files)

  (compile-angel-on-load-mode 1))

(use-package doom-themes
  :config
  (let ((inhibit-redisplay t))
    (mapc #'disable-theme custom-enabled-themes)
    (load-theme 'doom-dracula t)))

(use-package all-the-icons
  :commands all-the-icons-install-fonts)

(use-package doom-modeline
  :commands doom-modeline-mode
  :hook (after-init . doom-modeline-mode)
  :custom (doom-modeline-height 15))

(use-package autorevert
  :ensure nil
  :commands (auto-revert-mode global-auto-revert-mode)
  :hook (after-init . global-auto-revert-mode)
  :init
  ;; Android's storage is reached through a FUSE/SAF bridge where file-notify
  ;; support is unreliable, so global-auto-revert-mode falls back to this
  ;; poll interval on every buffer; a phone with no other process editing
  ;; the same files doesn't need 3s freshness and shouldn't wake the CPU
  ;; that often on battery.
  (setq auto-revert-interval (if (eq glz/platform 'android) 20 3))
  (setq auto-revert-remote-files nil)
  (setq auto-revert-use-notify t)
  (setq auto-revert-avoid-polling nil))

(use-package recentf
  :ensure nil
  :commands (recentf-mode recentf-cleanup)
  :hook (after-init . recentf-mode)
  :init
  (setq recentf-auto-cleanup (if (daemonp) 300 'never))
  (setq recentf-exclude
        (list "\\.tar$" "\\.tbz2$" "\\.tbz$" "\\.tgz$" "\\.bz2$"
              "\\.bz$" "\\.gz$" "\\.gzip$" "\\.xz$" "\\.zip$"
              "\\.7z$" "\\.rar$"
              "COMMIT_EDITMSG\\'"
              "\\.\\(?:gz\\|gif\\|svg\\|png\\|jpe?g\\|bmp\\|xpm\\)$"
              "-autoloads\\.el$" "autoload\\.el$"))
  :config
  (add-hook 'kill-emacs-hook #'recentf-cleanup -90))

(use-package savehist
  :ensure nil
  :commands (savehist-mode savehist-save)
  :hook (after-init . savehist-mode)
  :init
  (setq history-length 300)
  (setq savehist-autosave-interval 600))

(use-package saveplace
  :ensure nil
  :commands (save-place-mode save-place-local-mode)
  :hook (after-init . save-place-mode)
  :init
  (setq save-place-limit 400))

(use-package winner
  :ensure nil
  :hook (after-init . winner-mode))

(use-package hl-line
  :ensure nil
  :hook (after-init . global-hl-line-mode))

(defun glz/cleanup-stale-auto-saves ()
  "Delete auto-save files older than 14 days from `auto-save-list-file-prefix'."
  (let* ((dir (file-name-directory auto-save-list-file-prefix))
         (cutoff (- (float-time) (* 14 24 60 60))))
    (when (file-directory-p dir)
      (dolist (file (directory-files dir t "\\`[^.]"))
        (when (and (file-regular-p file)
                   (< (float-time (file-attribute-modification-time
                                    (file-attributes file)))
                      cutoff))
          (delete-file file))))))

(run-with-idle-timer 30 nil #'glz/cleanup-stale-auto-saves)

(use-package vertico
  :custom
  (vertico-scroll-margin 0)
  (vertico-count 20)
  (vertico-resize t)
  (vertico-cycle t)
  :bind (:map vertico-map
              ("C-j" . vertico-next)
              ("C-M-j" . vertico-next-group)
              ("C-k" . vertico-previous)
              ("C-M-k" . vertico-previous-group))
  :init
  (vertico-mode t))

(use-package orderless
  :custom
  (completion-styles '(orderless basic))
  (completion-category-overrides '((file (styles partial-completion))))
  (completion-category-defaults nil)
  (completion-pcm-leading-wildcard t))

(when-let* ((elc (locate-library "marginalia.elc")))
  (when (< emacs-major-version 31)
    (delete-file elc)))

(use-package marginalia
  :after compat
  :bind (:map minibuffer-local-map
              ("M-A" . marginalia-cycle))
  :hook (after-init . marginalia-mode))

(use-package embark
  :commands (embark-act
             embark-dwim
             embark-export
             embark-collect
             embark-bindings
             embark-prefix-help-command)
  :bind (("C-." . embark-act)
         ("C-;" . embark-dwim)
         ("C-h B" . embark-bindings))
  :init
  (setq prefix-help-command #'embark-prefix-help-command)
  :config
  (add-to-list 'display-buffer-alist
               '("\\`\\*Embark Collect \\(Live\\|Completions\\)\\*"
                 nil
                 (window-parameters (mode-line-format . none))))

  ;; Copy path or name of a buffer to the kill ring from any buffer picker.
  (defun glz/embark-copy-buffer-file-path (buffer)
    "Copy the full file path (or buffer name) of BUFFER to the kill ring."
    (interactive "bBuffer: ")
    (when-let ((name (or (buffer-file-name (get-buffer buffer)) buffer)))
      (kill-new name)
      (message "Copied: %s" name)))

  (defun glz/embark-copy-buffer-file-name (buffer)
    "Copy just the file name (no directory) of BUFFER to the kill ring."
    (interactive "bBuffer: ")
    (let* ((path (or (buffer-file-name (get-buffer buffer)) buffer))
           (name (file-name-nondirectory path)))
      (kill-new name)
      (message "Copied: %s" name)))

  (define-prefix-command 'glz/embark-buffer-yank-map)
  (define-key embark-buffer-map "y" 'glz/embark-buffer-yank-map)
  (define-key glz/embark-buffer-yank-map "p" #'glz/embark-copy-buffer-file-path)
  (define-key glz/embark-buffer-yank-map "n" #'glz/embark-copy-buffer-file-name))

(use-package embark-consult
  :hook (embark-collect-mode . consult-preview-at-point-mode))

(use-package consult
  :init
  ;; glz/buffer-map is declared in use-package meow which appears later in the
  ;; file; defer the binding until meow has loaded (meow has :demand t so this
  ;; fires during the same startup sequence, just after meow's use-package).
  (with-eval-after-load 'meow
    (define-key glz/buffer-map "b" #'consult-buffer)
    (with-eval-after-load 'which-key
      (which-key-add-keymap-based-replacements glz/buffer-map
        "b" "consult-buffer")))
  :bind (("C-c M-x" . consult-mode-command)
         ("C-c h" . consult-history)
         ("C-c k" . consult-kmacro)
         ("C-c m" . consult-man)
         ("C-c i" . consult-info)
         ([remap Info-search] . consult-info)
         ("C-x M-:" . consult-complex-command)
         ("C-x b" . consult-buffer)
         ("C-x 4 b" . consult-buffer-other-window)
         ("C-x 5 b" . consult-buffer-other-frame)
         ("C-x t b" . consult-buffer-other-tab)
         ("C-x r b" . consult-bookmark)
         ("C-x p b" . consult-project-buffer)
         ("M-#" . consult-register-load)
         ("M-'" . consult-register-store)
         ("C-M-#" . consult-register)
         ("M-y" . consult-yank-pop)
         ("M-g e" . consult-compile-error)
         ("M-g r" . consult-grep-match)
         ("M-g f" . consult-flymake)
         ("M-g g" . consult-goto-line)
         ("M-g M-g" . consult-goto-line)
         ("M-g o" . consult-outline)
         ("M-g m" . consult-mark)
         ("M-g k" . consult-global-mark)
         ("M-g i" . consult-imenu)
         ("M-g I" . consult-imenu-multi)
         ("M-s d" . consult-find)
         ("M-s c" . consult-locate)
         ("M-s g" . consult-grep)
         ("M-s G" . consult-git-grep)
         ("M-s r" . consult-ripgrep)
         ("C-s" . consult-line)
         ("M-s L" . consult-line-multi)
         ("M-s k" . consult-keep-lines)
         ("M-s u" . consult-focus-lines)
         ("M-s e" . consult-isearch-history)
         :map isearch-mode-map
         ("M-e" . consult-isearch-history)
         ("M-s e" . consult-isearch-history)
         ("M-s l" . consult-line)
         ("M-s L" . consult-line-multi)
         :map minibuffer-local-map
         ("M-s" . consult-history)
         ("M-r" . consult-history))
  :hook (completion-list-mode . consult-preview-at-point-mode)
  :init
  (advice-add #'register-preview :override #'consult-register-window)
  (setq register-preview-delay 0.5)
  (setq xref-show-xrefs-function #'consult-xref
        xref-show-definitions-function #'consult-xref)
  :config
  (consult-customize
   consult-theme :preview-key '(:debounce 0.2 any)
   consult-ripgrep consult-git-grep consult-grep consult-man
   consult-bookmark consult-recent-file consult-xref
   consult-source-bookmark consult-source-file-register
   consult-source-recent-file consult-source-project-recent-file
   :preview-key '(:debounce 0.4 any))
  (setq consult-narrow-key "<")
  (keymap-set consult-narrow-map (concat consult-narrow-key " ?") #'consult-narrow-help))

(use-package meow
  :ensure t
  :demand t
  :init
  ;; --- Leader sub-maps ---
  ;; Declared in :init so they exist before any with-eval-after-load 'meow
  ;; callback fires.  eval-after-load runs inside (require 'meow) — before
  ;; :config — so anything those callbacks reference must be set up here.
  (define-prefix-command 'glz/git-map)
  (define-prefix-command 'glz/git-ediff-map)
  (define-prefix-command 'glz/smerge-map)

  (defun glz/copy-buffer-file-path ()
    "Copy the current buffer's full file path (or buffer name) to the kill ring."
    (interactive)
    (let ((name (or (buffer-file-name) (buffer-name))))
      (kill-new name)
      (message "Copied: %s" name)))

  (defun glz/copy-buffer-file-name ()
    "Copy just the file name (no directory) of the current buffer to the kill ring."
    (interactive)
    (let ((name (file-name-nondirectory (or (buffer-file-name) (buffer-name)))))
      (kill-new name)
      (message "Copied: %s" name)))

  (define-prefix-command 'glz/buffer-yank-map)

  (defun glz/isearch-region ()
    "Search forward for the text of the active region using isearch."
    (interactive)
    (when (use-region-p)
      (let ((text (buffer-substring-no-properties (region-beginning) (region-end))))
        (deactivate-mark)
        (isearch-mode t)
        (isearch-yank-string text))))

  (define-prefix-command 'glz/buffer-map)
  (define-key glz/buffer-map "p" #'previous-buffer)
  (define-key glz/buffer-map "n" #'next-buffer)
  (define-key glz/buffer-map "k" #'kill-current-buffer)
  (define-key glz/buffer-map "y" 'glz/buffer-yank-map)
  (define-key glz/buffer-yank-map "p" #'glz/copy-buffer-file-path)
  (define-key glz/buffer-yank-map "n" #'glz/copy-buffer-file-name)

  (define-prefix-command 'glz/toggle-map)
  (define-key glz/toggle-map "l" #'display-line-numbers-mode)
  (define-key glz/toggle-map "=" #'text-scale-adjust)

  ;; Populated in the Org Mode section (=SPC o= leader keymap).
  (define-prefix-command 'glz/org-map)

  (define-prefix-command 'glz/window-map)
  (define-key glz/window-map "h" #'windmove-left)
  (define-key glz/window-map "j" #'windmove-down)
  (define-key glz/window-map "k" #'windmove-up)
  (define-key glz/window-map "l" #'windmove-right)
  (define-key glz/window-map "s" #'split-window-below)
  (define-key glz/window-map "v" #'split-window-right)
  (define-key glz/window-map "d" #'delete-window)
  (define-key glz/window-map "o" #'delete-other-windows)
  ;; Resize: uppercase = grow/shrink in that direction, step 3
  (define-key glz/window-map "H" (lambda () (interactive) (shrink-window-horizontally 3)))
  (define-key glz/window-map "L" (lambda () (interactive) (enlarge-window-horizontally 3)))
  (define-key glz/window-map "J" (lambda () (interactive) (enlarge-window 3)))
  (define-key glz/window-map "K" (lambda () (interactive) (shrink-window 3)))
  (define-key glz/window-map "=" #'balance-windows)
  (define-key glz/window-map "x" #'window-swap-states)
  (define-key glz/window-map "u" #'winner-undo)
  (define-key glz/window-map "r" #'winner-redo)
  (define-key glz/window-map "w" #'other-window)
  ;; Window map is accessible via SPC w (meow leader); don't override C-w
  ;; globally — meow-kill ('s') relies on kill-region living at C-w.

  ;; Frame map (SPC f): letters mirror the window map where they overlap.
  (define-prefix-command 'glz/frame-map)
  (define-key glz/frame-map "n" #'make-frame-command)
  (define-key glz/frame-map "d" #'delete-frame)
  (define-key glz/frame-map "o" #'delete-other-frames)
  (define-key glz/frame-map "w" #'other-frame)
  (define-key glz/frame-map "u" #'undelete-frame)
  (define-key glz/frame-map "c" #'clone-frame)
  (define-key glz/frame-map "P" #'select-frame-by-name)
  (define-key glz/frame-map "R" #'set-frame-name)
  (define-key glz/frame-map "f" #'find-file-other-frame)
  (define-key glz/frame-map "b" #'consult-buffer-other-frame)
  (define-key glz/frame-map "p" #'project-other-frame-command)
  (define-key glz/frame-map "m" #'toggle-frame-maximized)
  (define-key glz/frame-map "F" #'toggle-frame-fullscreen)
  ;; `undelete-frame' only works while this mode records deleted frames.
  (undelete-frame-mode 1)

  (when glz/enable-testfall
    (define-key glz/toggle-map "t" #'testfall-mode))

  (if glz/enable-org-roam
      (progn
        (define-prefix-command 'glz/org-roam-map)
        (define-key glz/org-roam-map "c" #'org-roam-capture)
        (define-key glz/org-roam-map "f" #'org-roam-node-find)
        (define-key glz/org-roam-map "i" #'org-roam-node-insert)
        (define-key glz/org-roam-map "a" #'org-roam-node-insert-immediate)
        (when glz/enable-org-roam-ui
          (define-key glz/org-roam-map "u" #'org-roam-ui-open))
        (define-key glz/org-roam-map "b" #'org-roam-buffer-toggle)
        ;; Journaling: same keys as C-c n j/J, but reachable through the
        ;; leader without a Ctrl chord — the whole point on a touchscreen.
        (define-key glz/org-roam-map "j" #'org-roam-dailies-capture-today)
        (define-key glz/org-roam-map "J" #'org-roam-dailies-goto-today)
        (define-key glz/org-map "r" 'glz/org-roam-map))
    ;; No usable SQLite backend for Org Roam's database (e.g. an Android
    ;; build without built-in sqlite) — fall back to browsing the notes
    ;; directory directly so "SPC o r" still gets you to your notes.
    (define-key glz/org-map "r"
      (lambda ()
        (interactive)
        (dired (concat glz/org-directory "roam/")))))

  :config
  (setq meow-cheatsheet-layout meow-cheatsheet-layout-qwerty)
  ;; Free up 'g' for the git leader key; shift C-M- prefix to 'G'.
  (setq meow-keypad-ctrl-meta-prefix ?G)

  (meow-motion-overwrite-define-key
   '("j" . meow-next)
   '("k" . meow-prev)
   '("<escape>" . ignore))

  (meow-leader-define-key
   '("." . find-file)
   '("SPC" . project-find-file)
   '("g" . glz/git-map)
   '("b" . glz/buffer-map)
   '("t" . glz/toggle-map)
   '("o" . glz/org-map)
   '("w" . glz/window-map)
   '("f" . glz/frame-map)
   '("h" . "C-h")
   '("p" . "C-x p")
   '("c" . (lambda () (interactive)
              (find-file (expand-file-name
                          (concat user-emacs-directory "Config.org")))))
   '("s" . eshell)
   '("/" . glz/isearch-region)
   '("?" . meow-cheatsheet))

  (meow-normal-define-key
   '("0" . meow-expand-0)
   '("9" . meow-expand-9)
   '("8" . meow-expand-8)
   '("7" . meow-expand-7)
   '("6" . meow-expand-6)
   '("5" . meow-expand-5)
   '("4" . meow-expand-4)
   '("3" . meow-expand-3)
   '("2" . meow-expand-2)
   '("1" . meow-expand-1)
   '("-" . negative-argument)
   '(";" . meow-reverse)
   '("," . meow-inner-of-thing)
   '("." . meow-bounds-of-thing)
   '("[" . meow-beginning-of-thing)
   '("]" . meow-end-of-thing)
   '("a" . meow-append)
   '("A" . meow-open-below)
   '("b" . meow-back-word)
   '("B" . meow-back-symbol)
   '("c" . meow-change)
   '("d" . meow-delete)
   '("D" . meow-backward-delete)
   '("e" . meow-next-word)
   '("E" . meow-next-symbol)
   '("f" . meow-find)
   '("g" . meow-cancel-selection)
   '("G" . meow-grab)
   '("h" . meow-left)
   '("H" . meow-left-expand)
   '("i" . meow-insert)
   '("I" . meow-open-above)
   '("j" . meow-next)
   '("J" . meow-next-expand)
   '("k" . meow-prev)
   '("K" . meow-prev-expand)
   '("l" . meow-right)
   '("L" . meow-right-expand)
   '("m" . meow-join)
   '("n" . meow-search)
   '("o" . meow-block)
   '("O" . meow-to-block)
   '("p" . meow-yank)
   '("q" . meow-quit)
   '("Q" . meow-goto-line)
   '("r" . meow-replace)
   '("R" . meow-swap-grab)
   '("s" . meow-kill)
   '("t" . meow-till)
   '("u" . meow-undo)
   '("U" . meow-undo-in-selection)
   '("v" . meow-visit)
   '("w" . meow-mark-word)
   '("W" . meow-mark-symbol)
   '("x" . meow-line)
   '("X" . meow-goto-line)
   '("y" . meow-save)
   '("Y" . meow-sync-grab)
   '("z" . meow-pop-selection)
   '("'" . repeat)
   '("*" . glz/isearch-region)
   '("<escape>" . ignore))

  (meow-setup-line-number)
  ;; meow--toggle-relative-line-number sets display-line-numbers to t in
  ;; insert mode.  Override it so relative numbers are kept in every state.
  (advice-add 'meow--toggle-relative-line-number :override
              (lambda ()
                (when display-line-numbers
                  (setq display-line-numbers 'relative))))
  (meow-global-mode 1))

(defun glz/org-babel-tangle-config ()
  (when (and (buffer-file-name)
             (string-match-p "Config\\.org$" (buffer-file-name)))
    (let ((org-confirm-babel-evaluate nil))
      (org-babel-tangle))))

(add-hook 'org-mode-hook
          (lambda ()
            (add-hook 'after-save-hook #'glz/org-babel-tangle-config nil t)))

;; Text-properties folding is significantly faster than overlay folding for
;; large org files; safe to set globally.
(setq org-fold-core-style 'text-properties)

(defun glz/requirements-org-perf ()
  "Disable expensive display features for the generated requirements.org."
  (when (and buffer-file-name
             (string-match-p "requirements\\.org\\'" buffer-file-name))
    (org-indent-mode -1)
    (variable-pitch-mode -1)
    (when (bound-and-true-p visual-fill-column-mode)
      (visual-fill-column-mode -1))
    (setq-local truncate-lines t)
    (setq-local jit-lock-defer-time 0.25)
    (read-only-mode 1)))

(add-hook 'org-mode-hook #'glz/requirements-org-perf)

(defun glz/org-mode-setup ()
  "Personal adjustments for org-mode."
  (org-indent-mode)
  (variable-pitch-mode 1)
  (auto-fill-mode 0)
  (visual-line-mode 1)
)

(use-package org
  :commands (org-mode org-version)
  :mode ("\\.org\\'" . org-mode)
  :hook (org-mode . glz/org-mode-setup)
  :config
  (setq org-ellipsis " ▾"
        org-hide-emphasis-markers t)

  ;; ── Structure editing (M-hjkl, all states) ───────────────────────────
  ;; Same as org's own M-<arrow> keys, on the Meow direction letters:
  ;; M-h/M-l promote/demote, M-j/M-k move the subtree/item/row down/up.
  ;; Shifted, M-H/M-L promote/demote the whole subtree.
  (define-key org-mode-map (kbd "M-h") #'org-metaleft)
  (define-key org-mode-map (kbd "M-l") #'org-metaright)
  (define-key org-mode-map (kbd "M-j") #'org-metadown)
  (define-key org-mode-map (kbd "M-k") #'org-metaup)
  (define-key org-mode-map (kbd "M-H") #'org-shiftmetaleft)
  (define-key org-mode-map (kbd "M-L") #'org-shiftmetaright)

  ;; ── Meow normal-state keys ───────────────────────────────────────────
  ;; Meow's normal state leaves RET, C-j and C-k unbound, so org's own
  ;; editing commands (newline, kill-line…) would run there.  In normal
  ;; state they act on the document instead; insert state is unchanged.
  (defun glz/org-dwim-at-point ()
    "Act on the Org element at point.
Links, timestamps, footnotes and citations are opened, checkboxes are
toggled and headings are folded/unfolded.  Anywhere else point moves to
the next line."
    (interactive)
    (cond
     ((memq (org-element-type (org-element-context))
            '(link timestamp footnote-reference footnote-definition
                   citation citation-reference))
      (org-open-at-point))
     ((org-at-item-checkbox-p) (org-toggle-checkbox))
     ((org-at-heading-p) (org-cycle))
     (t (call-interactively #'meow-next))))

  (defun glz/org-meow-normal-key (key normal-cmd)
    "Bind KEY in `org-mode-map' to NORMAL-CMD in Meow normal state.
In every other state KEY keeps its current `org-mode-map' binding."
    (let ((fallback (keymap-lookup org-mode-map key)))
      (keymap-set org-mode-map key
                  (lambda ()
                    (interactive)
                    (call-interactively
                     (if (bound-and-true-p meow-normal-mode) normal-cmd fallback))))))

  (glz/org-meow-normal-key "RET" #'glz/org-dwim-at-point)
  (glz/org-meow-normal-key "C-j" #'org-next-visible-heading)
  (glz/org-meow-normal-key "C-k" #'org-previous-visible-heading)

  ;; Register "subtree" as a Meow thing so `. s` selects the current subtree
  ;; and `[ s` / `] s` jump to its beginning/end.
  ;; meow-thing-register wants a FUNCTION returning (BEG . END), not a cons
  ;; of two function symbols — that dotted pair gets misread as a "multi"
  ;; thing spec and mapcar chokes on it (Wrong type argument: listp).
  (defun glz/meow-org-subtree-bounds ()
    "Return the (BEG . END) bounds of the org subtree at point."
    (save-excursion
      (org-back-to-heading t)
      (let ((beg (point)))
        (org-end-of-subtree t)
        (cons beg (point)))))
  (meow-thing-register 'subtree
                       #'glz/meow-org-subtree-bounds
                       #'glz/meow-org-subtree-bounds)
  (add-to-list 'meow-char-thing-table '(?s . subtree))

  ;; Fixed-pitch faces for code and special elements
  (require 'org-indent)
  (set-face-attribute 'org-block nil :foreground nil :inherit 'fixed-pitch)
  (set-face-attribute 'org-code nil :inherit '(shadow fixed-pitch))
  (set-face-attribute 'org-indent nil :inherit '(org-hide fixed-pitch))
  (set-face-attribute 'org-verbatim nil :inherit '(shadow fixed-pitch))
  (set-face-attribute 'org-special-keyword nil :inherit '(font-lock-comment-face fixed-pitch))
  (set-face-attribute 'org-meta-line nil :inherit '(font-lock-comment-face fixed-pitch))
  (set-face-attribute 'org-checkbox nil :inherit 'fixed-pitch)

  ;; Org Tempo snippets
  (require 'org-tempo)
  (add-to-list 'org-structure-template-alist '("sh" . "src shell"))
  (add-to-list 'org-structure-template-alist '("el" . "src emacs-lisp"))
  (add-to-list 'org-structure-template-alist '("py" . "src python"))

  ;; Enable execution of the languages used by the course notes: dot
  ;; (Graphviz sketches) and latex (equation rendering support code).
  (org-babel-do-load-languages
   'org-babel-load-languages
   '((dot . t)
     (latex . t)
     (shell . t)
     (python . t)))
  
  (setq org-preview-latex-default-process 'dvisvgm)

  ;; Replace list hyphen with bullet dot
  (font-lock-add-keywords 'org-mode
                          '(("^ *\\([-]\\) "
                             (0 (prog1 () (compose-region (match-beginning 1)
                                                          (match-end 1) "•"))))))

  ;; Directories and agenda files
  (setq org-directory glz/org-directory)
  (setq org-agenda-files (mapcar #'glz/org-file '("Tasks.org" "Birthdays.org" "Calendar.org")))

  ;; org-roam only indexes org-directory/roam/, so id: links to/from the
  ;; course notes in org-directory/Notes/ (index + chapter files) need
  ;; org-id to know about that tree separately, or they fail to resolve.
  (setq org-id-extra-files
        (directory-files-recursively (concat org-directory "Notes/") "\\.org$"))

  ;; Task management
  (setq org-agenda-start-with-log-mode t)
  (setq org-log-done 'time)
  (setq org-log-into-drawer t)

  (setq org-todo-keywords
        '((sequence "TODO(t)" "NEXT(n)" "|" "DONE(d!)")
          (sequence "IDEA(i)" "DISCUSSION(d)" "ANALYSIS(a)" "IN WORK(w)" "|" "DONE(d!)" "CANCELLED(c!)")))

  (setq org-agenda-custom-commands
        '(("d" "Dashboard"
           ((agenda "" ((org-deadline-warning-days 7)))
            (todo "NEXT"
                  ((org-agenda-overriding-header "Next Tasks")))
            (tags-todo "agenda/ACTIVE" ((org-agenda-overriding-header "Active Projects")))))

          ("n" "Next Tasks"
           ((todo "NEXT"
                  ((org-agenda-overriding-header "Next Tasks")))))

          ("W" "Work Tasks" tags-todo "+work")

          ("e" tags-todo "+TODO=\"NEXT\"+Effort<15&+Effort>0"
           ((org-agenda-overriding-header "Low Effort Tasks")
            (org-agenda-max-todos 20)
            (org-agenda-files org-agenda-files)))

          ("w" "Workflow Status"
           ((todo "WAIT"
                  ((org-agenda-overriding-header "Waiting on External")
                   (org-agenda-files org-agenda-files)))
            (todo "REVIEW"
                  ((org-agenda-overriding-header "In Review")
                   (org-agenda-files org-agenda-files)))
            (todo "PLAN"
                  ((org-agenda-overriding-header "In Planning")
                   (org-agenda-todo-list-sublevels nil)
                   (org-agenda-files org-agenda-files)))
            (todo "BACKLOG"
                  ((org-agenda-overriding-header "Project Backlog")
                   (org-agenda-todo-list-sublevels nil)
                   (org-agenda-files org-agenda-files)))
            (todo "READY"
                  ((org-agenda-overriding-header "Ready for Work")
                   (org-agenda-files org-agenda-files)))
            (todo "ACTIVE"
                  ((org-agenda-overriding-header "Active Projects")
                   (org-agenda-files org-agenda-files)))
            (todo "COMPLETED"
                  ((org-agenda-overriding-header "Completed Projects")
                   (org-agenda-files org-agenda-files)))
            (todo "CANC"
                  ((org-agenda-overriding-header "Cancelled Projects")
                   (org-agenda-files org-agenda-files)))))))

  (setq org-refile-targets `((,(glz/org-file "Archive.org") :maxlevel . 1)))
  (advice-add 'org-refile :after 'org-save-all-org-buffers)

  ;; ── Task origin and project tags ─────────────────────────────────────
  ;; Every task is captured into Tasks.org, so only that file has to be in
  ;; the agenda.  Each task remembers where it was captured (:ORIGIN: link)
  ;; and is tagged with its project, defaulting to the project.el project
  ;; of the buffer the capture was started from.
  (defun glz/org-tag (name)
    "Turn NAME into a valid org tag by replacing invalid characters with _."
    (replace-regexp-in-string "[^[:alnum:]_@#%]" "_" (string-trim name)))

  (defun glz/org-capture-project-tag ()
    "Return a tag for the project the capture was started from, or nil."
    (let ((buffer (org-capture-get :original-buffer)))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (when-let* ((project (project-current)))
            (glz/org-tag (project-name project)))))))

  (defun glz/org-task-tags ()
    "Return all tags already used in Tasks.org."
    (with-current-buffer (find-file-noselect (glz/org-file "Tasks.org"))
      (mapcar #'car (org-get-buffer-tags))))

  (defun glz/org-capture-tags ()
    "Read project tags for a captured task, formatted for the heading line."
    (let* ((default (glz/org-capture-project-tag))
           (tags (completing-read-multiple
                  (format-prompt "Project tags" default)
                  (glz/org-task-tags) nil nil nil nil default)))
      (if tags (concat " :" (mapconcat #'glz/org-tag tags ":") ":") "")))

  (defun glz/org-capture-origin ()
    "Return an :ORIGIN: property line linking to where the capture started."
    (let ((link (org-capture-get :annotation)))
      (if (org-string-nw-p link) (format ":ORIGIN: %s\n" link) "")))

  (defun glz/org-agenda-project (tag)
    "Show all open tasks tagged with project TAG."
    (interactive
     (list (completing-read "Project: " (glz/org-task-tags) nil nil nil nil
                            (when-let* ((project (project-current)))
                              (glz/org-tag (project-name project))))))
    (org-tags-view t tag))

  (defun glz/org-task-template (&optional planning)
    "Return a task capture template, with PLANNING line (e.g. a deadline)."
    (concat "* TODO %?%(glz/org-capture-tags)\n"
            (when planning (concat planning "\n"))
            ":PROPERTIES:\n:CREATED: %U\n%(glz/org-capture-origin):END:\n%i"))

  ;; Capture templates
  (setq org-capture-templates
        `(("t" "Task" entry (file+headline ,(glz/org-file "Tasks.org") "Tasks")
           ,(glz/org-task-template))
          ("d" "Task with deadline" entry (file+headline ,(glz/org-file "Tasks.org") "Tasks")
           ,(glz/org-task-template "DEADLINE: %^{Deadline}t"))
          ("b" "Birthday" entry (file ,(glz/org-file "Birthdays.org"))
           "* %?\n  %^t\n %i")))

  :custom
  (org-hide-leading-stars t)
  (org-startup-indented t)
  (org-adapt-indentation nil)
  (org-edit-src-content-indentation 0)
  (org-startup-truncated t)
  ;; RET on a link follows it instead of just inserting a newline.
  (org-return-follows-link t)
  ;; Refuse blind edits on folded text instead of silently corrupting structure.
  (org-catch-invisible-edits 'show-and-error))

(use-package org-bullets
  :after org
  :hook (org-mode . org-bullets-mode)
  :custom
  (org-bullets-bullet-list '("◉" "○" "●" "○" "●" "○" "●")))

(define-prefix-command 'glz/org-clock-map)
(define-key glz/org-clock-map "i" #'org-clock-in)
(define-key glz/org-clock-map "o" #'org-clock-out)
(define-key glz/org-clock-map "c" #'org-clock-cancel)
(define-key glz/org-clock-map "g" #'org-clock-goto)
(define-key glz/org-clock-map "r" #'org-clock-report)

(define-key glz/org-map "a" #'org-agenda)
(define-key glz/org-map "c" #'org-capture)
(define-key glz/org-map "m" #'glz/org-agenda-project)
(define-key glz/org-map "t" #'org-todo)
(define-key glz/org-map "T" #'org-set-tags-command)
(define-key glz/org-map "p" #'org-priority)
(define-key glz/org-map "P" #'org-set-property)
(define-key glz/org-map "s" #'org-schedule)
(define-key glz/org-map "d" #'org-deadline)
(define-key glz/org-map "." #'org-time-stamp)
(define-key glz/org-map "!" #'org-time-stamp-inactive)
(define-key glz/org-map "l" #'org-insert-link)
(define-key glz/org-map "y" #'org-store-link)
(define-key glz/org-map "o" #'org-open-at-point)
(define-key glz/org-map "x" #'org-toggle-checkbox)
(define-key glz/org-map "h" #'org-insert-heading-respect-content)
(define-key glz/org-map "*" #'org-ctrl-c-star)
(define-key glz/org-map "-" #'org-ctrl-c-minus)
(define-key glz/org-map "w" #'org-refile)
(define-key glz/org-map "A" #'org-archive-subtree-default)
(define-key glz/org-map "n" #'org-toggle-narrow-to-subtree)
(define-key glz/org-map "/" #'org-sparse-tree)
(define-key glz/org-map "j" #'org-next-visible-heading)
(define-key glz/org-map "k" #'org-previous-visible-heading)
(define-key glz/org-map "J" #'org-forward-heading-same-level)
(define-key glz/org-map "K" #'org-backward-heading-same-level)
(define-key glz/org-map "u" #'outline-up-heading)
(define-key glz/org-map "g" #'org-goto)
(define-key glz/org-map "e" #'org-export-dispatch)
(define-key glz/org-map "'" #'org-edit-special)
(define-key glz/org-map "b" #'org-babel-tangle)
(define-key glz/org-map (kbd "TAB") #'org-cycle)
(define-key glz/org-map "C" 'glz/org-clock-map)

(with-eval-after-load 'which-key
  (which-key-add-keymap-based-replacements glz/org-map
    "a" "agenda"            "c" "capture"
    "m" "project tasks"
    "t" "todo state"        "T" "tags"
    "p" "priority"          "P" "property"
    "s" "schedule"          "d" "deadline"
    "." "timestamp"         "!" "inactive timestamp"
    "l" "insert link"       "y" "store link"
    "o" "open at point"     "x" "toggle checkbox"
    "h" "new heading"       "*" "toggle heading"
    "-" "toggle list item"  "w" "refile"
    "A" "archive subtree"   "n" "narrow/widen"
    "/" "sparse tree"
    "j" "↓ next heading"    "k" "↑ prev heading"
    "J" "↓ next sibling"    "K" "↑ prev sibling"
    "u" "↑ parent"          "g" "goto heading"
    "e" "export"            "'" "edit src block"
    "b" "tangle"            "TAB" "cycle fold"
    "C" "clock →"           "r" "roam →")
  (which-key-add-keymap-based-replacements glz/org-clock-map
    "i" "clock in"          "o" "clock out"
    "c" "cancel clock"      "g" "goto clocked task"
    "r" "clock report"))

(when glz/enable-latex-preview
  (use-package auctex
    :ensure t
    :defer t
    :custom
    ;; Precompiled-preamble caching needs a `mylatex.ltx' this TeX Live
    ;; install doesn't provide; when it fails it corrupts every later
    ;; preview's PDF/DVI detection, so leave it off (see prose above).
    (preview-auto-cache-preamble nil)
    ;; Fallback raster type if a preview ever compiles to PDF anyway
    ;; (see `TeX-PDF-mode' below); SVG previews don't use this at all.
    (preview-image-type 'dvi*)
    (preview-dvi*-image-type 'svg)
    (preview-dvi*-command #'preview-dvisvgm-command)
    ;; Every compile (.aux/.log/.dvi, one set per preview) otherwise lands
    ;; right next to the .org/.tex file being edited. A relative path here
    ;; is resolved under TeX-master's own directory and treated as
    ;; pre-approved (no "is this safe" prompt) since it's a subdirectory of
    ;; it — collects the clutter into one hidden folder per notes
    ;; directory instead of scattering loose files. preview-mode's own
    ;; per-session image temp dirs (the basename.prv/ directories) already
    ;; self-organize this way regardless.
    (TeX-output-dir ".auctex-build"))


  (use-package org-auctex
    :vc (:url "https://github.com/karthink/org-auctex" :rev :newest)
    :after org
    ;; org-mode loads early at startup regardless, so requiring auctex
    ;; here (rather than gating on an `auctex' feature nothing else ever
    ;; loads) is what actually makes `org-auctex-mode' turn on in org
    ;; buffers instead of silently never firing. `auctex' alone only
    ;; loads the autoloads shim (`tex-site'), not the real `tex.el' that
    ;; defines `TeX-PDF-mode' and the rest, so both are required here.
    :init (progn (require 'auctex) (require 'tex))
    :hook ((org-mode . org-auctex-mode)
           ;; SVG previews need a real .dvi, which only a plain `latex'
           ;; (not `pdflatex') compile produces; scoped to org buffers
           ;; so a real standalone .tex file still gets pdflatex.
           (org-mode . (lambda () (TeX-PDF-mode -1)))))

  (with-eval-after-load 'preview
    (advice-add
     'preview-get-dpi :around
     (lambda (orig-fn)
       (let* ((attrs (frame-monitor-attributes))
              (mm (cdr (assq 'mm-size attrs)))
              (geom (nthcdr 3 (assq 'geometry attrs)))
              (pixel-w (nth 0 geom)) (pixel-h (nth 1 geom))
              (mm-w (nth 0 mm)) (mm-h (nth 1 mm)))
         (if (and (integerp mm-w) (integerp mm-h) (> mm-w 0) (> mm-h 0)
                  (> pixel-w pixel-h) (< mm-w mm-h))
             (cons (/ (* 25.4 pixel-w) mm-h) (/ (* 25.4 pixel-h) mm-w))
           (funcall orig-fn)))))))

(defun glz/org-mode-visual-fill ()
  ;; 300 columns assumes a desktop monitor; a phone in portrait can't use
  ;; anywhere near that, so narrow it there instead of centering three
  ;; words in an empty page.
  (setq visual-fill-column-width (if (eq glz/platform 'android) 80 300)
        visual-fill-column-center-text t)
  (visual-fill-column-mode 1))

(use-package visual-fill-column
  :hook (org-mode . glz/org-mode-visual-fill))

;; Lets file: links with a page number (e.g. file:paper.pdf::12, as used
;; by the co00/co01/... links in the course notes) open the PDF at that
;; page, with proper vector rendering, search and annotations.
;; pdf-tools compiles a native helper (epdfinfo) at install time, which
;; needs a C toolchain that a phone build of Emacs is unlikely to have;
;; skip it on Android and fall back to Emacs's built-in doc-view instead.
(when glz/enable-pdf-tools
  (use-package pdf-tools
    :magic ("%PDF" . pdf-view-mode)
    :config
    (pdf-tools-install :no-query)))

(when glz/enable-org-roam
  (use-package org-roam
    :after org
    :commands (org-roam-buffer-toggle
               org-roam-node-find
               org-roam-graph
               org-roam-node-insert
               org-roam-capture)
    :custom
    (org-roam-directory (file-truename (concat org-directory "roam/")))
    :bind (("C-c n l" . org-roam-buffer-toggle)
           ("C-c n f" . org-roam-node-find)
           ("C-c n g" . org-roam-graph)
           ("C-c n i" . org-roam-node-insert)
           ("C-c n c" . org-roam-capture)
           ("C-c n j" . org-roam-dailies-capture-today))
    :config
    (setq org-roam-node-display-template
          (concat "${title:*} " (propertize "${tags:10}" 'face 'org-tag)))
    (when (file-directory-p org-roam-directory)
      (org-roam-db-autosync-mode))
    (require 'org-roam-protocol))

  (defun org-roam-node-insert-immediate (arg &rest args)
    "Insert an org-roam node without opening a capture buffer."
    (interactive "P")
    (let ((args (cons arg args))
          (org-roam-capture-templates
           (list (append (car org-roam-capture-templates)
                         '(:immediate-finish t)))))
      (apply #'org-roam-node-insert args))))

(when glz/enable-org-roam-ui
  (use-package org-roam-ui
    :after org-roam
    :config
    (setq org-roam-ui-sync-theme t
          org-roam-ui-follow t
          org-roam-ui-update-on-save t
          org-roam-ui-open-on-start t)))

(use-package org-download
  :commands (org-download-clipboard org-download-yank org-download-enable)
  :hook (dired-mode . org-download-enable))

(add-to-list 'display-buffer-alist
             '((lambda (_buffer _action) (frame-parameter nil 'glz-popup))
               (display-buffer-full-frame)))

(defun glz/popup-frame-close ()
  "Delete the selected frame if it was opened as a popup."
  (when (frame-parameter nil 'glz-popup)
    (delete-frame)))

(add-hook 'org-capture-after-finalize-hook #'glz/popup-frame-close)

(defun glz/focus-main-frame ()
  "Raise and focus the main Emacs frame, creating one if needed.
Popup frames are skipped, so the Emacs shortcut never reuses them."
  (select-frame-set-input-focus
   (or (seq-find (lambda (frame)
                   (and (display-graphic-p frame)
                        (not (frame-parameter frame 'glz-popup))))
                 (frame-list))
       (make-frame))))

(use-package dired
  :ensure nil
  :defer t
  :hook (dired-mode . dired-hide-details-mode)
  :config
  (setq dired-dwim-target t)
  (setq dired-recursive-copies 'always)
  (setq dired-create-destination-dirs 'ask)
  (setq dired-clean-confirm-killing-deleted-buffers nil)
  (setq dired-make-directory-clickable t)
  (setq dired-mouse-drag-files t))

(use-package all-the-icons-dired
  :hook (dired-mode . all-the-icons-dired-mode))

(when glz/enable-magit
(use-package ediff
  :ensure nil
  :defer t
  :config
  (setq ediff-keep-variants nil)
  (setq ediff-make-buffers-readonly-at-startup nil)
  (setq ediff-merge-revisions-with-ancestor t)
  (setq ediff-show-clashes-only t)
  (setq ediff-split-window-function 'split-window-horizontally)
  (setq ediff-window-setup-function 'ediff-setup-windows-plain)
  ;; On Windows, prefer the Git-bundled diff/diff3 as an explicit fallback.
  (when (eq glz/platform 'windows)
    (let ((diff  (or (executable-find "diff")
                     "C:/Program Files/Git/usr/bin/diff.exe"))
          (diff3 (or (executable-find "diff3")
                     "C:/Program Files/Git/usr/bin/diff3.exe")))
      (setq ediff-diff-program  diff
            ediff-diff3-program diff3)))

  ;; Put the ediff control buffer in motion state so SPC leader works
  ;; while ediff's single-key commands still fall through.
  (add-hook 'ediff-mode-hook
            (lambda ()
              (meow-mode 1)
              (meow--switch-state 'motion)))

  ;; Track whether an ediff session is active so the auto-restore hook
  ;; (below) does not undo ediff's deliberate motion-state setup.
  (defvar glz/ediff-in-progress nil
    "Non-nil while an ediff session is active.")

  (defun glz/meow-suspend-for-ediff ()
    "Switch diff buffers to motion state so ediff keys pass through."
    (dolist (buf (list ediff-buffer-A ediff-buffer-B ediff-buffer-C
                       ediff-ancestor-buffer))
      (when (buffer-live-p buf)
        (with-current-buffer buf
          (meow--switch-state 'motion)
          ;; meow-setup-line-number sets type to t in motion state;
          ;; override it so relative numbers are preserved during ediff.
          (setq-local display-line-numbers-type 'relative)))))

  (defun glz/meow-restore-after-ediff ()
    "Restore normal state in diff buffers after ediff exits."
    (setq glz/ediff-in-progress nil)
    (dolist (buf (list ediff-buffer-A ediff-buffer-B ediff-buffer-C
                       ediff-ancestor-buffer))
      (when (buffer-live-p buf)
        (with-current-buffer buf (meow--switch-state 'normal))))
    ;; ediff restores the window configuration after this hook returns,
    ;; so the buffer the user lands in may not be in the list above.
    ;; Defer a final normal-state switch until ediff fully exits.
    (run-with-idle-timer 0 nil
                         (lambda ()
                           (when (bound-and-true-p meow-mode)
                             (meow--switch-state 'normal)))))

  ;; Auto-restore normal state when selecting any regular file buffer
  ;; that ended up in motion state (e.g. after ediff or magit navigation).
  (defun glz/meow-normal-on-file-select (&optional _frame)
    "Switch to normal meow state when a writable file buffer is selected.
Skipped while ediff is active so the motion-state setup there is
not immediately undone."
    (when (and (not glz/ediff-in-progress)
               (bound-and-true-p meow-mode)
               buffer-file-name
               (not buffer-read-only)
               (eq meow--current-state 'motion))
      (meow--switch-state 'normal)))

  (add-hook 'window-selection-change-functions #'glz/meow-normal-on-file-select)

  ;; Set the flag BEFORE buffers are prepared so after-change-major-mode-hook
  ;; in testfall sees it and skips the mode re-apply during ediff setup.
  (add-hook 'ediff-before-setup-hook (lambda () (setq glz/ediff-in-progress t)))
  (add-hook 'ediff-startup-hook  #'glz/meow-suspend-for-ediff)
  (add-hook 'ediff-quit-hook     #'glz/meow-restore-after-ediff)
  (add-hook 'ediff-suspend-hook  #'glz/meow-restore-after-ediff)))

(use-package rainbow-delimiters
  :hook (prog-mode . rainbow-delimiters-mode))

(use-package which-key
  :ensure nil
  :hook (after-init . which-key-mode)
  :config
  (setq which-key-idle-delay 0.3)

  ;; Top-level leader descriptions (shown in the SPC popup).
  ;; mode-specific-map is Meow's leader keymap, so SPC x = C-c x.
  (which-key-add-keymap-based-replacements mode-specific-map
    "g" "git"
    "b" "buffers"
    "t" "toggles"
    "o" "org"
    "w" "windows"
    "f" "frames")

  (which-key-add-keymap-based-replacements glz/window-map
    "h" "← left"      "j" "↓ down"       "k" "↑ up"         "l" "→ right"
    "H" "← shrink"    "J" "↓ grow"       "K" "↑ shrink"     "L" "→ grow"
    "s" "split ↓"     "v" "split →"
    "d" "delete"      "o" "only this"    "x" "swap"
    "=" "balance"     "w" "cycle"
    "u" "undo layout" "r" "redo layout")

  (which-key-add-keymap-based-replacements glz/frame-map
    "n" "new"           "d" "delete"        "o" "only this"
    "w" "cycle"         "u" "undo delete"   "c" "clone"
    "P" "switch by name" "R" "rename"
    "f" "find file →"   "b" "buffer →"      "p" "project →"
    "m" "maximize"      "F" "fullscreen")

  (which-key-add-keymap-based-replacements glz/buffer-map
    "p" "previous-buffer"
    "n" "next-buffer"
    "k" "kill-buffer"
    "y" "yank →")
  (which-key-add-keymap-based-replacements glz/buffer-yank-map
    "p" "yank full path"
    "n" "yank file name")

  (which-key-add-keymap-based-replacements glz/toggle-map
    "l" "line-numbers"))

(use-package helpful
  :commands (helpful-callable
             helpful-variable
             helpful-key
             helpful-command
             helpful-at-point
             helpful-function)
  :bind ([remap describe-command] . helpful-command)
  :bind ([remap describe-function] . helpful-callable)
  :bind ([remap describe-key] . helpful-key)
  :bind ([remap describe-symbol] . helpful-symbol)
  :bind ([remap describe-variable] . helpful-variable)
  :custom (helpful-max-buffers 7))

(use-package no-littering
  :demand t)

(when glz/enable-magit
(use-package magit
  :commands (magit-status magit-get-current-branch)
  :init
  ;; :init runs at startup regardless of when magit actually loads, so the
  ;; SPC g map is populated immediately.  Function symbols are autoloaded,
  ;; so pressing a key loads magit on demand.
  (define-key glz/git-map "g" #'magit-status)
  (define-key glz/git-map "b" #'magit-blame-addition)
  (define-key glz/git-map "B" #'magit-branch)
  (define-key glz/git-map "c" #'magit-commit)
  (define-key glz/git-map "d" #'magit-diff-buffer-file)
  (define-key glz/git-map "D" #'magit-diff-working-tree)
  (define-key glz/git-map "f" #'magit-fetch-all)
  (define-key glz/git-map "F" #'magit-find-file)
  (define-key glz/git-map "l" #'magit-log-buffer-file)
  (define-key glz/git-map "L" #'magit-log-current)
  (define-key glz/git-map "p" #'magit-push)
  (define-key glz/git-map "P" #'magit-pull)
  (define-key glz/git-map "r" #'magit-rebase)
  (define-key glz/git-map "s" #'magit-stash)
  (define-key glz/git-map "t" #'magit-tag)
  (define-key glz/git-ediff-map "e" #'magit-ediff-compare)
  (define-key glz/git-ediff-map "w" #'magit-ediff-show-working-tree)
  (define-key glz/git-ediff-map "s" #'magit-ediff-show-staged)
  (define-key glz/git-ediff-map "c" #'magit-ediff-show-commit)
  (define-key glz/git-map "e" 'glz/git-ediff-map)
  (define-key glz/git-map "m" 'glz/smerge-map)
  (with-eval-after-load 'which-key
    (which-key-add-keymap-based-replacements glz/git-map
      "g" "status"
      "b" "blame"
      "B" "branch"
      "c" "commit"
      "d" "diff file"
      "D" "diff worktree"
      "e" "ediff →"
      "f" "fetch all"
      "F" "find file@rev"
      "l" "log file"
      "L" "log branch"
      "m" "merge →"
      "p" "push"
      "P" "pull"
      "r" "rebase"
      "s" "stash"
      "t" "tag")
    (which-key-add-keymap-based-replacements glz/git-ediff-map
      "e" "compare refs"
      "w" "working tree"
      "s" "staged"
      "c" "commit"))
  :custom
  (magit-display-buffer-function #'magit-display-buffer-same-window-except-diff-v1)
  :config
  ;; In a dedicated diff buffer (SPC g d), open the visited file in the
  ;; other window so the diff stays visible.  In the status buffer, keep
  ;; the original same-window behaviour (opening ~index~ snapshots etc.).
  (defun glz/magit-visit-thing ()
    (interactive)
    (if (derived-mode-p 'magit-diff-mode)
        (magit-diff-visit-file-other-window)
      (magit-diff-visit-file)))
  (keymap-set magit-diff-section-map "<remap> <magit-visit-thing>"
              #'glz/magit-visit-thing)
  ;; Show unstaged/staged files grouped by type within the single collapsible
  ;; section.  Multiple magit--insert-diff calls with --diff-filter emit files
  ;; in the desired order; all magit operations (stage, discard, ediff…) keep
  ;; working because sections still use the original 'unstaged / 'staged types.
  (defun glz/magit-insert-unstaged-changes ()
    "Unstaged changes in one section, grouped: modified → deleted → renamed → unmerged.
Each filter runs in an inner (unstaged) section so that when git produces no
output for that filter magit-cancel-section only throws out of the inner catch,
leaving the outer section and heading intact."
    (when (magit-anything-unstaged-p)
      (magit-insert-section (unstaged)
        (magit-insert-heading "Unstaged changes")
        (dolist (filter '("M" "D" "R" "U"))
          (magit-insert-section (unstaged)
            (magit--insert-diff nil
              "diff" magit-buffer-diff-args "--no-prefix"
              (concat "--diff-filter=" filter)
              "--" magit-buffer-diff-files))))))

  (defun glz/magit-insert-staged-changes ()
    "Staged changes in one section, grouped: added → modified → deleted → renamed."
    (unless (magit-bare-repo-p)
      (when (magit-anything-staged-p)
        (magit-insert-section (staged)
          (magit-insert-heading "Staged changes")
          (dolist (filter '("A" "M" "D" "R"))
            (magit-insert-section (staged)
              (magit--insert-diff nil
                "diff" "--cached" magit-buffer-diff-args "--no-prefix"
                (concat "--diff-filter=" filter)
                "--" magit-buffer-diff-files)))))))

  (advice-add 'magit-insert-unstaged-changes :override #'glz/magit-insert-unstaged-changes)
  (advice-add 'magit-insert-staged-changes   :override #'glz/magit-insert-staged-changes)))

(use-package project
  :ensure nil
  :custom
  (project-switch-commands
   `((project-find-file    "Find file")
     (project-find-regexp  "Find regexp")
     (project-find-dir     "Find directory")
     ,@(when glz/enable-magit '((magit-project-status "Magit" ?g)))
     (project-eshell       "Eshell")))
  :config
  (when glz/enable-magit
    (keymap-set project-prefix-map "g" #'magit-project-status)))

(use-package perspective
  :demand t
  :custom
  (persp-mode-prefix-key (kbd "C-c M-p"))
  (persp-initial-frame-name "main")
  :config
  (persp-mode 1)

  (defun glz/project-switch-perspective (orig-fn dir)
    "Switch to the perspective of the project at DIR, creating it if needed.
The perspective is named after the project directory.  Only a newly
created perspective runs ORIG-FN, which shows the
`project-switch-commands' menu."
    (let* ((name (file-name-nondirectory (directory-file-name dir)))
           (new (not (member name (persp-names)))))
      (persp-switch name)
      (when new
        (funcall orig-fn dir))))
  (advice-add 'project-switch-project :around #'glz/project-switch-perspective)

  (define-key glz/window-map "p" #'project-switch-project)
  (define-key glz/window-map "P" #'persp-switch)
  (define-key glz/window-map "n" #'persp-next)
  (define-key glz/window-map "N" #'persp-prev)
  (define-key glz/window-map "X" #'persp-kill)
  (with-eval-after-load 'which-key
    (which-key-add-keymap-based-replacements glz/window-map
      "p" "project perspective"
      "P" "switch perspective"
      "n" "next perspective"
      "N" "prev perspective"
      "X" "kill perspective"))

  ;; Restrict consult-buffer to the current perspective by default.
  (with-eval-after-load 'consult
    (consult-customize consult-source-buffer :hidden t :default nil)
    (add-to-list 'consult-buffer-sources persp-consult-source)))

(when glz/enable-magit
(use-package smerge-mode
  :ensure nil
  :commands smerge-mode
  :config
  ;; Mirror ediff's colour scheme so smerge and ediff feel visually identical.
  ;; Inherit from ediff faces so the theme can override them in one place.
  (with-eval-after-load 'ediff-init
    (face-spec-set 'smerge-upper
                   '((t :inherit ediff-current-diff-A)))
    (face-spec-set 'smerge-lower
                   '((t :inherit ediff-current-diff-B)))
    (face-spec-set 'smerge-base
                   '((t :inherit ediff-current-diff-Ancestor)))
    (face-spec-set 'smerge-markers
                   '((t :inherit font-lock-warning-face :weight bold)))
    (face-spec-set 'smerge-refined-removed
                   '((t :inherit ediff-fine-diff-A)))
    (face-spec-set 'smerge-refined-added
                   '((t :inherit ediff-fine-diff-B))))

  ;; Populate the SPC g m prefix map.
  (define-key glz/smerge-map "n" #'smerge-next)
  (define-key glz/smerge-map "p" #'smerge-prev)
  (define-key glz/smerge-map "u" #'smerge-keep-upper)
  (define-key glz/smerge-map "l" #'smerge-keep-lower)
  (define-key glz/smerge-map "b" #'smerge-keep-base)
  (define-key glz/smerge-map "a" #'smerge-keep-all)
  (define-key glz/smerge-map "r" #'smerge-resolve)
  (define-key glz/smerge-map "f" #'smerge-refine)
  (define-key glz/smerge-map "e" #'smerge-ediff)
  (define-key glz/smerge-map "t" #'smerge-mode)
  (with-eval-after-load 'which-key
    (which-key-add-keymap-based-replacements glz/smerge-map
      "n" "next conflict"
      "p" "prev conflict"
      "u" "keep upper (ours)"
      "l" "keep lower (theirs)"
      "b" "keep base"
      "a" "keep all"
      "r" "auto-resolve"
      "f" "refine (word diff)"
      "e" "open in ediff"
      "t" "toggle mode")
    ;; smerge-mode's own default "C-c ^" prefix (smerge-basic-map) is
    ;; separate from glz/smerge-map above and unlabeled by default — Magit
    ;; and vc both drop you into smerge-mode with only this built-in prefix
    ;; available, so label it too.
    (which-key-add-keymap-based-replacements smerge-mode-map
      "C-c ^" "smerge")
    (which-key-add-keymap-based-replacements smerge-basic-map
      "n" "next conflict"
      "p" "prev conflict"
      "u" "keep upper (ours)"
      "o" "keep lower (theirs)"
      "l" "keep lower (theirs)"
      "m" "keep upper (ours)"
      "b" "keep base"
      "a" "keep all"
      "r" "auto-resolve"
      "R" "refine (word diff)"
      "E" "open in ediff"
      "C" "combine with next"
      "RET" "keep current"
      "=" "diff →"))))

(when glz/enable-forge
  (use-package forge
    :after magit))

(when glz/enable-nix
  (use-package nix-mode
    :mode "\\.nix\\'"))

(use-package markdown-mode
  :mode (("\\.md\\'"       . markdown-mode)
         ("\\.markdown\\'" . markdown-mode)
         ("README\\.md\\'" . gfm-mode))
  :custom
  (markdown-fontify-code-blocks-natively t)
  (markdown-command (or (executable-find "pandoc")
                        (executable-find "multimarkdown")
                        "markdown")))

(use-package markdown-preview-mode
  :commands markdown-preview-mode
  :after markdown-mode)

(when glz/enable-testfall
  (let ((f (expand-file-name "testfall-mode.el" user-emacs-directory)))
    (if (file-exists-p f) (load-file f)
      (message "Warning: %s not found, skipping testfall-mode" f)))

  (defun glz/testfall-buffer-p ()
    "Return non-nil if the buffer content matches testfall grammar patterns."
    (save-excursion
      (save-restriction
        (widen)
        (goto-char (point-min))
        ;; Match patterns that are highly distinctive to testfall files
        (re-search-forward
         (rx (or "<Konzern-Varianten>"
                 (seq "DUT::" (+ (any alpha "_")))
                 (seq "VAR::" (+ (any alpha "_")))
                 (seq "CAL::" (+ (any alpha "_")))
                 (seq bol "Variation:")
                 (seq bol "VarEnd")))
         (min (point-max) 100000)
         t))))

  (defun glz/testfall-apply ()
    "Apply testfall-base-mode to the current buffer if it contains testfall content.
Forces full refontification: font-lock-flush clears any stale 'fontified'
text properties that jit-lock would otherwise skip, then font-lock-ensure
drives immediate fontification regardless of display state."
    (when (and (not (derived-mode-p 'testfall-base-mode))
               (glz/testfall-buffer-p))
      (testfall-base-mode)
      ;; jit-lock marks already-fontified regions with text property
      ;; 'fontified=t and skips them.  After a mode change the previous
      ;; mode's fontification is still on the text; flush it so that
      ;; jit-lock-fontify-now (called by font-lock-ensure) re-applies
      ;; the new testfall keyword rules over the whole buffer.
      (font-lock-flush)
      (font-lock-ensure)))

  (defun glz/maybe-enable-testfall-mode ()
    "Enable testfall-base-mode for file-visiting buffers containing testfall grammar.
Skipped during ediff (ediff-prepare-buffer-hook handles those buffers)."
    (when (and (not (bound-and-true-p glz/ediff-in-progress))
               buffer-file-name
               (not (string-match-p "\\.org\\'" buffer-file-name)))
      (glz/testfall-apply)))

  ;; hack-local-variables-hook fires once after the mode and file-local
  ;; variables are fully settled — on find-file AND after revert-buffer
  ;; (which magit and auto-revert trigger to refresh a buffer).  Unlike
  ;; after-change-major-mode-hook it never fires recursively mid-setup,
  ;; so it cannot wipe font-lock state or cause re-entry loops.
  (add-hook 'hack-local-variables-hook #'glz/maybe-enable-testfall-mode)

  ;; ediff-prepare-buffer-hook runs inside each buffer as ediff sets it up —
  ;; including VC revision buffers that have no buffer-file-name.
  (add-hook 'ediff-prepare-buffer-hook #'glz/testfall-apply)

  ;; magit-find-blob-hook fires after magit sets up a revision/blob buffer
  ;; (e.g. the ~index~ staged version).  magit calls normal-mode WITHOUT the
  ;; find-file argument, so hack-local-variables-hook never fires for these
  ;; buffers.  Append so magit-blob-mode (the default hook entry) runs first.
  (with-eval-after-load 'magit-files
    (add-hook 'magit-find-blob-hook #'glz/testfall-apply t)))

(when glz/enable-anforderungen
  (let ((f (expand-file-name "anforderungen-mode.el" user-emacs-directory)))
    (if (file-exists-p f) (load-file f)
      (message "Warning: %s not found, skipping anforderungen-mode" f))))

(when glz/enable-canape-par
  (let ((f (expand-file-name "canape-par-mode.el" user-emacs-directory)))
    (if (file-exists-p f) (load-file f)
      (message "Warning: %s not found, skipping canape-par-mode" f))))

(setq tramp-use-scp-direct-remote-copying t)
(setq remote-file-name-inhibit-cache nil)
(setq vc-handled-backends '(Git))
(setq remote-file-name-inhibit-locks t)
(setq remote-file-name-inhibit-auto-save-visited t)
(setq tramp-copy-size-limit (* 1024 1024) ;; 1MB
      tramp-verbose 2)

(connection-local-set-profile-variables
 'my-dired-profile
 '((dired-check-symlinks . nil)))


(connection-local-set-profiles
 '(:application tramp :machine "remotehost")
 'my-dired-profile)

(connection-local-set-profile-variables
 'remote-direct-async-process
 '((tramp-direct-async-process . t)))

(connection-local-set-profiles
 '(:application tramp :protocol "scp")
 'remote-direct-async-process)

(with-eval-after-load 'tramp
  (with-eval-after-load 'compile
    (remove-hook 'compilation-mode-hook #'tramp-compile-disable-ssh-controlmaster-options)))

(setq magit-tramp-pipe-stty-settings 'pty)

(setq shell-history-file-name t)

;; don't show the diff by default in the commit buffer. Use `C-c C-d' to display it
(setq magit-commit-show-diff nil)
;; don't show git variables in magit branch
(setq magit-branch-direct-configure nil)
;; don't automatically refresh the status buffer after running a git command
(setq magit-refresh-status-buffer nil)

(with-eval-after-load 'org
  (require 'ox-md))

(when (executable-find "pandoc")
  (use-package ox-pandoc
    :after org))

(when glz/enable-open-externally

  (defvar glz/external-file-extensions
    '(;; Microsoft Office
      "xlsx" "xls" "xlsm" "xlsb"
      "docx" "doc" "docm"
      "pptx" "ppt" "pptm"
      ;; OpenDocument
      "odt" "ods" "odp" "odg"
      ;; Images
      "png" "jpg" "jpeg" "gif" "bmp" "tiff" "tif" "webp" "svg" "ico"
      ;; Audio / Video
      "mp3" "wav" "flac" "ogg" "aac"
      "mp4" "avi" "mkv" "mov" "wmv" "webm"
      ;; Archives
      "zip" "rar" "7z" "tar" "gz" "bz2" "xz"
      ;; Misc binary
      "exe" "msi" "dmg" "iso")
    "Extensions delegated to the OS default application instead of Emacs.")

  (defun glz/open-file-with-os-default (file)
    "Open FILE using the OS default application."
    (pcase glz/platform
      ('windows (w32-shell-execute "open" (expand-file-name file)))
      (_        (call-process "xdg-open" nil 0 nil (expand-file-name file)))))

  (defun glz/maybe-open-externally ()
    "Hand off the visited file to the OS when its extension is external."
    (when-let* ((file buffer-file-name)
                (ext  (file-name-extension file))
                (_    (member (downcase ext) glz/external-file-extensions)))
      (glz/open-file-with-os-default file)
      (let ((buf (current-buffer)))
        (run-with-idle-timer 0 nil #'kill-buffer buf))))

  (add-hook 'find-file-hook #'glz/maybe-open-externally))

(use-package corfu
  :custom
  (corfu-auto        t)
  (corfu-auto-delay  0.2)
  (corfu-auto-prefix 2)
  (corfu-cycle       t)
  (corfu-quit-no-match 'separator)
  :hook ((prog-mode   . corfu-mode)
         (eshell-mode . corfu-mode)))

(when glz/enable-lsp-c
  ;; ----- Eglot: clangd for C/C++ -----
  (use-package eglot
    :ensure nil
    :preface
    (defun glz/eglot-c-maybe-start ()
      "Start eglot for C/C++ only when clangd is available."
      (when (executable-find "clangd")
        (eglot-ensure)))
    :config
    (add-to-list 'eglot-server-programs
                 '((c-mode c++-mode c-ts-mode c++-ts-mode)
                   . ("clangd"
                      "--background-index"
                      "--clang-tidy"
                      "--header-insertion=never"
                      "--completion-style=detailed"
                      "--function-arg-placeholders=0")))
    :hook ((c-mode      . glz/eglot-c-maybe-start)
           (c++-mode    . glz/eglot-c-maybe-start)
           (c-ts-mode   . glz/eglot-c-maybe-start)
           (c++-ts-mode . glz/eglot-c-maybe-start))))

(load custom-file 'noerror 'no-message)
