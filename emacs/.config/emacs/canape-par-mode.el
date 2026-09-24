;;; canape-par-mode.el --- Major mode for CANAPE .par parameter files -*- lexical-binding: t; -*-

(require 'cl-lib)

(defgroup canape-par nil
  "Major mode for CANAPE parameter export (.par) files."
  :group 'languages)

;;; ── Syntax table ─────────────────────────────────────────────────────────────
;; ; begins a line comment (real-world value annotation or free-text note).

(defvar canape-par-mode-syntax-table
  (let ((st (make-syntax-table)))
    (modify-syntax-entry ?\; "<" st)   ; comment start
    (modify-syntax-entry ?\n ">" st)   ; comment end
    (modify-syntax-entry ?_  "w" st)   ; _ is a word constituent
    st)
  "Syntax table for `canape-par-mode'.")

;;; ── Custom faces ─────────────────────────────────────────────────────────────

(defface canape-par-parameter-face
  '((t :inherit font-lock-function-name-face))
  "Face for top-level parameter names."
  :group 'canape-par)

(defface canape-par-value-marker-face
  '((t :inherit font-lock-builtin-face))
  "Face for the : value-line marker."
  :group 'canape-par)

;;; ── Font-lock ────────────────────────────────────────────────────────────────

(defconst canape-par-font-lock-keywords
  (list
   ;; Parameter name: identifier (dots allowed) at line start, before [
   '("^\\([A-Za-z][A-Za-z0-9_.]*\\)[[:space:]]*\\["
     (1 'canape-par-parameter-face))

   ;; Type annotation: [TYPE(BITS)] or [TYPE(BITS),(ROWS,COLS)]
   ;;   group 1 → type name, group 2 → bit width, group 3 → dims (optional)
   '("\\[\\([A-Za-z]+\\)(\\([0-9]+\\))\\(?:,(\\([0-9,]+\\))\\)?\\]"
     (1 font-lock-type-face)
     (2 font-lock-constant-face)
     (3 font-lock-constant-face nil t))

   ;; Value-line marker :
   '("^[[:space:]]*\\(:\\)"
     (1 'canape-par-value-marker-face))

   ;; Numeric literals — integer or float, possibly negative
   '("-?\\b[0-9]+\\(?:\\.[0-9]+\\(?:[eE][+-]?[0-9]+\\)?\\)?\\b"
     . font-lock-constant-face))
  "Font-lock keyword list for `canape-par-mode'.")

;;; ── Imenu ────────────────────────────────────────────────────────────────────

(defun canape-par--imenu-index ()
  "Build an imenu index of parameter names."
  (let (entries)
    (save-excursion
      (goto-char (point-min))
      (while (re-search-forward
              "^\\([A-Za-z][A-Za-z0-9_.]*\\)[[:space:]]*\\[" nil t)
        (push (cons (match-string-no-properties 1) (match-beginning 1))
              entries)))
    (nreverse entries)))

;;; ── Table popup internals ────────────────────────────────────────────────────

(defconst canape-par--header-re
  "^\\([A-Za-z][A-Za-z0-9_.]*\\)[[:space:]]*\\(\\[[^]\n]+\\]\\)"
  "Match a parameter header line.
Group 1: identifier.  Group 2: full bracket annotation.")

(defconst canape-par--value-line-re
  (concat "^[[:space:]]*:[[:space:]]*"
          "\\(-?[0-9]+\\(?:\\.[0-9]+\\(?:[eE][+-]?[0-9]+\\)?\\)?\\)"
          "[[:space:]]*;[[:space:]]*"
          "\\([^\n\r]*\\)")
  "Match a value line ': RAW ; REAL-OR-LABEL'.
Group 1: raw numeric value.  Group 2: real-world value or text label.")

(defun canape-par--parse-annotation (annotation)
  "Parse bracket annotation string e.g. \"[INT(16),(6,3)]\".
Returns plist (:type :bits :rows :cols)."
  (let* ((inner (substring annotation 1 (1- (length annotation))))
         type bits rows cols)
    (when (string-match "\\([A-Za-z]+\\)(\\([0-9]+\\))" inner)
      (setq type (match-string 1 inner)
            bits (string-to-number (match-string 2 inner))))
    (cond
     ;; 2-D  (ROWS,COLS)
     ((string-match ",(\\([0-9]+\\),\\([0-9]+\\))" inner)
      (setq rows (string-to-number (match-string 1 inner))
            cols (string-to-number (match-string 2 inner))))
     ;; 1-D  (N)  — treat as 1 × N
     ((string-match ",(\\([0-9]+\\))" inner)
      (setq rows 1
            cols (string-to-number (match-string 1 inner))))
     ;; scalar — no dimension spec
     (t (setq rows 1 cols 1)))
    (list :type (or type "?") :bits (or bits 0)
          :rows (or rows 1)   :cols (or cols 1))))

(defun canape-par--find-header ()
  "Return info plist for the parameter block containing point, or nil.
Plist keys: :name :type :bits :rows :cols :header-pos."
  (save-excursion
    (beginning-of-line)
    (when (or (looking-at canape-par--header-re)
              (re-search-backward canape-par--header-re nil t))
      ;; Capture match data BEFORE parse-annotation calls string-match,
      ;; which would overwrite the global match data with string offsets.
      (let* ((header-pos (match-beginning 0))
             (name    (match-string-no-properties 1))
             (annot   (match-string-no-properties 2))
             (parsed  (canape-par--parse-annotation annot)))
        (list :name       name
              :type       (plist-get parsed :type)
              :bits       (plist-get parsed :bits)
              :rows       (plist-get parsed :rows)
              :cols       (plist-get parsed :cols)
              :header-pos header-pos)))))

(defun canape-par--collect-values (header-pos count)
  "Collect up to COUNT value lines immediately after HEADER-POS.
Returns a list of (RAW-STRING . REAL-STRING) pairs."
  (save-excursion
    (goto-char header-pos)
    (forward-line 1)
    (let (values)
      (while (and (< (length values) count) (not (eobp)))
        (cond
         ((looking-at canape-par--value-line-re)
          (push (cons (string-trim (match-string-no-properties 1))
                      (string-trim (match-string-no-properties 2)))
                values)
          (forward-line 1))
         ((looking-at "^[[:space:]]*$")  ; skip blank separators
          (forward-line 1))
         (t                              ; next header or unknown line → stop
          (goto-char (point-max)))))
      (nreverse values))))

(defconst canape-par--max-cell-width 28
  "Maximum cell width in table display; longer values are truncated.")

(defun canape-par--trunc (s)
  "Truncate S to `canape-par--max-cell-width', appending … if cut."
  (if (> (length s) canape-par--max-cell-width)
      (concat (substring s 0 (- canape-par--max-cell-width 1)) "…")
    s))

(defun canape-par--col-widths (rows cols values getter)
  "Compute per-column display widths for a ROWS×COLS grid.
Returns a list of COLS integers, each at least as wide as its column header."
  (cl-loop for c from 0 below cols collect
           (apply #'max
                  (length (format "Col %d" (1+ c)))
                  (cl-loop for r from 0 below rows
                           for i = (+ (* r cols) c)
                           collect (length (canape-par--trunc
                                            (if (< i (length values))
                                                (funcall getter (nth i values))
                                              "—")))))))

(defun canape-par--table-string (rows cols values getter &optional numeric col-widths)
  "Render VALUES as a ROWS×COLS ASCII table.
GETTER extracts the display string from each (RAW . REAL) pair.
NUMERIC non-nil → right-align cells; nil → left-align.
COL-WIDTHS, if supplied, overrides the per-column width calculation so that
two tables sharing the same COL-WIDTHS list stay visually aligned."
  (let* ((grid
          (cl-loop for r from 0 below rows collect
                   (cl-loop for c from 0 below cols
                            for i = (+ (* r cols) c)
                            collect (canape-par--trunc
                                     (if (< i (length values))
                                         (funcall getter (nth i values))
                                       "—")))))
         (col-widths (or col-widths (canape-par--col-widths rows cols values getter)))
         (row-lw
          (apply #'max 5
                 (cl-loop for r from 1 to rows collect
                          (length (format "Row %d" r)))))
         (pad (if numeric
                  (lambda (s w) (concat (make-string (max 0 (- w (length s))) ?\s) s))
                (lambda (s w) (concat s (make-string (max 0 (- w (length s))) ?\s)))))
         (rpad (lambda (s w) (concat (make-string (max 0 (- w (length s))) ?\s) s)))
         lines)
    ;; ── Column header ─────────────────────────────────────────────────────────
    (push (concat (make-string row-lw ?\s) " │ "
                  (mapconcat
                   (lambda (c)
                     (funcall rpad (format "Col %d" (1+ c)) (nth c col-widths)))
                   (number-sequence 0 (1- cols)) " │ ")
                  " │")
          lines)
    ;; ── Separator ─────────────────────────────────────────────────────────────
    (push (concat (make-string row-lw ?─) "─┼─"
                  (mapconcat (lambda (c) (make-string (nth c col-widths) ?─))
                             (number-sequence 0 (1- cols)) "─┼─")
                  "─┤")
          lines)
    ;; ── Data rows ─────────────────────────────────────────────────────────────
    (cl-loop for r from 0 below rows do
             (push (concat
                    (funcall rpad (format "Row %d" (1+ r)) row-lw)
                    " │ "
                    (mapconcat
                     (lambda (c)
                       (funcall pad (nth c (nth r grid)) (nth c col-widths)))
                     (number-sequence 0 (1- cols)) " │ ")
                    " │")
                   lines))
    (mapconcat #'identity (nreverse lines) "\n")))

(defun canape-par--numeric-values-p (values getter)
  "Return non-nil when every value extracted by GETTER looks like a number."
  (cl-every (lambda (v)
               (string-match-p
                "^-?[0-9]+\\(?:\\.[0-9]+\\(?:[eE][+-]?[0-9]+\\)?\\)?$"
                (string-trim (funcall getter v))))
             values))

;;; ── Generic grid renderer ────────────────────────────────────────────────────

(defun canape-par--grid-col-widths (col-labels grid)
  "Compute per-column widths for GRID, at least as wide as each COL-LABEL."
  (cl-loop for c from 0 below (length col-labels) collect
           (apply #'max
                  (length (nth c col-labels))
                  (mapcar (lambda (row) (length (nth c row))) grid))))

(defun canape-par--render-grid (row-labels col-labels grid &optional numeric col-widths)
  "Render GRID as a fixed-width ASCII table with explicit labels.
ROW-LABELS / COL-LABELS are string lists.  GRID is a list-of-lists of
pre-truncated cell strings.  NUMERIC → right-align cells; else left-align.
COL-WIDTHS overrides computed column widths for cross-table alignment."
  (let* ((row-lw (apply #'max 1 (mapcar #'length row-labels)))
         (col-widths
          (or col-widths (canape-par--grid-col-widths col-labels grid)))
         (pad (if numeric
                  (lambda (s w) (concat (make-string (max 0 (- w (length s))) ?\s) s))
                (lambda (s w) (concat s (make-string (max 0 (- w (length s))) ?\s)))))
         (rpad (lambda (s w) (concat (make-string (max 0 (- w (length s))) ?\s) s)))
         lines)
    (push (concat (make-string row-lw ?\s) " │ "
                  (mapconcat (lambda (c)
                               (funcall rpad (nth c col-labels) (nth c col-widths)))
                             (number-sequence 0 (1- (length col-labels))) " │ ")
                  " │")
          lines)
    (push (concat (make-string row-lw ?─) "─┼─"
                  (mapconcat (lambda (c) (make-string (nth c col-widths) ?─))
                             (number-sequence 0 (1- (length col-labels))) "─┼─")
                  "─┤")
          lines)
    (cl-loop for r from 0 below (length row-labels) do
             (push (concat
                    (funcall rpad (nth r row-labels) row-lw)
                    " │ "
                    (mapconcat
                     (lambda (c)
                       (funcall pad (nth c (nth r grid)) (nth c col-widths)))
                     (number-sequence 0 (1- (length col-labels))) " │ ")
                    " │")
                   lines))
    (mapconcat #'identity (nreverse lines) "\n")))

;;; ── Structured inline format: BASE._IDX_LABEL._FIELD [TYPE] VALUE ; COMMENT ─

(defconst canape-par--struct-re
  (concat "^\\([A-Za-z][A-Za-z0-9_]*\\)"         ; group 1: base name (no dots)
          "\\._\\([0-9]+\\)"                        ; group 2: numeric index
          "_\\([A-Za-z][A-Za-z0-9_]*\\)"            ; group 3: row label
          "\\._\\([A-Za-z][A-Za-z0-9_]*\\)"         ; group 4: field / column
          "[[:space:]]*\\[[^]]+\\]"                  ; bracket annotation (skipped)
          "[[:space:]]+"
          "\\([^;[:space:]\n]+\\)"                   ; group 5: raw value
          "\\(?:[[:space:]]*;[[:space:]]*\\([^\n\r]*\\)\\)?") ; group 6: comment (opt)
  "Match BASE._IDX_LABEL._FIELD [TYPE] VALUE ; COMMENT.")

(defun canape-par--struct-at-point ()
  "If point is on a structured inline parameter line, return its base name; else nil."
  (save-excursion
    (beginning-of-line)
    (when (looking-at canape-par--struct-re)
      (match-string-no-properties 1))))

(defun canape-par--collect-struct (base)
  "Scan the buffer for all structured inline parameters sharing BASE.
Returns plists (:index :label :field :value :comment) sorted by index."
  (let (entries
        (re (concat "^" (regexp-quote base)
                    "\\._\\([0-9]+\\)"
                    "_\\([A-Za-z][A-Za-z0-9_]*\\)"
                    "\\._\\([A-Za-z][A-Za-z0-9_]*\\)"
                    "[[:space:]]*\\[[^]]+\\][[:space:]]+"
                    "\\([^;[:space:]\n]+\\)"
                    "\\(?:[[:space:]]*;[[:space:]]*\\([^\n\r]*\\)\\)?")))
    (save-excursion
      (goto-char (point-min))
      (while (re-search-forward re nil t)
        (push (list :index   (match-string-no-properties 1)
                    :label   (match-string-no-properties 2)
                    :field   (match-string-no-properties 3)
                    :value   (match-string-no-properties 4)
                    :comment (string-trim (or (match-string-no-properties 5) "")))
              entries)))
    (cl-sort (nreverse entries) #'string<
             :key (lambda (e) (plist-get e :index)))))

(defun canape-par--show-struct-table (base)
  "Show the structured parameter group BASE as a 2-D table popup."
  (let* ((entries (canape-par--collect-struct base)))
    (unless entries
      (user-error "No structured parameters found for base: %s" base))
    ;; Unique row keys (index . label) and col keys (field), preserving order
    (let* ((row-keys
            (let (seen)
              (dolist (e entries (nreverse seen))
                (let ((k (cons (plist-get e :index) (plist-get e :label))))
                  (unless (cl-find k seen :test #'equal) (push k seen))))))
           (col-keys
            (let (seen)
              (dolist (e entries (nreverse seen))
                (let ((f (plist-get e :field)))
                  (unless (member f seen) (push f seen))))))
           ;; Separate lookup tables for raw values and real-world comments
           (val-lookup     (make-hash-table :test #'equal))
           (comment-lookup (make-hash-table :test #'equal)))
      (dolist (e entries)
        (let ((k (list (plist-get e :index)
                       (plist-get e :label)
                       (plist-get e :field))))
          (puthash k (plist-get e :value)   val-lookup)
          (puthash k (plist-get e :comment) comment-lookup)))
      (let* ((row-labels (mapcar (lambda (k) (format "%s %s" (car k) (cdr k)))
                                 row-keys))
             (col-labels col-keys)
             ;; Build both grids
             (mk-grid (lambda (tbl)
                        (cl-loop for rk in row-keys collect
                                 (cl-loop for ck in col-keys collect
                                          (canape-par--trunc
                                           (or (gethash (list (car rk) (cdr rk) ck) tbl)
                                               "—"))))))
             (val-grid     (funcall mk-grid val-lookup))
             (comment-grid (funcall mk-grid comment-lookup))
             ;; Unified column widths so both tables stay aligned
             (widths (cl-mapcar #'max
                                (canape-par--grid-col-widths col-labels val-grid)
                                (canape-par--grid-col-widths col-labels comment-grid)))
             ;; Alignment: raw values always numeric; comments only when all numeric
             (comment-numeric
              (cl-every (lambda (row)
                          (cl-every (lambda (v) (string-match-p "^-?[0-9]" v)) row))
                        comment-grid))
             (buf (get-buffer-create (format "*CANAPE: %s*" base))))
        (with-current-buffer buf
          (let ((inhibit-read-only t))
            (erase-buffer)
            (insert (format "Parameter group: %s\n" base))
            (insert (format "Structure:       %d row%s × %d field%s\n\n"
                            (length row-keys) (if (= (length row-keys) 1) "" "s")
                            (length col-keys) (if (= (length col-keys) 1) "" "s")))
            (insert "Real-world values:\n\n")
            (insert (canape-par--render-grid row-labels col-labels
                                             comment-grid comment-numeric widths))
            (insert "\n\nRaw (stored) values:\n\n")
            (insert (canape-par--render-grid row-labels col-labels
                                             val-grid t widths))
            (insert "\n\n[q] close  [TAB] section  [n/p] rows  [f/b] cols  [B] binary\n"))
          (canape-par-table-mode)
          (setq-local canape-par-table--raw-grid   val-grid)
          (setq-local canape-par-table--row-labels row-labels)
          (setq-local canape-par-table--col-labels col-labels)
          (canape-par-table--goto-first-cell))
        (pop-to-buffer buf '((display-buffer-below-selected)))
        (when-let ((win (get-buffer-window buf)))
          (with-selected-window win
            (fit-window-to-buffer win 25 8)))))))

;;; ── Table popup command ──────────────────────────────────────────────────────

(defun canape-par-show-table ()
  "Display the parameter at point as a 2-D table in a popup buffer.
Detects format automatically:
  - BASE._IDX_LABEL._FIELD [TYPE] VALUE ; COMMENT  → structured group table
  - PARAM [TYPE,(ROWS,COLS)] followed by : value lines → array block table"
  (interactive)
  (let ((struct-base (canape-par--struct-at-point)))
    (if struct-base
        (canape-par--show-struct-table struct-base)
      ;; Array / block format
      (let ((info (canape-par--find-header)))
    (unless info (user-error "Not inside a CANAPE parameter block"))
    (let* ((name  (plist-get info :name))
           (type  (plist-get info :type))
           (bits  (plist-get info :bits))
           (rows  (plist-get info :rows))
           (cols  (plist-get info :cols))
           (hpos  (plist-get info :header-pos))
           (total (* rows cols))
           (vals  (canape-par--collect-values hpos total))
           (found (length vals))
           ;; Unified column widths: element-wise max of both tables so that
           ;; the two grids stay visually aligned for easy comparison.
           (widths (cl-mapcar #'max
                              (canape-par--col-widths rows cols vals #'cdr)
                              (canape-par--col-widths rows cols vals #'car)))
           ;; Right-align real-world values only when they are all numeric
           (real-numeric (canape-par--numeric-values-p vals #'cdr))
           (buf   (get-buffer-create (format "*CANAPE: %s*" name))))
      (with-current-buffer buf
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert (format "Parameter:  %s\n" name))
          (insert (format "Type:       %s(%d)   Dimensions: %d × %d"
                          type bits rows cols))
          (when (< found total)
            (insert (format "  [only %d/%d values found]" found total)))
          (insert "\n\n")
          ;; Real-world values — right-aligned when numeric, left when text labels
          (insert "Real-world values:\n\n")
          (insert (canape-par--table-string rows cols vals #'cdr real-numeric widths))
          (insert "\n\n")
          ;; Raw (stored) values — right-aligned (always numeric), same widths
          (insert "Raw (stored) values:\n\n")
          (insert (canape-par--table-string rows cols vals #'car t widths))
          (insert "\n\n[q] close  [TAB] section  [n/p] rows  [f/b] cols  [B] binary\n"))
        (canape-par-table-mode)
        (setq-local canape-par-table--raw-grid
                    (cl-loop for r from 0 below rows collect
                             (cl-loop for c from 0 below cols collect
                                      (car (nth (+ (* r cols) c) vals)))))
        (setq-local canape-par-table--row-labels
                    (cl-loop for r from 1 to rows collect (format "Row %d" r)))
        (setq-local canape-par-table--col-labels
                    (cl-loop for c from 1 to cols collect (format "Col %d" c)))
        (canape-par-table--goto-first-cell))
      ;; Show below the current window; fit height to content (max 25 lines)
      (pop-to-buffer buf '((display-buffer-below-selected)))
      (when-let ((win (get-buffer-window buf)))
        (with-selected-window win
          (fit-window-to-buffer win 25 8))))))))

;;; ── Table popup navigation mode ─────────────────────────────────────────────

(defvar-local canape-par-table--raw-grid nil
  "List-of-lists of raw integer strings, stored at render time for binary toggle.")
(defvar-local canape-par-table--row-labels nil
  "Row label strings for the current popup (set at render time).")
(defvar-local canape-par-table--col-labels nil
  "Column label strings for the current popup (set at render time).")
(defvar-local canape-par-table--binary-p nil
  "Non-nil when the raw section is currently showing binary values.")

(defun canape-par-table--data-row-p ()
  "Non-nil if the current line is a data row (│ present, ┼ absent, label non-blank)."
  (let ((line (buffer-substring-no-properties
               (line-beginning-position) (line-end-position))))
    (and (string-match-p "│" line)
         (not (string-match-p "┼" line))
         ;; Content before first │ must not be all-whitespace (that would be the col header)
         (string-match-p "[^[:space:]]" (car (split-string line "│"))))))

(defun canape-par-table--col-at-point ()
  "0-based column index at point (0 = first data column, after the row-label │)."
  (let ((p (point)) (n 0))
    (save-excursion
      (beginning-of-line)
      (while (and (< (point) p) (search-forward "│" p t))
        (cl-incf n)))
    (max 0 (1- n))))

(defun canape-par-table--goto-col (col)
  "Move to the start of data cell COL (0-based) on the current line."
  (beginning-of-line)
  ;; Skip row-label separator plus COL column separators
  (dotimes (_ (1+ col))
    (when (search-forward "│" (line-end-position) t)
      (when (eq (char-after) ?\s) (forward-char 1)))))

(defun canape-par-table--row-offset ()
  "0-based index of the current data row within its section."
  (let ((target (line-number-at-pos)) (idx 0))
    (save-excursion
      (when (re-search-backward "^\\(?:Real-world values\\|Raw (stored) values\\)" nil t)
        (forward-line 1)
        (while (and (not (eobp)) (not (canape-par-table--data-row-p)))
          (forward-line 1))
        (while (and (< (line-number-at-pos) target)
                    (not (eobp))
                    (canape-par-table--data-row-p))
          (cl-incf idx)
          (forward-line 1))))
    idx))

(defun canape-par-table-next-row ()
  "Move to the same column in the next data row."
  (interactive)
  (let ((col   (if (canape-par-table--data-row-p) (canape-par-table--col-at-point) 0))
        (start (point)))
    (forward-line 1)
    (while (and (not (eobp)) (not (canape-par-table--data-row-p)))
      (forward-line 1))
    (if (canape-par-table--data-row-p)
        (canape-par-table--goto-col col)
      (goto-char start))))

(defun canape-par-table-prev-row ()
  "Move to the same column in the previous data row."
  (interactive)
  (let ((col   (if (canape-par-table--data-row-p) (canape-par-table--col-at-point) 0))
        (start (point)))
    (forward-line -1)
    (while (and (not (bobp)) (not (canape-par-table--data-row-p)))
      (forward-line -1))
    (if (canape-par-table--data-row-p)
        (canape-par-table--goto-col col)
      (goto-char start))))

(defun canape-par-table-next-col ()
  "Move to the next column in the current data row."
  (interactive)
  (when (canape-par-table--data-row-p)
    (canape-par-table--goto-col (1+ (canape-par-table--col-at-point)))))

(defun canape-par-table-prev-col ()
  "Move to the previous column in the current data row."
  (interactive)
  (when (canape-par-table--data-row-p)
    (let ((col (canape-par-table--col-at-point)))
      (when (> col 0)
        (canape-par-table--goto-col (1- col))))))

(defun canape-par-table-toggle-section ()
  "Jump to the same row and column in the other table section."
  (interactive)
  (let* ((col      (if (canape-par-table--data-row-p) (canape-par-table--col-at-point) 0))
         (row      (canape-par-table--row-offset))
         (here-hdr (save-excursion
                     (re-search-backward
                      "^\\(?:Real-world values\\|Raw (stored) values\\)" nil t)))
         (other    (when here-hdr
                     (save-excursion
                       (goto-char (point-min))
                       (let (found)
                         (while (re-search-forward
                                 "^\\(?:Real-world values\\|Raw (stored) values\\)" nil t)
                           (unless (= (match-beginning 0) here-hdr)
                             (setq found (match-beginning 0))))
                         found)))))
    (when other
      (goto-char other)
      (forward-line 1)
      (while (and (not (eobp)) (not (canape-par-table--data-row-p)))
        (forward-line 1))
      (dotimes (_ row)
        (when (and (canape-par-table--data-row-p) (not (eobp)))
          (forward-line 1)))
      (when (canape-par-table--data-row-p)
        (canape-par-table--goto-col col)))))

(defun canape-par-table--to-binary (n)
  "Return binary string for integer N (e.g. 5 → \"0b101\", -3 → \"-0b11\")."
  (let* ((neg (< n 0))
         (v   (abs n))
         (bits (if (= v 0) "0"
                 (let (acc)
                   (while (> v 0)
                     (push (if (= (% v 2) 1) "1" "0") acc)
                     (setq v (/ v 2)))
                   (apply #'concat acc)))))
    (concat (if neg "-" "") "0b" bits)))

(defun canape-par-table--raw-table-region ()
  "Return (START . END) of the raw table body in the popup buffer."
  (save-excursion
    (goto-char (point-min))
    (when (re-search-forward "^Raw (stored) values:\n\n" nil t)
      (let ((start (point)))
        (when (re-search-forward "\n\n\\[" nil t)
          (cons start (match-beginning 0)))))))

(defun canape-par-table-toggle-binary ()
  "Toggle the Raw (stored) values section between decimal and binary.
The binary form is prefixed with 0b (e.g. 5 → 0b101).  Negative values
retain their sign (e.g. -3 → -0b11)."
  (interactive)
  (unless canape-par-table--raw-grid
    (user-error "Binary toggle not available (no raw integer data stored)"))
  (let* ((region (canape-par-table--raw-table-region)))
    (unless region (user-error "No raw values section found"))
    (let ((in-raw (save-excursion
                    (when (re-search-backward
                           "^\\(?:Real-world values\\|Raw (stored) values\\)" nil t)
                      (string-match-p "^Raw" (match-string 0)))))
          (cur-col (if (canape-par-table--data-row-p) (canape-par-table--col-at-point) 0))
          (cur-row (if (canape-par-table--data-row-p) (canape-par-table--row-offset) 0)))
    (setq canape-par-table--binary-p (not canape-par-table--binary-p))
    (let* ((grid (if canape-par-table--binary-p
                     (mapcar (lambda (row-vals)
                               (mapcar (lambda (v)
                                         (canape-par-table--to-binary
                                          (string-to-number v)))
                                       row-vals))
                             canape-par-table--raw-grid)
                   canape-par-table--raw-grid))
           (widths    (canape-par--grid-col-widths canape-par-table--col-labels grid))
           (new-table (canape-par--render-grid canape-par-table--row-labels
                                               canape-par-table--col-labels
                                               grid t widths))
           (inhibit-read-only t))
      (save-excursion
        (delete-region (car region) (cdr region))
        (goto-char (car region))
        (insert new-table)))
    ;; Restore cursor: same row/col in raw section when we were there, else first cell
    (goto-char (point-min))
    (when (re-search-forward "^Raw (stored) values:" nil t)
      (forward-line 2)
      (while (and (not (eobp)) (not (canape-par-table--data-row-p)))
        (forward-line 1))
      (when in-raw
        (dotimes (_ cur-row)
          (when (and (canape-par-table--data-row-p) (not (eobp)))
            (forward-line 1)))
        (unless (canape-par-table--data-row-p) (forward-line -1)))
      (when (canape-par-table--data-row-p)
        (canape-par-table--goto-col (if in-raw cur-col 0)))))))

(defun canape-par-table--goto-first-cell ()
  "Place point on the first data cell of the first table section."
  (goto-char (point-min))
  (when (re-search-forward "^\\(?:Real-world values\\|Raw (stored) values\\)" nil t)
    (while (and (not (eobp)) (not (canape-par-table--data-row-p)))
      (forward-line 1))
    (when (canape-par-table--data-row-p)
      (canape-par-table--goto-col 0))))

(defvar canape-par-table-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m "q"         #'quit-window)
    (define-key m "n"         #'canape-par-table-next-row)
    (define-key m "p"         #'canape-par-table-prev-row)
    (define-key m "f"         #'canape-par-table-next-col)
    (define-key m "b"         #'canape-par-table-prev-col)
    (define-key m (kbd "TAB") #'canape-par-table-toggle-section)
    (define-key m "s"         #'canape-par-table-toggle-section)
    (define-key m "B"         #'canape-par-table-toggle-binary)
    m)
  "Keymap for `canape-par-table-mode'.")

(define-derived-mode canape-par-table-mode special-mode "CANAPE-Table"
  "Read-only display mode for CANAPE parameter table popups.
Keys:
  n / p     next / previous data row
  f / b     next / previous column
  TAB / s   toggle between real-world and raw-stored table
  B         toggle raw values between decimal and binary
  q         close"
  :keymap canape-par-table-mode-map)

;;; ── Keymap ───────────────────────────────────────────────────────────────────

(defvar canape-par-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "C-c C-t") #'canape-par-show-table)
    m)
  "Keymap for `canape-par-mode'.")

;;; ── Mode definition ──────────────────────────────────────────────────────────

;;;###autoload
(define-derived-mode canape-par-mode fundamental-mode "CANAPE-PAR"
  "Major mode for CANAPE parameter export (.par) files.

File structure:
  PARAM_NAME [TYPE(BITS),(ROWS,COLS)]    parameter header
  :  RAW_INT ;  REAL_WORLD_VALUE         one value line per array cell
  ; standalone comment                   free-text note

Commands:
  \\[canape-par-show-table]  Show the parameter at point as a 2-D table popup."
  :syntax-table canape-par-mode-syntax-table
  (setq-local font-lock-defaults  '(canape-par-font-lock-keywords))
  (setq-local comment-start       "; ")
  (setq-local comment-end         "")
  (setq-local imenu-create-index-function #'canape-par--imenu-index)
  (font-lock-mode 1))

;;; ── Auto-mode registration ───────────────────────────────────────────────────

;;;###autoload
(add-to-list 'auto-mode-alist '("\\.par\\'" . canape-par-mode))

(provide 'canape-par-mode)
;;; canape-par-mode.el ends here
