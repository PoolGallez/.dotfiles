;;; sprint.el --- Sprint training system for PKDB -*- lexical-binding: t; -*-

;;; Commentary:
;; Automation layer for the files in PKDB/Athletics/Sprint/:
;;
;;   sprint_config_YYYY.org    all tunable parameters (#+MACRO lines)   edit by hand
;;   sprint_plan_YYYY.org      plan template, reads the config via #+SETUPFILE
;;   sprint_log_YYYY.org       sessions, tests and races                captures
;;   sprint_schedule_YYYY.org  generated week-by-week, day-by-day calendar
;;
;; sprint.el reads the same #+MACRO lines and the weekly tables of the plan, so
;; the config stays the single source of truth.
;;
;; Commands (prefix SPC o S when `glz/org-map' exists, or `sprint-map'):
;;   g `sprint-generate-schedule'  build/refresh the calendar from the config
;;   v `sprint-validate'           sanity-check config, plan and exercise DB
;;   i `sprint-today-info'         phase, planned session and readiness inputs now
;;   a `sprint-agenda'             agenda restricted to the sprint schedule
;;   s/t/r                         capture a session / test / race
;;   y `sprint-season-summary'     best values of the season for PREV_ macros
;;   n `sprint-new-season'         create next year's config/plan/log
;;
;; Lives in the dotfiles next to Config.org and is loaded from there (see the
;; "Sprint training system" section of Config.org).

;;; Code:

(require 'org)
(require 'org-capture)
(require 'calendar)
(require 'cl-lib)
(require 'subr-x)

(defgroup sprint nil "Sprint training system." :group 'org)

(defcustom sprint-directory
  (expand-file-name "Athletics/Sprint/"
                    (if (boundp 'glz/org-directory) glz/org-directory "~/PKDB/"))
  "Directory holding the sprint config, plan, log and schedule files."
  :type 'directory)

(defcustom sprint-db-file
  (expand-file-name "../TrainingDB.org" sprint-directory)
  "Exercise database (used by `sprint-validate')."
  :type 'file)

(defcustom sprint-season-year nil
  "Season to operate on.  nil means the highest sprint_config_YYYY.org found."
  :type '(choice (const nil) integer))

(defcustom sprint-test-weekday "WED"
  "Weekday on which the testing battery is scheduled in deload weeks."
  :type 'string)

(defvar sprint-today nil
  "Override for today's date as YYYY-MM-DD (testing only).")

;;;; Files and config

(defun sprint-season ()
  "Return the season year to work on."
  (or sprint-season-year
      (let (years)
        (dolist (f (directory-files sprint-directory))
          (when (string-match "\\`sprint_config_\\([0-9]+\\)\\.org\\'" f)
            (push (string-to-number (match-string 1 f)) years)))
        (if years (apply #'max years)
          (user-error "No sprint_config_YYYY.org in %s" sprint-directory)))))

(defun sprint-file (kind &optional year)
  "Path of the KIND (config, plan, log, schedule) file for YEAR."
  (expand-file-name (format "sprint_%s_%d.org" kind (or year (sprint-season)))
                    sprint-directory))

(defun sprint--read-macros (file)
  "Return the #+MACRO definitions of FILE as an alist of strings."
  (with-temp-buffer
    (insert-file-contents file)
    (let (res)
      (while (re-search-forward
              "^#\\+MACRO:[ \t]+\\([A-Za-z0-9_-]+\\)[ \t]+\\(.*?\\)[ \t]*$" nil t)
        (push (cons (match-string 1) (match-string 2)) res))
      (nreverse res))))

(defun sprint-config (&optional year)
  "Config alist for YEAR."
  (sprint--read-macros (sprint-file 'config year)))

(defun sprint--get (cfg key &optional default)
  (or (cdr (assoc key cfg)) default))

(defun sprint--int (cfg key &optional default)
  (let ((v (sprint--get cfg key)))
    (if (and v (string-match-p "\\`-?[0-9]+\\'" v)) (string-to-number v) (or default 0))))

(defun sprint--expand (string cfg)
  "Replace {{{MACRO}}} references in STRING using CFG."
  (replace-regexp-in-string
   "{{{\\([A-Za-z0-9_]+\\)}}}"
   (lambda (m) (or (sprint--get cfg (match-string 1 m)) (format "?%s?" (match-string 1 m))))
   string t t))

;;;; Dates (absolute day numbers, Monday = 1 by `calendar-day-of-week')

(defconst sprint--dow-names ["Sun" "Mon" "Tue" "Wed" "Thu" "Fri" "Sat"])
(defconst sprint--dow-codes '(("MON" . 1) ("TUE" . 2) ("WED" . 3) ("THU" . 4)
                              ("FRI" . 5) ("SAT" . 6) ("SUN" . 0)))

(defun sprint--date-p (s)
  (and (stringp s) (string-match-p "\\`[0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}\\'" s)))

(defun sprint--abs (s)
  "Absolute day number of the YYYY-MM-DD string S."
  (unless (sprint--date-p s) (error "Bad date: %S" s))
  (calendar-absolute-from-gregorian
   (list (string-to-number (substring s 5 7))
         (string-to-number (substring s 8 10))
         (string-to-number (substring s 0 4)))))

(defun sprint--str (abs)
  (let ((g (calendar-gregorian-from-absolute abs)))
    (format "%04d-%02d-%02d" (nth 2 g) (nth 0 g) (nth 1 g))))

(defun sprint--dow (abs) (mod abs 7))

(defun sprint--ts (abs)
  (format "<%s %s>" (sprint--str abs) (aref sprint--dow-names (sprint--dow abs))))

(defun sprint--today ()
  (if sprint-today (sprint--abs sprint-today)
    (calendar-absolute-from-gregorian (calendar-current-date))))

;;;; Phase calendar

(defconst sprint--phase-meta
  ;; id name indoor-only kind
  '(("PH1" "Fundamental I (GPP)"        nil "BLOCK")
    ("PH2" "Fundamental II (SPP-I)"     t   "BLOCK")
    ("PH3" "Indoor Competition"         t   "COMP")
    ("PH4" "Transition I"               t   "TRANSITION")
    ("PH5" "Transformation (SPP-II)"    nil "BLOCK")
    ("PH6" "Outdoor Competition"        nil "COMP")
    ("PH7" "Championship Peak"          nil "COMP")
    ("PH8" "Transition II"              nil "TRANSITION")))

(defun sprint--indoor-p (cfg) (equal (sprint--get cfg "INDOOR_SEASON") "true"))

(defun sprint--subphases (cfg id extra)
  "Sub-phases of phase ID as ((sub-id name load deload) ...).
EXTRA weeks are appended to the load weeks of the last sub-phase."
  (let ((n (sprint--int cfg (concat id "_SUBPHASES"))) subs)
    (dotimes (i n)
      (let ((p (format "%s_SP%d" id (1+ i))))
        (push (list p (sprint--get cfg (concat p "_NAME") p)
                    (sprint--int cfg (concat p "_LOAD_WEEKS"))
                    (sprint--int cfg (concat p "_DELOAD_WEEKS")))
              subs)))
    (setq subs (nreverse subs))
    (when (and subs (> extra 0))
      (let ((last (car (last subs))))
        (setf (nth 2 last) (+ (nth 2 last) extra))))
    subs))

(defun sprint--phases (cfg)
  "Active phases for CFG as plists (:id :name :weeks :kind :subs)."
  (let ((indoor (sprint--indoor-p cfg)) out)
    (dolist (m sprint--phase-meta)
      (let* ((id (nth 0 m))
             (extra (if (and (equal id "PH1") (not indoor))
                        (sprint--int cfg "PH1_EXTENSION_WEEKS") 0))
             (weeks (+ (sprint--int cfg (concat id "_WEEKS")) extra)))
        (unless (and (nth 2 m) (not indoor))
          (push (list :id id :name (nth 1 m) :weeks weeks :kind (nth 3 m)
                      :subs (sprint--subphases cfg id extra))
                out))))
    (nreverse out)))

(defun sprint--weeks (cfg)
  "Week records for the whole season as plists.
Keys: :n :start :phase :pname :sub :sname :type :k :of :pk."
  (let ((abs (sprint--abs (sprint--get cfg "SEASON_START")))
        (n 0) weeks)
    (dolist (ph (sprint--phases cfg))
      (let ((target (plist-get ph :weeks)) cells)
        (if (plist-get ph :subs)
            (dolist (s (plist-get ph :subs))
              (dotimes (i (nth 2 s)) (push (list (nth 0 s) (nth 1 s) "LOAD" (1+ i) (nth 2 s)) cells))
              (dotimes (i (nth 3 s)) (push (list (nth 0 s) (nth 1 s) "DELOAD" (1+ i) (nth 3 s)) cells)))
          (dotimes (i target) (push (list nil nil (plist-get ph :kind) (1+ i) target) cells)))
        (setq cells (nreverse cells))
        ;; Pad or truncate so the phase has exactly its configured duration.
        (while (< (length cells) target)
          (let ((l (car (last cells)))) (setq cells (append cells (list (copy-sequence l))))))
        (setq cells (cl-subseq cells 0 target))
        (let ((pk 0))
          (dolist (c cells)
            (cl-incf n) (cl-incf pk)
            (push (list :n n :start abs :phase (plist-get ph :id) :pname (plist-get ph :name)
                        :sub (nth 0 c) :sname (nth 1 c) :type (nth 2 c)
                        :k (nth 3 c) :of (nth 4 c) :pk pk)
                  weeks)
            (cl-incf abs 7)))))
    (nreverse weeks)))

(defun sprint-context (&optional abs year)
  "Plist describing the training week containing ABS (default today)."
  (let* ((abs (or abs (sprint--today)))
         (weeks (sprint--weeks (sprint-config year)))
         (first (car weeks)) (last (car (last weeks))))
    (cond ((< abs (plist-get first :start)) (list :phase "PRE" :type "PRE"))
          ((>= abs (+ 7 (plist-get last :start))) (list :phase "POST" :type "POST"))
          (t (cl-find-if (lambda (w) (and (>= abs (plist-get w :start))
                                          (< abs (+ 7 (plist-get w :start)))))
                         weeks)))))

(defun sprint--phase-label (ctx)
  "Chat-style PHASE value: sub-phase id if any, else the phase id."
  (or (plist-get ctx :sub) (plist-get ctx :phase) "?"))

;;;; Weekly templates (parsed from the plan)

(defun sprint--parse-templates (plan cfg)
  "Parse the weekly tables of PLAN.  Return alist ((PHn . ((kind . rows) ...))).
ROWS are (day cns content) with macros expanded from CFG.  KIND is
default, race, train or taper (the 10-day taper table)."
  (let (phase label res)
    (with-temp-buffer
      (insert-file-contents plan)
      (goto-char (point-min))
      (while (not (eobp))
        (let ((line (buffer-substring-no-properties (line-beginning-position)
                                                    (line-end-position))))
          (cond
           ((string-match "^\\* PHASE \\([0-9]\\)" line)
            (setq phase (concat "PH" (match-string 1 line)) label nil)
            (forward-line 1))
           ((string-match "^\\*\\([^*\n]+\\)\\*[ \t]*$" line)
            (setq label (match-string 1 line))
            (forward-line 1))
           ((string-prefix-p "|" line)
            (let (rows)
              (while (and (not (eobp))
                          (string-prefix-p "|" (buffer-substring-no-properties
                                                (line-beginning-position)
                                                (line-end-position))))
                (let ((l (buffer-substring-no-properties (line-beginning-position)
                                                         (line-end-position))))
                  (unless (string-match-p "^|-" l)
                    (push (mapcar (lambda (c) (sprint--expand (string-trim c) cfg))
                                  (split-string (string-trim l "|" "|") "|"))
                          rows)))
                (forward-line 1))
              (setq rows (nreverse rows))
              (let ((head (car (car rows))))
                (when (and phase (member head '("Day" "Day before race")))
                  (let ((kind (cond ((equal head "Day before race") "taper")
                                    ((and label (string-match-p "Training" label)) "train")
                                    ((and label (string-match-p "Race" label)) "race")
                                    (t "default"))))
                    (push (cons kind (cdr rows)) (alist-get phase res nil nil #'equal)))))
              (setq label nil)))
           (t (forward-line 1))))))
    res))

(defun sprint--template (templates phase kind)
  (cdr (assoc kind (cdr (assoc phase templates)))))

(defconst sprint--battery
  '(("PH1_SP1" . "10m + CMJ + broad jump + back squat 3RM + trap bar DL 3RM + OH backward MB throw")
    ("PH1_SP2" . "10m + 30m + CMJ + broad jump + back squat 3RM + trap bar DL 3RM")
    ("PH2_SP1" . "10m + 30m + CMJ")
    ("PH5_SP1" . "10m + 30m + CMJ + broad jump + OH backward MB throw")
    ("PH6"     . "10m + 30m (monthly) + CMJ"))
  "Testing battery per sub-phase, from the plan's testing schedule.")

(defun sprint--races (cfg)
  "Alist (abs . label) of the race dates in CFG."
  (let (res)
    (dolist (k '(("INDOOR_TARGET_DATE" . "Indoor target meet")
                 ("OUTDOOR_SEASON_START" . "Outdoor season opener")
                 ("OUTDOOR_CHAMPIONSHIP" . "Outdoor championship")
                 ("SECONDARY_CHAMPIONSHIP" . "Secondary championship")))
      (let ((v (sprint--get cfg (car k))))
        (when (sprint--date-p v) (push (cons (sprint--abs v) (cdr k)) res))))
    (let ((extra (sprint--get cfg "EXTRA_RACE_DATES" "")) (pos 0))
      (while (string-match "[0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}" extra pos)
        (push (cons (sprint--abs (match-string 0 extra)) "Race") res)
        (setq pos (match-end 0))))
    (sort res (lambda (a b) (< (car a) (car b))))))

(defun sprint--champs (cfg)
  (delq nil (mapcar (lambda (k) (let ((v (sprint--get cfg k)))
                                  (and (sprint--date-p v) (sprint--abs v))))
                    '("OUTDOOR_CHAMPIONSHIP" "SECONDARY_CHAMPIONSHIP"))))

;;;; Schedule generation

(defun sprint--cns-tag (cns)
  (let ((c (downcase cns)))
    (cond ((string-match-p "\\`[a-z]+\\'" c) c)
          (t nil))))

(defun sprint--entry (abs cns content tags)
  (let ((tags (delete-dups (delq nil (append (list (sprint--cns-tag cns)) tags)))))
    (format "** TODO [%s] %s%s\nSCHEDULED: %s\n"
            cns content
            (if tags (concat " :" (mapconcat #'identity tags ":") ":") "")
            (sprint--ts abs))))

(defun sprint--week-text (w cfg templates races champs warnings)
  "Org text for week W.  Returns (text . warnings)."
  (let* ((start (plist-get w :start))
         (phase (plist-get w :phase))
         (type (plist-get w :type))
         (deload (equal type "DELOAD"))
         (week-races (cl-remove-if-not (lambda (r) (and (>= (car r) start) (< (car r) (+ start 7)))) races))
         (kind (cond ((and (equal phase "PH3") week-races) "race")
                     ((equal phase "PH3") "train")
                     (t "default")))
         (tbl-phase (if (equal phase "PH7") "PH6" phase))
         (rows (or (sprint--template templates tbl-phase kind)
                   (sprint--template templates tbl-phase "default")))
         (taper (sprint--template templates "PH7" "taper"))
         (entries nil))
    (when (and (equal kind "race") week-races)
      (let* ((race-dow (sprint--dow (car (car week-races))))
             (row (cl-find-if (lambda (r) (string-match-p "RACE DAY" (nth 2 r))) rows))
             (row-dow (and row (cdr (assoc (car row) sprint--dow-codes)))))
        (when (and row-dow (/= race-dow row-dow))
          (push (format "Week %d: race on %s but the Phase 3 race-week template puts RACE DAY on %s"
                        (plist-get w :n) (aref sprint--dow-names race-dow) (car row))
                warnings))))
    (dotimes (i 7)
      (let* ((abs (+ start i))
             (dow (sprint--dow abs))
             (champ (cl-find-if (lambda (c) (and (<= (- c 9) abs) (<= abs c))) champs))
             (race (assoc abs races)))
        (cond
         (champ
          (let ((row (cl-find-if (lambda (r) (equal (car r) (format "Day %d" (1+ (- champ abs)))))
                                 taper)))
            (when row
              (push (sprint--entry abs (if (equal (nth 1 row) "—") "—" (nth 1 row))
                                   (format "TAPER %s — %s" (car row) (nth 2 row))
                                   '("taper"))
                    entries))))
         (t
          (let ((row (cl-find-if (lambda (r) (eq (cdr (assoc (car r) sprint--dow-codes)) dow)) rows)))
            (when (and row (not (equal (nth 1 row) "Rest")))
              (push (sprint--entry abs (nth 1 row)
                                   (concat (if deload "DELOAD −50% volume: " "") (nth 2 row))
                                   (delq nil (list (and deload "deload")
                                                   (and race "race"))))
                    entries)))))
        (when (and race (not (and champ (= champ abs))) (not (equal kind "race")))
          (push (sprint--entry abs "—" (format "RACE — %s" (cdr race)) '("race")) entries))))
    ;; Testing battery on deload weeks, monthly in Phase 6.
    (let ((battery (or (and deload (cdr (assoc (or (plist-get w :sub) phase) sprint--battery)))
                       (and (equal phase "PH6") (= 1 (mod (plist-get w :pk) 4))
                            (cdr (assoc "PH6" sprint--battery))))))
      (when (and battery (not (member phase '("PH7"))))
        (let ((day (+ start (mod (+ (cdr (assoc sprint-test-weekday sprint--dow-codes)) 6) 7))))
          (push (sprint--entry day "Test" (concat "TESTING BATTERY — " battery) '("test")) entries))))
    (cons
     (concat
      (format "* Week %02d · %s · %s%s\n:PROPERTIES:\n:START: %s\n:WEEK: %d\n:PHASE: %s\n:SUBPHASE: %s\n:WEEKTYPE: %s\n:END:\n"
              (plist-get w :n) phase
              (or (plist-get w :sname) (plist-get w :pname))
              (if (plist-get w :sub) (format " · %s %d/%d" type (plist-get w :k) (plist-get w :of))
                (format " · %s" type))
              (sprint--str start) (plist-get w :n) phase (or (plist-get w :sub) "-") type)
      (if (and (null entries) (member type '("TRANSITION")))
          "Transition week: no structured sessions. Follow the category distribution in the plan.\n"
        "")
      (mapconcat #'identity (nreverse entries) ""))
     warnings)))

(defun sprint--week-start-of-chunk (chunk)
  (when (string-match ":START: \\([0-9-]+\\)" chunk) (sprint--abs (match-string 1 chunk))))

;;;###autoload
(defun sprint-generate-schedule (&optional year)
  "Generate the schedule file for YEAR from its config and plan.
Weeks before the current week are kept as they are (so DONE/SKIPPED
states survive); the current week onward is regenerated."
  (interactive)
  (let* ((cfg (sprint-config year))
         (plan (sprint-file 'plan year))
         (out (sprint-file 'schedule year))
         (templates (sprint--parse-templates plan cfg))
         (weeks (sprint--weeks cfg))
         (races (sprint--races cfg)) (champs (sprint--champs cfg))
         (today (sprint--today))
         (cutoff (- today (mod (+ (sprint--dow today) 6) 7)))
         (old (when (file-exists-p out)
                (with-temp-buffer
                  (insert-file-contents out)
                  (let ((s (buffer-string)) chunks)
                    (dolist (c (cdr (split-string s "^\\* Week " t)))
                      (push (concat "* Week " c) chunks))
                    (nreverse chunks)))))
         (kept (cl-remove-if-not (lambda (c) (let ((s (sprint--week-start-of-chunk c)))
                                               (and s (< s cutoff))))
                                 old))
         (kept-n (length kept))
         (warnings nil) (texts nil))
    (dolist (w weeks)
      (when (>= (plist-get w :start) cutoff)
        (let ((r (sprint--week-text w cfg templates races champs warnings)))
          (push (car r) texts) (setq warnings (cdr r)))))
    (dolist (c (sprint--validate-dates cfg weeks))
      (push c warnings))
    (with-temp-file out
      (insert (format "#+TITLE: Sprint Schedule %d (generated)\n" (or year (sprint-season)))
              "#+SEQ_TODO: TODO(t) NEXT(n) | DONE(d) SKIPPED(s)\n#+STARTUP: overview\n"
              "# Generated by sprint-generate-schedule from the config + plan.\n"
              "# Mark sessions DONE or SKIPPED here; weeks before the current one are kept on regeneration.\n")
      (dolist (w (delete-dups (reverse warnings)))
        (insert "# WARNING: " w "\n"))
      (insert "\n")
      (dolist (c kept) (insert (string-trim-right c) "\n"))
      (dolist (tx (nreverse texts)) (insert tx)))
    (message "Sprint schedule: %d weeks (%d kept, %d generated) → %s"
             (length weeks) kept-n (- (length weeks) kept-n) out)
    out))

;;;; Validation

(defun sprint--validate-dates (cfg weeks)
  "Messages about race dates and the season start vs the phase calendar."
  (let (msgs)
    (unless (sprint--date-p (sprint--get cfg "SEASON_START"))
      (push "SEASON_START is missing or not YYYY-MM-DD" msgs))
    (when (and weeks (/= 1 (sprint--dow (plist-get (car weeks) :start))))
      (push "SEASON_START is not a Monday" msgs))
    (dolist (spec '(("INDOOR_TARGET_DATE" "PH3") ("OUTDOOR_SEASON_START" "PH5" "PH6")
                    ("OUTDOOR_CHAMPIONSHIP" "PH7") ("SECONDARY_CHAMPIONSHIP" "PH7" "PH6")))
      (let ((v (sprint--get cfg (car spec))))
        (when (and (sprint--date-p v) weeks
                   (or (sprint--indoor-p cfg) (not (equal (car spec) "INDOOR_TARGET_DATE"))))
          (let* ((abs (sprint--abs v))
                 (w (cl-find-if (lambda (w) (and (>= abs (plist-get w :start))
                                                 (< abs (+ 7 (plist-get w :start)))))
                                weeks)))
            (cond ((null w)
                   (push (format "%s (%s) is outside the %d-week calendar" (car spec) v (length weeks)) msgs))
                  ((not (member (plist-get w :phase) (cdr spec)))
                   (push (format "%s (%s) falls in %s, expected %s" (car spec) v
                                 (plist-get w :phase) (mapconcat #'identity (cdr spec) "/"))
                         msgs)))))))
    (nreverse msgs)))

;;;###autoload
(defun sprint-validate (&optional year)
  "Check config, plan and exercise DB for YEAR.  Return the message list."
  (interactive)
  (let* ((cfg (sprint-config year)) (msgs nil)
         (weeks (ignore-errors (sprint--weeks cfg))))
    ;; 1. macros used by the plan but undefined
    (with-temp-buffer
      (insert-file-contents (sprint-file 'plan year))
      (let (missing)
        (while (re-search-forward "{{{\\([A-Za-z0-9_]+\\)}}}" nil t)
          (unless (assoc (match-string 1) cfg) (cl-pushnew (match-string 1) missing :test #'equal)))
        (dolist (m (nreverse missing)) (push (format "plan uses undefined macro %s" m) msgs))))
    ;; 2. category weights sum to 100
    (dolist (m sprint--phase-meta)
      (let ((sum 0) (n 0))
        (dolist (c cfg)
          (when (string-prefix-p (concat (car m) "_W_") (car c))
            (cl-incf n) (cl-incf sum (string-to-number (cdr c)))))
        (when (and (> n 0) (/= sum 100))
          (push (format "%s category weights sum to %d (expected 100)" (car m) sum) msgs))))
    ;; 3. sub-phase weeks vs phase weeks
    (dolist (ph (sprint--phases cfg))
      (when (plist-get ph :subs)
        (let ((sum (apply #'+ (mapcar (lambda (s) (+ (nth 2 s) (nth 3 s))) (plist-get ph :subs)))))
          (unless (= sum (plist-get ph :weeks))
            (push (format "%s sub-phases total %d weeks but the phase has %d" (plist-get ph :id)
                          sum (plist-get ph :weeks))
                  msgs)))))
    ;; 4. dates
    (setq msgs (append (reverse (sprint--validate-dates cfg weeks)) msgs))
    (when weeks
      (push (format "INFO: %d training weeks, %s → %s" (length weeks)
                    (sprint--str (plist-get (car weeks) :start))
                    (sprint--str (+ 6 (plist-get (car (last weeks)) :start))))
            msgs))
    ;; 5. exercise DB categories
    (when (file-exists-p sprint-db-file)
      (let ((known '("Technical Drills" "Warm-Up & Activation" "Acceleration" "Max Velocity"
                     "Speed Endurance" "Special Endurance I" "Special Endurance II"
                     "Extensive Tempo" "Intensive Tempo" "Plyometrics" "Strength — Max Force"
                     "Strength — Eccentric" "Strength-Power" "Resisted Sprinting"
                     "Assisted / Overspeed" "Medicine Ball Power" "Isometrics" "Core & Trunk"
                     "Mobility & Flexibility" "Recovery & Regeneration"))
            (seen nil) (count 0))
        (with-temp-buffer
          (insert-file-contents sprint-db-file)
          (while (re-search-forward "^:CATEGORY:[ \t]+\\(.*?\\)[ \t]*$" nil t)
            (cl-incf count) (cl-pushnew (match-string 1) seen :test #'equal)))
        (dolist (s seen)
          (unless (member s known) (push (format "DB: unknown category %S" s) msgs)))
        (dolist (k known)
          (unless (member k seen) (push (format "DB: category %S has no exercises" k) msgs)))
        (push (format "INFO: DB has %d exercises in %d categories" count (length seen)) msgs)))
    (setq msgs (nreverse msgs))
    (when (called-interactively-p 'any)
      (with-current-buffer (get-buffer-create "*sprint-validation*")
        (erase-buffer)
        (insert (mapconcat #'identity (or msgs '("OK")) "\n") "\n")
        (display-buffer (current-buffer))))
    msgs))

;;;; Readiness

(defun sprint--baseline (cfg)
  (float (sprint--int cfg "CMJ_BASELINE" (sprint--int cfg "PREV_CMJ_BASELINE" 1))))

(defun sprint-readiness (cmj-pct last-rpe soreness cfg)
  "Return (STATUS . ADVICE) from CMJ percentage, previous RPE and SORENESS."
  (let* ((rank 0) (why nil))
    (cond ((null cmj-pct))
          ((>= cmj-pct (sprint--int cfg "READY_GREEN_CMJ" 97)))
          ((>= cmj-pct (sprint--int cfg "READY_YELLOW_CMJ" 90)) (setq rank 1 why "CMJ"))
          (t (setq rank 2 why "CMJ")))
    (when last-rpe
      (let ((r (cond ((<= last-rpe (sprint--int cfg "READY_GREEN_RPE" 7)) 0)
                     ((<= last-rpe (sprint--int cfg "READY_YELLOW_RPE" 8)) 1)
                     (t 2))))
        (when (> r rank) (setq rank r why "RPE"))))
    (when (equal soreness "acute") (setq rank 2 why "soreness"))
    (cons (nth rank '("Green" "Yellow" "Red"))
          (pcase rank
            (0 "Full program as planned.")
            (1 (format "Yellow (%s): drop Very High CNS work, cut plyometric contacts by 30%%." why))
            (_ (if (equal why "soreness")
                   "Acute soreness: downgrade to a Low-CNS day."
                 (format "Red (%s): Low-CNS day only (Extensive Tempo + Recovery + Mobility)." why)))))))

(defun sprint--entries-before (pos props)
  "Values of PROPS (list) for entries before POS in the (widened) buffer."
  (save-restriction
    (widen)
    (delq nil (org-map-entries
               (lambda ()
                 (when (< (point) pos)
                   (mapcar (lambda (p) (org-entry-get nil p)) props)))
               nil nil))))

;;;; Capture

(defun sprint--log-file () (sprint-file 'log))

(defun sprint--ctx-field (field)
  (let ((v (plist-get (sprint-context) field)))
    (cond ((null v) "-") ((numberp v) (number-to-string v)) (t v))))

(defun sprint--phase-id () (sprint--phase-label (sprint-context)))

(defun sprint--planned-today ()
  "Planned sessions for today, from the schedule file."
  (let ((file (sprint-file 'schedule)) (day (sprint--str (sprint--today))) res)
    (if (not (file-exists-p file)) "no schedule generated yet"
      (with-temp-buffer
        (insert-file-contents file)
        (while (re-search-forward (format "^SCHEDULED: <%s " day) nil t)
          (save-excursion
            (forward-line -1)
            (when (looking-at "\\*+ \\(?:TODO\\|NEXT\\|DONE\\|SKIPPED\\) \\(.*?\\)\\(?:[ \t]+:[[:alnum:]_@#%:]+:\\)?[ \t]*$")
              (push (match-string 1) res)))))
      (if res (mapconcat #'identity (nreverse res) "\n         ") "nothing scheduled"))))

(defun sprint--capture-templates ()
  `(("S" "Sprint training")
    ("Ss" "Sprint session log" entry (file+olp+datetree sprint--log-file)
     ,(concat "* Session %<%H:%M>\n:PROPERTIES:\n"
              ":WEEK: %(sprint--ctx-field :n)\n"
              ":PHASE: %(sprint--phase-id)\n"
              ":WEEKTYPE: %(sprint--ctx-field :type)\n"
              ":CMJ: %^{CMJ height (cm)}\n"
              ":RPE: %^{Session RPE (1-10)|7|1|2|3|4|5|6|7|8|9|10}\n"
              ":SORENESS: %^{Soreness|none|mild|acute}\n"
              ":DURATION_MIN: %^{Session duration (min)}\n:END:\n"
              "Planned: %(sprint--planned-today)\n\n%?")
     :empty-lines 1)
    ("St" "Test result" entry (file+headline sprint--log-file "Testing Battery")
     ,(concat "* Test %T\n:PROPERTIES:\n"
              ":PHASE: %(sprint--phase-id)\n"
              ":10M: %^{10m fly time (s)}\n:30M: %^{30m fly time (s)}\n"
              ":CMJ: %^{CMJ (cm)}\n:BROAD_JUMP: %^{Broad jump (m)}\n"
              ":MB_THROW: %^{OH backward MB throw (m)}\n"
              ":SQUAT_3RM: %^{Squat 3RM (kg)}\n:TBDL_3RM: %^{Trap bar DL 3RM (kg)}\n"
              ":PCLEAN_1RM: %^{Power clean 1RM (kg)}\n:END:\n%?")
     :empty-lines 1)
    ("Sr" "Race result" entry (file+headline sprint--log-file "Races")
     ,(concat "* Race %T\n:PROPERTIES:\n"
              ":PHASE: %(sprint--phase-id)\n"
              ":MEET: %^{Meet}\n:EVENT: %^{Event|100m|60m|200m|4x100m}\n"
              ":ROUND: %^{Round|Final|Heat|Semi|Time trial}\n"
              ":TIME: %^{Time (s)}\n:WIND: %^{Wind (m/s, blank if none)}\n"
              ":PLACE: %^{Place}\n:END:\n%?")
     :empty-lines 1)))

(defun sprint--ensure-templates (&rest _)
  "Install the Sprint capture templates (idempotent, survives later `setq's)."
  (unless (assoc "Ss" org-capture-templates)
    (setq org-capture-templates
          (append (cl-remove-if (lambda (e) (string-prefix-p "S" (car e))) org-capture-templates)
                  (sprint--capture-templates)))))

(defun sprint--drop-empty-properties ()
  (dolist (p (org-entry-properties nil 'standard))
    (when (string-empty-p (string-trim (cdr p))) (org-entry-delete nil (car p)))))

(defun sprint--num (s) (and s (string-match-p "\\`[0-9.]+\\'" s) (string-to-number s)))

(defun sprint--finalize-session ()
  "Compute CMJ%, readiness and overreach flag for a session capture."
  (goto-char (point-min)) (org-back-to-heading t)
  (let* ((cfg (sprint-config))
         (cmj (sprint--num (org-entry-get nil "CMJ")))
         (pct (and cmj (/ (* 100.0 cmj) (sprint--baseline cfg))))
         (prev (sprint--entries-before (point) '("RPE" "CMJ_PCT")))
         (last-rpe (sprint--num (car (car (last prev)))))
         (prev-pct (delq nil (mapcar (lambda (p) (sprint--num (cadr p))) prev)))
         (res (sprint-readiness pct last-rpe (org-entry-get nil "SORENESS") cfg))
         (limit (sprint--int cfg "READY_OVERREACH_CMJ" 85))
         (over (and pct (< pct limit) (>= (length prev-pct) 2)
                    (cl-every (lambda (p) (< p limit)) (last prev-pct 2)))))
    (sprint--drop-empty-properties)
    (when pct (org-set-property "CMJ_PCT" (format "%.1f" pct)))
    (org-set-property "READINESS" (if pct (car res) "Unknown"))
    (org-set-property "ADVICE" (cdr res))
    (when over
      (org-set-property "OVERREACH" "yes")
      (message "CMJ < %d%% for 3 sessions in a row: insert an unplanned deload week" limit))
    (unless over (message "Readiness: %s — %s" (car res) (cdr res)))))

(defun sprint--finalize-race ()
  (goto-char (point-min)) (org-back-to-heading t)
  (let ((wind (sprint--num (replace-regexp-in-string "\\`+" "" (or (org-entry-get nil "WIND") "")))))
    (sprint--drop-empty-properties)
    (org-set-property "LEGAL" (if (and wind (> wind 2.0)) "no" "yes"))))

(defun sprint--prepare-finalize ()
  (pcase (org-capture-get :key)
    ("Ss" (sprint--finalize-session))
    ("St" (goto-char (point-min)) (org-back-to-heading t) (sprint--drop-empty-properties))
    ("Sr" (sprint--finalize-race))))

(add-hook 'org-capture-prepare-finalize-hook #'sprint--prepare-finalize)
(advice-add 'org-capture :before #'sprint--ensure-templates)
(sprint--ensure-templates)

;;;; Today, agenda

;;;###autoload
(defun sprint-today-info ()
  "Show where today falls in the plan and what is scheduled."
  (interactive)
  (let ((ctx (sprint-context)))
    (message "%s | week %s | %s\nPlanned: %s"
             (sprint--phase-id) (or (plist-get ctx :n) "-") (or (plist-get ctx :type) "-")
             (sprint--planned-today))))

;;;###autoload
(defun sprint-agenda ()
  "Agenda for the sprint schedule only."
  (interactive)
  (let ((org-agenda-files (list (sprint-file 'schedule))))
    (org-agenda-list)))

;;;; Season summary and rollover

(defun sprint--log-stats (log)
  "Best values of the season from LOG as an alist."
  (let (t10 t30 cmjs squat tbdl pclean races)
    (with-temp-buffer
      (insert-file-contents log)
      (delay-mode-hooks (org-mode))
      (org-map-entries
       (lambda ()
         (let ((top (car (org-get-outline-path))) (n #'sprint--num))
           (cond
            ((equal top "Testing Battery")
             (let ((g (lambda (p) (funcall n (org-entry-get nil p)))))
               (when (funcall g "10M") (push (funcall g "10M") t10))
               (when (funcall g "30M") (push (funcall g "30M") t30))
               (when (funcall g "CMJ") (push (funcall g "CMJ") cmjs))
               (when (funcall g "SQUAT_3RM") (push (funcall g "SQUAT_3RM") squat))
               (when (funcall g "TBDL_3RM") (push (funcall g "TBDL_3RM") tbdl))
               (when (funcall g "PCLEAN_1RM") (push (funcall g "PCLEAN_1RM") pclean))))
            ((equal top "Races")
             (let ((time (funcall n (org-entry-get nil "TIME"))))
               (when (and time (equal (org-entry-get nil "EVENT") "100m")
                          (equal (org-entry-get nil "LEGAL") "yes"))
                 (push time races)))))))
       nil nil))
    (let ((top (lambda (l k) (let ((s (sort (copy-sequence l) #'>))) (cl-subseq s 0 (min k (length s)))))))
      (delq nil
            (list (and t10 (cons "PREV_10M_PB" (format "%.2f" (apply #'min t10))))
                  (and t30 (cons "PREV_30M_PB" (format "%.2f" (apply #'min t30))))
                  (and races (cons "PREV_100M_PB" (format "%.2f" (apply #'min races))))
                  (and cmjs (let ((tp (funcall top cmjs 3)))
                              (cons "PREV_CMJ_BASELINE"
                                    (format "%.0f" (/ (apply #'+ tp) (float (length tp)))))))
                  ;; Brzycki 3RM → 1RM estimate: w * 36 / (37 - 3)
                  (and squat (cons "PREV_SQUAT_1RM" (format "%.0f" (* (apply #'max squat) (/ 36.0 34)))))
                  (and tbdl (cons "PREV_TBDL_1RM" (format "%.0f" (* (apply #'max tbdl) (/ 36.0 34)))))
                  (and pclean (cons "PREV_PCLEAN_1RM" (format "%.0f" (apply #'max pclean)))))))))

;;;###autoload
(defun sprint-season-summary (&optional year)
  "Show the season's best values as PREV_ macro lines for next year's config."
  (interactive)
  (let ((stats (sprint--log-stats (sprint-file 'log year))))
    (with-current-buffer (get-buffer-create "*sprint-season-summary*")
      (erase-buffer)
      (insert "# Best values of the season (copy into next season's config, or run sprint-new-season)\n"
              "# 3RM → 1RM uses Brzycki; CMJ baseline = mean of the 3 best test CMJs.\n")
      (dolist (s stats) (insert (format "#+MACRO: %s %s\n" (car s) (cdr s))))
      (unless stats (insert "# (no test or race data in the log yet)\n"))
      (org-mode) (display-buffer (current-buffer)))
    stats))

(defun sprint--set-macro (name value)
  "Set the #+MACRO NAME line in the current buffer to VALUE (keeps trailing comments off)."
  (goto-char (point-min))
  (if (re-search-forward (format "^#\\+MACRO:[ \t]+%s[ \t]+.*$" (regexp-quote name)) nil t)
      (replace-match (format "#+MACRO: %-22s %s" name value) t t)
    (user-error "Macro %s not found" name)))

;;;###autoload
(defun sprint-new-season ()
  "Create the files for the season after the current one.
The config is copied, SEASON_YEAR/SEASON_START advance, the competition
dates move forward 52 weeks (and are flagged for review), the PREV_ values
come from the log, and the plan's #+SETUPFILE points to the new config."
  (interactive)
  (let* ((y (sprint-season)) (ny (1+ y))
         (cfg (sprint-config y))
         (stats (ignore-errors (sprint--log-stats (sprint-file 'log y)))))
    (dolist (k '(config plan log))
      (when (file-exists-p (sprint-file k ny))
        (user-error "%s already exists" (sprint-file k ny))))
    ;; config
    (with-temp-buffer
      (insert-file-contents (sprint-file 'config y))
      (sprint--set-macro "SEASON_YEAR" (number-to-string ny))
      (sprint--set-macro "SEASON_START"
                         (sprint--str (+ 364 (sprint--abs (sprint--get cfg "SEASON_START")))))
      (dolist (k '("INDOOR_TARGET_DATE" "OUTDOOR_SEASON_START" "OUTDOOR_CHAMPIONSHIP"
                   "SECONDARY_CHAMPIONSHIP"))
        (when (sprint--date-p (sprint--get cfg k))
          (sprint--set-macro k (sprint--str (+ 364 (sprint--abs (sprint--get cfg k)))))))
      (goto-char (point-min))
      (when (re-search-forward "^#\\+MACRO:[ \t]+INDOOR_TARGET_DATE" nil t)
        (beginning-of-line)
        (insert "# !! Competition dates below were moved forward 52 weeks automatically: replace them with the real calendar.\n"))
      (dolist (s stats) (sprint--set-macro (car s) (cdr s)))
      (dolist (p '("PH1" "PH2" "PH5"))
        (sprint--set-macro (concat "PREV_" p "_WEEKS") (sprint--get cfg (concat p "_WEEKS"))))
      (when (assoc "PREV_CMJ_BASELINE" stats)
        (sprint--set-macro "CMJ_BASELINE" (cdr (assoc "PREV_CMJ_BASELINE" stats))))
      (write-region (point-min) (point-max) (sprint-file 'config ny)))
    ;; plan
    (with-temp-buffer
      (insert-file-contents (sprint-file 'plan y))
      (goto-char (point-min))
      (unless (re-search-forward "^#\\+SETUPFILE:.*$" nil t) (user-error "No #+SETUPFILE in plan"))
      (replace-match (format "#+SETUPFILE: sprint_config_%d.org" ny) t t)
      (write-region (point-min) (point-max) (sprint-file 'plan ny)))
    ;; log
    (with-temp-file (sprint-file 'log ny)
      (insert (sprint--log-skeleton ny)))
    (message "Season %d created (%s). Review the config, then run sprint-generate-schedule."
             ny (if stats (format "%d PREV_ values taken from the %d log" (length stats) y)
                  "no log data: PREV_ values copied unchanged"))
    (sprint-file 'config ny)))

(defun sprint--log-skeleton (year)
  (format "#+TITLE: Sprint Log %d\n#+STARTUP: overview\n#+TODO: TODO | DONE\n\n* Testing Battery\n* Races\n" year))

;;;; Keys

(defvar sprint-map
  (let ((m (make-sparse-keymap)))
    (define-key m "g" #'sprint-generate-schedule)
    (define-key m "v" #'sprint-validate)
    (define-key m "i" #'sprint-today-info)
    (define-key m "a" #'sprint-agenda)
    (define-key m "s" (lambda () (interactive) (org-capture nil "Ss")))
    (define-key m "t" (lambda () (interactive) (org-capture nil "St")))
    (define-key m "r" (lambda () (interactive) (org-capture nil "Sr")))
    (define-key m "y" #'sprint-season-summary)
    (define-key m "n" #'sprint-new-season)
    m)
  "Keymap for the sprint commands.")

(when (boundp 'glz/org-map)
  (define-key glz/org-map "S" sprint-map))

(provide 'sprint)
;;; sprint.el ends here
