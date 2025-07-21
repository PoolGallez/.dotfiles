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

(when (string= "windows-nt" system-type)
  ;; Configuration for windows
  (setq org-directory "~/Desktop/PKDB_Org/Notes")
  )

(when (string= "gnu/linux" system-type)
  ;; Configuration for Linux

  (setq org-directory "~/Documents/PKDB_Org/Notes")
  )

(when (string= "windows-nt" system-type)
  ;; Configuration for windows
  (setq org-roam-directory "~/Desktop/PKDB_Org/Zettlekasten/")
  )

(when (string= "gnu/linux" system-type)
  ;; Configuration for Linux

  (setq org-roam-directory "~/Documents/PKDB_Org/Zettlekasten/")
  )

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

;; Bind this to Spc n r I
(defun org-roam-node-insert-immediate (arg &rest args)
  (interactive "P")
  (let ((args (cons arg args))
        (org-roam-capture-templates (list (append (car org-roam-capture-templates)
                                                  '(:immediate-finish t)))))
    (apply #'org-roam-node-insert args)))

(add-hook 'org-roam-file-setup-hook #'glz/update-todo-tag)
(add-hook 'before-save-hook #'glz/update-todo-tag)
(advice-add 'org-agenda :before #'glz/update-todo-files)
(defun glz/todo-p ()
  "Return non-nil if current buffer has any TODO entry.

TODO entries marked as done are ignored, meaning the this
function returns nil if current buffer contains only completed
tasks."
  (org-element-map
      (org-element-parse-buffer 'headline)
      'headline
    (lambda (h)
      (eq (org-element-property :todo-type h)
          'todo))
    nil 'first-match))

(defun glz/update-todo-tag ()
  "Update TODO tag in the current buffer."
  (when (and (not (active-minibuffer-window))
             (org-roam--org-file-p buffer-file-name))
    (let* ((file (buffer-file-name (buffer-base-buffer)))
           (all-tags (org-roam--extract-tags file))
           (prop-tags (org-roam--extract-tags-prop file))
           (tags prop-tags))
      (if (glz/todo-p)
          (setq tags (seq-uniq (cons "todo" tags)))
        (setq tags (remove "todo" tags)))
      (unless (equal prop-tags tags)
        (org-roam--set-global-prop
         "roam_tags"
         (combine-and-quote-strings tags))))))

(defun glz/todo-files ()
  "Return a list of note files containing todo tag."
  (seq-map
   #'car
   (org-roam-db-query
    [:select file
             :from tags
             :where (like tags (quote "%\"todo\"%"))])))

(defun glz/update-todo-files (&rest _)
  "Update the value of `org-agenda-files'."
  (setq org-agenda-files (glz/todo-files)))

(dolist (file (org-roam-list-files))
  (message "processing %s" file)
  (with-current-buffer (or (find-buffer-visiting file)
                           (find-file-noselect file))
    (glz/update-todo-files)
    (save-buffer)))

(dolist (file (org-roam-list-files))
  (message "processing %s" file)
  (with-current-buffer (or (find-buffer-visiting file)
                           (find-file-noselect file))
    (glz/update-todo-files)
    (save-buffer)))

(setq org-latex-create-formula-image-program 'dvipng)

;; Automatically tangle our Emacs.org config file when we save it
(defun glz/org-babel-tangle-config ()
  (when (string-equal (file-name-nondirectory buffer-file-name)
                      ; Select different location depending on the os (hopefully this works in elisp :D)
                      "config.org")

    (let ((org-confirm-babel-evaluate nil))
      (org-babel-tangle))))

(add-hook 'org-mode-hook (lambda () (add-hook 'after-save-hook #'glz/org-babel-tangle-config)))

; Here we define different sequences of "Task/Todos" and define a custom workflow

(setq org-todo-keywords
      '((sequence "TODO(t)" "|" "DONE(d)")
        (sequence "REPORT(r)" "BUG(b)" "KNOWNCAUSE(k)" "|" "FIXED(f)")
        (sequence "IDEA" "DISCUSSION" "FEASIBILITY_ANALYSIS" "|" "ABORTED" "ACCEPTED")
        (sequence "|" "CANCELED(c)")))

(after! org
  (use-package! ox-extra
    :config
    (ox-extras-activate '(latex-header-blocks ignore-headlines)))
  )

(after! org
  ;; Import ox-latex to get org-latex-classes and other funcitonality
  ;; for exporting to LaTeX from org
  (use-package! ox-latex
    :init
    ;; code here will run immediately
    :config
    ;; code here will run after the package is loaded
    (setq org-latex-pdf-process
          '("pdflatex -interaction nonstopmode -output-directory %o %f"
            "bibtex %b"
            "pdflatex -interaction nonstopmode -output-directory %o %f"
            "pdflatex -interaction nonstopmode -output-directory %o %f"))
    (setq org-latex-with-hyperref nil) ;; stop org adding hypersetup{author..} to latex export
    ;; (setq org-latex-prefer-user-labels t)

    ;; deleted unwanted file extensions after latexMK
    (setq org-latex-logfiles-extensions
          (quote ("lof" "lot" "tex~" "aux" "idx" "log" "out" "toc" "nav" "snm" "vrb" "dvi" "fdb_latexmk" "blg" "brf" "fls" "entoc" "ps" "spl" "bbl" "xmpi" "run.xml" "bcf" "acn" "acr" "alg" "glg" "gls" "ist")))

    (unless (boundp 'org-latex-classes)
      (setq org-latex-classes nil)))

(map! :after org-roam
      :map org-roam-immediate-insert
      "SPC n r I" #'org-roam-insert-immediate)

(setq shell-file-name (executable-find
      "bash"))

(setq default-directory "~")
