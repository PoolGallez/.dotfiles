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
;;   l `sprint-lock-week'          keep a hand-edited week on regeneration
;;   x/X `sprint-reroll-session', `sprint-reroll-week'   redraw exercises under the same rules
;;   w `sprint-swap-exercise'     replace one exercise by another of its category
;;   o `sprint-override'          change volume, loads, targets, deload or F-V focus for chosen weeks
;;   L `sprint-log'               log a day exercise by exercise (times, kg×reps, status)
;;   R `sprint-report', c `sprint-export-csv'   plan vs actual; one CSV row per exercise
;;   F `sprint-fatigue', W `sprint-review-week', A `sprint-apply'   fatigue, proposals, overrides
;;   N `sprint-wizard'            guided setup of a season
;;
;; Generation also picks exercises from the DB per session (see "Exercise
;; selection and load progression") and interpolates the weekly lift loads.
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
  (expand-file-name (if (boundp 'glz/org-sprint-directory) glz/org-sprint-directory
                      "~/PKDB/Athletics/Sprint/"))
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

(defcustom sprint-log-style 'form
  "How `sprint-log' asks for the results.
form: a buffer listing every exercise with a result line to fill in (good on a
phone); prompts: one minibuffer question per exercise."
  :type '(choice (const form) (const prompts)))

(defcustom sprint-weight-file
  (expand-file-name "Health.org" (if (boundp 'glz/org-directory) glz/org-directory "~/PKDB/"))
  "File whose \"Weight\" section holds the body-weight table (| Date | kg | Note |).
It belongs to general health tracking; sprint.el only reads it for the reports."
  :type 'file)

(defvar sprint-today nil
  "Override for today's date as YYYY-MM-DD (testing only).")

;;;; Files and config

(defun sprint-season ()
  "Return the season year to work on.
Unless `sprint-season-year' is set: the latest season whose SEASON_START is at
most 21 days away (so next year's files, once created, do not take over until
the new season is about to begin); if none qualifies, the earliest season."
  (or sprint-season-year
      (let (seasons)
        (dolist (f (directory-files sprint-directory))
          (when (string-match "\\`sprint_config_\\([0-9]+\\)\\.org\\'" f)
            (let* ((y (string-to-number (match-string 1 f)))
                   (start (cdr (assoc "SEASON_START"
                                      (sprint--read-macros (expand-file-name f sprint-directory))))))
              (push (cons y (and (sprint--date-p start) (sprint--abs start))) seasons))))
        (unless seasons (user-error "No sprint_config_YYYY.org in %s" sprint-directory))
        (setq seasons (sort seasons (lambda (a b) (< (car a) (car b)))))
        (let ((limit (+ (sprint--today) 21)))
          (or (car (car (last (cl-remove-if-not (lambda (s) (and (cdr s) (<= (cdr s) limit))) seasons))))
              (car (car seasons)))))))

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

;;;; Exercise selection and load progression
;;
;; Turns the category prose of the weekly templates into concrete exercises from
;; TrainingDB.org and puts the week's number on the lifts.  The result is a
;; starting point: edit the generated list, and add ":LOCKED: yes" to the week
;; (see `sprint-lock-week') so regeneration leaves it alone.

(defcustom sprint-fill-sessions t
  "Non-nil: `sprint-generate-schedule' lists exercises under each session."
  :type 'boolean)

(defcustom sprint-exercises-per-category
  '(("Technical Drills" . 3) ("Warm-Up & Activation" . 2) ("Mobility & Flexibility" . 2)
    ("Core & Trunk" . 2) ("Acceleration" . 2) ("Plyometrics" . 2))
  "Number of exercises picked per category and session (default: see below)."
  :type '(alist :key-type string :value-type integer))

(defcustom sprint-default-exercises-per-category 1
  "Exercises per category and session when not in `sprint-exercises-per-category'."
  :type 'integer)

(defcustom sprint-unavailable-equipment nil
  "Exercises whose EQUIPMENT matches one of these regexps are never picked."
  :type '(repeat string))

(defcustom sprint-swap-after 2
  "The weekly review proposes a SWAP once an exercise was replaced by the same one this often."
  :type 'integer)

(defcustom sprint-swap-window-weeks 3
  "Weeks (ending with the reviewed one) in which replacements are counted for `sprint-swap-after'."
  :type 'integer)

(defcustom sprint-warmup-on-high-days t
  "Non-nil: add Warm-Up & Activation to High-CNS sessions that do not name it."
  :type 'boolean)

(defcustom sprint-show-execution t
  "Non-nil: put each exercise's EXECUTION (TrainingDB.org) on a \"How:\" line under it
in the schedule, and in the shared HTML."
  :type 'boolean)

(defvar sprint--all-weeks nil "Week records of the season being generated.")
(defvar sprint--usage nil "Hash name -> (count . last-week) while generating.")
(defvar sprint--streak nil "Hash name -> (first-week . last-week) of the current run of consecutive weeks.")
(defvar sprint--db nil "Parsed exercise DB while generating.")

(defun sprint--parse-db ()
  "Exercises of `sprint-db-file' as plists."
  (when (file-exists-p sprint-db-file)
    (with-temp-buffer
      (insert-file-contents sprint-db-file)
      (let (res)
        (while (re-search-forward "^\\*\\* \\(.+?\\)[ \t]*$" nil t)
          (let ((name (match-string 1))
                (end (or (save-excursion (and (re-search-forward "^\\*+ " nil t) (match-beginning 0)))
                         (point-max)))
                props)
            (while (re-search-forward "^:\\([A-Z_]+\\):[ \t]+\\(.*?\\)[ \t]*$" end t)
              (push (cons (match-string 1) (match-string 2)) props))
            (when (assoc "CATEGORY" props)
              (push (list :name name
                          :cat (cdr (assoc "CATEGORY" props))
                          :sub (cdr (assoc "SUBCATEGORY" props))
                          :cns (or (cdr (assoc "CNS_DEMAND" props)) "")
                          :equip (or (cdr (assoc "EQUIPMENT" props)) "")
                          :fv (or (cdr (assoc "FV_BIAS" props)) "neutral")
                          :flags (let ((f (cdr (assoc "FLAGS" props))))
                                   (and f (not (equal f "none")) (split-string f)))
                          :unit (cdr (assoc "VOLUME_UNIT" props))
                          :vol (cdr (assoc "TYPICAL_VOLUME" props))
                          :next (cdr (assoc "PROGRESSION" props))
                          :how (cdr (assoc "EXECUTION" props)))
                    res))))
        (nreverse res)))))

(defun sprint--db ()
  (or sprint--db (setq sprint--db (sprint--parse-db))))

(defun sprint--cns-rank (s)
  (pcase (downcase (string-trim s))
    ("very low" 0) ("low" 1) ("low-medium" 1.5) ("medium" 2)
    ("medium-high" 3) ("high" 4) ("very high" 5) (_ 0)))

(defun sprint--cns-cap (day-cns)
  (pcase (downcase day-cns) ("low" 2) ("medium" 4) (_ 5)))

(defconst sprint--category-keywords
  '(("Warm-?Up"                                    . "Warm-Up & Activation")
    ("Technical Drills"                            . "Technical Drills")
    ("Acceleration\\|Block starts"                 . "Acceleration")
    ("Max Velocity\\|Flying"                       . "Max Velocity")
    ("Speed Endurance"                             . "Speed Endurance")
    ("Special Endurance II"                        . "Special Endurance II")
    ("Special Endurance I\\([^I]\\|$\\)"           . "Special Endurance I")
    ("Extensive Tempo"                             . "Extensive Tempo")
    ("Intensive Tempo"                             . "Intensive Tempo")
    ("Plyo"                                        . "Plyometrics")
    ("Max Force"                                   . "Strength — Max Force")
    ("Eccentric"                                   . "Strength — Eccentric")
    ("Strength-Power\\|Power clean\\|Trap Bar Jumps\\|Jump Squat" . "Strength-Power")
    ("Resisted\\|[Ss]led\\|Contrast"               . "Resisted Sprinting")
    ("Overspeed\\|Assisted\\|Downhill"             . "Assisted / Overspeed")
    ("Med\\(icine\\)? ?[Bb]all"                    . "Medicine Ball Power")
    ("Isometric"                                   . "Isometrics")
    ("Core"                                        . "Core & Trunk")
    ("Mobility"                                    . "Mobility & Flexibility")
    ("Recovery"                                    . "Recovery & Regeneration"))
  "Regexps over a session description and the DB category each one names.")

(defun sprint--content-categories (content)
  "DB categories named in CONTENT, in order of appearance."
  (let ((case-fold-search t) found)
    (dolist (k sprint--category-keywords)
      (when (string-match (car k) content)
        (push (cons (match-beginning 0) (cdr k)) found)))
    ;; a bare "Strength" names no sub-category: default to max force
    (when (and (string-match-p "\\bStrength\\b" content)
               (not (cl-find-if (lambda (f) (string-prefix-p "Strength" (cdr f))) found)))
      (push (cons (string-match "\\bStrength\\b" content) "Strength — Max Force") found))
    (mapcar #'cdr (sort found (lambda (a b) (< (car a) (car b)))))))

;; Load progression

(defun sprint--scopes (w)
  "Config scopes of week W, most specific first."
  (let ((ph (plist-get w :phase)))
    (delq nil (list (plist-get w :sub) ph (and (member ph '("PH3" "PH6" "PH7")) "COMP")))))

(defun sprint--arc-frac (w scope)
  "Position (0..1) of week W along the load weeks of SCOPE."
  (let* ((sub (string-match-p "_SP" scope))
         (ws (cl-remove-if-not
              (lambda (x) (and (equal (plist-get x :phase) (plist-get w :phase))
                               (or (not sub) (equal (plist-get x :sub) scope))
                               (not (equal (plist-get x :type) "DELOAD"))
                               (<= (plist-get x :n) (plist-get w :n))))
              sprint--all-weeks))
         (total (cl-count-if
                 (lambda (x) (and (equal (plist-get x :phase) (plist-get w :phase))
                                  (or (not sub) (equal (plist-get x :sub) scope))
                                  (not (equal (plist-get x :type) "DELOAD"))))
                 sprint--all-weeks)))
    (if (> total 1) (/ (float (max 0 (1- (length ws)))) (1- total)) 0.0)))

(defun sprint--num-of (s) (and s (string-match "-?[0-9.]+" s) (string-to-number (match-string 0 s))))

(defun sprint--find (cfg key w)
  "Scope of the first config entry KEY_<scope>_SETS (or _VOL-like KEY_<scope>) for W."
  (cl-find-if (lambda (s) (or (sprint--get cfg (format "%s_%s_SETS" key s))
                              (sprint--get cfg (format "%s_%s" key s))
                              (sprint--get cfg (format "%s_%s_MAX" key s))))
              (sprint--scopes w)))

(defconst sprint--lift-keys
  '(("\\`Back Squat" . "SQUAT") ("\\`Trap Bar Deadlift" . "TBDL")
    ("\\`Power Clean" . "PCLEAN") ("Nordic" . "NORDIC")))

(defun sprint--lift-prescription (e w cfg deload)
  "Sets × reps @ load for exercise E in week W from the config, or nil."
  (let* ((key (cdr (cl-find-if (lambda (k) (string-match-p (car k) (plist-get e :name)))
                               sprint--lift-keys)))
         (scope (and key (sprint--find cfg key w))))
    (when scope
      (let* ((g (lambda (f) (sprint--get cfg (format "%s_%s_%s" key scope f))))
             (sets (sprint--num-of (funcall g "SETS")))
             (reps (funcall g "REPS"))
             (variant (funcall g "VARIANT"))
             (single (funcall g "LOAD"))
             (start (funcall g "LOAD_START")) (end (funcall g "LOAD_END"))
             (pct (cond (single (sprint--num-of single))
                        ((and start end)
                         (let ((a (sprint--num-of start)) (b (sprint--num-of end)))
                           (+ a (* (- b a) (sprint--arc-frac w scope)))))))
             (rm (let ((r (sprint--num-of (sprint--get cfg (format "PREV_%s_1RM" key)))))
                  ;; FORM_FACTOR (percent, default 100) scales the starting maxima, e.g. 85 when out of shape
                  (and r (* r 0.01 (sprint--int cfg "FORM_FACTOR" 100)
                       (sprint--override-factor "LOAD" (plist-get w :n)))))))
        (when (and sets reps)
          (concat (format "%d×%s" (if deload (ceiling (/ sets 2.0)) (truncate sets)) reps)
                  (when pct
                    (format " @ %d%%%s" (round pct)
                            (if rm (format " (≈ %s kg)" (* 2.5 (round (/ (* rm pct 0.01) 2.5)))) "")))
                  (when variant (format " (%s)" variant))))))))

(defconst sprint--volume-keys
  '(("Acceleration" "ACC_VOL" "m") ("Max Velocity" "MAXVEL_VOL" "m")
    ("Speed Endurance" "SE_VOL" "m") ("Plyometrics" "PLY_CONTACTS" "contacts")
    ("Extensive Tempo" "TEMPO_VOL" "m"))
  "Category, config key and unit of the per-session volume targets.")

(defun sprint--volume-amount (cat w cfg deload)
  "Per-session volume target of CAT in week W (metres or contacts), or nil."
  (let* ((k (cdr (assoc cat sprint--volume-keys)))
         (scope (and k (sprint--find cfg (car k) w)))
         (v (and scope (sprint--num-of (or (sprint--get cfg (format "%s_%s" (car k) scope))
                                           (sprint--get cfg (format "%s_%s_MAX" (car k) scope)))))))
    (and v (round (* (sprint--vol-factor cat (plist-get w :n)) (if deload (* v 0.5) v))))))

(defun sprint--volume-target (cat w cfg deload)
  (let ((v (sprint--volume-amount cat w cfg deload)))
    (when v (format "%s %d %s%s" cat v (nth 2 (assoc cat sprint--volume-keys))
                    (if deload " (deload)" "")))))

;;;; Overrides (adjustments applied on top of the config)
;;
;; sprint_adjust_YYYY.org keeps proposals and their fate.  Entries in state
;; APPLIED are read here as overrides: a factor on sprint volume, plyometric
;; contacts or lift loads for a range of weeks, a forced deload week, or a
;; different F-V focus.  The config itself is never edited by the engine.

(defvar sprint--overrides nil "Applied adjustments: plists (:kind :factor :value :from :to).")

(defun sprint--week-in (o n)
  (and n (>= n (or (plist-get o :from) 0)) (<= n (or (plist-get o :to) 999))))

(defun sprint--override-factor (kind week-n)
  "Product of the applied KIND factors covering WEEK-N, kept within 0.6 … 1.25."
  (let ((f 1.0))
    (dolist (o sprint--overrides)
      (when (and (equal (plist-get o :kind) kind) (plist-get o :factor) (sprint--week-in o week-n))
        (setq f (* f (plist-get o :factor)))))
    (max 0.6 (min 1.25 f))))

(defun sprint--override-value (kind week-n)
  (let (v)
    (dolist (o sprint--overrides)
      (when (and (equal (plist-get o :kind) kind) (plist-get o :value) (sprint--week-in o week-n))
        (setq v (plist-get o :value))))
    v))

(defun sprint--vol-factor (cat week-n)
  (cond ((member cat '("Acceleration" "Max Velocity" "Speed Endurance")) (sprint--override-factor "SPRINT_VOL" week-n))
        ((equal cat "Plyometrics") (sprint--override-factor "PLYO" week-n))
        (t 1.0)))

(defun sprint--read-overrides (&optional year)
  (let ((f (sprint-file 'adjust year)) res)
    (when (file-exists-p f)
      (with-temp-buffer
        (insert-file-contents f)
        (delay-mode-hooks (org-mode))
        (org-map-entries
         (lambda ()
           (when (equal (org-get-todo-state) "APPLIED")
             (let ((num (lambda (p) (sprint--num-of (org-entry-get nil p)))))
               (push (list :kind (org-entry-get nil "KIND") :factor (funcall num "FACTOR")
                           :value (org-entry-get nil "VALUE")
                           :from (funcall num "FROM_WEEK") :to (funcall num "TO_WEEK"))
                     res))))
         nil nil)))
    (nreverse res)))

(defun sprint--apply-week-overrides (weeks)
  "WEEKS with forced deloads (KIND DELOAD) applied."
  (dolist (w weeks)
    (dolist (o sprint--overrides)
      (when (and (equal (plist-get o :kind) "DELOAD") (sprint--week-in o (plist-get w :n))
                 (not (member (plist-get w :type) '("TRANSITION" "DELOAD"))))
        (plist-put w :type "DELOAD"))))
  weeks)

(defun sprint--swaps (week-n)
  "Applied SWAP overrides covering WEEK-N: alist (OLD . NEW) of exercise names."
  (let (res)
    (dolist (o sprint--overrides (nreverse res))
      (let ((v (plist-get o :value)))
        (when (and (equal (plist-get o :kind) "SWAP") v (sprint--week-in o week-n)
                   (string-match "\\`\\(.+?\\) *-> *\\(.+?\\) *\\'" v))
          (push (cons (match-string 1 v) (match-string 2 v)) res))))))

(defun sprint--apply-swaps (w picks)
  "PICKS of week W with the exercises of its SWAP overrides replaced (when the new one is in the DB)."
  (let ((sw (sprint--swaps (plist-get w :n))))
    (if (null sw) picks
      (mapcar (lambda (e)
                (let* ((new (cdr (assoc (plist-get e :name) sw)))
                       (ne (and new (cl-find new (sprint--db) :key (lambda (x) (plist-get x :name)) :test #'equal))))
                  (or ne e)))
              picks))))

(defun sprint--scale-sets (vol factor)
  "VOL with its leading set count scaled by FACTOR (at least 1 set)."
  (if (and (/= factor 1.0) vol (string-match "\\`\\([0-9]+\\)×" vol))
      (replace-match (number-to-string (max 1 (round (* factor (string-to-number (match-string 1 vol))))))
                     t t vol 1)
    vol))

;;;; Rules, F-V regime and weekday pattern
;;
;; The spacing and injury rules of the master plan, as code.  They steer the
;; picker (a violating exercise is skipped when an alternative exists) and are
;; re-checked after generation; what could not be avoided is reported as a
;; WARNING line at the top of the schedule.

(defvar sprint--day-log nil
  "Sessions generated so far, newest first: (ABS CNS PICKS) with PICKS the DB plists.")
(defvar sprint--session-picks nil "Exercises picked so far for the session being filled.")
(defvar sprint--current-abs nil "Absolute day of the session being filled.")
(defvar sprint--fv-ctx nil "Plist (:phase :cfg) of the week being generated.")
(defvar sprint--nonce 0 "Mixed into the tie-break hash; `sprint-reroll-session' bumps it.")
(defvar sprint--planned nil
  "Flags the weekly template already promises for coming days: ((ABS . (FLAG ...)) ...).")
(defvar sprint--rule-hits nil "Rule violations left after generation: ((RULE . WHERE) ...).")
(defconst sprint--track-equipment-re "[Hh]urdle\\|[Ss]led\\|[Bb]locks\\|Timing gates\\|Tow cord"
  "EQUIPMENT values that are only at the track (excluded from gym sessions).")
(defconst sprint--elsewhere-re "\\`Pool\\|\\`Hill\\|\\`Suitable hill\\|\\`Downhill"
  "EQUIPMENT values found neither at the track nor at the gym (pool, hill): only on outside days, and never the pool.")
(defvar sprint--venue nil "`track' or `gym' for the session being filled when SPLIT_VENUES is on.")
(defconst sprint--timed-categories
  '("Acceleration" "Max Velocity" "Speed Endurance" "Special Endurance I" "Special Endurance II"
    "Resisted Sprinting" "Assisted / Overspeed"))
(defvar sprint--tctx nil "Target context used to print target times into the schedule.")
(defvar sprint--split-active nil "Non-nil while generating with SPLIT_VENUES on.")

(defun sprint--flag-p (e flag) (member flag (plist-get e :flags)))

(defun sprint--picks-with (flag from to &optional planned)
  "Picks flagged FLAG on days FROM..TO, from finished sessions and the current one.
With PLANNED, days promised by the template count too (as the symbol `planned')."
  (let ((entries (if sprint--current-abs
                     (cons (list sprint--current-abs nil sprint--session-picks) sprint--day-log)
                   sprint--day-log))
        res)
    (dolist (en entries)
      (when (and (>= (car en) from) (<= (car en) to))
        (dolist (p (nth 2 en)) (when (sprint--flag-p p flag) (push p res)))))
    (when planned
      (dolist (pl sprint--planned)
        (when (and (>= (car pl) from) (<= (car pl) to) (member flag (cdr pl)))
          (push (quote planned) res))))
    res))

(defun sprint--rule-violation (e abs)
  "Name of the rule broken by putting exercise E on day ABS, or nil."
  (cond
   ((and (sprint--flag-p e "hamstring-load") (sprint--picks-with "max-velocity" (1- abs) abs))
    "hamstring: no Nordic/RDL within 24 h of max velocity")
   ((and (sprint--flag-p e "depth-jump") (sprint--picks-with "calf-volume" (1- abs) (1- abs)))
    "achilles: no depth jumps the day after calf/pogo volume")
   ((and (sprint--flag-p e "max-velocity") (sprint--picks-with "max-velocity" (1- abs) (1- abs)))
    "max-velocity sessions need 48 h between them")
   ((and (sprint--flag-p e "heavy-resisted") (sprint--picks-with "max-velocity" (- abs 2) (+ abs 2) t))
    "heavy resisted sprints need 72 h from max velocity")
   ((and (sprint--flag-p e "max-velocity") (sprint--picks-with "heavy-resisted" (- abs 2) abs))
    "max velocity needs 72 h from heavy resisted sprints")
   ((and (sprint--flag-p e "special-endurance") (sprint--picks-with "max-velocity" (- abs 5) (+ abs 5) t))
    "special endurance not within 5 days of max velocity")
   ((and (sprint--flag-p e "max-velocity") (sprint--picks-with "special-endurance" (- abs 5) abs))
    "max velocity not within 5 days of special endurance")
   ((and (sprint--flag-p e "block-start") (sprint--picks-with "block-start" (1- abs) (1- abs)))
    "block starts not on back-to-back days")))

(defun sprint--fv-regime (phase)
  "F-V emphasis of PHASE (master plan: force Oct-Dec, balanced Jan-Mar, then velocity)."
  (pcase phase ("PH1" "force") ("PH2" "balanced") (_ "velocity")))

(defun sprint--avoid-flags (w cfg)
  "Rule flags to keep out of week W: AVOID_<sub-phase> or AVOID_<phase> from CFG."
  (let ((scope (cl-find-if (lambda (s) (sprint--get cfg (concat "AVOID_" s))) (sprint--scopes w))))
    (and scope (let ((v (sprint--get cfg (concat "AVOID_" scope))))
                 (and (not (equal v "none")) (split-string v "[ ,]+" t))))))

(defun sprint--avoided-p (e w cfg)
  (cl-some (lambda (f) (sprint--flag-p e f)) (sprint--avoid-flags w cfg)))

(defun sprint--regime-violation (e phase)
  (let ((regime (sprint--fv-regime phase)))
    (cond ((and (equal regime "force") (sprint--flag-p e "overspeed"))
           "overspeed is restricted in the force-dominant phase")
          ((and (equal regime "velocity") (sprint--flag-p e "heavy-resisted"))
           "heavy resisted work is restricted in the velocity-dominant phases"))))

(defun sprint--fv-cost (e)
  "0 (preferred) .. 2 (against the current emphasis) for exercise E."
  (let* ((phase (plist-get sprint--fv-ctx :phase))
         (deficit (or (sprint--override-value "FV_FOCUS" (plist-get sprint--fv-ctx :week))
                      (sprint--get (plist-get sprint--fv-ctx :cfg) "DOMINANT_FV_DEFICIT" "balanced")))
         (regime (and phase (sprint--fv-regime phase)))
         (want (cond ((null regime) nil)
                     ((equal regime "balanced") (and (member deficit '("force" "velocity")) deficit))
                     (t regime)))
         (bias (plist-get e :fv)))
    (cond ((null want) 0) ((equal bias want) 0) ((equal bias "neutral") 1) (t 2))))

(defun sprint--parse-rx (vol)
  "Parse a TYPICAL_VOLUME string into (SETS REPS DIST-M); nil where absent or not parsable."
  (when (and vol (string-match "\\`\\([0-9]+\\)×\\([0-9]+\\)\\(?:[–-][0-9]+\\)?\\(m\\)?\\(?:×\\([0-9]+\\)m\\)?" vol))
    (let ((s (string-to-number (match-string 1 vol)))
          (n (string-to-number (match-string 2 vol))))
      (cond ((match-string 3 vol) (list s 1 n))
            ((match-string 4 vol) (list s n (string-to-number (match-string 4 vol))))
            (t (list s n nil))))))

(defun sprint--cap-block-starts (e vol budget)
  "VOL for block-start exercise E limited to BUDGET reps.  Returns (VOL . REMAINING)."
  (let ((rx (and (sprint--flag-p e "block-start") vol (sprint--parse-rx vol))))
    (if (not rx) (cons vol budget)
      (let* ((s (nth 0 rx)) (r (nth 1 rx)) (total (* s r)))
        (cond ((<= total budget) (cons vol (- budget total)))
              ((<= budget 0) (cons vol 0))
              (t (let* ((r2 (min r budget)) (s2 (max 1 (min s (/ budget r2)))))
                   (cons (replace-regexp-in-string "\\`[0-9]+×[0-9]+\\(?:[–-][0-9]+\\)?"
                                                   (format "%d×%d" s2 r2) vol)
                         (- budget (* s2 r2))))))))))

(defun sprint--order-categories (cats)
  "CATS with the rule-constrained sprint categories first (they pick before the rest)."
  (let ((rank (lambda (c) (cond ((equal c "Max Velocity") 0)
                                ((string-prefix-p "Special Endurance" c) 1)
                                ((equal c "Speed Endurance") 1)
                                ((equal c "Acceleration") 2)
                                (t 3)))))
    (cl-stable-sort (copy-sequence cats) (lambda (a b) (< (funcall rank a) (funcall rank b))))))

(defun sprint--note-hit (rule where)
  (push (cons rule where) sprint--rule-hits))

(defun sprint--check-week (w)
  "Re-check the sessions of week W against the rules; record what is still broken."
  (let* ((start (plist-get w :start))
         (entries (sort (cl-remove-if-not (lambda (en) (and (>= (car en) start) (< (car en) (+ start 7))))
                                          (copy-sequence sprint--day-log))
                        (lambda (a b) (< (car a) (car b))))))
    (dolist (en entries)
      (let ((abs (car en)) (cns (downcase (or (nth 1 en) ""))))
        (when (and (member cns '("high" "very high"))
                   (cl-find-if (lambda (o) (and (= (car o) (1- abs))
                                                (member (downcase (or (nth 1 o) "")) '("high" "very high"))
                                                ;; SPLIT_VENUES: a gym day next to a track day is by design
                                                (not (and sprint--split-active
                                                          (not (eq (nth 3 o) (nth 3 en)))))))
                               sprint--day-log))
          (sprint--note-hit "two High-CNS days in a row (rule 1)"
                            (format "week %d %s" (plist-get w :n) (aref sprint--dow-names (sprint--dow abs)))))
        (dolist (e (nth 2 en))
          (let* ((sprint--current-abs abs)
                 (sprint--session-picks (remq e (nth 2 en)))
                 (sprint--day-log (cl-remove-if-not (lambda (o) (< (car o) abs)) sprint--day-log))
                 (why (sprint--rule-violation e abs)))
            (when why
              (sprint--note-hit why (format "week %d %s: %s" (plist-get w :n)
                                            (aref sprint--dow-names (sprint--dow abs))
                                            (plist-get e :name))))))))))

(defun sprint--rule-warnings ()
  "Aggregated warning strings from `sprint--rule-hits'."
  (let (res)
    (dolist (rule (delete-dups (mapcar #'car (reverse sprint--rule-hits))))
      (let ((hits (cl-remove-if-not (lambda (h) (equal (car h) rule)) (reverse sprint--rule-hits))))
        (push (format "rule: %s — %d time%s, first at %s" rule (length hits)
                      (if (= 1 (length hits)) "" "s") (cdr (car hits)))
              res)))
    (nreverse res)))

;; Weekday pattern: which kind of session each weekday gets

(defun sprint--gym-row (dayname phase)
  "Gym-only session row for DAYNAME in PHASE (tagged `gym' as 4th element)."
  (append
   (pcase phase
     ("PH1" (list dayname "Medium" "Strength (Max Force / Eccentric) + Core & Trunk + Isometrics + Mobility & Flexibility"))
     ("PH2" (list dayname "High" "Strength-Power (Power Clean) + Strength (Max Force) + Core & Trunk + Isometrics"))
     ("PH5" (list dayname "High" "Strength-Power + Strength (Max Force) + Core & Trunk"))
     (_     (list dayname "High" "Strength (Max Force) maintenance + Core & Trunk + Mobility & Flexibility")))
   (list 'gym)))

(defun sprint--gym-row-light (dayname)
  "Medium-CNS gym row used next to a High sprint day (no Olympic lifts or ballistics)."
  (list dayname "Medium" "Strength (Max Force) + Core & Trunk + Isometrics + Mobility & Flexibility" 'gym))

;; Separate venues (SPLIT_VENUES): the track and the gym are different places,
;; so a session is either a track session or a gym session.  The strength part
;; of the plan's track days moves, in order, to the gym days of the week.

(defconst sprint--gym-categories '("Strength — Max Force" "Strength — Eccentric" "Strength-Power")
  "Categories that need the gym.")

(defconst sprint--gym-equipment-re
  "\\`\\(?:Barbell\\|Dumbbell\\|Kettlebell\\|Trap bar\\)\\|rack\\|GHR bench\\|machine\\'"
  "EQUIPMENT values that are only at the gym (excluded from track sessions).")


(defconst sprint--track-only-re "Starting blocks\\|[Tt]iming gates\\|, timing\\'\\|\\`Track"
  "EQUIPMENT values that need the track (not drawn on days without it).")

(defun sprint--track-days (cfg)
  "Weekday numbers (0 = Sun) of TRACK_DAYS, or nil when unset or \"all\" (every day)."
  (let ((v (upcase (string-trim (sprint--get cfg "TRACK_DAYS" "all")))))
    (unless (equal v "ALL")
      (delq nil (mapcar (lambda (d) (cdr (assoc d sprint--dow-codes))) (split-string v "[ ,]+" t))))))

(defun sprint--track-day-p (cfg abs)
  (let ((days (sprint--track-days cfg))) (or (null days) (memq (sprint--dow abs) days))))

(defun sprint--needs-track-p (content)
  "Non-nil when session text CONTENT asks for work that needs the track."
  (let ((case-fold-search t))
    (or (cl-some (lambda (c) (member c '("Max Velocity" "Speed Endurance" "Special Endurance I" "Special Endurance II")))
                 (sprint--content-categories content))
        (string-match-p "block starts\\|TESTING BATTERY\\|full sprint session" content))))

(defun sprint--track-warning (w cfg abs content)
  "Warning string when CONTENT on day ABS needs the track but ABS is not a track day."
  (when (and (not (sprint--track-day-p cfg abs)) (sprint--needs-track-p content))
    (format "Week %d %s: \"%s\" needs the track, which you have on %s"
            (plist-get w :n) (aref sprint--dow-names (sprint--dow abs))
            (truncate-string-to-width content 60 nil nil "…") (sprint--get cfg "TRACK_DAYS"))))

(defun sprint--split-p (cfg)
  (member (downcase (sprint--get cfg "SPLIT_VENUES" "no")) '("yes" "true" "on")))

(defun sprint--split-segments (content)
  "The \" + \"-separated parts of CONTENT, ignoring \"+\" inside parentheses."
  (let ((depth 0) (start 0) (i 0) (n (length content)) parts)
    (while (< i n)
      (let ((c (aref content i)))
        (cond ((eq c ?\() (cl-incf depth))
              ((eq c ?\)) (setq depth (max 0 (1- depth))))
              ((and (= depth 0) (eq c ?+) (> i 0) (eq (aref content (1- i)) ?\s)
                    (< (1+ i) n) (eq (aref content (1+ i)) ?\s))
               (push (string-trim (substring content start (1- i))) parts)
               (setq start (+ i 2)))))
      (cl-incf i))
    (push (string-trim (substring content start)) parts)
    (delete "" (nreverse parts))))

(defun sprint--segment-gym-p (seg)
  "Non-nil when every category SEG names needs the gym."
  (let ((cats (append (sprint--content-categories seg)
                      (mapcar (lambda (e) (plist-get e :cat))
                              (cl-remove-if-not (lambda (e) (string-match-p (regexp-quote (plist-get e :name)) seg))
                                                (sprint--db))))))
    (and cats (cl-every (lambda (c) (member c sprint--gym-categories)) cats))))

(defun sprint--split-week (start base-row)
  "Rows of the 7 days from START with track and gym kept apart: (ALIST . DROPPED).
ALIST maps day -> row (or `rest'); DROPPED lists strength parts that found no gym day."
  (let (rows moved)
    (dotimes (i 7)
      (let* ((abs (+ start i)) (r (funcall base-row abs)))
        (if (and (consp r) (not (eq (nth 3 r) 'gym)) (not (member (nth 1 r) '("Rest" "—"))))
            (let* ((segs (sprint--split-segments (nth 2 r)))
                   (gym (cl-remove-if-not #'sprint--segment-gym-p segs))
                   (keep (cl-remove-if #'sprint--segment-gym-p segs)))
              (when gym (push gym moved))
              (push (cons abs (cond ((null gym) r)
                                    (keep (list (car r) (nth 1 r) (mapconcat #'identity keep " + ")))
                                    (t 'rest)))
                    rows))
          (push (cons abs r) rows))))
    (setq rows (nreverse rows) moved (nreverse moved))
    (let ((gym-days (cl-remove-if-not (lambda (x) (and (consp (cdr x)) (eq (nth 3 (cdr x)) 'gym))) rows)))
      (if (null gym-days)
          (cons rows (apply #'append moved))
        (let ((k 0) (n (length gym-days)) (assigned (make-vector (length gym-days) nil)))
          (dolist (m moved)
            (aset assigned (min k (1- n)) (append (aref assigned (min k (1- n))) m))
            (cl-incf k))
          (cl-loop for g in gym-days for j from 0
                   do (let* ((segs (aref assigned j)) (r (cdr g)))
                        (setcdr g (if segs
                                      (list (car r)
                                            (if (cl-some (lambda (s) (member "Strength-Power" (sprint--content-categories s))) segs)
                                                "High" "Medium")
                                            (concat "Gym: " (mapconcat #'identity (append segs '("Core & Trunk" "Mobility & Flexibility")) " + "))
                                            'gym)
                                    ;; no strength left for this gym day: keep the plan's dose, go light
                                    (list (car r) "Low" "Gym: Core & Trunk + Isometrics + Mobility & Flexibility" 'gym)))))
          (cons rows nil))))))

(defun sprint--high-row-p (row)
  (and (consp row) (not (eq (nth 3 row) 'gym))
       (member (downcase (or (nth 1 row) "")) '("high" "very high"))))

(defun sprint--hill-row (cfg dayname phase)
  (let ((ok (split-string (sprint--get cfg "HILL_PHASES" "PH1 PH2 PH5"))))
    (when (member phase ok)
      (list dayname "High" "Hill Sprints (short uphill reps, easy walk down) + Technical Drills"))))

(defconst sprint--pattern-days (quote ("MON" "TUE" "WED" "THU" "FRI" "SAT" "SUN")))

(defun sprint--pattern-row (cfg phase dayname template-row)
  "Session row for DAYNAME after applying PATTERN_<DAY> from CFG.
Returns TEMPLATE-ROW, a replacement row, or `rest'."
  (let ((p (downcase (sprint--get cfg (concat "PATTERN_" dayname) "template"))))
    (cond
     ((member p '("template" "")) template-row)
     ((equal p "rest") 'rest)
     ((equal p "gym") (sprint--gym-row dayname phase))
     ((equal p "hill") (or (sprint--hill-row cfg dayname phase) template-row))
     ((equal p "tempo")
      (list dayname "Low" (format "Extensive Tempo %dm + Mobility & Flexibility + Core & Trunk"
                                  (sprint--int cfg "TEMPO_VOL_PH1" 1500))))
     ((equal p "recovery") (list dayname "Low" "Recovery & Regeneration + Mobility & Flexibility"))
     (t template-row))))

;; Selection

(defun sprint--hash (s)
  (let ((h 7)) (dolist (c (string-to-list s) h) (setq h (mod (+ (* h 31) c) 100003)))))

(defun sprint--key< (a b)
  (cl-loop for x in a for y in b
           when (< x y) return t
           when (> x y) return nil))

(defun sprint--pick (pool n w &optional rules)
  "Pick N exercises of POOL: least used first, different sub-categories, stable ties.
With RULES each pick must also respect the spacing/injury rules given the earlier picks."
  (let (chosen)
    (dotimes (_ (min n (length pool)))
      (let* ((subs (mapcar (lambda (e) (plist-get e :sub)) chosen))
             (rest (cl-remove-if (lambda (e) (memq e chosen)) pool))
             (rest (if (and rules sprint--current-abs)
                       (let* ((sprint--session-picks (append chosen sprint--session-picks))
                              (ok (cl-remove-if (lambda (e) (sprint--rule-violation e sprint--current-abs)) rest)))
                         (or ok rest))
                     rest))
             (key (lambda (e)
                    (let ((u (or (gethash (plist-get e :name) sprint--usage) '(0 . 0))))
                      (list (if (member (plist-get e :sub) subs) 1 0)
                            ;; least used first; the F-V emphasis of the phase weighs like 1.5 uses per step
                            (+ (car u) (* 1.5 (sprint--fv-cost e))) (cdr u)
                            (sprint--hash (format "%s/%d/%d" (plist-get e :name) (plist-get w :n) sprint--nonce)))))))
        (push (car (sort rest (lambda (a b) (sprint--key< (funcall key a) (funcall key b))))) chosen)))
    (nreverse chosen)))

;; Rotation cap and harder variants

(defun sprint--streak-blocked-p (e w cfg)
  "Non-nil when E was already planned in each of the last ROTATION_WEEKS weeks before W."
  (let ((cap (sprint--int cfg "ROTATION_WEEKS" 3))
        (s (and sprint--streak (gethash (plist-get e :name) sprint--streak)))
        (n (plist-get w :n)))
    (and s (> cap 0) (= (cdr s) (1- n)) (>= (- n (car s)) cap))))

(defun sprint--note-pick (e w)
  "Record exercise E as planned in week W (usage count and consecutive-week run)."
  (let ((name (plist-get e :name)) (n (plist-get w :n)))
    (let ((u (or (gethash name sprint--usage) '(0 . 0))))
      (puthash name (cons (1+ (car u)) n) sprint--usage))
    (when sprint--streak
      (let ((s (gethash name sprint--streak)))
        (puthash name (if (and s (>= (cdr s) (1- n))) (cons (car s) n) (cons n n)) sprint--streak)))))

(defun sprint--late-block-p (w cfg)
  "Non-nil in the loading weeks of a sub-phase past PROGRESS_FROM_PCT of its load arc."
  (let ((sub (plist-get w :sub)) (from (sprint--int cfg "PROGRESS_FROM_PCT" 60)))
    (and sub (equal (plist-get w :type) "LOAD") (<= from 100)
         (> (sprint--arc-frac w sub) 0)
         (>= (* 100 (sprint--arc-frac w sub)) from))))

(defun sprint--harder-variant (e cap used w cfg)
  "The PROGRESSION variant of E when it fits the day (CNS CAP, rules, F-V regime, equipment), else nil."
  (let ((next (and (plist-get e :next)
                   (cl-find (plist-get e :next) (sprint--db) :key (lambda (x) (plist-get x :name)) :test #'equal))))
    (and next
         (not (gethash (plist-get next :name) used))
         (<= (sprint--cns-rank (plist-get next :cns)) cap)
         (not (cl-some (lambda (re) (string-match-p re (plist-get next :equip))) sprint-unavailable-equipment))
         (not (and sprint--current-abs (sprint--rule-violation next sprint--current-abs)))
         (not (sprint--regime-violation next (plist-get w :phase)))
         (not (sprint--avoided-p next w cfg))
         (not (sprint--streak-blocked-p next w cfg))
         next)))

(defun sprint--scale-vol (vol deload)
  (if (and deload (string-match "\\`\\([0-9]+\\)×" vol))
      (replace-match (number-to-string (ceiling (/ (string-to-number (match-string 1 vol)) 2.0)))
                     t t vol 1)
    vol))

(defun sprint--fill-session (w cfg cns content used)
  "Exercise lines for a session of week W, or nil.  USED: hash of this week's picks.
Records the picks in `sprint--session-picks' (the caller binds it)."
  (let* ((case-fold-search t)
         (deload (equal (plist-get w :type) "DELOAD"))
         (phase (plist-get w :phase))
         (pinned (cl-remove-if-not
                  (lambda (e) (string-match-p (regexp-quote (plist-get e :name)) content))
                  (sprint--db)))
         (cats (sprint--content-categories content))
         (cap (sprint--cns-cap cns))
         (bs-budget 6)
         lines targets)
    (dolist (e pinned)
      (unless (member (plist-get e :cat) cats) (setq cats (append cats (list (plist-get e :cat))))))
    (setq cats (sprint--order-categories cats))
    (when (and cats sprint-warmup-on-high-days (equal (downcase cns) "high")
               (not (member "Warm-Up & Activation" cats)))
      (push "Warm-Up & Activation" cats))
    (when (and cats (not (string-match-p "RACE DAY" content)))
      (dolist (cat (if (member "Warm-Up & Activation" cats)
                       (cons "Warm-Up & Activation" (remove "Warm-Up & Activation" cats))
                     cats))
        (let* ((all (cl-remove-if
                     (lambda (e) (or (not (equal (plist-get e :cat) cat))
                                     (cl-some (lambda (re) (string-match-p re (plist-get e :equip)))
                                              sprint-unavailable-equipment)
                                     ;; SPLIT_VENUES: nothing that needs the gym at the track
                                     (and sprint--split-active (memq sprint--venue '(track outside))
                                          (string-match-p sprint--gym-equipment-re (plist-get e :equip)))
                                     ;; days without the track: nothing that needs blocks or timing gates
                                     (and (eq sprint--venue 'outside)
                                          (string-match-p sprint--track-only-re (plist-get e :equip)))
                                     ;; pool and hill work: not at the track or the gym (the pool never)
                                     (and sprint--venue
                                          (string-match-p sprint--elsewhere-re (plist-get e :equip))
                                          (or (not (eq sprint--venue 'outside))
                                              (string-prefix-p "Pool" (plist-get e :equip))))
                                     (and (eq sprint--venue 'gym)
                                          (string-match-p sprint--track-equipment-re (plist-get e :equip)))))
                     (sprint--db)))
               (pool0 (or (cl-remove-if (lambda (e) (gethash (plist-get e :name) used)) all) all))
               (pool (or (cl-remove-if (lambda (e) (> (sprint--cns-rank (plist-get e :cns)) cap)) pool0)
                         pool0))
               ;; named in the session text: kept whatever the rules or the CNS level say
               (pin (cl-remove-if (lambda (e) (sprint--avoided-p e w cfg))
                                  (cl-remove-if-not (lambda (e) (memq e pinned)) pool0)))
               ;; the rest must respect the spacing/injury rules and the F-V emphasis
               ;; AVOID_<block> (e.g. no block starts when coming back from a break): hard filter
               (pool (or (cl-remove-if (lambda (e) (sprint--avoided-p e w cfg)) pool) pool))
               (pool (let ((ok (cl-remove-if
                                (lambda (e) (or (and sprint--current-abs
                                                     (sprint--rule-violation e sprint--current-abs))
                                                (sprint--regime-violation e phase)))
                                pool)))
                       (or ok pool)))
               ;; lifts prescribed by the config (Section 4) are kept whatever the CNS level of the day
               (conf (let ((c (cl-remove-if-not (lambda (e) (sprint--lift-prescription e w cfg deload)) pool0)))
                       (or (cl-remove-if (lambda (e) (and sprint--current-abs (sprint--rule-violation e sprint--current-abs))) c)
                           c)))
               (n (or (cdr (assoc cat sprint-exercises-per-category))
                      sprint-default-exercises-per-category))
               ;; rotation: nothing stays more than ROTATION_WEEKS weeks in a row while alternatives exist
               (fresh (cl-remove-if (lambda (e) (sprint--streak-blocked-p e w cfg)) pool))
               (pool (if (>= (length fresh) n) fresh pool))
               (picks (sprint--apply-swaps w (cond (pin (sprint--pick pin (max n (length pin)) w))
                            (conf (sprint--pick conf 1 w t))
                            (t (let* ((late (sprint--late-block-p w cfg))
                                      (drawn (sprint--pick pool n w t))
                                      (taken (mapcar (lambda (e) (plist-get e :name)) drawn)))
                                 ;; late in a block an exercise gives way to its harder variant
                                 (mapcar (lambda (e)
                                           (let ((h (and late (sprint--harder-variant e cap used w cfg))))
                                             (if (and h (not (member (plist-get h :name) taken)))
                                                 (progn (push (plist-get h :name) taken)
                                                        (append h (list :up (plist-get e :name))))
                                               e)))
                                         drawn)))))))
          (when picks
            (push (sprint--as-subtodos
                          (mapconcat
                           (lambda (e)
                             (let ((p (sprint--lift-prescription e w cfg deload))
                                   (v (plist-get e :vol)))
                               (puthash (plist-get e :name) t used)
                               (push e sprint--session-picks)
                               (sprint--note-pick e w)
                               (when v (setq v (sprint--scale-sets v (sprint--vol-factor (plist-get e :cat) (plist-get w :n)))))
                               (when (and v (sprint--flag-p e "block-start"))
                                 (let ((c (sprint--cap-block-starts e v bs-budget)))
                                   (setq v (car c) bs-budget (cdr c))))
                               (let ((txt
                                (cond (p (format "%s %s" (plist-get e :name) p))
                                      ;; tempo: the configured distance replaces the DB's generic volume
                                      ((and (equal cat "Extensive Tempo") (sprint--volume-amount cat w cfg deload))
                                       (format "%s %d m total (65–75%%)" (plist-get e :name)
                                               (sprint--volume-amount cat w cfg deload)))
                                      ((and v (not (string-empty-p v)))
                                       (format "%s %s" (plist-get e :name) (sprint--scale-vol v deload)))
                                      (t (plist-get e :name)))))
                                 (concat
                                  txt
                                  ;; ↑ marks a harder variant chosen late in the block
                                  (if (plist-get e :up) " ↑" "")
                                  ;; target time as an indication (from the tests; logging scores against it)
                                  (let* ((it (and sprint--tctx (member cat sprint--timed-categories)
                                                  (sprint--parse-plan-item cat txt)))
                                         (tg (and it (sprint--target-for it (plist-get w :n) sprint--tctx))))
                                    (cond ((null tg) "")
                                          ((and (plist-get sprint--tctx :acc-provisional)
                                                (not (string-prefix-p "Flying" (plist-get e :name))))
                                           (format " · target ~%.2f s (pre-break best, until the test)" tg))
                                          (t (format " · target %.2f s" tg))))))))
                           picks "\x1f"))
                  lines))
          (let ((tg (sprint--volume-target cat w cfg deload))) (when tg (push tg targets))))))
    (when lines
      (concat (when targets (format "- Targets: %s\n" (mapconcat #'identity (nreverse targets) " · ")))
              (mapconcat #'identity (nreverse lines) "")))))

(defun sprint--as-subtodos (joined)
  "One \"*** TODO\" line per exercise of JOINED (texts separated by \\x1f)."
  (mapconcat (lambda (s) (concat "*** TODO " s "\n" (sprint--how-line s))) (split-string joined "\x1f" t) ""))

(defun sprint--how-line (text)
  "The \"How:\" body line of the exercise TEXT (its EXECUTION in the DB), or \"\".
Indented, so the parsers of \"- Category: …\" lines and the hand-edit hash ignore it."
  (let ((how (and sprint-show-execution (plist-get (sprint--db-match text) :how))))
    (if (and how (not (string-empty-p how))) (format "    How: %s\n" how) "")))

(defun sprint--annotate-how (text)
  "TEXT with every exercise sub-heading followed by its current \"How:\" line.
Old How lines are dropped first, so a changed DB shows up on the next generation."
  (with-temp-buffer
    (insert text)
    (goto-char (point-min))
    (while (re-search-forward "^[ \t]+How: .*\n?" nil t) (replace-match ""))
    (goto-char (point-min))
    (while (re-search-forward "^\\*\\*\\*+ \\(?:\\(?:TODO\\|NEXT\\|IN-WORK\\|DONE\\|SKIPPED\\) \\)?\\(.*?\\)[ \t]*$" nil t)
      (let ((how (sprint--how-line (match-string 1))))
        (unless (string-empty-p how)
          (forward-line 1)
          ;; below the planning line and the drawers (properties, logbook with the clock
          ;; lines), which org wants right under the heading
          (while (looking-at "[ \t]*\\(?:CLOSED\\|SCHEDULED\\|DEADLINE\\):") (forward-line 1))
          (while (looking-at "[ \t]*:[A-Za-z_-]+:[ \t]*$")
            (re-search-forward "^[ \t]*:END:.*\n?" nil t))
          (unless (bolp) (insert "\n"))
          (insert how))))
    (buffer-string)))

;;;; Schedule generation

(defun sprint--cns-tag (cns)
  (let ((c (downcase cns)))
    (cond ((string-match-p "\\`[a-z]+\\'" c) c)
          (t nil))))

(defun sprint--entry (abs cns content tags &optional body)
  (let ((tags (delete-dups (delq nil (append (list (sprint--cns-tag cns)) tags))))
        (n (if body (with-temp-buffer (insert body) (count-matches "^\\*\\*\\* " (point-min) (point-max))) 0)))
    (format "** TODO [%s] %s%s%s\nSCHEDULED: %s\n%s"
            cns content (if (> n 0) (format " [0/%d]" n) "")
            (if tags (concat " :" (mapconcat #'identity tags ":") ":") "")
            (sprint--ts abs) (or body ""))))

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
         (use-pattern (and (member phase (quote ("PH1" "PH2" "PH3" "PH5" "PH6" "PH7"))) (not (equal kind "race"))))
         (sprint--fv-ctx (list :phase phase :cfg cfg :week (plist-get w :n)))
         (used (make-hash-table :test #'equal))
         (base-row (lambda (abs)
                    (let ((row0 (cl-find-if (lambda (r) (eq (cdr (assoc (car r) sprint--dow-codes)) (sprint--dow abs))) rows)))
                      (if (and use-pattern (not (assoc abs races)))
                          (sprint--pattern-row cfg phase (upcase (aref sprint--dow-names (sprint--dow abs))) row0)
                        row0))))
         (split (and (sprint--split-p cfg) (sprint--split-week start base-row)))
         ;; High-Low: a High gym day next to a High sprint day becomes a Medium one
         ;; (not with SPLIT_VENUES: there the gym day carries the moved strength work)
         (row-for (lambda (abs)
                    (let ((r (if (assoc abs (car split)) (cdr (assoc abs (car split))) (funcall base-row abs))))
                      (if (and (not split) (consp r) (eq (nth 3 r) 'gym)
                               (not (equal (downcase (sprint--get cfg "GYM_NEXT_TO_SPRINT" "medium")) "high"))
                               (member (downcase (nth 1 r)) '("high" "very high"))
                               (or (sprint--high-row-p (funcall base-row (1- abs)))
                                   (sprint--high-row-p (funcall base-row (1+ abs)))))
                          (sprint--gym-row-light (car r))
                        r))))
         (sprint--planned
          (cl-loop for i below 14
                   for abs = (+ start i)
                   for row = (funcall row-for abs)
                   for cats = (and (consp row) (sprint--content-categories (nth 2 row)))
                   for flags = (append (and (member "Max Velocity" cats) (list "max-velocity"))
                                       (and (cl-some (lambda (c) (string-prefix-p "Special Endurance" c)) cats)
                                            (list "special-endurance")))
                   when flags collect (cons abs flags)))
         (entries nil))
    (when (cdr split)
      (push (format "Week %d: no gym day for %s (SPLIT_VENUES)" (plist-get w :n)
                    (mapconcat #'identity (delete-dups (copy-sequence (cdr split))) ", "))
            warnings))
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
              (let ((tw (sprint--track-warning w cfg abs (nth 2 row)))) (when tw (push tw warnings)))
              (push (sprint--entry abs (if (equal (nth 1 row) "—") "—" (nth 1 row))
                                   (format "TAPER %s — %s" (car row) (nth 2 row))
                                   '("taper"))
                    entries))))
         (t
          (let* ((row (funcall row-for abs)))
            (when (and row (not (eq row (quote rest))) (not (equal (nth 1 row) "Rest")))
              (let* ((sprint--session-picks nil)
                     (sprint--current-abs abs)
                     (sprint--venue (cond ((and split (eq (nth 3 row) 'gym)) 'gym)
                                          ((not (sprint--track-day-p cfg abs)) 'outside)
                                          (split 'track)))
                     (body (and sprint-fill-sessions
                                (sprint--fill-session w cfg (nth 1 row) (nth 2 row) used))))
                (push (list abs (nth 1 row) sprint--session-picks sprint--venue) sprint--day-log)
                (let ((tw (sprint--track-warning w cfg abs (nth 2 row)))) (when tw (push tw warnings)))
                (push (sprint--entry abs (nth 1 row)
                                     (concat (if deload "DELOAD −50% volume: " "") (nth 2 row))
                                     (delq nil (list (and deload "deload")
                                                     (and race "race")
                                                     (and (eq sprint--venue 'gym) "gym")))
                                     body)
                      entries))))))
        (when (and race (not (and champ (= champ abs))) (not (equal kind "race")))
          (push (sprint--entry abs "—" (format "RACE — %s" (cdr race)) '("race")) entries))))
    ;; Testing battery on deload weeks, monthly in Phase 6.
    (let ((battery (or (and deload (cdr (assoc (or (plist-get w :sub) phase) sprint--battery)))
                       (and (equal phase "PH6") (= 1 (mod (plist-get w :pk) 4))
                            (cdr (assoc "PH6" sprint--battery))))))
      (when (and battery (not (member phase '("PH7"))))
        (let ((day (+ start (mod (+ (cdr (assoc sprint-test-weekday sprint--dow-codes)) 6) 7))))
          (let ((tw (sprint--track-warning w cfg day "TESTING BATTERY"))) (when tw (push tw warnings)))
          (push (sprint--entry day "Test" (concat "TESTING BATTERY — " battery) '("test")) entries))))
    (let ((body (concat
                 (if (and (null entries) (member type '("TRANSITION")))
                     "Transition week: no structured sessions. Follow the category distribution in the plan.\n"
                   "")
                 (mapconcat #'identity (nreverse entries) ""))))
      (cons
       (concat
        (format "* Week %02d · %s · %s%s\n:PROPERTIES:\n:START: %s\n:WEEK: %d\n:PHASE: %s\n:SUBPHASE: %s\n:WEEKTYPE: %s\n:GEN_HASH: %s\n:END:\n"
                (plist-get w :n) phase
                (or (plist-get w :sname) (plist-get w :pname))
                (if (plist-get w :sub) (format " · %s %d/%d" type (plist-get w :k) (plist-get w :of))
                  (format " · %s" type))
                (sprint--str start) (plist-get w :n) phase (or (plist-get w :sub) "-") type
                (sprint--exercise-lines-hash body))
        body)
       warnings))))

(defun sprint--exercise-lines-hash (text)
  "Hash of the exercise bullet lines of TEXT (state changes and logbook notes do not count)."
  (let (lines)
    (dolist (l (split-string text "\n"))
      (cond ((string-match "\\`\\*\\*\\*+ \\(?:\\(?:TODO\\|NEXT\\|IN-WORK\\|DONE\\|SKIPPED\\) \\)?\\(.*?\\)[ \t]*\\'" l)
             (push (concat "*** " (match-string 1 l)) lines))
            ((and (string-match-p "\\`- [^:\n]+: " l)
                  (not (string-match-p "\\`- \\(State\\|Note taken\\|Rescheduled\\|Refiled\\) " l)))
             (push (string-trim-right l) lines))))
    (substring (md5 (mapconcat #'identity (nreverse lines) "\n")) 0 12)))

(defun sprint--hand-edited-p (chunk)
  "Non-nil when the exercise lines of week CHUNK differ from what was generated."
  (and (string-match "^:GEN_HASH:[ \t]+\\([0-9a-f]+\\)" chunk)
       (not (equal (match-string 1 chunk) (sprint--exercise-lines-hash chunk)))))

(defun sprint--chunk-set-locked (chunk)
  "CHUNK with \":LOCKED: yes\" in its week property drawer."
  (if (string-match "^:END:" chunk)
      (replace-match ":LOCKED: yes\n:END:" t t chunk)
    chunk))

;; Sessions already marked DONE or SKIPPED survive the rebuild of their week

(defun sprint--session-chunks (text)
  "Split week TEXT into (HEAD . SESSIONS), each session a string starting with \"** \"."
  (let ((parts (split-string text "^\\*\\* ")))
    (cons (car parts) (mapcar (lambda (s) (concat "** " s)) (cdr parts)))))

(defun sprint--session-date (s)
  (and (string-match "SCHEDULED: <\\([0-9-]+\\)" s) (match-string 1 s)))

(defun sprint--merge-closed (new old)
  "Week text NEW with the DONE/SKIPPED sessions of OLD in place of the new sessions of their days."
  (let ((closed (and old (cl-remove-if-not (lambda (s) (or (string-match-p "\\`\\*\\* \\(DONE\\|SKIPPED\\) " s)
                                                           ;; started: an exercise already ticked off
                                                           (string-match-p "^\\*\\*\\* \\(DONE\\|SKIPPED\\) " s)))
                                             (cdr (sprint--session-chunks old))))))
    (if (null closed) new
      (let* ((dates (mapcar #'sprint--session-date closed))
             (n (sprint--session-chunks new))
             (sessions (cl-stable-sort
                        (append (cl-remove-if (lambda (s) (member (sprint--session-date s) dates)) (cdr n))
                                (mapcar (lambda (s) (concat (string-trim-right s) "\n")) closed))
                        #'string< :key (lambda (s) (or (sprint--session-date s) ""))))
             (text (concat (car n) (mapconcat #'identity sessions ""))))
        ;; the kept sessions are part of what counts as generated for the hand-edit check
        (replace-regexp-in-string "^:GEN_HASH: .*$"
                                  (concat ":GEN_HASH: " (sprint--exercise-lines-hash text)) text t t)))))

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
         (sprint--overrides (sprint--read-overrides year))
         (weeks (sprint--apply-week-overrides (sprint--weeks cfg)))
         (races (sprint--races cfg)) (champs (sprint--champs cfg))
         (today (sprint--today))
         (cutoff (- today (mod (+ (sprint--dow today) 6) 7)))
         ;; an open schedule buffer is saved first, so unsaved hand edits count
         (visiting (find-buffer-visiting out))
         (_ (when (and visiting (buffer-modified-p visiting))
              (with-current-buffer visiting (save-buffer))))
         (old (when (file-exists-p out)
                (with-temp-buffer
                  (insert-file-contents out)
                  (let ((s (buffer-string)) chunks)
                    (dolist (c (cdr (split-string s "^\\* Week " t)))
                      (push (concat "* Week " c) chunks))
                    (nreverse chunks)))))
         ;; weeks before the current one, weeks marked ":LOCKED: yes" and weeks whose
         ;; exercise lines were edited by hand (unless ":LOCKED: no") stay as written
         (edited 0)
         (kept (delq nil
                     (mapcar
                      (lambda (c)
                        (let ((s (sprint--week-start-of-chunk c)))
                          (cond ((null s) nil)
                                ((or (< s cutoff) (string-match-p "^:LOCKED:[ \t]+\\(yes\\|t\\|true\\)" c)) c)
                                ((and (not (string-match-p "^:LOCKED:[ \t]+no" c)) (sprint--hand-edited-p c))
                                 (cl-incf edited)
                                 (sprint--chunk-set-locked c)))))
                      old)))
         (old-by-start (mapcar (lambda (c) (cons (sprint--week-start-of-chunk c) c)) old))
         (kept-n (length kept))
         (kept-starts (mapcar #'sprint--week-start-of-chunk kept))
         (sprint--all-weeks weeks)
         (sprint--db nil)
         (sprint--usage (make-hash-table :test #'equal))
         (sprint--streak (make-hash-table :test #'equal))
         (sprint--split-active (sprint--split-p cfg))
         (sprint--tctx (ignore-errors (sprint--target-ctx year t)))
         (sprint--day-log nil)
         (sprint--rule-hits nil)
         (sprint-unavailable-equipment
          (append sprint-unavailable-equipment
                  (let ((u (sprint--get cfg "EQUIPMENT_UNAVAILABLE" "none")))
                    (and (not (equal u "none")) (split-string u "[|,]" t "[ \t]+")))))
         (warnings nil) (texts nil))
    ;; Every week is generated, in order, so that the exercise rotation sees the
    ;; same history on each run; only the weeks not kept are written.
    (dolist (w weeks)
      (let ((r (sprint--week-text w cfg templates races champs nil)))
        (sprint--check-week w)
        (unless (memq (plist-get w :start) kept-starts)
          (push (cons (plist-get w :start)
                      (sprint--merge-closed (car r) (cdr (assoc (plist-get w :start) old-by-start))))
                texts)
          (setq warnings (append (cdr r) warnings)))))
    (dolist (c (sprint--validate-dates cfg weeks))
      (push c warnings))
    (dolist (c (sprint--rule-warnings)) (push c warnings))
    (with-temp-file out
      (insert (format "#+TITLE: Sprint Schedule %d (generated)\n" (or year (sprint-season)))
              "#+SEQ_TODO: TODO(t) IN-WORK(w) | DONE(d) SKIPPED(s)\n#+STARTUP: overview\n"
              "# Generated by sprint-generate-schedule from the config + plan.\n"
              "# Mark sessions DONE or SKIPPED here; weeks before the current one are kept on regeneration.\n")
      (dolist (w (delete-dups (reverse warnings)))
        (insert "# WARNING: " w "\n"))
      (insert "\n")
      (dolist (c (sort (append (mapcar (lambda (c) (cons (sprint--week-start-of-chunk c)
                                                       (concat (string-trim-right c) "\n")))
                                       kept)
                               texts)
                       (lambda (a b) (< (car a) (car b)))))
        (insert (sprint--annotate-how (cdr c)))))
    (when (buffer-live-p visiting)
      (with-current-buffer visiting (revert-buffer t t t)))
    (message "Sprint schedule: %d weeks (%d kept%s, %d generated) → %s"
             (length weeks) kept-n
             (if (> edited 0) (format ", %d of them edited by hand and now locked" edited) "")
             (- (length weeks) kept-n) out)
    out))

;;;; Reroll: new draw for one session or week

(defun sprint--db-match (text)
  "The DB exercise whose name is the longest prefix of TEXT, or nil."
  (let (best)
    (dolist (e (sprint--db) best)
      (when (and (string-prefix-p (plist-get e :name) text)
                 (or (null best) (> (length (plist-get e :name)) (length (plist-get best :name)))))
        (setq best e)))))

(defun sprint--body-entries (body)
  "Exercises of a session BODY as (CATEGORY TEXT STATE): \"*** TODO text\" sub-headings
or the older \"- Category: a; b\" bullet lines (STATE nil)."
  (let (res)
    (dolist (line (split-string body "\n" t))
      (cond
       ((string-match "\\`\\*\\*\\*+ \\(?:\\(TODO\\|NEXT\\|IN-WORK\\|DONE\\|SKIPPED\\) \\)?\\(.*?\\)\\(?:[ \t]+:[[:alnum:]_@#%:]+:\\)?[ \t]*\\'" line)
        (let* ((state (match-string 1 line)) (text (match-string 2 line)) (e (sprint--db-match text)))
          (push (list (and e (plist-get e :cat)) text state) res)))
       ((and (string-match "\\`- \\([^:]+\\): \\(.*\\)\\'" line)
             (not (equal (match-string 1 line) "Targets")))
        (let ((cat (match-string 1 line)))
          (dolist (seg (split-string (match-string 2 line) "; " t)) (push (list cat seg nil) res))))))
    (nreverse res)))

(defun sprint--picks-from-body (body)
  "DB plists of the exercises of session BODY."
  (delq nil (mapcar (lambda (en) (sprint--db-match (nth 1 en))) (sprint--body-entries body))))

(defun sprint--schedule-sessions ()
  "Sessions of the (widened) schedule buffer: list of plists (:abs :cns :content :picks :state :beg :body-beg :end)."
  (save-excursion
    (save-restriction
      (widen)
      (goto-char (point-min))
      (let (res)
        (while (re-search-forward
                "^\\*\\* \\(TODO\\|NEXT\\|IN-WORK\\|DONE\\|SKIPPED\\) \\[\\([^]]+\\)\\] \\(.*?\\)\\(?:[ \t]+\\[[0-9]*/[0-9]*\\]\\)?\\(?:[ \t]+:[[:alnum:]_@#%:]+:\\)?[ \t]*$"
                nil t)
          (let* ((state (match-string 1)) (cns (match-string 2)) (content (match-string 3))
                 (beg (match-beginning 0))
                 (abs (progn (forward-line 1)
                             (and (looking-at "\\(?:CLOSED: \\[[^]\n]*\\] +\\)?SCHEDULED: <\\([0-9-]+\\)")
                                  (sprint--abs (match-string 1)))))
                 (body-beg (progn (forward-line 1) (point)))
                 (end (save-excursion (if (re-search-forward "^\\*\\{1,2\\} " nil t) (match-beginning 0) (point-max)))))
            (push (list :abs abs :cns cns :content content :state state :beg beg
                        :body-beg body-beg :end end
                        :picks (sprint--picks-from-body (buffer-substring-no-properties body-beg end)))
                  res)
            (goto-char body-beg)))
        (nreverse res)))))

(defun sprint--schedule-year ()
  (if (and buffer-file-name (string-match "sprint_schedule_\\([0-9]+\\)\\.org" buffer-file-name))
      (string-to-number (match-string 1 buffer-file-name))
    (sprint-season)))

(defmacro sprint--with-session-at-point (&rest body)
  "Run BODY on the open schedule session at point, with the generator state rebuilt.
BODY sees `me' (the session plist), `w' (its week record), `cfg', `week-n',
`content' (the session text without the deload prefix), `cap' (its CNS cap) and
`used' (hash of the exercises already in the session); the spacing rules see the
other sessions of the schedule."
  (declare (indent 0) (debug t))
  `(save-excursion
     (end-of-line)
     (unless (re-search-backward "^\\*\\* " nil t) (user-error "Not on a session"))
     (let* ((pos (point))
            (year (sprint--schedule-year))
            (cfg (sprint-config year))
            (sprint--db nil)
            (sessions (sprint--schedule-sessions))
            (me (cl-find-if (lambda (s) (= (plist-get s :beg) pos)) sessions)))
       (unless me (user-error "Not on a session"))
       (when (member (plist-get me :state) '("DONE" "SKIPPED"))
         (user-error "Session is already %s" (plist-get me :state)))
       (let* ((week-n (save-excursion (org-back-to-heading t)
                                      (while (org-up-heading-safe))
                                      (string-to-number (or (org-entry-get nil "WEEK") "0"))))
              (sprint--overrides (sprint--read-overrides year))
              (sprint--all-weeks (sprint--apply-week-overrides (sprint--weeks cfg)))
              (w (cl-find week-n sprint--all-weeks :key (lambda (x) (plist-get x :n))))
              (content (replace-regexp-in-string "\\`DELOAD −50% volume: " "" (plist-get me :content)))
              (cap (sprint--cns-cap (plist-get me :cns)))
              (others (cl-remove me sessions))
              (sprint--split-active (sprint--split-p cfg))
              (sprint--day-log (mapcar (lambda (s) (list (plist-get s :abs) (plist-get s :cns) (plist-get s :picks)
                                                         (and sprint--split-active
                                                              (if (string-match-p "\\`\\(?:DELOAD −50% volume: \\)?Gym: " (plist-get s :content))
                                                                  'gym 'track))))
                                       others))
              (sprint--planned
               (delq nil (mapcar (lambda (s)
                                   (let* ((cats (sprint--content-categories (plist-get s :content)))
                                          (fl (append (and (member "Max Velocity" cats) (list "max-velocity"))
                                                      (and (cl-some (lambda (c) (string-prefix-p "Special Endurance" c)) cats)
                                                           (list "special-endurance")))))
                                     (and fl (cons (plist-get s :abs) fl))))
                                 others))))
         (unless w (user-error "Week %s not in the calendar" week-n))
         (let* ((sprint--usage (make-hash-table :test #'equal))
                (sprint--streak nil)
                (sprint--fv-ctx (list :phase (plist-get w :phase) :cfg cfg :week (plist-get w :n)))
                (sprint--nonce (+ 1 sprint--nonce (random 1000)))
                (sprint--tctx (ignore-errors (sprint--target-ctx year t)))
                (sprint--session-picks nil)
                (sprint--current-abs (plist-get me :abs))
                (sprint--venue (cond ((and sprint--split-active (string-prefix-p "Gym: " content)) 'gym)
                                     ((not (sprint--track-day-p cfg (plist-get me :abs))) 'outside)
                                     (sprint--split-active 'track)))
                (sprint-unavailable-equipment
                 (append sprint-unavailable-equipment
                         (let ((u (sprint--get cfg "EQUIPMENT_UNAVAILABLE" "none")))
                           (and (not (equal u "none")) (split-string u "[|,]" t "[ \t]+")))))
                (used (make-hash-table :test #'equal)))
           (ignore cap content)
           (dolist (e (plist-get me :picks)) (puthash (plist-get e :name) t used))
           ,@body)))))

(defun sprint--lock-week-at-point ()
  (save-excursion
    (org-back-to-heading t) (while (org-up-heading-safe))
    (org-set-property "LOCKED" "yes")))

;;;###autoload
(defun sprint-reroll-session ()
  "Draw new exercises for the session at point (same categories, rules respected).
The week is locked afterwards so regeneration keeps the new draw."
  (interactive)
  (sprint--with-session-at-point
    (let ((body (sprint--fill-session w cfg (plist-get me :cns) content used)))
      (unless body (user-error "No exercises to draw for this session"))
      (goto-char (plist-get me :body-beg))
      (delete-region (plist-get me :body-beg) (plist-get me :end))
      (insert body)
      (sprint--lock-week-at-point)
      (message "Session redrawn; week %d locked" week-n))))

(defun sprint--swap-candidates (cat seg w cfg cap used)
  "Alist (LABEL . TEXT) of replacements for exercise segment SEG of category CAT, fitting ones first."
  (let* ((deload (equal (plist-get w :type) "DELOAD"))
         (cands (cl-remove-if
                 (lambda (e) (or (not (equal (plist-get e :cat) cat))
                                 (string-prefix-p (plist-get e :name) seg)
                                 (cl-some (lambda (re) (string-match-p re (plist-get e :equip)))
                                          sprint-unavailable-equipment)))
                 (sprint--db)))
         (rows (mapcar
                (lambda (e)
                  (let* ((why (or (and (> (sprint--cns-rank (plist-get e :cns)) cap)
                                       (format "CNS %s above the day" (plist-get e :cns)))
                                  (and (gethash (plist-get e :name) used) "already in this session")
                                  (and (sprint--avoided-p e w cfg) "avoided in this block (AVOID_…)")
                                  (sprint--rule-violation e sprint--current-abs)
                                  (sprint--regime-violation e (plist-get w :phase))))
                         (p (sprint--lift-prescription e w cfg deload))
                         (v (plist-get e :vol))
                         (text (cond (p (format "%s %s" (plist-get e :name) p))
                                     ((and (equal cat "Extensive Tempo") (sprint--volume-amount cat w cfg deload))
                                      (format "%s %d m total (65–75%%)" (plist-get e :name)
                                              (sprint--volume-amount cat w cfg deload)))
                                     ((and v (not (string-empty-p v)))
                                      (format "%s %s" (plist-get e :name)
                                              (sprint--scale-vol (sprint--scale-sets v (sprint--vol-factor cat (plist-get w :n))) deload)))
                                     (t (plist-get e :name)))))
                    (list why (if why (format "%s   [! %s]" text why) text) text)))
                cands)))
    (mapcar (lambda (r) (cons (nth 1 r) (nth 2 r)))
            (append (cl-remove-if #'car rows) (cl-remove-if-not #'car rows)))))

;;;###autoload
(defun sprint-swap-exercise ()
  "Replace one exercise of the bullet line at point by another of the same category.
Candidates that fit the day and the rules come first; the others say why they do
not.  The week is locked so regeneration keeps the change."
  (interactive)
  (let* ((line (buffer-substring-no-properties (line-beginning-position) (line-end-position)))
         (lbeg (line-beginning-position))
         (head (and (string-match "\\`\\(\\*\\*\\*+ \\(?:\\(?:TODO\\|NEXT\\|IN-WORK\\|DONE\\|SKIPPED\\) \\)?\\)\\(.*?\\)[ \t]*\\'" line)
                    (cons (match-string 1 line) (match-string 2 line)))))
    (unless (or head
                (and (string-match "\\`- \\([^:]+\\): \\(.*\\)\\'" line)
                     (not (equal (match-string 1 line) "Targets"))))
      (user-error "Put point on an exercise of a session"))
    (let* ((cat (if head (plist-get (or (sprint--db-match (cdr head)) (user-error "%s is not in the exercise DB" (cdr head))) :cat)
                  (match-string 1 line)))
           (segs (if head (list (cdr head)) (split-string (match-string 2 line) "; " t)))
           (seg (if (cdr segs) (completing-read "Replace: " segs nil t) (car segs))))
      (sprint--with-session-at-point
        (let* ((cands (sprint--swap-candidates cat seg w cfg cap used))
               (choice (if cands (completing-read (format "Replace %s with: " seg) (mapcar #'car cands) nil t)
                         (user-error "No other %s exercises in the DB" cat)))
               (text (cdr (assoc choice cands))))
          (goto-char lbeg)
          (delete-region lbeg (line-end-position))
          (insert (if head (concat (car head) text)
                    (format "- %s: %s" cat (mapconcat #'identity
                                                       (mapcar (lambda (s) (if (equal s seg) text s)) segs)
                                                       "; "))))
          ;; the How line under it now describes the new exercise
          (when head
            (let* ((b (line-beginning-position))
                   (e (save-excursion (forward-line 1)
                                      (if (re-search-forward "^\\*" nil t) (match-beginning 0) (point-max))))
                   (new (sprint--annotate-how (buffer-substring-no-properties b e))))
              (delete-region b e)
              (goto-char b)
              (insert new)
              (goto-char b)))
          (sprint--lock-week-at-point)
          (message "%s → %s; week %d locked" seg text week-n))))))

;;;###autoload
(defun sprint-reroll-week ()
  "Redraw every open session of the week at point; locks the week."
  (interactive)
  (save-excursion
    (org-back-to-heading t) (while (org-up-heading-safe))
    (let ((end (save-excursion (org-end-of-subtree t t) (point))) (n 0))
      (org-back-to-heading t)
      (while (re-search-forward "^\\*\\* \\(TODO\\|NEXT\\|IN-WORK\\) " end t)
        (beginning-of-line)
        (ignore-errors (sprint-reroll-session) (cl-incf n))
        (setq end (save-excursion (org-back-to-heading t) (while (org-up-heading-safe))
                                  (org-end-of-subtree t t) (point)))
        (end-of-line))
      (message "%d sessions redrawn" n))))

;;;###autoload
(defun sprint-lock-week ()
  "Toggle :LOCKED: on the week at point in the schedule.
yes: regeneration keeps the week.  no: regeneration rebuilds it even when its
exercises were edited by hand (hand-edited weeks are otherwise locked automatically)."
  (interactive)
  (save-excursion
    (org-back-to-heading t)
    (while (org-up-heading-safe))
    (if (member (org-entry-get nil "LOCKED") '("yes" "t" "true"))
        (progn (org-set-property "LOCKED" "no")
               (message "Week unlocked: regeneration rebuilds it, hand edits included"))
      (org-set-property "LOCKED" "yes") (message "Week locked: regeneration will keep it"))))

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
    ;; 3b. weekday pattern and equipment
    (dolist (d sprint--pattern-days)
      (let ((v (sprint--get cfg (concat "PATTERN_" d))))
        (when (and v (not (member (downcase v) (quote ("template" "gym" "hill" "tempo" "recovery" "rest")))))
          (push (format "PATTERN_%s is %S (use template, gym, hill, tempo, recovery or rest)" d v) msgs))))
    (let ((td (sprint--get cfg "TRACK_DAYS")))
      (when (and td (not (equal (upcase td) "ALL"))
                 (cl-some (lambda (d) (not (assoc d sprint--dow-codes))) (split-string (upcase td) "[ ,]+" t)))
        (push (format "TRACK_DAYS is %S (weekdays like MON WED FRI, or all)" td) msgs)))
    (let ((ff (sprint--get cfg "FORM_FACTOR")))
      (when (and ff (not (and (string-match-p "\\`[0-9]+\\'" ff) (<= 40 (string-to-number ff) 130))))
        (push (format "FORM_FACTOR %S should be a percentage between 40 and 130" ff) msgs)))
    (dolist (spec '(("TARGET_RAMP" "on" "off") ("GYM_NEXT_TO_SPRINT" "medium" "high")))
      (let ((v (sprint--get cfg (car spec))))
        (when (and v (not (member (downcase v) (cdr spec))))
          (push (format "%s is %S (use %s)" (car spec) v (mapconcat #'identity (cdr spec) " or ")) msgs))))
    (dolist (k '("ROTATION_WEEKS" "PROGRESS_FROM_PCT"))
      (let ((v (sprint--get cfg k)))
        (when (and v (not (string-match-p "\\`[0-9]+\\'" v)))
          (push (format "%s is %S (a whole number)" k v) msgs))))
    (let ((sprint--db nil))
      (dolist (e (sprint--db))
        (when (and (plist-get e :next)
                   (not (cl-find (plist-get e :next) (sprint--db) :key (lambda (x) (plist-get x :name)) :test #'equal)))
          (push (format "DB: PROGRESSION of %s names an unknown exercise %S" (plist-get e :name) (plist-get e :next)) msgs))))
    ;; 4. dates
    (setq msgs (append (reverse (sprint--validate-dates cfg weeks)) msgs))
    (let ((target (sprint--num-of (sprint--get cfg "TARGET_100M")))
          (pb (sprint--num-of (sprint--get cfg "PREV_100M_PB"))))
      (when (and target pb (> pb 0))
        (push (format "INFO: 100m target %.2f s vs PB %.2f s: %.2f s (%.1f%%) to gain"
                      target pb (- pb target) (* 100 (/ (- pb target) pb)))
              msgs)))
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
        (while (re-search-forward (format "^\\(?:CLOSED: \\[[^]\n]*\\] +\\)?SCHEDULED: <%s " day) nil t)
          (save-excursion
            (forward-line -1)
            (when (looking-at "\\*+ \\(?:TODO\\|NEXT\\|IN-WORK\\|DONE\\|SKIPPED\\) \\(.*?\\)\\(?:[ \t]+:[[:alnum:]_@#%:]+:\\)?[ \t]*$")
              (push (replace-regexp-in-string "[ \t]+\\[[0-9]*/[0-9]*\\]\\'" "" (match-string 1)) res)))))
      (if res (mapconcat #'identity (nreverse res) "\n         ") "nothing scheduled"))))

(defconst sprint--capture-fields
  '(("Ss" ("CMJ" "CMJ (cm)") ("RPE" "RPE (1-10)" "7") ("SORENESS" "Soreness (none/mild/acute)" "none")
          ("DURATION_MIN" "Duration (min)"))
    ("St" ("10M" "Flying 10 m (s)") ("30M" "Flying 30 m (s)") ("ACC10" "Standing 10 m (s)")
          ("ACC30" "Standing 30 m (s)") ("CMJ" "CMJ (cm)") ("BROAD_JUMP" "Broad jump (m)")
          ("MB_THROW" "Overhead back MB throw (m)") ("SQUAT_3RM" "Squat 3RM (kg)")
          ("TBDL_3RM" "Trap bar DL 3RM (kg)") ("PCLEAN_1RM" "Power clean 1RM (kg)"))
    ("Sd" ("REASON" "Why not as planned (e.g. holiday, ill, no track)") ("INSTEAD" "What you did instead (empty = nothing)")
          ("DURATION_MIN" "Duration (min)") ("RPE" "RPE (1-10)"))
    ("Sr" ("MEET" "Meet") ("EVENT" "Event" "100m") ("ROUND" "Round" "Final") ("TIME" "Time (s)" "" required)
          ("WIND" "Wind (m/s)") ("PLACE" "Place")))
  "Fill-in fields of the sprint captures: KEY then (PROPERTY LABEL [DEFAULT]).
The capture shows them as \"- LABEL :: value\" lines (easy to fill on a phone);
on save they become properties, empty ones are dropped.")

(defun sprint--capture-form (key)
  "Fill-in lines of capture KEY, with the cursor on the first one."
  (let ((first t))
    (mapconcat (lambda (f)
                 (prog1 (format "- %s :: %s%s\n" (nth 1 f) (or (nth 2 f) "") (if first "%?" ""))
                   (setq first nil)))
               (cdr (assoc key sprint--capture-fields)) "")))

(defun sprint--capture-fields-to-properties ()
  "Turn the \"- LABEL :: value\" lines of a sprint capture into properties."
  (let ((fields (cdr (assoc (org-capture-get :key) sprint--capture-fields))))
    (goto-char (point-min)) (org-back-to-heading t)
    (dolist (f fields)
      (when (and (eq (nth 3 f) 'required)
                 (not (save-excursion
                        (re-search-forward (format "^- %s ::[ \t]*\\(\\S-.*\\)$" (regexp-quote (nth 1 f))) nil t))))
        (user-error "Fill in \"%s\", then C-c C-c" (nth 1 f))))
    (dolist (f fields)
      (save-excursion
        (when (re-search-forward (format "^- %s ::[ \t]*\\(.*\\)\n?" (regexp-quote (nth 1 f))) nil t)
          (let ((v (string-trim (match-string-no-properties 1))))
            (replace-match "" t t)
            (unless (string-empty-p v) (org-set-property (car f) v))))))))

(defun sprint--capture-templates ()
  `(("S" "Sprint training")
    ("Ss" "Sprint session (quick, without exercises)" entry (file+olp+datetree sprint--log-file)
     ,(concat "* Session %<%H:%M>\n:PROPERTIES:\n"
              ":WEEK: %(sprint--ctx-field :n)\n"
              ":PHASE: %(sprint--phase-id)\n"
              ":WEEKTYPE: %(sprint--ctx-field :type)\n:END:\n"
              (sprint--capture-form "Ss")
              "Planned: %(sprint--planned-today)\n")
     :empty-lines 1)
    ("St" "Test result" entry (file+headline sprint--log-file "Testing Battery")
     ,(concat "* Test %T\n:PROPERTIES:\n:PHASE: %(sprint--phase-id)\n:END:\n"
              "# Fill in what you tested (leave the rest empty), then C-c C-c\n"
              (sprint--capture-form "St"))
     :empty-lines 1)
    ("Sd" "Not as planned today (skipped / did something else)" entry (file+olp+datetree sprint--log-file)
     ,(concat "* Not as planned %<%H:%M>\n:PROPERTIES:\n"
              ":WEEK: %(sprint--ctx-field :n)\n:PHASE: %(sprint--phase-id)\n"
              ":PLANNED: %(sprint--planned-today-line)\n:END:\n"
              (sprint--capture-form "Sd"))
     :empty-lines 1)
    ("Sr" "Race result" entry (file+headline sprint--log-file "Races")
     ,(concat "* Race %T\n:PROPERTIES:\n:PHASE: %(sprint--phase-id)\n:END:\n"
              (sprint--capture-form "Sr"))
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
         (prev (cl-remove-if (lambda (p) (and (null (car p)) (null (cadr p))))
                        (sprint--entries-before (point) '("RPE" "CMJ_PCT"))))
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

(defun sprint--planned-today-line ()
  (replace-regexp-in-string "\n *" " | " (sprint--planned-today)))

(defun sprint--finalize-not-planned ()
  "Mark today's open sessions SKIPPED (with the reason) for a \"not as planned\" entry."
  (goto-char (point-min)) (org-back-to-heading t)
  (sprint--drop-empty-properties)
  (let* ((reason (or (org-entry-get nil "REASON") "not as planned"))
         (instead (org-entry-get nil "INSTEAD"))
         (abs (sprint--today))
         (sched (find-file-noselect (sprint-file 'schedule)))
         (n 0))
    (org-set-property "DATE" (sprint--str abs))
    (org-set-property "STATUS" (if instead "REPLACED" "SKIPPED"))
    (with-current-buffer sched
      (dolist (s (reverse (sprint--schedule-sessions)))
        (when (and (eql (plist-get s :abs) abs) (member (plist-get s :state) '("TODO" "NEXT" "IN-WORK")))
          (save-excursion
            (goto-char (plist-get s :beg))
            (let ((end (save-excursion (org-end-of-subtree t t) (point))))
              (save-excursion (forward-line 1)
                              (while (re-search-forward "^\\*\\*\\* \\(TODO\\|NEXT\\|IN-WORK\\) " end t)
                                (org-todo "SKIPPED") (end-of-line)
                                (setq end (save-excursion (goto-char (plist-get s :beg)) (org-end-of-subtree t t) (point))))))
            (org-todo "SKIPPED")
            (org-set-property "SKIP_REASON" (if instead (format "%s; did instead: %s" reason instead) reason)))
          (cl-incf n)))
      (save-buffer))
    (message "%s" (if (> n 0) (format "%d planned session%s marked SKIPPED (%s)" n (if (= n 1) "" "s") reason)
                     "Stored (nothing was planned today)"))))

(defun sprint--finalize-race ()
  (goto-char (point-min)) (org-back-to-heading t)
  (let ((wind (sprint--num (replace-regexp-in-string "\\`+" "" (or (org-entry-get nil "WIND") "")))))
    (sprint--drop-empty-properties)
    (org-set-property "LEGAL" (if (and wind (> wind 2.0)) "no" "yes"))))

(defconst sprint--test-ranges
  '(("10M" 0.7 2.0 "s") ("30M" 2.4 5.0 "s") ("ACC10" 1.3 3.0 "s") ("ACC30" 3.3 6.0 "s")
    ("CMJ" 10 90 "cm") ("BROAD_JUMP" 1.0 4.0 "m") ("MB_THROW" 3 25 "m")
    ("SQUAT_3RM" 20 350 "kg") ("TBDL_3RM" 20 400 "kg") ("PCLEAN_1RM" 20 250 "kg"))
  "Plausible ranges of the test results; a value outside stops the capture.")

(defun sprint--finalize-test ()
  "Drop empty fields of a test capture; refuse implausible values (they would become targets)."
  (goto-char (point-min)) (org-back-to-heading t)
  (sprint--drop-empty-properties)
  (let (bad)
    (dolist (r sprint--test-ranges)
      (let* ((raw (org-entry-get nil (car r)))
             (v (and raw (sprint--num (replace-regexp-in-string "," "." raw)))))
        (when (and raw (or (null v) (< v (nth 1 r)) (> v (nth 2 r))))
          (push (format "%s = %s (expected %g–%g %s)" (car r) raw (nth 1 r) (nth 2 r) (nth 3 r)) bad))))
    (when bad
      (user-error "Check %s, then C-c C-c again (or C-c C-k to cancel)"
                  (mapconcat #'identity (nreverse bad) "; ")))))

(defun sprint--prepare-finalize ()
  ;; C-c C-k (cancel) also runs this hook: no checks then
  (unless org-note-abort (sprint--prepare-finalize-1)))

(defun sprint--prepare-finalize-1 ()
  (when (member (org-capture-get :key) '("Ss" "St" "Sr" "Sd"))
    (sprint--capture-fields-to-properties)
    (save-excursion (goto-char (point-min))
                    (while (re-search-forward "^# Fill in what you tested.*\n" nil t) (replace-match ""))))
  (pcase (org-capture-get :key)
    ("Sd" (sprint--finalize-not-planned))
    ("Ss" (sprint--finalize-session))
    ("St" (sprint--finalize-test))
    ("Sr" (sprint--finalize-race))))

(add-hook 'org-capture-prepare-finalize-hook #'sprint--prepare-finalize)

(defun sprint--after-capture ()
  "After a stored test, rebuild the schedule so its target times follow the new results."
  (when (and (equal (org-capture-get :key) "St") (not org-note-abort))
    (sprint-generate-schedule)
    (message "Test stored; target times in the schedule updated")))

(add-hook 'org-capture-after-finalize-hook #'sprint--after-capture)
(advice-add 'org-capture :before #'sprint--ensure-templates)
(setq org-capture-templates (cl-remove-if (lambda (e) (string-prefix-p "S" (car e))) org-capture-templates))
(sprint--ensure-templates)

;;;; Today, agenda

;;;###autoload
(defun sprint-show-today (&optional date)
  "Show today's (or DATE's) training in its own buffer, exercises ready to tick off.
The buffer is a view of the schedule: C-c C-t on an exercise marks it, SPC o S L
logs the session, SPC o S d records that the day went differently."
  (interactive)
  (let* ((abs (if date (sprint--abs date) (sprint--today)))
         (year (sprint-season))
         (sched (find-file-noselect (sprint-file 'schedule year)))
         (sessions (with-current-buffer sched
                     (cl-remove-if-not (lambda (s) (eql (plist-get s :abs) abs)) (sprint--schedule-sessions))))
         (ctx (sprint-context abs year))
         (name "*Sprint today*"))
    (when (get-buffer name) (kill-buffer name))
    (if (null sessions)
        (message "%s %s: nothing planned — free day" (aref sprint--dow-names (sprint--dow abs)) (sprint--short-date abs))
      (let ((buf (make-indirect-buffer sched name t)))
        (with-current-buffer buf
          (widen)
          (narrow-to-region (plist-get (car sessions) :beg)
                            (save-excursion (goto-char (plist-get (car (last sessions)) :beg))
                                            (org-end-of-subtree t t) (point)))
          (if (fboundp 'org-fold-show-all) (org-fold-show-all) (outline-show-all))
          (setq header-line-format
                (format " %s %s · week %s · %s · C-c C-t tick · SPC o S L log · SPC o S d not as planned"
                        (aref sprint--dow-names (sprint--dow abs)) (sprint--short-date abs)
                        (or (plist-get ctx :n) "-") (sprint--phase-label ctx)))
          (goto-char (point-min)))
        (pop-to-buffer-same-window buf)
        buf))))

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
      ;; tested maxima replace the estimates, so the form reduction no longer applies
      (when (and (cl-some (lambda (s) (string-match-p "1RM" (car s))) stats)
                 (sprint--get cfg "FORM_FACTOR"))
        (sprint--set-macro "FORM_FACTOR" "100"))
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
  (format "#+TITLE: Sprint Log %d\n#+STARTUP: overview\n#+OPTIONS: prop:t toc:2 author:nil\n#+TODO: TODO | DONE\n\n* Testing Battery\n* Races\n" year))

;;;; Exercise-level logging, reports and CSV (Milestone 2)
;;
;; `sprint-log' walks through the exercises planned for a day and stores one
;; heading per exercise under the session entry of the log:
;;
;;   **** Session 18:30                       (WEEK PHASE DATE CMJ RPE ... READINESS)
;;   ***** Back Squat                         (STATUS PLAN SETS_DONE TONNAGE EST_1RM ...)
;;   ***** Flying 10m                         (STATUS PLAN TIMES DIST_M TARGET_S HITS ...)
;;
;; Answers per exercise: RET = done as planned · s [why] = skipped · m <note> =
;; modified (then the actuals) · or the actuals directly: kg×reps per set
;; (100x5 105x5 105x4, or 100x5x3) for lifts, times in seconds (3.64 3.61) for sprints.

(defvar sprint--scripted-answers :none
  "Test hook: a list of answers used instead of prompting, or :none.")

(defun sprint--ask (prompt &optional initial)
  (if (eq sprint--scripted-answers :none)
      (read-string prompt initial)
    (or (pop sprint--scripted-answers) "")))

(defun sprint--parse-times (s)
  "Times in seconds from \"3.64 3.61;3.66\" (comma is a decimal mark)."
  (delq nil (mapcar (lambda (x)
                      (and (string-match-p "\\`[0-9]+\\(?:[.,][0-9]+\\)?\\'" x)
                           (string-to-number (replace-regexp-in-string "," "." x))))
                    (split-string s "[ \t;]+" t))))

(defun sprint--parse-sets (s &optional default-kg)
  "List of (KG . REPS) from \"100x5 105x5 105x4\" or \"100x5x3\" (three sets of 5).
With DEFAULT-KG a bare number is the reps of one set at that load (\"5 5 4\")."
  (let (res)
    (dolist (tok (split-string s "[ \t;]+" t))
      (cond
       ((string-match "\\`\\([0-9]+\\(?:[.,][0-9]+\\)?\\)[x×]\\([0-9]+\\)\\(?:[x×]\\([0-9]+\\)\\)?\\'" tok)
        (let ((kg (string-to-number (replace-regexp-in-string "," "." (match-string 1 tok))))
              (reps (string-to-number (match-string 2 tok)))
              (n (if (match-string 3 tok) (string-to-number (match-string 3 tok)) 1)))
          (dotimes (_ n) (push (cons kg reps) res))))
       ((and default-kg (string-match-p "\\`[0-9]+\\'" tok))
        (push (cons default-kg (string-to-number tok)) res))))
    (nreverse res)))

(defun sprint--est-1rm (kg reps)
  "Brzycki estimate of the 1RM from KG × REPS (nil beyond 10 reps)."
  (and (> kg 0) (<= 1 reps 10) (/ (* kg 36.0) (- 37 reps))))

(defun sprint--sets-summary (sets)
  "Plist (:tonnage :best :est1rm) of SETS ((kg . reps) ...)."
  (let ((ton 0) (best nil) (est nil))
    (dolist (s sets)
      (cl-incf ton (* (car s) (cdr s)))
      (when (or (null best) (> (car s) (car best))) (setq best s))
      (let ((e (sprint--est-1rm (car s) (cdr s))))
        (when (and e (or (null est) (> e est))) (setq est e))))
    (list :tonnage ton :best best :est1rm est)))



(defun sprint--item-distance (name rx)
  (or (nth 2 rx)
      (and (string-match "\\`\\([0-9]+\\)m " name) (string-to-number (match-string 1 name)))
      (and (string-match "Flying \\([0-9]+\\)m" name) (string-to-number (match-string 1 name)))))

(defun sprint--parse-plan-item (cat seg)
  "Plist for one exercise segment SEG (category CAT) of a schedule bullet."
  (let* ((best nil))
    (dolist (x (sprint--db))
      (when (and (string-prefix-p (plist-get x :name) seg)
                 (or (null best) (> (length (plist-get x :name)) (length (plist-get best :name)))))
        (setq best x)))
    (let* ((name (if best (plist-get best :name) seg))
           (rest (string-trim (substring seg (length name))))
           (rx (sprint--parse-rx rest))
           (dist (sprint--item-distance name rx))
           (timed (and dist (member cat sprint--timed-categories) t))
           (kg (and (string-match "(≈ \\([0-9.]+\\) kg)" rest) (string-to-number (match-string 1 rest))))
           (pct (and (string-match "@ \\([0-9.]+\\)%" rest) (string-to-number (match-string 1 rest)))))
      (list :name name :cat cat :text rest :sets (nth 0 rx) :reps (nth 1 rx) :dist dist
            :timed timed :kg kg :pct pct :flags (plist-get best :flags)))))

(defun sprint--plan-items (body)
  "Planned exercise items of schedule session BODY (with their :state)."
  (mapcar (lambda (en) (append (sprint--parse-plan-item (or (nth 0 en) "") (nth 1 en)) (list :state (nth 2 en))))
          (sprint--body-entries body)))

(defun sprint--planned-reps (item)
  "Number of timed reps planned for ITEM (sets × reps)."
  (let ((s (or (plist-get item :sets) 1)) (r (or (plist-get item :reps) 1)))
    (* s r)))

;; Target times
;;
;; Flying reps are scored against the flying 10 m / 30 m test (linear between the
;; two splits), standing-start accelerations against the standing 10 m / 30 m
;; test.  While TARGET_100M is not reached the flying targets also ramp: from
;; the first test they tighten week by week toward the flying speed the 100 m
;; target needs (via TEST_TO_100M_SENS_PCT), reaching it in the championship
;; week; a target is never slower than your best test.  Applied TARGET
;; overrides multiply the target times (1.03 = 3 % easier).

(defun sprint--tests (&optional year)
  "Testing Battery entries of the log, oldest first: plists (:date :fly10 :fly30 :acc10 :acc30)."
  (let ((log (sprint-file 'log year)) res)
    (when (file-exists-p log)
      (with-temp-buffer
        (insert-file-contents log)
        (delay-mode-hooks (org-mode))
        (org-map-entries
         (lambda ()
           (when (equal (car (org-get-outline-path)) "Testing Battery")
             (let ((g (lambda (p) (sprint--num (org-entry-get nil p))))
                   (h (org-get-heading t t t t)))
               (push (list :date (and (string-match "[0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}" h) (match-string 0 h))
                           :fly10 (funcall g "10M") :fly30 (funcall g "30M")
                           :acc10 (funcall g "ACC10") :acc30 (funcall g "ACC30"))
                     res))))
         nil nil)))
    (nreverse res)))

(defun sprint--split-pair (tests k10 k30 pick)
  "(T10 . T30) from TESTS for keys K10/K30: PICK is `best' or `first'."
  (let ((a (delq nil (mapcar (lambda (x) (plist-get x k10)) tests)))
        (b (delq nil (mapcar (lambda (x) (plist-get x k30)) tests))))
    (and a b (if (eq pick 'best) (cons (apply #'min a) (apply #'min b)) (cons (car a) (car b))))))

(defun sprint--interp (pair dist)
  (max 0.1 (+ (car pair) (* (- dist 10) (/ (- (cdr pair) (car pair)) 20.0)))))

(defun sprint--target-ctx (&optional year provisional)
  "Everything the target times depend on, computed once per log/report run.
With PROVISIONAL and no standing-start test yet, PREV_10M_PB / PREV_30M_PB stand in
for it (marked :acc-provisional); used only for the indications in the schedule."
  (let* ((cfg (sprint-config year))
         (tests (sprint--tests year))
         (weeks (sprint--weeks cfg))
         (week-of (lambda (date) (and (sprint--date-p date)
                                       (plist-get (cl-find-if (lambda (w) (and (>= (sprint--abs date) (plist-get w :start))
                                                                               (< (sprint--abs date) (+ 7 (plist-get w :start)))))
                                                              weeks)
                                                  :n))))
         (first-fly (cl-find-if (lambda (x) (and (plist-get x :fly10) (plist-get x :fly30))) tests))
         (pb (sprint--num-of (sprint--get cfg "PREV_100M_PB")))
         (goal (sprint--num-of (sprint--get cfg "TARGET_100M")))
         (sens (/ (sprint--int cfg "TEST_TO_100M_SENS_PCT" 60) 100.0))
         (status (ignore-errors (sprint-target-status year)))
         (ramp (and first-fly pb goal (> pb goal) (> sens 0)
                    (not (equal (sprint--get cfg "TARGET_RAMP" "on") "off"))
                    (not (and status (plist-get status :reached)))
                    (min 0.10 (/ (/ (- pb goal) pb) sens)))))
    (list :tests tests :cfg cfg :overrides (sprint--read-overrides year)
          :fly-best (sprint--split-pair tests :fly10 :fly30 'best)
          :fly-first (and first-fly (cons (plist-get first-fly :fly10) (plist-get first-fly :fly30)))
          :acc-best (or (sprint--split-pair tests :acc10 :acc30 'best)
                        (and provisional
                             (let ((a (sprint--num-of (sprint--get cfg "PREV_10M_PB")))
                                   (b (sprint--num-of (sprint--get cfg "PREV_30M_PB"))))
                               (and a b (cons a b)))))
          :acc-provisional (and provisional (not (sprint--split-pair tests :acc10 :acc30 'best)))
          :ramp ramp
          :ramp-from (and first-fly (funcall week-of (plist-get first-fly :date)))
          :ramp-to (or (funcall week-of (sprint--get cfg "OUTDOOR_CHAMPIONSHIP"))
                       (plist-get (car (last weeks)) :n)))))

(defun sprint--target-for (item week tctx)
  "Target time in seconds for planned ITEM in WEEK, or nil (see the comment above)."
  (let* ((name (plist-get item :name)) (dist (plist-get item :dist))
         (factor (let ((sprint--overrides (plist-get tctx :overrides)))
                   (sprint--override-factor "TARGET" week)))
         (base
          (cond
           ((not (and dist (plist-get item :timed))) nil)
           ((string-match-p "\\`Flying" name)
            (let ((best (and (plist-get tctx :fly-best) (sprint--interp (plist-get tctx :fly-best) dist)))
                  (ramp (plist-get tctx :ramp)))
              (if (and best ramp week (plist-get tctx :ramp-from) (plist-get tctx :ramp-to)
                       (> (plist-get tctx :ramp-to) (plist-get tctx :ramp-from)))
                  (let ((frac (max 0.0 (min 1.0 (/ (float (- week (plist-get tctx :ramp-from)))
                                                   (- (plist-get tctx :ramp-to) (plist-get tctx :ramp-from)))))))
                    (min best (* (sprint--interp (plist-get tctx :fly-first) dist) (- 1 (* ramp frac)))))
                best)))
           ((and (equal (plist-get item :cat) "Acceleration") (string-match-p "\\`[0-9]+m " name)
                 (not (member "heavy-resisted" (plist-get item :flags))))
            (and (plist-get tctx :acc-best) (sprint--interp (plist-get tctx :acc-best) dist))))))
    (and base (* base factor))))

(defun sprint--ask-exercise (item)
  "Prompt for ITEM; return a record plist (:status :note :times :sets)."
  (let* ((name (plist-get item :name)) (timed (plist-get item :timed))
         (lift (or (plist-get item :kg) (string-prefix-p "Strength" (plist-get item :cat))))
         (prompt (format "%s %s — RET done · s skip · m note · or %s: "
                         name (plist-get item :text)
                         (cond (timed (let ((tg (plist-get item :target)))
                                        (if tg (format "times (s, target %.2f)" tg) "times (s)")))
                               ((plist-get item :kg) "kg×reps or reps per set")
                               (lift "kg×reps per set")
                               (t "result"))))
         (ans (string-trim (sprint--ask prompt)))
         (status "DONE") note times sets)
    (cond
     ((string-empty-p ans)
      (when (and (plist-get item :kg) (plist-get item :sets) (plist-get item :reps))
        (setq sets (cl-loop repeat (plist-get item :sets) collect (cons (plist-get item :kg) (plist-get item :reps))))))
     ((string-match "\\`s\\(?:kip\\)?\\(?: +\\(.*\\)\\)?\\'" ans)
      (setq status "SKIPPED" note (match-string 1 ans)))
     (t
      (when (string-match "\\`m\\(?:od\\)?\\(?: +\\(.*\\)\\)?\\'" ans)
        (setq status "MODIFIED" note (match-string 1 ans)
              ans (string-trim (sprint--ask (format "  actuals for %s (RET none): " name)))))
      (cond
       (timed
        (setq times (sprint--parse-times ans))
        (let ((n (sprint--planned-reps item)) (k (length times)))
          (while (and (< k n)
                      (let ((a (string-trim (sprint--ask (format "  rep %d/%d (RET to stop): " (1+ k) n)))))
                        (if (string-empty-p a) nil
                          (setq times (append times (sprint--parse-times a))) t)))
            (setq k (length times)))
          (when (and (equal status "DONE") (< (length times) n)) (setq status "MODIFIED"))))
       (t
        (setq sets (sprint--parse-sets ans (plist-get item :kg)))
        ;; fewer sets than planned: ask for the rest one at a time (RET stops)
        (let ((n (plist-get item :sets)))
          (when (and lift n sets (< (length sets) n))
            (while (and (< (length sets) n)
                        (let ((a (string-trim (sprint--ask (format "  set %d/%d (kg×reps%s, RET to stop): "
                                                                   (1+ (length sets)) n
                                                                   (if (plist-get item :kg) " or reps" ""))))))
                          (unless (string-empty-p a)
                            (setq sets (append sets (sprint--parse-sets a (or (plist-get item :kg) (car (car (last sets)))))))
                            t))))))
        (when (and (null sets) (not (string-empty-p ans))) (setq note (concat (or note "") ans)))
        (when (and (equal status "DONE") (plist-get item :sets)
                   (or (< (length sets) (plist-get item :sets))
                       (cl-some (lambda (s) (< (cdr s) (or (plist-get item :reps) 0))) sets)))
          (setq status "MODIFIED"))))))
    (list :status status :note note :times times :sets sets)))

(defun sprint--format-sets (sets)
  (mapconcat (lambda (s) (format "%gx%d" (car s) (cdr s))) sets " "))

(defun sprint--exercise-entry (level item rec tol)
  "Org text of the exercise heading for ITEM (with its :target) and record REC, at LEVEL."
  (let* ((times (plist-get rec :times)) (sets (plist-get rec :sets))
         (dist (plist-get item :dist))
         (target (plist-get item :target))
         (lift (and (not (plist-get item :timed)) (or sets (plist-get item :kg))))
         (hits (and target times
                    (cl-count-if (lambda (x) (<= x (* target (+ 1 (/ tol 100.0))))) times)))
         (sum (and sets (sprint--sets-summary sets)))
         (props `(("EXERCISE" . ,(plist-get item :name))
                  ("CATEGORY" . ,(plist-get item :cat))
                  ("STATUS" . ,(plist-get rec :status))
                  ("PLAN" . ,(plist-get item :text))
                  ("PLAN_KG" . ,(and (plist-get item :kg) (format "%g" (plist-get item :kg))))
                  ("DIST_M" . ,(and dist (plist-get item :timed) (number-to-string dist)))
                  ("REPS_PLANNED" . ,(and (plist-get item :timed) (number-to-string (sprint--planned-reps item))))
                  ("SETS_PLANNED" . ,(and lift (plist-get item :sets) (number-to-string (plist-get item :sets))))
                  ("REPS_PER_SET" . ,(and lift (plist-get item :reps) (number-to-string (plist-get item :reps))))
                  ("TIMES" . ,(and times (mapconcat (lambda (x) (format "%.2f" x)) times " ")))
                  ("TARGET_S" . ,(and target (format "%.2f" target)))
                  ("HITS" . ,(and hits (number-to-string hits)))
                  ("SETS_DONE" . ,(and sets (sprint--format-sets sets)))
                  ("TONNAGE" . ,(and sum (format "%.0f" (plist-get sum :tonnage))))
                  ("EST_1RM" . ,(and sum (plist-get sum :est1rm) (format "%.1f" (plist-get sum :est1rm))))
                  ("REPS_DONE" . ,(and (plist-get rec :reps-done)
                                       (mapconcat #'number-to-string (plist-get rec :reps-done) " ")))
                  ("DONE_SETS" . ,(plist-get rec :done))
                  ("REPLACED_BY" . ,(plist-get rec :replaced-by))
                  ("REPLACED_SETS" . ,(plist-get rec :replaced-sets))
                  ;; per exercise; the session's own RPE (read by readiness) stays on the session
                  ("EX_RPE" . ,(and (plist-get rec :ex-rpe) (number-to-string (plist-get rec :ex-rpe))))
                  ("DURATION_MIN" . ,(and (plist-get rec :minutes) (number-to-string (plist-get rec :minutes))))
                  ("NOTE" . ,(plist-get rec :note)))))
    (concat (make-string level ?*) " " (plist-get item :name) "\n:PROPERTIES:\n"
            (mapconcat (lambda (p) (and (cdr p) (not (string-empty-p (cdr p)))
                                        (format ":%s: %s\n" (car p) (cdr p))))
                       props "")
            ":END:\n")))

(defun sprint--insert-session-log (abs plan-heading items recs session-props year)
  "Insert a session with exercise children into the log for ABS; return the buffer."
  (let* ((cfg (sprint-config year))
         (tol (sprint--int cfg "TARGET_TOL_PCT" 2))
         (ctx (sprint-context abs year)))
    (with-current-buffer (find-file-noselect (sprint-file 'log year))
      (org-with-wide-buffer
       (org-datetree-find-date-create (calendar-gregorian-from-absolute abs))
       (let ((level (1+ (org-current-level))) (day (point)))
         ;; the same session logged again (a save retried after an error) replaces the old entry
         (let ((end (save-excursion (org-end-of-subtree t t) (point))) olds)
           (while (re-search-forward (format "^%s Session " (regexp-quote (make-string level ?*))) end t)
             (when (equal (org-entry-get nil "PLANNED") plan-heading) (push (line-beginning-position) olds)))
           (dolist (b olds)
             (goto-char b)
             (delete-region b (save-excursion (org-end-of-subtree t t) (point)))))
         (goto-char day)
         (org-end-of-subtree t t)
         (unless (bolp) (insert "\n"))
         (let ((beg (point)))
           (insert (make-string level ?*) (format-time-string " Session %H:%M\n")
                   ":PROPERTIES:\n"
                   (format ":DATE: %s\n:WEEK: %s\n:PHASE: %s\n:WEEKTYPE: %s\n:PLANNED: %s\n"
                           (sprint--str abs)
                           (or (plist-get ctx :n) "-") (sprint--phase-label ctx)
                           (or (plist-get ctx :type) "-") plan-heading)
                   (mapconcat (lambda (p) (and (cdr p) (not (string-empty-p (cdr p)))
                                               (format ":%s: %s\n" (car p) (cdr p))))
                              session-props "")
                   ":END:\n")
           (cl-mapc (lambda (item rec)
                      (insert (sprint--exercise-entry (1+ level) item rec tol)))
                    items recs)
           (save-restriction
             (narrow-to-region beg (point))
             (goto-char (point-min))
             (sprint--finalize-session)))))
      (save-buffer)
      (current-buffer))))

;;;###autoload
(defun sprint-log (&optional date)
  "Log today's (or DATE's) planned session exercise by exercise."
  (interactive)
  (let* ((abs (if date (sprint--abs date) (sprint--today)))
         (year (sprint-season))
         (sched (find-file-noselect (sprint-file 'schedule year)))
         (sessions (with-current-buffer sched
                     (cl-remove-if-not (lambda (s) (and (eql (plist-get s :abs) abs)
                                                        (member (plist-get s :state) '("TODO" "NEXT" "IN-WORK"))))
                                       (sprint--schedule-sessions)))))
    (unless sessions
      (user-error "Nothing open is planned for %s: use SPC o S s for an unplanned session" (sprint--str abs)))
    (let ((s (if (cdr sessions)
                 (let ((c (completing-read "Session: " (mapcar (lambda (x) (plist-get x :content)) sessions) nil t)))
                   (cl-find c sessions :key (lambda (x) (plist-get x :content)) :test #'equal))
               (car sessions))))
      (if (string-prefix-p "TESTING BATTERY" (plist-get s :content))
          ;; a testing day is logged by the test capture; its results become the targets
          (progn (with-current-buffer sched
                   (goto-char (plist-get s :beg)) (org-todo "DONE") (save-buffer))
                 (org-capture nil "St"))
        (if (and (eq sprint-log-style 'form) (eq sprint--scripted-answers :none))
            (sprint--log-form s abs year sched)
          (sprint--log-session s abs year sched))))))

(defun sprint--log-session (s abs year sched)
  "Ask for the exercises of schedule session S on day ABS and write them to the log."
  (let* ((body (with-current-buffer sched
                 (buffer-substring-no-properties (plist-get s :body-beg) (plist-get s :end))))
         (tctx (sprint--target-ctx year))
         (week (plist-get (sprint-context abs year) :n))
         (items (mapcar (lambda (it) (append it (list :target (sprint--target-for it week tctx))))
                        (sprint--plan-items body)))
         (recs (mapcar #'sprint--ask-exercise items))
         (props (list (cons "CNS" (plist-get s :cns))
                      (cons "CMJ" (string-trim (sprint--ask "CMJ height (cm, RET none): ")))
                      (cons "RPE" (string-trim (sprint--ask "Session RPE (1-10): ")))
                      (cons "SORENESS" (let ((a (string-trim (sprint--ask "Soreness (none/mild/acute): "))))
                                         (if (string-empty-p a) "none" a)))
                      (cons "DURATION_MIN" (string-trim (sprint--ask "Duration (min): ")))))
         (all-skipped (and recs (cl-every (lambda (r) (equal (plist-get r :status) "SKIPPED")) recs))))
    (sprint--insert-session-log abs (plist-get s :content) items recs props year)
    (with-current-buffer sched
      (sprint--mark-children s recs)
      (goto-char (plist-get s :beg))
      (org-todo (if all-skipped "SKIPPED" "DONE"))
      (save-buffer))
    (message "Logged %d exercises (%s)" (length recs)
             (mapconcat (lambda (st) (format "%d %s" (cl-count st recs :key (lambda (r) (plist-get r :status)) :test #'equal) st))
                        '("DONE" "MODIFIED" "SKIPPED") ", "))))

;; Log form (phone-friendly): one buffer with every planned exercise as a table
;; filled in with the plan, edited at your pace and kept as a synced draft
;; (drafts/ beside the sprint files) until you save it.


(defvar-local sprint--form-key nil "\"DATE | CONTENT\" of the session a log form belongs to.")

(defun sprint--insert-state ()
  "Start typing right away in a form (meow or evil users land in insert state)."
  (cond ((fboundp 'meow-insert-mode) (meow-insert-mode 1))
        ((fboundp 'evil-insert-state) (evil-insert-state))))

(defun sprint--capture-insert-state ()
  (when (member (org-capture-get :key) '("Ss" "St" "Sr" "Sd")) (sprint--insert-state)))

(add-hook 'org-capture-mode-hook #'sprint--capture-insert-state)

(defcustom sprint-log-draft-directory nil
  "Where unsaved log forms are kept, one file per session.
nil = the drafts/ folder beside the sprint files.  It is synced with them, so a
form started on the phone continues on the PC (and back) with SPC o S L."
  :type '(choice (const :tag "drafts/ beside the sprint files" nil) directory))

(defun sprint--log-draft-file (key)
  "Draft file of the log form of the session KEY (\"DATE | CONTENT\")."
  (expand-file-name (format "log_%s_%s.org" (substring key 0 10) (substring (md5 key) 0 6))
                    (or sprint-log-draft-directory (expand-file-name "drafts/" sprint-directory))))

(defun sprint--fresh-buffer (file)
  "Buffer visiting FILE, re-read first when it changed on disk (e.g. synced from the phone).
Never asks; a buffer that is stale and also has unsaved changes is an error."
  (let ((b (get-file-buffer file)))
    (if (null b) (find-file-noselect file)
      (with-current-buffer b
        (unless (or (not (file-exists-p file)) (verify-visited-file-modtime b))
          (if (buffer-modified-p)
              (user-error "%s changed on disk and has unsaved changes here: save or revert it first"
                          (file-name-nondirectory file))
            (revert-buffer t t t))))
      b)))

(defun sprint--session-items (s abs year sched)
  "Planned items of session S on day ABS, with their target times."
  (let* ((body (with-current-buffer sched
                 (buffer-substring-no-properties (plist-get s :body-beg) (plist-get s :end))))
         (tctx (sprint--target-ctx year))
         (week (plist-get (sprint-context abs year) :n)))
    (mapcar (lambda (it) (append it (list :target (sprint--target-for it week tctx))))
            (sprint--plan-items body))))

(defconst sprint--form-session-fields
  '(("CMJ" "CMJ (cm)" "") ("RPE" "RPE (1-10)" "") ("SORENESS" "Soreness (none/mild/acute)" "none")
    ("DURATION_MIN" "Duration (min, empty = from the clock)" ""))
  "Session fields of the log form: (PROPERTY LABEL DEFAULT).")

;; Each exercise of the form is a small table filled in with the plan, one row
;; per set (or per rep for timed runs): only what differed is typed.  A deleted
;; row is a set not done, an empty time a rep run but not timed.

(defun sprint--form-kind (item)
  "How ITEM is logged: `timed' (a time per rep), `lift' (kg and reps per set),
`sets' (one cell per set) or `plain' (one line)."
  (cond ((plist-get item :timed) 'timed)
        ((and (plist-get item :sets) (string-prefix-p "Strength" (or (plist-get item :cat) ""))) 'lift)
        ((plist-get item :sets) 'sets)
        (t 'plain)))

(defun sprint--form-plan (item)
  "The plan text of ITEM without its target time."
  (string-trim (replace-regexp-in-string " · target .*" "" (or (plist-get item :text) ""))))

(defun sprint--per-set-plan (item)
  "What one set of ITEM is (\"8 per side\" for \"3×8 per side\")."
  (string-trim (replace-regexp-in-string "\\`[0-9]+×" "" (sprint--form-plan item))))

(defun sprint--form-table (header rows)
  (concat "| " (mapconcat #'identity header " | ") " |\n|-\n"
          (mapconcat (lambda (r) (concat "| " (mapconcat #'identity r " | ") " |\n")) rows "")))

(defun sprint--form-exercise (i it)
  "Form text of exercise number I (plan item IT)."
  (let* ((plan (sprint--form-plan it))
         (sets (or (plist-get it :sets) 1)) (reps (or (plist-get it :reps) 1))
         (kg (plist-get it :kg)) (n #'number-to-string))
    (concat
     (format "\n* %d · %s\n" i (plist-get it :name))
     (if (string-empty-p plan) "" (format "  plan: %s\n" plan))
     (if (plist-get it :target) (format "  target: %.2f s\n" (plist-get it :target)) "")
     (pcase (sprint--form-kind it)
       ('timed (sprint--form-table '("set" "rep" "time (s)" "note")
                                   (cl-loop for s from 1 to sets
                                            append (cl-loop for r from 1 to reps
                                                            collect (list (funcall n s) (funcall n r) "" "")))))
       ('lift (sprint--form-table '("set" "kg" "reps" "note")
                                  (cl-loop for s from 1 to sets
                                           collect (list (funcall n s) (if kg (format "%g" kg) "") (funcall n reps) ""))))
       ('sets (sprint--form-table '("set" "done" "note")
                                  (cl-loop for s from 1 to sets collect (list (funcall n s) (sprint--per-set-plan it) ""))))
       ('plain (format "- done :: %s\n" plan)))
     (format "- skipped (why) :: %s\n- replaced by :: \n- RPE (1-10) :: \n- note :: \n"
             (if (equal (plist-get it :state) "SKIPPED") "yes" "")))))

(defun sprint--log-form-text (key abs s items &optional targets)
  "Text of a new log form; TARGETS is the session's \"- Targets:\" text, if any."
  (concat
   (format "#+TITLE: Log · %s %s\n#+STARTUP: showall\n#+SESSION: %s\n"
           (aref sprint--dow-names (sprint--dow abs)) (sprint--short-date abs) key)
   (format "# %s\n" (replace-regexp-in-string "\\`DELOAD −50% volume: " "" (plist-get s :content)))
   "# The tables hold the plan: change only what differed.  Delete a row = set not done.\n"
   "# Timed runs: type each time (empty = run, not timed).  Skipped: write why.  Swapped:\n"
   "# the exercise after \"replaced by\", and the table holds what you did instead.\n"
   "# This draft is synced: continue on another device with SPC o S L.  [Save] or C-c C-c stores it.\n\n"
   "* Plan\n"
   (if targets (format "- Targets: %s\n" targets) "")
   (let ((i 0))
     (mapconcat (lambda (it)
                  ;; the schedule line as is, with its target time
                  (let ((plan (string-trim (or (plist-get it :text) ""))))
                    (format "%d. %s%s%s\n" (cl-incf i) (plist-get it :name)
                            (if (string-empty-p plan) "" (concat " " plan))
                            (if (and (plist-get it :target) (not (string-match-p "target" plan)))
                                (format " · target %.2f s" (plist-get it :target)) ""))))
                items ""))
   "\n* Session\n"
   (mapconcat (lambda (f) (format "- %s :: %s\n" (nth 1 f) (nth 2 f))) sprint--form-session-fields "")
   (let ((i 0)) (mapconcat (lambda (it) (sprint--form-exercise (cl-incf i) it)) items ""))
   "\n[Save]    [Cancel]\n"))

(defun sprint--mark-children (s recs)
  "Set the sub-TODO exercises of schedule session S (current buffer) from the log records RECS."
  (save-excursion
    (goto-char (plist-get s :beg))
    (let ((i 0) (end (save-excursion (org-end-of-subtree t t) (point))))
      (forward-line 1)
      (while (and (< i (length recs)) (re-search-forward "^\\*\\*\\* " end t))
        (let ((st (plist-get (nth i recs) :status)))
          (org-todo (if (equal st "SKIPPED") "SKIPPED" "DONE")))
        (cl-incf i)
        (end-of-line)
        (setq end (save-excursion (goto-char (plist-get s :beg)) (org-end-of-subtree t t) (point)))))))

(defun sprint--log-form-buttons ()
  "Make [Save] and [Cancel] in the form tappable."
  (with-silent-modifications
    (save-excursion
      (goto-char (point-min))
      (while (re-search-forward "\\[\\(Save\\|Cancel\\)\\]" nil t)
        (make-text-button (match-beginning 0) (match-end 0)
                          'action (if (equal (match-string 1) "Save")
                                      (lambda (_) (sprint-log-form-save))
                                    (lambda (_) (sprint-log-form-cancel)))
                          'follow-link t 'help-echo "Tap to run")))))

(defvar sprint-log-form-mode-map
  (let ((m (make-sparse-keymap)))
    (define-key m (kbd "C-c C-c") #'sprint-log-form-save)
    (define-key m (kbd "C-c C-k") #'sprint-log-form-cancel)
    m))

(define-minor-mode sprint-log-form-mode
  "Log form of a training session: fill in the tables, then save."
  :lighter " SprintLog" :keymap sprint-log-form-mode-map
  (when sprint-log-form-mode (sprint--log-form-buttons)))

(defun sprint--log-form (s abs year sched)
  "Open (or resume, from whichever device wrote it last) the log form for session S on day ABS."
  (let* ((key (format "%s | %s" (sprint--str abs) (plist-get s :content)))
         (file (sprint--log-draft-file key))
         (resumed (and (file-exists-p file) (> (file-attribute-size (file-attributes file)) 0))))
    (make-directory (file-name-directory file) t)
    (let ((buf (sprint--fresh-buffer file)))
      (with-current-buffer buf
        (unless resumed
          (erase-buffer)
          (insert (sprint--log-form-text
                   key abs s (sprint--session-items s abs year sched)
                   (with-current-buffer sched
                     (save-excursion
                       (goto-char (plist-get s :body-beg))
                       (and (re-search-forward "^- Targets: \\(.*\\)$" (plist-get s :end) t)
                            (match-string-no-properties 1))))))
          (org-table-map-tables #'org-table-align t)
          (save-buffer))
        (setq sprint--form-key key)
        (sprint-log-form-mode 1))
      (pop-to-buffer-same-window buf)
      (goto-char (point-min))
      (re-search-forward "^- CMJ (cm) :: " nil t)
      (sprint--insert-state)
      (message (if resumed
                   (format "Draft of %s resumed: fill in, then [Save] or C-c C-c"
                           (format-time-string "%H:%M" (file-attribute-modification-time (file-attributes file))))
                 "Fill in, then [Save] or C-c C-c"))
      buf)))

(defun sprint--form-field (label beg end)
  "Value after \"- LABEL :: \" between BEG and END (trimmed), or \"\"."
  (save-excursion
    (goto-char beg)
    (if (re-search-forward (format "^- %s ::[ \t]*\\(.*\\)$" (regexp-quote label)) end t)
        (string-trim (match-string-no-properties 1))
      "")))

(defun sprint--form-rows (beg end)
  "Rows of the table between BEG and END as alists (COLUMN . CELL), the header naming the columns."
  (save-excursion
    (goto-char beg)
    (let (header rows)
      (while (re-search-forward "^[ \t]*|\\(.*\\)$" end t)
        (let ((inner (match-string-no-properties 1)))
          (unless (string-match-p "\\`[-+]" inner)
            (let ((cells (mapcar #'string-trim (split-string inner "|"))))
              (when (and cells (string-empty-p (car (last cells)))) (setq cells (butlast cells)))
              (if header (push (cl-mapcar #'cons header cells) rows)
                (setq header (mapcar #'downcase cells)))))))
      (nreverse rows))))

(defun sprint--canonical-exercise (text)
  "The DB name TEXT stands for (same name or a prefix of it, any case), else TEXT."
  (let* ((d (downcase text))
         (e (or (cl-find-if (lambda (e) (equal (downcase (plist-get e :name)) d)) (sprint--db))
                (cl-find-if (lambda (e) (string-prefix-p d (downcase (plist-get e :name)))) (sprint--db)))))
    (if e (plist-get e :name) text)))

(defun sprint--rec-from-table (item beg end)
  "Record plist for ITEM from its part of the form, between BEG and END."
  (let* ((name (plist-get item :name))
         (field (lambda (l) (sprint--form-field l beg end)))
         (skip (funcall field "skipped (why)"))
         (repl (funcall field "replaced by"))
         (ex-rpe (let ((r (funcall field "RPE (1-10)")))
                   (cond ((string-empty-p r) nil)
                         ((and (string-match-p "\\`[0-9]+\\'" r) (<= 1 (string-to-number r) 10)) (string-to-number r))
                         (t (user-error "%s: RPE %S is not a whole number from 1 to 10" (plist-get item :name) r)))))
         (kind (sprint--form-kind item))
         (rows (sprint--form-rows beg end))
         (sets-p (or (plist-get item :sets) 1)) (reps-p (or (plist-get item :reps) 1))
         (kg-p (plist-get item :kg))
         (cell (lambda (row col) (let ((v (cdr (assoc col row)))) (and v (not (string-empty-p v)) v))))
         (notes (delq nil (cons (let ((n (funcall field "note"))) (and (not (string-empty-p n)) n))
                                (mapcar (lambda (r)
                                          (let ((n (funcall cell r "note")))
                                            (and n (if (eq kind 'timed)
                                                       (format "set %s rep %s: %s" (funcall cell r "set") (funcall cell r "rep") n)
                                                     (format "set %s: %s" (funcall cell r "set") n)))))
                                        rows))))
         (status "DONE") times sets reps-done done)
    (if (not (string-empty-p skip))
        (progn (setq status "SKIPPED")
               (unless (member (downcase skip) '("y" "yes" "x" "s" "skip" "skipped")) (push skip notes)))
      (pcase kind
        ('timed
         (dolist (r rows)
           (let ((tm (funcall cell r "time (s)")))
             (when tm
               (setq times (append times (or (sprint--parse-times tm)
                                             (user-error "%s: %S is not a time in seconds" name tm)))))))
         (when (< (length rows) (sprint--planned-reps item)) (setq status "MODIFIED")))
        ('lift
         (dolist (r rows)
           (let* ((k (funcall cell r "kg")) (n (funcall cell r "reps"))
                  (kgv (if k (or (sprint--num (replace-regexp-in-string "," "." k))
                                 (user-error "%s: kg %S is not a number" name k))
                         kg-p))
                  (nv (if n (if (string-match-p "\\`[0-9]+\\'" n) (string-to-number n)
                              (user-error "%s: reps %S is not a whole number" name n))
                        reps-p)))
             (if kgv (push (cons kgv nv) sets) (push nv reps-done))))
         (setq sets (nreverse sets) reps-done (nreverse reps-done))
         (when (or (< (length rows) sets-p)
                   (cl-some (lambda (x) (< (cdr x) reps-p)) sets)
                   (cl-some (lambda (x) (< x reps-p)) reps-done)
                   (and kg-p (cl-some (lambda (x) (< (car x) kg-p)) sets)))
           (setq status "MODIFIED")))
        ('sets
         (let ((plan (sprint--per-set-plan item)))
           (setq done (mapcar (lambda (r) (or (funcall cell r "done") "")) rows))
           (when (or (< (length rows) sets-p) (cl-some (lambda (d) (not (equal d plan))) done))
             (setq status "MODIFIED"))))
        ('plain
         (let ((d (funcall field "done")))
           (unless (equal d (sprint--form-plan item)) (setq status "MODIFIED" done (list d)))))))
    (let ((rec (list :status status :note (and notes (string-join notes "; ")) :ex-rpe ex-rpe)))
      (if (and (not (string-empty-p repl)) (not (equal status "SKIPPED")))
          ;; what was done belongs to the replacement, not to the planned exercise
          (append (list :status "MODIFIED" :note (plist-get rec :note) :ex-rpe ex-rpe
                        :replaced-by (sprint--canonical-exercise repl)
                        :replaced-sets (cond (sets (sprint--format-sets sets))
                                             (reps-done (mapconcat #'number-to-string reps-done " "))
                                             (times (mapconcat (lambda (x) (format "%.2f" x)) times " "))
                                             (done (string-join done "; ")))))
        (append rec (list :times times :sets sets :reps-done reps-done
                          :done (and done (or (equal status "MODIFIED") (/= (length done) sets-p)) ; extra sets too
                                     (string-join done "; "))))))))

(defun sprint--session-clock (s)
  "Clocked minutes of the exercises of schedule session S (current buffer), in order (nil
where not clocked), and the session span in minutes from the first clock-in to the last
clock-out: (MINUTES . SPAN)."
  (save-excursion
    (goto-char (plist-get s :beg))
    (let ((end (save-excursion (org-end-of-subtree t t) (point))) mins first last)
      (forward-line 1)
      (while (re-search-forward "^\\*\\*\\*+ " end t)
        (let ((hend (save-excursion (if (re-search-forward "^\\*" end t) (match-beginning 0) end)))
              (m 0) any)
          (while (re-search-forward "^[ \t]*CLOCK: \\[\\([^]]+\\)\\]--\\[\\([^]]+\\)\\]" hend t)
            (let* ((sa (match-string 1)) (sb (match-string 2)) ; parsing changes the match data
                   (a (float-time (org-time-string-to-time sa)))
                   (b (float-time (org-time-string-to-time sb))))
              (setq any t m (+ m (/ (- b a) 60.0))
                    first (if first (min first a) a) last (if last (max last b) b))))
          (push (and any (round m)) mins)
          (goto-char hend)))
      (cons (nreverse mins) (and first (round (/ (- last first) 60.0)))))))

(defun sprint--clock-out-in (s)
  "Clock out when the running clock is in schedule session S (current buffer)."
  (when (and (fboundp 'org-clocking-p) (org-clocking-p)
             (eq (marker-buffer org-clock-marker) (or (buffer-base-buffer) (current-buffer))))
    (let ((end (save-excursion (goto-char (plist-get s :beg)) (org-end-of-subtree t t) (point))))
      (when (<= (plist-get s :beg) org-clock-marker end)
        (org-clock-out nil t)))))

(defun sprint-log-form-save ()
  "Store the log form in the training log and mark the session done.
Saving again after a failure replaces the entry written by the failed attempt."
  (interactive)
  (let* ((form (current-buffer))
         (key (or sprint--form-key
                  (save-excursion (goto-char (point-min))
                                  (and (re-search-forward "^#\\+SESSION: \\(.*\\)$" nil t) (match-string-no-properties 1)))
                  (user-error "Not a sprint log form")))
         (date (substring key 0 10)) (content (substring key 13))
         (abs (sprint--abs date))
         (year (sprint-season))
         (sched (sprint--fresh-buffer (sprint-file 'schedule year)))
         (find (lambda ()
                 (or (cl-find-if (lambda (x) (and (eql (plist-get x :abs) abs) (equal (plist-get x :content) content)
                                                  (member (plist-get x :state) '("TODO" "NEXT" "IN-WORK"))))
                                 (with-current-buffer sched (sprint--schedule-sessions)))
                     (user-error "The session of %s is no longer open in the schedule (logged elsewhere?): [Cancel] this draft" date))))
         (_ (with-current-buffer sched (sprint--clock-out-in (funcall find))))
         (s (funcall find))
         (items (sprint--session-items s abs year sched))
         (heads (with-current-buffer form
                  (save-excursion
                    (goto-char (point-min))
                    (let (res)
                      (while (re-search-forward "^\\* \\([0-9]+\\) · " nil t)
                        (push (cons (string-to-number (match-string 1)) (line-beginning-position)) res))
                      (nreverse res)))))
         (form-end (with-current-buffer form
                     (save-excursion (goto-char (point-min)) (or (and (re-search-forward "^\\[Save\\]" nil t) (match-beginning 0))
                                                                 (point-max)))))
         (sess-beg (with-current-buffer form (save-excursion (goto-char (point-min)) (re-search-forward "^\\* Session" nil t) (point))))
         (sess-end (or (cdr (car heads)) form-end))
         (clock (with-current-buffer sched (sprint--session-clock s)))
         (props (cons (cons "CNS" (plist-get s :cns))
                      (mapcar (lambda (f) (cons (car f) (with-current-buffer form (sprint--form-field (nth 1 f) sess-beg sess-end))))
                              sprint--form-session-fields)))
         (recs (let ((i 0))
                 (mapcar (lambda (it)
                           (cl-incf i)
                           (let* ((beg (or (cdr (assoc i heads)) (user-error "Exercise %d is missing in the form" i)))
                                  (end (or (cdr (assoc (1+ i) heads)) form-end))
                                  (m (nth (1- i) (car clock))))
                             (append (with-current-buffer form (sprint--rec-from-table it beg end))
                                     (list :minutes m))))
                         items)))
         (all-skipped (and recs (cl-every (lambda (r) (equal (plist-get r :status) "SKIPPED")) recs))))
    (let ((cmj (cdr (assoc "CMJ" props))) (rpe (cdr (assoc "RPE" props))))
      (unless (or (string-empty-p cmj) (and (sprint--num cmj) (<= 10 (sprint--num cmj) 90)))
        (user-error "CMJ %S: give the height in cm (10–90) or leave it empty" cmj))
      (unless (or (string-empty-p rpe) (and (string-match-p "\\`[0-9]+\\'" rpe) (<= 1 (string-to-number rpe) 10)))
        (user-error "RPE %S: a whole number from 1 to 10, or empty" rpe)))
    (when (string-empty-p (cdr (assoc "SORENESS" props))) (setcdr (assoc "SORENESS" props) "none"))
    (when (and (string-empty-p (cdr (assoc "DURATION_MIN" props))) (cdr clock))
      (setcdr (assoc "DURATION_MIN" props) (number-to-string (cdr clock))))
    (sprint--fresh-buffer (sprint-file 'log year))
    (sprint--insert-session-log abs content items recs props year)
    (with-current-buffer sched
      ;; bulk state changes: not the automatic clock's business
      (let ((this-command 'sprint-log-form-save))
        (sprint--mark-children s recs)
        (goto-char (plist-get s :beg))
        (org-todo (if all-skipped "SKIPPED" "DONE")))
      (save-buffer))
    (let ((file (buffer-file-name form)))
      (with-current-buffer form (set-buffer-modified-p nil))
      (kill-buffer form)
      (when (and file (file-exists-p file)) (delete-file file)))
    (message "Logged %d exercises (%s)" (length recs)
             (mapconcat (lambda (st) (format "%d %s" (cl-count st recs :key (lambda (r) (plist-get r :status)) :test #'equal) st))
                        '("DONE" "MODIFIED" "SKIPPED") ", "))))

(defun sprint-log-form-cancel ()
  "Discard the log form (nothing is stored; the synced draft is deleted)."
  (interactive)
  (when (yes-or-no-p "Discard this log form? ")
    (let ((form (current-buffer)) (file (buffer-file-name)))
      (set-buffer-modified-p nil)
      (kill-buffer form)
      (when (and file (file-exists-p file)) (delete-file file))
      (message "Log form discarded"))))

;; Reading the log back

(defun sprint--log-records (&optional year)
  "Exercise records of the log as plists (:date :week :phase :name :cat :status :plan :times :sets :dist :tonnage :est1rm :hits :target :note :reps-planned :plan-kg)."
  (let ((log (sprint-file 'log year)) res)
    (when (file-exists-p log)
      (with-temp-buffer
        (insert-file-contents log)
        (delay-mode-hooks (org-mode))
        (org-map-entries
         (lambda ()
           (when (org-entry-get nil "EXERCISE")
             (let ((g (lambda (p) (org-entry-get nil p)))
                   (gi (lambda (p) (org-entry-get nil p t))))
               (push (list :date (funcall gi "DATE") :week (sprint--num (funcall gi "WEEK"))
                           :phase (funcall gi "PHASE")
                           :name (funcall g "EXERCISE") :cat (funcall g "CATEGORY")
                           :status (funcall g "STATUS") :plan (funcall g "PLAN")
                           :plan-kg (sprint--num (funcall g "PLAN_KG"))
                           :times (and (funcall g "TIMES") (sprint--parse-times (funcall g "TIMES")))
                           :sets (and (funcall g "SETS_DONE") (sprint--parse-sets (funcall g "SETS_DONE")))
                           :dist (sprint--num (funcall g "DIST_M"))
                           :reps-planned (sprint--num (funcall g "REPS_PLANNED"))
                           :tonnage (sprint--num (funcall g "TONNAGE"))
                           :est1rm (sprint--num (funcall g "EST_1RM"))
                           :hits (sprint--num (funcall g "HITS"))
                           :target (sprint--num (funcall g "TARGET_S"))
                           :note (funcall g "NOTE")
                           :replaced-by (funcall g "REPLACED_BY")
                           :ex-rpe (sprint--num (funcall g "EX_RPE"))
                           :minutes (sprint--num (funcall g "DURATION_MIN"))
                           :cmj-pct (sprint--num (funcall gi "CMJ_PCT")) :rpe (sprint--num (funcall gi "RPE"))
                           :readiness (funcall gi "READINESS")
                           :cns (funcall gi "CNS")
                           :sets-planned (sprint--num (funcall g "SETS_PLANNED"))
                           :reps-per-set (sprint--num (funcall g "REPS_PER_SET")))
                     res))))
         nil nil)))
    (nreverse res)))

(defun sprint--plan-records (&optional year)
  "Planned exercise items of every session of the schedule, with date, week and state."
  (let ((file (sprint-file 'schedule year)) res)
    (when (file-exists-p file)
      (with-temp-buffer
        (insert-file-contents file)
        (delay-mode-hooks (org-mode))
        (dolist (s (sprint--schedule-sessions))
          (let ((week (save-excursion
                        (goto-char (plist-get s :beg))
                        (org-back-to-heading t) (while (org-up-heading-safe))
                        (list (sprint--num (org-entry-get nil "WEEK")) (org-entry-get nil "PHASE")))))
            (dolist (it (sprint--plan-items (buffer-substring-no-properties (plist-get s :body-beg) (plist-get s :end))))
              (push (append (list :date (and (plist-get s :abs) (sprint--str (plist-get s :abs)))
                                  :week (car week) :phase (cadr week)
                                  :state (plist-get s :state) :session (plist-get s :content)
                                  :cns (plist-get s :cns))
                            it)
                    res))))))
    (nreverse res)))

(defun sprint--in-scope (rec week phase)
  (and (or (null week) (eql (plist-get rec :week) week))
       (or (null phase) (equal (substring (or (plist-get rec :phase) "") 0 (min 3 (length (or (plist-get rec :phase) "")))) phase))))

(defun sprint--pct (a b) (if (and b (> b 0)) (format "%.0f%%" (* 100.0 (/ (float a) b))) "-"))

;; Body weight (read-only, from `sprint-weight-file')

(defun sprint--weights ()
  "Body weights as ((ABS . KG) ...), oldest first; nil without the file or rows."
  (when (file-exists-p sprint-weight-file)
    (with-temp-buffer
      (insert-file-contents sprint-weight-file)
      (let (res)
        (when (re-search-forward "^\\*+ Weight" nil t)
          (let ((end (save-excursion (if (re-search-forward "^\\* " nil t) (point) (point-max)))))
            (while (re-search-forward "^| *\\([0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}\\) *| *\\([0-9]+\\(?:[.,][0-9]+\\)?\\) *|" end t)
              (push (cons (sprint--abs (match-string 1))
                          (string-to-number (replace-regexp-in-string "," "." (match-string 2))))
                    res))))
        (sort res (lambda (a b) (< (car a) (car b))))))))

(defun sprint--weight-at (abs weights)
  "Last weight of WEIGHTS on or before day ABS (within 21 days), or nil."
  (cdr (car (last (cl-remove-if-not (lambda (w) (and (<= (car w) abs) (> (car w) (- abs 21)))) weights)))))

(defun sprint--weight-line (week year weights)
  "Report line on body weight up to the end of WEEK (or today), with the change over 4 weeks."
  (let* ((end (if week
                  (+ 6 (plist-get (cl-find week (sprint--weeks (sprint-config year)) :key (lambda (w) (plist-get w :n))) :start))
                (sprint--today)))
         (now (car (last (cl-remove-if (lambda (w) (> (car w) end)) weights))))
         (then (and now (sprint--weight-at (- (car now) 28) weights))))
    (cond ((null weights) "")
          ((null now) "Body weight: no weigh-in up to the end of this period.\n")
          (t (format "Body weight: %.1f kg (%s)%s\n" (cdr now) (sprint--str (car now))
                     (if then (format ", %+.1f kg over 4 weeks" (- (cdr now) then)) ""))))))

(defun sprint--volume-stats (plan logd)
  "Plist (:planned-m :actual-m :hits :reps :tonnage) of plan records PLAN and log records LOGD."
  (let ((planned-m 0) (actual-m 0) (hits 0) (reps 0) (ton 0))
    (dolist (r plan)
      (when (and (plist-get r :timed) (plist-get r :dist))
        (cl-incf planned-m (* (plist-get r :dist) (sprint--planned-reps r)))))
    (dolist (r logd)
      (when (and (plist-get r :dist) (not (equal (plist-get r :status) "SKIPPED")))
        (cl-incf actual-m (* (plist-get r :dist)
                             (if (plist-get r :times) (length (plist-get r :times)) (or (plist-get r :reps-planned) 0)))))
      (when (and (plist-get r :target) (plist-get r :times))
        (cl-incf reps (length (plist-get r :times)))
        (cl-incf hits (or (plist-get r :hits) 0)))
      (cl-incf ton (or (plist-get r :tonnage) 0)))
    (list :planned-m planned-m :actual-m actual-m :hits hits :reps reps :tonnage ton)))

(defun sprint--session-states (plan)
  "Alist state -> number of distinct planned sessions in PLAN."
  (let ((ss (cl-remove-duplicates
             (mapcar (lambda (r) (list (plist-get r :date) (plist-get r :session) (plist-get r :state))) plan)
             :test #'equal)))
    (mapcar (lambda (st) (cons st (cl-count st ss :key #'caddr :test #'equal)))
            '("TODO" "NEXT" "IN-WORK" "DONE" "SKIPPED"))))

(defun sprint--report-text (&optional week phase year)
  "Org text comparing plan and log for WEEK, PHASE (PHn) or the whole season."
  (let* ((plan (cl-remove-if-not (lambda (r) (sprint--in-scope r week phase)) (sprint--plan-records year)))
         (logd (cl-remove-if-not (lambda (r) (sprint--in-scope r week phase)) (sprint--log-records year)))
         (st (sprint--session-states plan))
         (n-sess (apply #'+ (mapcar #'cdr st)))
         (cnt (lambda (s) (cl-count s logd :key (lambda (r) (plist-get r :status)) :test #'equal)))
         (v (sprint--volume-stats plan logd))
         (scope (cond (week (format "week %d" week)) (phase phase) (t "season"))))
    (concat
     (format "Report for %s (generated %s)\n\n" scope (format-time-string "%Y-%m-%d"))
     "| Sessions planned | done | skipped | still open |\n|---+---+---+---|\n"
     (format "| %d | %d | %d | %d |\n\n" n-sess (cdr (assoc "DONE" st)) (cdr (assoc "SKIPPED" st))
             (+ (cdr (assoc "TODO" st)) (cdr (assoc "NEXT" st)) (cdr (assoc "IN-WORK" st))))
     "| Exercises logged | done as planned | modified | skipped |\n|---+---+---+---|\n"
     (format "| %d | %d | %d | %d |\n\n" (length logd) (funcall cnt "DONE") (funcall cnt "MODIFIED") (funcall cnt "SKIPPED"))
     (format "Sprint volume: planned %d m, done %d m (%s)\n" (plist-get v :planned-m) (plist-get v :actual-m)
             (sprint--pct (plist-get v :actual-m) (plist-get v :planned-m)))
     (if (> (plist-get v :reps) 0)
         (format "Target hit rate: %d of %d timed reps (%s)\n" (plist-get v :hits) (plist-get v :reps)
                 (sprint--pct (plist-get v :hits) (plist-get v :reps)))
       "Target hit rate: no timed reps with a target yet (log the 10 m / 30 m test first: SPC o S t)\n")
     (format "Lift tonnage: %.0f kg\n" (plist-get v :tonnage))
     (sprint--weight-line week year (sprint--weights))
     (let ((ts (sprint-target-status year)))
       (if ts (concat (plist-get ts :text) "\n") ""))
     (let ((f (and week (sprint-fatigue-estimate week year))))
       (if f (format "Fatigue estimate: %d / 100 (%s)\n" (plist-get f :score) (plist-get f :level)) ""))
     (if week "" (concat "\n" (sprint--trend-table plan logd year)))
     (if (or week phase) "" (concat "\n" (sprint--phase-table plan logd)))
     "\n" (sprint--lift-table logd)
     (if week "" (concat "\n" (sprint--lift-week-table logd))))))

(defun sprint--trend-table (plan logd year)
  "Org table, one row per week that has started: sessions, sprint metres, hit rate, tonnage, fatigue."
  (let* ((today (sprint--today))
         (weights (sprint--weights))
         (cal (sprint--weeks (sprint-config year)))
         (weeks (sort (delete-dups (delq nil (append (mapcar (lambda (r) (plist-get r :week)) logd)
                                                     (mapcar (lambda (r) (and (plist-get r :date)
                                                                              (<= (sprint--abs (plist-get r :date)) today)
                                                                              (plist-get r :week)))
                                                             plan))))
                      #'<)))
    (if (null weeks) "Trend: no week has started yet.\n"
      (concat
       "| Week | Phase | sessions done/planned | exercises done/mod/skip | sprint m plan/done | hit rate | tonnage | fatigue | body kg |\n|---+---+---+---+---+---+---+---+---|\n"
       (mapconcat
        (lambda (n)
          (let* ((p (cl-remove-if-not (lambda (r) (eql (plist-get r :week) n)) plan))
                 (l (cl-remove-if-not (lambda (r) (eql (plist-get r :week) n)) logd))
                 (st (sprint--session-states p))
                 (v (sprint--volume-stats p l))
                 (f (sprint-fatigue-estimate n year))
                 (c (lambda (s) (cl-count s l :key (lambda (r) (plist-get r :status)) :test #'equal))))
            (format "| %d | %s | %d/%d | %d/%d/%d | %d/%d | %s | %.0f | %s | %s |\n"
                    n (or (plist-get (car p) :phase) (plist-get (car l) :phase) "")
                    (cdr (assoc "DONE" st)) (apply #'+ (mapcar #'cdr st))
                    (funcall c "DONE") (funcall c "MODIFIED") (funcall c "SKIPPED")
                    (plist-get v :planned-m) (plist-get v :actual-m)
                    (if (> (plist-get v :reps) 0) (sprint--pct (plist-get v :hits) (plist-get v :reps)) "-")
                    (plist-get v :tonnage)
                    (if f (format "%d %s" (plist-get f :score) (plist-get f :level)) "-")
                    (let* ((w (cl-find n cal :key (lambda (x) (plist-get x :n))))
                           (kg (and w (sprint--weight-at (+ 6 (plist-get w :start)) weights))))
                      (if kg (format "%.1f" kg) "-")))))
        weeks "")))))

(defun sprint--phase-table (plan logd)
  "Org table of sessions, sprint metres, hit rate and tonnage per phase."
  (let ((phases (delete-dups (delq nil (mapcar (lambda (r) (plist-get r :phase)) plan)))))
    (concat
     "| Phase | sessions done/planned | sprint m plan/done | hit rate | tonnage |\n|---+---+---+---+---|\n"
     (mapconcat
      (lambda (ph)
        (let* ((p (cl-remove-if-not (lambda (r) (equal (plist-get r :phase) ph)) plan))
               (l (cl-remove-if-not (lambda (r) (sprint--in-scope r nil ph)) logd))
               (st (sprint--session-states p))
               (v (sprint--volume-stats p l)))
          (format "| %s | %d/%d | %d/%d | %s | %.0f |\n" ph
                  (cdr (assoc "DONE" st)) (apply #'+ (mapcar #'cdr st))
                  (plist-get v :planned-m) (plist-get v :actual-m)
                  (if (> (plist-get v :reps) 0) (sprint--pct (plist-get v :hits) (plist-get v :reps)) "-")
                  (plist-get v :tonnage))))
      phases ""))))

(defun sprint--lift-week-table (logd)
  "Org table of each lift per week: planned kg, top set, mean kg, estimated 1RM, tonnage."
  (let ((weights (sprint--weights)) cells)
    (dolist (r logd)
      (when (and (plist-get r :sets) (not (equal (plist-get r :status) "SKIPPED")))
        (let* ((k (cons (plist-get r :name) (plist-get r :week)))
               (cell (assoc k cells)))
          (unless cell (setq cell (list k)) (push cell cells))
          (push r (cdr cell)))))
    (if (null cells) ""
      (setq cells (sort cells (lambda (a b) (or (string< (caar a) (caar b))
                                                (and (equal (caar a) (caar b)) (< (or (cdar a) 0) (or (cdar b) 0)))))))
      (concat
       "| Lift | week | planned kg | top set | mean kg | est. 1RM | 1RM per kg body | tonnage |\n|---+---+---+---+---+---+---+---|\n"
       (mapconcat
        (lambda (cell)
          (let* ((rs (cdr cell))
                 (sets (apply #'append (mapcar (lambda (r) (plist-get r :sets)) rs)))
                 (sum (sprint--sets-summary sets))
                 (plan (delq nil (mapcar (lambda (r) (plist-get r :plan-kg)) rs))))
            (format "| %s | %s | %s | %s | %.1f | %s | %s | %.0f |\n"
                    (caar cell) (or (cdar cell) "-")
                    (if plan (format "%g" (apply #'max plan)) "-")
                    (let ((b (plist-get sum :best))) (if b (format "%g×%d" (car b) (cdr b)) "-"))
                    (sprint--mean (mapcar #'car sets))
                    (let ((e (plist-get sum :est1rm))) (if e (format "%.1f" e) "-"))
                    (let* ((e (plist-get sum :est1rm))
                           (day (apply #'max (mapcar (lambda (r) (if (sprint--date-p (plist-get r :date))
                                                                       (sprint--abs (plist-get r :date)) 0))
                                                     rs)))
                           (kg (sprint--weight-at day weights)))
                      (if (and e kg) (format "%.2f" (/ e kg)) "-"))
                    (plist-get sum :tonnage))))
        cells "")))))

(defun sprint--lift-table (logd)
  "Org table of per-lift progression from log records LOGD."
  (let (lifts)
    (dolist (r logd)
      (when (and (plist-get r :sets) (not (equal (plist-get r :status) "SKIPPED")))
        (let ((cell (assoc (plist-get r :name) lifts)))
          (unless cell (setq cell (list (plist-get r :name))) (push cell lifts))
          (push r (cdr cell)))))
    (if (null lifts) "No lift data logged yet.\n"
      (concat "| Lift | sessions | best set (kg×reps) | best est. 1RM | tonnage |\n|---+---+---+---+---|\n"
              (mapconcat
               (lambda (cell)
                 (let* ((rs (cdr cell))
                        (all (apply #'append (mapcar (lambda (r) (plist-get r :sets)) rs)))
                        (sum (sprint--sets-summary all)))
                   (format "| %s | %d | %s | %s | %.0f |\n" (car cell) (length rs)
                           (let ((b (plist-get sum :best))) (if b (format "%g×%d" (car b) (cdr b)) "-"))
                           (let ((e (plist-get sum :est1rm))) (if e (format "%.1f" e) "-"))
                           (apply #'+ (mapcar (lambda (r) (or (plist-get r :tonnage) 0)) rs)))))
               (nreverse lifts) "")))))

;;;###autoload
(defun sprint-report (&optional scope)
  "Show a plan-vs-actual report: SCOPE is a week number, a phase id like PH1, or nil for the season."
  (interactive
   (list (let ((a (completing-read "Report for (week number, PHn or RET = season): " nil)))
           (cond ((string-empty-p a) nil) ((string-match-p "\\`[0-9]+\\'" a) (string-to-number a)) (t (upcase a))))))
  (let ((text (sprint--report-text (and (integerp scope) scope) (and (stringp scope) scope))))
    (with-current-buffer (get-buffer-create "*sprint-report*")
      (erase-buffer) (insert text) (org-mode) (display-buffer (current-buffer)))
    text))

(defun org-dblock-write:sprint-report (params)
  "Dynamic block: #+BEGIN: sprint-report :week 12 (or :phase PH1; nothing = season)."
  (insert (sprint--report-text (plist-get params :week)
                               (let ((p (plist-get params :phase))) (and p (format "%s" p)))
                               (plist-get params :year))))

(defun sprint--csv-field (v)
  (let ((s (cond ((null v) "") ((numberp v) (format "%s" v)) (t v))))
    (if (string-match-p "[\",\n]" s) (concat "\"" (replace-regexp-in-string "\"" "\"\"" s) "\"") s)))

;;;###autoload
(defun sprint-export-csv (&optional year)
  "Write export/sprint_exercises_YYYY.csv: one row per planned exercise with its logged result."
  (interactive)
  (let* ((year (or year (sprint-season)))
         (plan (sprint--plan-records year))
         (logd (sprint--log-records year))
         (dir (expand-file-name "export/" sprint-directory))
         (file (expand-file-name (format "sprint_exercises_%d.csv" year) dir))
         (used nil) (rows nil))
    (make-directory dir t)
    (dolist (p plan)
      (let* ((r (cl-find-if (lambda (r) (and (equal (plist-get r :date) (plist-get p :date))
                                             (equal (plist-get r :name) (plist-get p :name))
                                             (not (memq r used))))
                            logd)))
        (when r (push r used))
        (push (list (plist-get p :date) (plist-get p :week) (plist-get p :phase) (plist-get p :state)
                    (plist-get p :cat) (plist-get p :name) (plist-get p :text)
                    (if r (plist-get r :status) "")
                    (if r (and (plist-get r :sets) (sprint--format-sets (plist-get r :sets))) "")
                    (if r (and (plist-get r :times) (mapconcat (lambda (x) (format "%.2f" x)) (plist-get r :times) " ")) "")
                    (and r (plist-get r :dist)) (and r (plist-get r :tonnage)) (and r (plist-get r :est1rm))
                    (and r (plist-get r :target)) (and r (plist-get r :hits)) (and r (plist-get r :note)))
              rows)))
    (with-temp-file file
      (insert "date,week,phase,session_state,category,exercise,planned,status,sets_done,times,dist_m,tonnage,est_1rm,target_s,hits,note\n")
      (setq rows (nreverse rows))
      (dolist (row rows)
        (insert (mapconcat #'sprint--csv-field row ",") "\n")))
    (message "CSV: %d rows → %s" (length rows) file)
    file))

;;;; Fatigue estimate, 100 m target, review and proposals (Milestone 3)
;;
;; Fatigue is estimated from what the log shows, not entered: slow-down inside
;; a session (last reps against the first), the share of reps that miss the
;; target time, skipped or modified exercises, and the optional CMJ and RPE.
;; `sprint-review-week' turns the findings into PROPOSED entries in
;; sprint_adjust_YYYY.org; you mark them ACCEPTED or REJECTED and
;; `sprint-apply' stores the accepted ones as overrides and rebuilds the
;; unfinished weeks.  The 100 m target only ever pushes while it is not yet
;; reached: once the best time is at or below the target nothing is raised.

(defun sprint--mean (l) (and l (/ (apply #'+ l) (float (length l)))))

(defun sprint--record-decay (r)
  "Percent slow-down of the last two reps against the first (timed record R, ≥ 3 reps)."
  (let ((ts (plist-get r :times)))
    (when (>= (length ts) 3)
      (* 100.0 (/ (- (sprint--mean (last ts 2)) (car ts)) (car ts))))))

(defun sprint--week-records (week year)
  (cl-remove-if-not (lambda (r) (eql (plist-get r :week) week)) (sprint--log-records year)))

(defun sprint--lift-drop (r)
  "Percent load drop from the first to the last set of lift record R (≥ 3 sets), or nil."
  (let ((s (plist-get r :sets)))
    (when (and (>= (length s) 3) (> (car (car s)) 0))
      (* 100.0 (/ (float (- (car (car s)) (car (car (last s))))) (car (car s)))))))

(defun sprint--missed-lift-reps (recs)
  "(MISSED . PLANNED) reps over the lift records of RECS that carry a plan."
  (let ((missed 0) (planned 0))
    (dolist (r recs)
      (let ((sp (plist-get r :sets-planned)) (rp (plist-get r :reps-per-set)))
        (when (and sp rp (not (equal (plist-get r :status) "SKIPPED")))
          (let ((done (apply #'+ (mapcar (lambda (s) (min (cdr s) rp)) (plist-get r :sets)))))
            (cl-incf planned (* sp rp))
            (cl-incf missed (max 0 (- (* sp rp) done)))))))
    (cons missed planned)))

(defun sprint--back-to-back-high (recs)
  "Number of logged High-CNS sessions in RECS that came the day after another one."
  (let* ((days (delete-dups (delq nil (mapcar (lambda (r) (and (member (downcase (or (plist-get r :cns) "")) '("high" "very high"))
                                                              (sprint--date-p (plist-get r :date))
                                                              (sprint--abs (plist-get r :date))))
                                             recs)))))
    (cl-count-if (lambda (d) (memq (1- d) days)) days)))

(defun sprint--week-decline (recs)
  "Percent by which the timed reps of the later sessions of the week are further from target than the early ones.
nil without targeted reps on at least two days."
  (let (by-day)
    (dolist (r recs)
      (when (and (plist-get r :target) (plist-get r :times) (plist-get r :date))
        (let ((cell (assoc (plist-get r :date) by-day)))
          (unless cell (setq cell (list (plist-get r :date))) (push cell by-day))
          (dolist (x (plist-get r :times)) (push (/ x (plist-get r :target)) (cdr cell))))))
    (setq by-day (sort by-day (lambda (a b) (string< (car a) (car b)))))
    (when (>= (length by-day) 2)
      (let* ((half (/ (length by-day) 2))
             (early (sprint--mean (apply #'append (mapcar #'cdr (cl-subseq by-day 0 half)))))
             (late (sprint--mean (apply #'append (mapcar #'cdr (cl-subseq by-day (- (length by-day) half)))))))
        (* 100 (/ (- late early) early))))))

(defun sprint-fatigue-estimate (week &optional year)
  "Fatigue of WEEK from the log: plist (:score :level :parts :decay :hit-rate :n ...), or nil without data."
  (let* ((cfg (sprint-config year))
         (recs (sprint--week-records week year)))
    (when recs
      (let* ((high (sprint--int cfg "FATIGUE_HIGH" 60))
             (n (length recs))
             (decays (delq nil (append (mapcar #'sprint--record-decay recs) (mapcar #'sprint--lift-drop recs))))
             (decay (sprint--mean decays))
             (tt (cl-remove-if-not (lambda (r) (and (plist-get r :target) (plist-get r :times))) recs))
             (reps (apply #'+ (mapcar (lambda (r) (length (plist-get r :times))) tt)))
             (hits (apply #'+ (mapcar (lambda (r) (or (plist-get r :hits) 0)) tt)))
             (hit-rate (and (> reps 0) (/ (float hits) reps)))
             (off (cl-count-if (lambda (r) (member (plist-get r :status) '("SKIPPED" "MODIFIED"))) recs))
             (lift (sprint--missed-lift-reps recs))
             (missed (and (> (cdr lift) 0) (/ (float (car lift)) (cdr lift))))
             (b2b (sprint--back-to-back-high recs))
             (decline (sprint--week-decline recs))
             (cmj (sprint--mean (delq nil (mapcar (lambda (r) (plist-get r :cmj-pct)) recs))))
             (rpe (sprint--mean (delq nil (mapcar (lambda (r) (plist-get r :rpe)) recs))))
             (parts (list (cons "slow-down within sessions (times, lift loads)" (if decay (min 30 (* 6 (max 0 decay))) 0))
                          (cons "reps missing the target" (if hit-rate (min 15 (* 20 (- 1 hit-rate))) 0))
                          (cons "decline from early to late sessions of the week" (if decline (min 15 (* 5 (max 0 decline))) 0))
                          (cons "lift reps missed against the plan" (if missed (min 15 (* 40 missed)) 0))
                          (cons "skipped/modified work" (min 20 (* 40 (/ (float off) n))))
                          (cons "High-CNS sessions on consecutive days" (min 15 (* 8 b2b)))
                          (cons "CMJ below baseline" (cond ((null cmj) 0) ((< cmj 90) 25) ((< cmj 97) 12) (t 0)))
                          (cons "session RPE" (cond ((null rpe) 0) ((>= rpe 8) 15) ((>= rpe 7) 6) (t 0)))))
             (score (min 100 (round (apply #'+ (mapcar #'cdr parts))))))
        (list :score score :parts parts :decay decay :hit-rate hit-rate :n n :off off :reps reps
              :missed missed :decline decline :b2b b2b
              :level (cond ((>= score high) "high") ((>= score 35) "moderate") (t "low")))))))

(defun sprint--best-race (year)
  (let ((log (sprint-file 'log year)) times)
    (when (file-exists-p log)
      (with-temp-buffer
        (insert-file-contents log) (delay-mode-hooks (org-mode))
        (org-map-entries
         (lambda ()
           (when (and (equal (car (org-get-outline-path)) "Races")
                      (equal (org-entry-get nil "EVENT") "100m")
                      (equal (org-entry-get nil "LEGAL") "yes"))
             (let ((tm (sprint--num (org-entry-get nil "TIME")))) (when tm (push tm times)))))
         nil nil)))
    (and times (apply #'min times))))

(defun sprint--fly30-progress (year)
  "Relative improvement of the flying 30 m from the first to the best logged test, or nil."
  (let ((log (sprint-file 'log year)) vals)
    (when (file-exists-p log)
      (with-temp-buffer
        (insert-file-contents log) (delay-mode-hooks (org-mode))
        (org-map-entries
         (lambda ()
           (when (equal (car (org-get-outline-path)) "Testing Battery")
             (let ((v (sprint--num (org-entry-get nil "30M")))) (when v (push v vals)))))
         nil nil)))
    (setq vals (nreverse vals))
    (when (>= (length vals) 2)
      (/ (- (car vals) (apply #'min vals)) (car vals)))))

(defun sprint-target-status (&optional year)
  "Plist (:target :now :gap :source :reached :text) for the 100 m target."
  (let* ((cfg (sprint-config year))
         (target (sprint--num-of (sprint--get cfg "TARGET_100M")))
         (pb (sprint--num-of (sprint--get cfg "PREV_100M_PB")))
         (race (sprint--best-race year))
         (prog (and (not race) (sprint--fly30-progress year)))
         (sens (/ (sprint--int cfg "TEST_TO_100M_SENS_PCT" 60) 100.0))
         (now (cond (race race) ((and pb prog) (* pb (- 1 (* sens prog)))) (t pb)))
         (source (cond (race "best legal race this season")
                       (prog (format "predicted from flying 30 m progress %.1f%% × %.1f" (* 100 prog) sens))
                       (t "previous best (no legal race and fewer than two 30 m tests this season)"))))
    (when (and target now)
      (let ((gap (- now target)))
        (list :target target :now now :gap gap :source source :reached (<= gap 0)
              :text (if (<= gap 0)
                        (format "100 m target %.2f s reached: %.2f s (%s). Hold the volumes, no further push." target now source)
                      (format "100 m target %.2f s: now %.2f s (%s) → %.2f s (%.1f%%) to gain."
                              target now source gap (* 100 (/ gap now)))))))))

(defun sprint--diagnose (week year)
  "Findings for WEEK: list of (KEY TEXT . DATA), the diagnosis table of the roadmap.
KEY is fatigue, decay, accumulated, targets, lifts, execution or progress."
  (let* ((cfg (sprint-config year))
         (tol (sprint--int cfg "TARGET_TOL_PCT" 2))
         (recs (sprint--week-records week year))
         (fat (sprint-fatigue-estimate week year))
         (tt (cl-remove-if-not (lambda (r) (and (plist-get r :target) (plist-get r :times))) recs))
         (first-missed (cl-count-if (lambda (r) (> (car (plist-get r :times))
                                                   (* (plist-get r :target) (+ 1 (/ tol 100.0)))))
                                    tt))
         (decayed (cl-count-if (lambda (r) (let ((d (or (sprint--record-decay r) (sprint--lift-drop r))))
                                             (and d (> d (sprint--int cfg "DECAY_MAX_PCT" 4)))))
                               recs))
         res)
    (when fat
      (when (equal (plist-get fat :level) "high")
        (push (list 'fatigue (format "fatigue %d (%s): %s" (plist-get fat :score) (plist-get fat :level)
                                     (mapconcat (lambda (p) (format "%s +%d" (car p) (round (cdr p))))
                                                (cl-remove-if (lambda (p) (< (cdr p) 1)) (plist-get fat :parts)) ", ")))
              res))
      (when (>= decayed 2)
        (push (list 'decay (format "first rep (set) fine, later ones fall off in %d exercises (more than %d%% slower or lighter): volume or rest too high"
                                   decayed (sprint--int cfg "DECAY_MAX_PCT" 4)))
              res))
      (when (and (plist-get fat :decline) (> (plist-get fat :decline) tol))
        (push (list 'accumulated (format "early sessions of the week were faster than the later ones (%.1f%% further from target): accumulated fatigue"
                                         (plist-get fat :decline)))
              res))
      (when (and (>= (length tt) 3) (= first-missed (length tt)))
        (let ((ratio (sprint--mean (mapcar (lambda (r) (/ (car (plist-get r :times)) (plist-get r :target))) tt))))
          (push (cons 'targets (cons (format "the first rep missed the target in all %d timed exercises (on average %.1f%% slower): the target is unrealistic for now"
                                             (length tt) (* 100 (- ratio 1)))
                                     (min 1.10 (/ (fceiling (* 100 ratio)) 100))))
                res)))
      (when (and (plist-get fat :missed) (>= (plist-get fat :missed) 0.15))
        (push (list 'lifts (format "%.0f%% of the planned lift reps were missed: loads too high for now" (* 100 (plist-get fat :missed))))
              res))
      (when (and (>= (plist-get fat :n) 5) (>= (/ (float (plist-get fat :off)) (plist-get fat :n)) 0.4))
        (push (list 'execution (format "%d of %d exercises skipped or modified: the plan asks for more than you can do now"
                                       (plist-get fat :off) (plist-get fat :n)))
              res))
      (when (and (plist-get fat :hit-rate) (>= (plist-get fat :hit-rate) 0.9) (>= (plist-get fat :reps) 6)
                 (< (plist-get fat :score) 40) (or (null (plist-get fat :decay)) (< (plist-get fat :decay) 2)))
        (push (list 'progress (format "%.0f%% of timed reps on target with little slow-down: room to progress"
                                      (* 100 (plist-get fat :hit-rate))))
              res)))
    (nreverse res)))

;; Proposals file

(defun sprint--adjust-skeleton (year)
  (format "#+TITLE: Sprint adjustments %d\n#+TODO: PROPOSED ACCEPTED | APPLIED REJECTED\n#+STARTUP: overview\n# Review: set a proposal to ACCEPTED or REJECTED (C-c C-t), edit FACTOR / FROM_WEEK / TO_WEEK if you want, then run SPC o S A.\n# APPLIED entries are read by the generator as overrides; the file is also the history of what was tuned and why.\n\n* Proposals\n" year))

(defun sprint--adjust-buffer (year)
  (let ((f (sprint-file 'adjust year)))
    (unless (file-exists-p f) (with-temp-file f (insert (sprint--adjust-skeleton year))))
    (find-file-noselect f)))

(defun sprint--add-proposal (year kind factor value from to title evidence source-week)
  "Append a PROPOSED entry unless the same KIND from SOURCE-WEEK already exists.  Return it or nil."
  (with-current-buffer (sprint--adjust-buffer year)
    (let ((dup nil))
      (org-map-entries
       (lambda ()
         (when (and (equal (org-entry-get nil "KIND") kind)
                    (or (equal (org-entry-get nil "SOURCE_WEEK") (number-to-string source-week))
                        ;; a swap is proposed once, whichever week found it
                        (equal kind "SWAP"))
                    (or (null value) (equal (org-entry-get nil "VALUE") value))
                    (not (equal (org-get-todo-state) "REJECTED")))
           (setq dup t)))
       nil nil)
      (unless dup
        (org-with-wide-buffer
         (goto-char (point-max))
         (unless (bolp) (insert "\n"))
         (insert (format "** PROPOSED %s\n:PROPERTIES:\n:KIND: %s\n%s%s:FROM_WEEK: %d\n:TO_WEEK: %d\n:SOURCE_WEEK: %d\n:CREATED: %s\n:END:\n%s\n"
                         title kind
                         (if factor (format ":FACTOR: %s\n" (number-to-string factor)) "")
                         (if value (format ":VALUE: %s\n" value) "")
                         from to source-week (format-time-string "%Y-%m-%d") evidence))
         (save-buffer))
        title))))

;;;###autoload
(defun sprint-review-week (&optional week)
  "Review WEEK (default the current one): estimate fatigue, check the 100 m target, write proposals."
  (interactive)
  (let* ((year (sprint-season))
         (week (or week (plist-get (sprint-context nil year) :n)
                   (user-error "No training week today")))
         (fat (sprint-fatigue-estimate week year))
         (tgt (sprint-target-status year))
         (found (and fat (sprint--diagnose week year)))
         (prev (and (> week 1) (sprint-fatigue-estimate (1- week) year)))
         (next (1+ week)) (made nil) (deloaded nil)
         (add (lambda (kind factor value from to title ev)
                (let ((p (sprint--add-proposal year kind factor value from to title ev week)))
                  (when p (push p made))))))
    (dolist (f found)
      (let ((ev (cadr f)))
        (pcase (car f)
          ('fatigue
           (if (or (>= (plist-get fat :score) 80) (and prev (equal (plist-get prev :level) "high")))
               (progn (setq deloaded t)
                      (funcall add "DELOAD" nil nil next next (format "W%d: unplanned deload week" next) ev))
             (funcall add "SPRINT_VOL" 0.85 nil next next (format "W%d: sprint volume ×0.85" next) ev)
             (funcall add "PLYO" 0.80 nil next next (format "W%d: plyometric contacts ×0.80" next) ev)))
          ('accumulated
           (unless deloaded
             (funcall add "SPRINT_VOL" 0.85 nil next next (format "W%d: reduce next week, sprint volume ×0.85" next) ev)))
          ('decay
           (unless deloaded (funcall add "SPRINT_VOL" 0.90 nil next next (format "W%d: sprint volume ×0.90 (fewer reps or longer rest)" next) ev)))
          ('targets
           (let ((factor (cddr f)))
             (funcall add "TARGET" factor nil next 999
                      (format "W%d on: target times ×%.2f (lowered to recent actuals)" next factor)
                      (concat ev ".  Alternatively retest the flying 10 m / 30 m (SPC o S t) and reject this."))))
          ('lifts
           (unless deloaded
             (funcall add "LOAD" 0.95 nil next next (format "W%d: lift loads ×0.95" next) ev)))
          ('execution
           (unless deloaded (funcall add "SPRINT_VOL" 0.90 nil next (1+ next) (format "W%d–%d: sprint volume ×0.90" next (1+ next)) ev)))
          ('progress
           (if (and tgt (plist-get tgt :reached))
               (funcall add "NOTE" nil "hold" next next (format "W%d: target reached, hold" next)
                        (format "%s %s" ev (plist-get tgt :text)))
             (funcall add "SPRINT_VOL" 1.08 nil next (1+ next) (format "W%d–%d: sprint volume ×1.08" next (1+ next))
                      (format "%s %s" ev (if tgt (plist-get tgt :text) "")))
             (funcall add "LOAD" 1.025 nil next (1+ next) (format "W%d–%d: lift loads ×1.025" next (1+ next)) ev)
             ;; the 100 m ramp already tightens the flying targets; without it, raise them here
             (unless (plist-get (sprint--target-ctx year) :ramp)
               (funcall add "TARGET" 0.99 nil next 999 (format "W%d on: target times ×0.99 (raised)" next) ev)))))))
    ;; an exercise replaced by the same one again and again: propose the swap
    (let ((counts (make-hash-table :test #'equal)))
      (dolist (r (sprint--log-records year))
        (when (and (plist-get r :replaced-by) (plist-get r :week)
                   (<= (- week (1- sprint-swap-window-weeks)) (plist-get r :week) week))
          (cl-incf (gethash (cons (plist-get r :name) (plist-get r :replaced-by)) counts 0))))
      (maphash
       (lambda (k n)
         (when (>= n sprint-swap-after)
           (let ((ev (format "%s was replaced by %s %d times in weeks %d–%d."
                             (car k) (cdr k) n (max 1 (- week (1- sprint-swap-window-weeks))) week)))
             (if (cl-find (cdr k) (sprint--db) :key (lambda (x) (plist-get x :name)) :test #'equal)
                 (progn
                   (setq found (append found (list (list 'swap ev))))
                   (funcall add "SWAP" nil (format "%s -> %s" (car k) (cdr k)) next 999
                            (format "W%d on: %s instead of %s" next (cdr k) (car k))
                            (concat ev "  Edit TO_WEEK to limit it; reject it to keep the plan.")))
               (setq found (append found (list (list 'swap (format "%s  Add %s to TrainingDB.org to get a swap proposal."
                                                                   ev (cdr k))))))))))
       counts))
    (with-current-buffer (get-buffer-create "*sprint-review*")
      (erase-buffer)
      (insert (format "Review of week %d\n\n" week))
      (if fat
          (insert (format "Fatigue estimate: %d / 100 (%s) from %d logged exercises\n"
                          (plist-get fat :score) (plist-get fat :level) (plist-get fat :n))
                  (mapconcat (lambda (p) (format "  %s: +%d\n" (car p) (round (cdr p)))) (plist-get fat :parts) ""))
        (insert "No exercises logged for this week yet (SPC o S L).\n"))
      (when tgt (insert "\n" (plist-get tgt :text) "\n"))
      (insert "\nFindings:\n" (if found (mapconcat (lambda (f) (format "  - %s\n" (cadr f))) found "") "  none\n"))
      (insert (if made (format "\n%d proposal%s written to %s (state PROPOSED):\n%s"
                               (length made) (if (cdr made) "s" "") (file-name-nondirectory (sprint-file 'adjust year))
                               (mapconcat (lambda (m) (format "  - %s\n" m)) (reverse made) ""))
                "\nNo new proposals.\n"))
      (org-mode) (display-buffer (current-buffer)))
    (list :fatigue fat :target tgt :found found :proposals (reverse made))))

;;;###autoload
(defun sprint-fatigue (&optional week)
  "Show the fatigue estimate for WEEK (default the current one)."
  (interactive)
  (let* ((year (sprint-season))
         (week (or week (plist-get (sprint-context nil year) :n)))
         (f (and week (sprint-fatigue-estimate week year))))
    (message "%s" (if f (format "Week %d fatigue %d/100 (%s)" week (plist-get f :score) (plist-get f :level))
                    "No exercises logged for this week yet"))
    f))

;;;###autoload
(defun sprint-apply ()
  "Turn ACCEPTED proposals into APPLIED overrides and rebuild the unfinished weeks."
  (interactive)
  (let* ((year (sprint-season)) (n 0))
    (with-current-buffer (sprint--adjust-buffer year)
      (org-map-entries
       (lambda ()
         (when (equal (org-get-todo-state) "ACCEPTED")
           (org-todo "APPLIED")
           (org-set-property "APPLIED" (format-time-string "%Y-%m-%d"))
           (cl-incf n)))
       nil nil)
      (save-buffer))
    (sprint-generate-schedule year)
    (message "%d adjustment%s applied; unfinished weeks rebuilt" n (if (= n 1) "" "s"))
    n))

(defconst sprint--override-kinds
  '(("SPRINT_VOL" . "sprint volume factor (sets and metres of sprint work)")
    ("PLYO"       . "plyometric contacts factor")
    ("LOAD"       . "lift load factor (kg on the bar)")
    ("TARGET"     . "target time factor (1.03 = 3% easier, 0.99 = harder)")
    ("DELOAD"     . "turn the weeks into deload weeks")
    ("FV_FOCUS"   . "F-V focus in the balanced phase: force / velocity / balanced")
    ("SWAP"       . "replace an exercise by another (VALUE \"Old -> New\", names from TrainingDB.org)"))
  "Override kinds read by the generator, with a description.")

(defun sprint--resolve-weeks (spec year)
  "(FROM . TO) week numbers for SPEC: \"12\", \"12-14\", a phase \"PH5\" or a sub-phase \"PH1_SP2\"."
  (let ((weeks (sprint--weeks (sprint-config year))) (spec (upcase (string-trim spec))))
    (cond
     ((string-match "\\`\\([0-9]+\\)\\(?:[-–]\\([0-9]+\\)\\)?\\'" spec)
      (let ((a (string-to-number (match-string 1 spec))))
        (cons a (if (match-string 2 spec) (string-to-number (match-string 2 spec)) a))))
     (t (let ((ns (mapcar (lambda (w) (plist-get w :n))
                          (cl-remove-if-not (lambda (w) (or (equal (plist-get w :phase) spec) (equal (plist-get w :sub) spec)))
                                            weeks))))
          (unless ns (user-error "No weeks match %s" spec))
          (cons (apply #'min ns) (apply #'max ns)))))))

;;;###autoload
(defun sprint-override ()
  "Override the plan for a week, a range of weeks, a sub-phase or a phase, then rebuild.
Written straight to sprint_adjust_YYYY.org as APPLIED (the history keeps it);
set it to REJECTED and run `sprint-apply' to undo."
  (interactive)
  (let* ((year (sprint-season))
         (kind (car (split-string (sprint--ask-choice
                                   "Override: "
                                   (mapcar (lambda (k) (format "%s — %s" (car k) (cdr k))) sprint--override-kinds)))))
         (cur (plist-get (sprint-context nil year) :n))
         (range (sprint--resolve-weeks
                 (let ((a (string-trim (sprint--ask (format "Weeks (12, 12-14, PH5, PH1_SP2; RET = %s): " (or cur 1))))))
                   (if (string-empty-p a) (number-to-string (or cur 1)) a))
                 year))
         (value (cond ((equal kind "DELOAD") nil)
                      ((equal kind "FV_FOCUS")
                       (sprint--ask-choice "Focus: " '("force" "velocity" "balanced")))
                      ((equal kind "SWAP")
                       (let ((names (mapcar (lambda (e) (plist-get e :name)) (sprint--db))))
                         (format "%s -> %s" (sprint--ask-choice "Replace: " names)
                                 (sprint--ask-choice "With: " names))))
                      (t (let ((a (string-trim (sprint--ask (format "%s factor (e.g. 0.9 or 1.1): " kind)))))
                           (unless (string-match-p "\\`[0-9]*\\.?[0-9]+\\'" a) (user-error "Not a number: %s" a))
                           a))))
         (why (string-trim (sprint--ask "Reason (optional): ")))
         (title (format "W%d%s: %s%s" (car range)
                        (if (/= (car range) (cdr range)) (format "–%d" (cdr range)) "")
                        kind (if value (format " %s" value) ""))))
    (with-current-buffer (sprint--adjust-buffer year)
      (org-with-wide-buffer
       (goto-char (point-max))
       (unless (bolp) (insert "\n"))
       (insert (format "** APPLIED %s (manual)\n:PROPERTIES:\n:KIND: %s\n%s:FROM_WEEK: %d\n:TO_WEEK: %d\n:SOURCE: manual\n:CREATED: %s\n:APPLIED: %s\n:END:\n%s\n"
                       title kind
                       (cond ((null value) "")
                             ((member kind '("FV_FOCUS" "SWAP")) (format ":VALUE: %s\n" value))
                             (t (format ":FACTOR: %s\n" value)))
                       (car range) (cdr range)
                       (format-time-string "%Y-%m-%d") (format-time-string "%Y-%m-%d")
                       (if (string-empty-p why) "Set by hand." why))))
      (save-buffer))
    (sprint-generate-schedule year)
    (message "Override %s applied; unfinished weeks rebuilt" title)
    title))

;;;; Season wizard (Milestone 4)
;;
;; `sprint-wizard' asks the handful of questions that define a season and
;; writes the answers into the config.  Every question shows the current value
;; (from the config you started with, which `sprint-new-season' fills from last
;; season's log); RET keeps it.  Afterwards it validates and offers to build
;; the schedule.

(defun sprint--macro-ref (name cfg) (or (sprint--get cfg name) ""))

(defun sprint--set-or-add-macro (name value comment)
  "Set #+MACRO NAME to VALUE in the current buffer; add it (with COMMENT) at the end of Section 1 if absent."
  (goto-char (point-min))
  (if (re-search-forward (format "^#\\+MACRO:[ \t]+%s[ \t]+.*$" (regexp-quote name)) nil t)
      (replace-match (format "#+MACRO: %-22s %s" name value) t t)
    (goto-char (point-min))
    (if (re-search-forward "^# SECTION 2" nil t)
        (progn (forward-line -1) (beginning-of-line)
               (when (looking-at "^# ─") (forward-line -0)))
      (goto-char (point-max)))
    (insert (format "#+MACRO: %-22s %s\n" name value)
            (if (and comment (not (save-excursion (goto-char (point-min)) (search-forward comment nil t))))
                (concat "# " comment "\n") "")
            "\n")))

(defconst sprint--wizard-questions
  ;; macro  prompt  type  (choices)  comment-if-new
  '(("SEASON_START"            "First Monday of the season"                     monday)
    ("INDOOR_SEASON"           "Indoor season (double periodization)?"          choice ("true" "false"))
    ("INDOOR_TARGET_DATE"      "Key indoor meet (YYYY-MM-DD)"                   date indoor)
    ("OUTDOOR_SEASON_START"    "First outdoor meet (YYYY-MM-DD)"                date)
    ("OUTDOOR_CHAMPIONSHIP"    "Main championship (YYYY-MM-DD)"                 date)
    ("SECONDARY_CHAMPIONSHIP"  "Secondary championship (YYYY-MM-DD or none)"    date-none)
    ("EXTRA_RACE_DATES"        "Other meets (dates separated by spaces, or none)" text)
    ("PREV_SQUAT_1RM"          "Back squat 1RM (kg)"                            number)
    ("PREV_TBDL_1RM"           "Trap bar deadlift 1RM (kg, bar included)"       number)
    ("PREV_PCLEAN_1RM"         "Power clean 1RM (kg)"                           number)
    ("PREV_10M_PB"             "Best 10 m (s)"                                  number)
    ("PREV_30M_PB"             "Best 30 m (s)"                                  number)
    ("PREV_100M_PB"            "Best 100 m (s)"                                 number)
    ("CMJ_BASELINE"            "Fresh CMJ height (cm)"                          number)
    ("FORM_FACTOR"             "Current form as % of those maxima (100 = fully fit)" percent
     nil "Percent of the PREV_*_1RM values used for every kg in the schedule (see Section 4).")
    ("TARGET_100M"             "Season target for the 100 m (s)"                number
     nil "Season goal for the 100 m, seconds; the review proposes pushes only while it is not reached.")
    ("DOMINANT_FV_DEFICIT"     "F-V deficit (force / velocity / balanced)"      choice ("force" "velocity" "balanced"))
    ("TRACK_DAYS"              "Days you have the track (e.g. MON WED FRI, or all)" days
     nil "Weekdays with track access; other days are outside (no blocks or timing gates), sessions needing the track there are flagged."))
  "Wizard questions: (MACRO PROMPT TYPE [CHOICES-or-flag] [COMMENT]).")

(defun sprint--wizard-valid (type choices v cfg)
  "Non-nil when V is an acceptable answer of TYPE."
  (pcase type
    ('monday (and (sprint--date-p v) (= 1 (sprint--dow (sprint--abs v)))))
    ('date (sprint--date-p v))
    ('date-none (or (equal v "none") (sprint--date-p v)))
    ('choice (member v choices))
    ('number (string-match-p "\\`[0-9]+\\(?:\\.[0-9]+\\)?\\'" v))
    ('percent (and (string-match-p "\\`[0-9]+\\'" v) (<= 40 (string-to-number v) 130)))
    ('days (or (equal (upcase v) "ALL")
               (cl-every (lambda (d) (assoc d sprint--dow-codes)) (split-string (upcase v) "[ ,]+" t))))
    ('text t)
    (_ t)))

(defun sprint--wizard-ask (q cfg stats)
  "Ask question Q; return the new value, or nil to keep the current one."
  (let* ((macro (nth 0 q)) (prompt (nth 1 q)) (type (nth 2 q))
         (choices (and (eq type 'choice) (nth 3 q)))
         (cur (sprint--macro-ref macro cfg))
         (hint (let ((s (assoc macro stats))) (and s (not (equal (cdr s) cur)) (format ", last log: %s" (cdr s)))))
         (result :ask))
    (while (eq result :ask)
      (let ((a (string-trim (sprint--ask (format "%s [%s%s]: " prompt (if (string-empty-p cur) "unset" cur) (or hint ""))))))
        (cond ((string-empty-p a) (setq result nil))
              ((sprint--wizard-valid type choices a cfg) (setq result a))
              (t (message "Not valid for %s (%s)" macro
                          (pcase type ('monday "a Monday as YYYY-MM-DD") ('choice (mapconcat #'identity choices "/"))
                                 ('percent "40-130") ('number "a number") ('days "weekdays like MON WED FRI, or all")
                                 (_ "a date YYYY-MM-DD")))
                 (when (not (eq sprint--scripted-answers :none)) (setq result nil))))))
    (and result (not (equal result cur)) result)))

(defun sprint--wizard-answers (year)
  "Run the questions for YEAR; return the alist of changed (MACRO . VALUE)."
  (let* ((cfg (sprint-config year))
         (stats (ignore-errors (sprint--log-stats (sprint-file 'log (1- year)))))
         (indoor (equal (sprint--get cfg "INDOOR_SEASON") "true"))
         changed)
    (dolist (q sprint--wizard-questions)
      (let ((flag (nth 3 q)))
        (unless (and (eq flag 'indoor) (not indoor))
          (let ((v (sprint--wizard-ask q cfg stats)))
            (when v
              (push (cons (nth 0 q) v) changed)
              (setq cfg (cons (cons (nth 0 q) v) cfg))
              (when (equal (nth 0 q) "INDOOR_SEASON") (setq indoor (equal v "true"))))))))
    ;; weekday pattern
    (when (member (downcase (string-trim (sprint--ask "Change the weekday pattern (gym / hill / tempo days)? [y/N]: ")))
                  '("y" "yes"))
      (dolist (d sprint--pattern-days)
        (let* ((m (concat "PATTERN_" d)) (cur (sprint--get cfg m "template"))
               (a (string-trim (sprint--ask (format "%s: template / gym / hill / tempo / recovery / rest [%s]: " d cur)))))
          (when (and (not (string-empty-p a)) (member a '("template" "gym" "hill" "tempo" "recovery" "rest"))
                     (not (equal a cur)))
            (push (cons m a) changed) (setq cfg (cons (cons m a) cfg))))))
    ;; phase lengths and blocks, with what last season's adjustments say
    (when (member (downcase (string-trim (sprint--ask "Change phase lengths or load/deload blocks? [y/N]: ")))
                  '("y" "yes"))
      (let ((hints (sprint--adjust-hints (1- year))))
        (dolist (ph (sprint--phases cfg))
          (let* ((id (plist-get ph :id))
                 (set (lambda (m v) (push (cons m v) changed) (setq cfg (cons (cons m v) cfg))))
                 (ask (lambda (m prompt)
                        (let* ((cur (sprint--get cfg m ""))
                               (a (string-trim (sprint--ask (format "%s [%s]: " prompt cur)))))
                          (cond ((string-empty-p a) nil)
                                ((not (string-match-p "\\`[0-9]+\\'" a)) (message "%s: not a whole number, kept %s" m cur) nil)
                                ((equal a cur) nil)
                                (t (funcall set m a) a))))))
            (funcall ask (concat id "_WEEKS")
                     (format "%s %s weeks%s%s" id (plist-get ph :name)
                             (let ((p (sprint--get cfg (format "PREV_%s_WEEKS" id)))) (if p (format " (last season %s)" p) ""))
                             (let ((h (cdr (assoc id hints)))) (if h (format " — last season: %s" h) ""))))
            (let ((subs (sprint--subphases cfg id 0)))
              (when subs
                (dolist (s subs)
                  (funcall ask (concat (car s) "_LOAD_WEEKS") (format "  %s %s: loading weeks" (car s) (nth 1 s)))
                  (funcall ask (concat (car s) "_DELOAD_WEEKS") (format "  %s: deload weeks" (car s))))
                ;; keep the blocks adding up to the phase: the last block absorbs the difference
                (let* ((subs (sprint--subphases cfg id 0))
                       (sum (apply #'+ (mapcar (lambda (s) (+ (nth 2 s) (nth 3 s))) subs)))
                       (weeks (sprint--int cfg (concat id "_WEEKS")))
                       (last (car (last subs)))
                       (fixed (+ (nth 2 last) (- weeks sum))))
                  (when (and (/= sum weeks) (>= fixed 1))
                    (funcall set (concat (car last) "_LOAD_WEEKS") (number-to-string fixed))
                    (message "%s: blocks added up to %d of %d weeks; %s now has %d loading weeks"
                             id sum weeks (car last) fixed)))))))))
    (let* ((cur (sprint--get cfg "EQUIPMENT_UNAVAILABLE" "none"))
           (a (string-trim (sprint--ask (format "Equipment you do NOT have (regex list separated by | , or none) [%s]: " cur)))))
      (when (and (not (string-empty-p a)) (not (equal a cur)))
        (push (cons "EQUIPMENT_UNAVAILABLE" a) changed)))
    ;; a macro answered twice keeps its last value
    (let (out)
      (dolist (c changed) (unless (assoc (car c) out) (push c out)))
      out)))

(defun sprint--adjust-hints (year)
  "Alist PHASE -> summary of the adjustments applied in season YEAR, or nil."
  (let ((f (sprint-file 'adjust year)) (cfgf (sprint-file 'config year)) counts)
    (when (and (file-exists-p f) (file-exists-p cfgf))
      (let ((weeks (sprint--weeks (sprint-config year))))
        (with-temp-buffer
          (insert-file-contents f)
          (delay-mode-hooks (org-mode))
          (org-map-entries
           (lambda ()
             (when (equal (org-get-todo-state) "APPLIED")
               (let* ((from (sprint--num-of (org-entry-get nil "FROM_WEEK")))
                      (w (cl-find from weeks :key (lambda (x) (plist-get x :n))))
                      (kind (org-entry-get nil "KIND"))
                      (fac (sprint--num-of (org-entry-get nil "FACTOR")))
                      (what (cond ((equal kind "DELOAD") "unplanned deload")
                                  ((and (equal kind "TARGET") fac) (if (> fac 1) "targets eased" "targets tightened"))
                                  ((and fac (< fac 1)) (format "%s cut" (downcase kind)))
                                  ((and fac (> fac 1)) (format "%s raised" (downcase kind)))
                                  (t (downcase (or kind "note"))))))
                 (when w
                   (let ((cell (assoc (plist-get w :phase) counts)))
                     (unless cell (setq cell (list (plist-get w :phase))) (push cell counts))
                     (push what (cdr cell)))))))
           nil nil))))
    (mapcar (lambda (c)
              (cons (car c)
                    (mapconcat (lambda (w) (let ((n (cl-count w (cdr c) :test #'equal)))
                                             (if (> n 1) (format "%d× %s" n w) w)))
                               (delete-dups (copy-sequence (cdr c))) ", ")))
            counts)))

(defun sprint--wizard-write (year changed)
  "Write CHANGED ((MACRO . VALUE) ...) into the config of YEAR; return a summary string."
  (let* ((file (sprint-file 'config year)) (cfg (sprint-config year)) (lines nil))
    (with-temp-buffer
      (insert-file-contents file)
      (dolist (c changed)
        (let ((comment (nth 4 (assoc (car c) sprint--wizard-questions))))
          (push (format "  %s: %s → %s" (car c) (let ((o (sprint--get cfg (car c)))) (or o "unset")) (cdr c)) lines)
          (sprint--set-or-add-macro
           (car c) (cdr c)
           (or comment
               (and (string-prefix-p "PATTERN_" (car c))
                    "Session type of this weekday: template (the plan's own table) | gym | hill | tempo | recovery | rest")
               (and (equal (car c) "EQUIPMENT_UNAVAILABLE")
                    "Exercises whose EQUIPMENT matches one of these (| separated) are never picked; none = no limit")))))
      (write-region (point-min) (point-max) file))
    (mapconcat #'identity (nreverse lines) "\n")))

;;;###autoload
(defun sprint-wizard ()
  "Guided setup of a season's config: current values are proposed, RET keeps them."
  (interactive)
  (let* ((cur (sprint-season)) (next (1+ cur))
         (pick (if (file-exists-p (sprint-file 'config next))
                   (format "%d (edit)" next)
                 (sprint--ask-choice
                  "Plan which season? "
                  (list (format "%d (edit the current config)" cur)
                        (format "%d (new season based on %d)" next cur)))))
         (year (if (string-match "\\`\\([0-9]+\\) (new" pick)
                   (progn (sprint-new-season) (string-to-number (match-string 1 pick)))
                 (string-to-number pick)))
         (changed (sprint--wizard-answers year))
         (summary (if changed (sprint--wizard-write year changed) "  (nothing changed)"))
         (msgs (sprint-validate year)))
    (with-current-buffer (get-buffer-create "*sprint-wizard*")
      (erase-buffer)
      (insert (format "Season %d\n\nChanges written to %s:\n%s\n\nValidation:\n%s\n"
                      year (file-name-nondirectory (sprint-file 'config year)) summary
                      (mapconcat (lambda (m) (concat "  " m)) msgs "\n")))
      (org-mode) (display-buffer (current-buffer)))
    (when (and (eq sprint--scripted-answers :none)
               (y-or-n-p "Build the schedule now? "))
      (sprint-generate-schedule year))
    (list :year year :changed changed :messages msgs)))

(defun sprint--ask-choice (prompt choices)
  (if (eq sprint--scripted-answers :none)
      (completing-read prompt choices nil t nil nil (car choices))
    (let ((a (string-trim (sprint--ask prompt))))
      (or (cl-find-if (lambda (c) (string-prefix-p a c)) choices) (car choices)))))

;;;; Export (for sharing)

;;;###autoload
(defun sprint-export (&optional year)
  "Export plan, schedule and log of YEAR to self-contained HTML and Markdown.
Files go to the export/ folder next to the config.  Macros are resolved,
so the result can be read without Emacs.  For PDF use C-c C-e l p in the
plan; for a single phase or week narrow with C-x n s / use C-c C-e C-s."
  (interactive)
  (require (quote ox-html)) (require (quote ox-md))
  (let ((dir (expand-file-name "export/" sprint-directory)) out)
    (make-directory dir t)
    (dolist (kind (quote (plan schedule log)))
      (let ((src (sprint-file kind year)))
        (when (file-exists-p src)
          (with-current-buffer (find-file-noselect src)
            (dolist (ext (quote ("html" "md")))
              (let ((target (expand-file-name (concat (file-name-base src) "." ext) dir))
                    (org-export-use-babel nil))
                (org-export-to-file (if (equal ext "html") (quote html) (quote md)) target)
                (push target out)))))))
    (message "Exported: %s" (mapconcat (function file-name-nondirectory) (nreverse out) ", "))
    dir))

;;;; Shareable plan (visual HTML page)
;;
;; `sprint-export-schedule' writes one self-contained HTML page: a season
;; timeline of phases and blocks, a calendar (weeks × days, coloured by session
;; type) and the sessions day by day.  Nothing but the plan goes out.

(defconst sprint--month-names ["Jan" "Feb" "Mar" "Apr" "May" "Jun" "Jul" "Aug" "Sep" "Oct" "Nov" "Dec"])

(defun sprint--h (s)
  "S escaped for HTML."
  (replace-regexp-in-string
   "[&<>\"]" (lambda (m) (pcase m ("&" "&amp;") ("<" "&lt;") (">" "&gt;") (_ "&quot;"))) (or s "") t t))

(defun sprint--short-date (abs &optional year)
  (let ((g (calendar-gregorian-from-absolute abs)))
    (format "%d %s%s" (nth 1 g) (aref sprint--month-names (1- (car g)))
            (if year (format " %d" (nth 2 g)) ""))))

(defun sprint--session-kind (s)
  "Display kind of schedule session S: gym, test, race, taper, high, medium, low."
  (let ((c (plist-get s :content)))
    (cond ((string-match-p "\\`\\(?:DELOAD −50% volume: \\)?Gym: " c) "gym")
          ((string-prefix-p "TESTING BATTERY" c) "test")
          ((string-prefix-p "RACE" c) "race")
          ((string-match-p "RACE DAY" c) "race")
          ((string-prefix-p "TAPER" c) "taper")
          ((member (downcase (plist-get s :cns)) '("high" "very high")) "high")
          ((equal (downcase (plist-get s :cns)) "medium") "medium")
          (t "low"))))

(defconst sprint--short-cats
  '(("Acceleration" . "Accel") ("Max Velocity" . "Max V") ("Speed Endurance" . "Speed end.")
    ("Extensive Tempo" . "Tempo") ("Plyometrics" . "Plyo")))

(defun sprint--session-label (s lines)
  "Short calendar label of session S from its exercise LINES."
  (let ((c (replace-regexp-in-string "\\`DELOAD −50% volume: " "" (plist-get s :content)))
        (kind (sprint--session-kind s)))
    (pcase kind
      ("gym"
       (let (lifts)
         (dolist (l lines)
           (when (string-match "\\`- \\(Strength[^:]*\\): \\(.*\\)" l)
             (dolist (seg (split-string (match-string 2 l) "; " t))
               (let ((name (car (split-string seg " [0-9]"))))
                 (push (concat (replace-regexp-in-string " (.*" "" name)
                               (if (string-match "≈ \\([0-9.]+\\) kg" seg) (format " %s kg" (match-string 1 seg)) ""))
                       lifts)))))
         (if lifts (mapconcat #'identity (nreverse lifts) " · ") "Core · mobility")))
      ("test" "Testing day")
      ("race" (if (string-prefix-p "RACE — " c) (substring c 7) "Race"))
      ("taper" (car (split-string (replace-regexp-in-string "\\`TAPER " "" c) " — ")))
      (_
       (let ((tl (cl-find-if (lambda (l) (string-prefix-p "- Targets: " l)) lines)))
         (if tl
             (mapconcat (lambda (part)
                          (let ((p (string-trim part)))
                            (dolist (sc sprint--short-cats p)
                              (setq p (replace-regexp-in-string (concat "\\`" (regexp-quote (car sc))) (cdr sc) p)))))
                        (split-string (substring tl 11) "·" t) " · ")
           (truncate-string-to-width c 38 nil nil "…")))))))

(defun sprint--export-weeks (year)
  "Weeks of the schedule of YEAR: plists (:n :start :phase :title :type :block :sessions)."
  (with-temp-buffer
    (insert-file-contents (sprint-file 'schedule year))
    (delay-mode-hooks (org-mode))
    (let ((sessions (sprint--schedule-sessions)) weeks)
      (goto-char (point-min))
      (while (re-search-forward "^\\* Week \\([0-9]+\\) · \\(PH[0-9]\\) · \\(.*?\\) · \\(.*\\)$" nil t)
        (let* ((n (string-to-number (match-string 1))) (ph (match-string 2))
               (block (match-string 3)) (type (match-string 4))
               (start (save-excursion (and (re-search-forward "^:START:[ \t]+\\([0-9-]+\\)" nil t)
                                           (sprint--abs (match-string 1))))))
          (push (list :n n :start start :phase ph :block block :type type
                      :sessions (cl-remove-if-not (lambda (s) (and (plist-get s :abs)
                                                                   (>= (plist-get s :abs) start)
                                                                   (< (plist-get s :abs) (+ start 7))))
                                                  sessions))
                weeks)))
      (dolist (w weeks)
        (plist-put w :sessions
                   (mapcar (lambda (s)
                             (let ((body (buffer-substring-no-properties (plist-get s :body-beg) (plist-get s :end))))
                     (append s (list :lines
                                     (append
                                      (cl-remove-if-not (lambda (l) (string-prefix-p "- Targets: " l)) (split-string body "\n" t))
                                      (mapcar (lambda (en) (format "- %s: %s%s" (or (nth 0 en) "Other") (nth 1 en)
                                                                   (pcase (nth 2 en) ("DONE" " ✓") ("SKIPPED" " (skipped)") (_ ""))))
                                              (sprint--body-entries body)))))))
                           (plist-get w :sessions))))
      (nreverse weeks))))

(defconst sprint--export-css "
:root{--bg:#fafaf7;--card:#fff;--ink:#1d2330;--muted:#6b7280;--line:#e5e7eb;
--high:#e4572e;--medium:#f2a541;--low:#4caf7a;--gym:#3f7cdb;--test:#8e5bd8;--race:#111827;--taper:#d9468f;
--ph1:#7aa6d8;--ph2:#78b98a;--ph3:#e0b84f;--ph4:#b8bcc6;--ph5:#d9785b;--ph6:#e39b3c;--ph7:#c4536a;--ph8:#a0a6b2}
@media (prefers-color-scheme:dark){:root{--bg:#12151c;--card:#1b2030;--ink:#e8eaf0;--muted:#9aa3b2;--line:#2c3346;--race:#e8eaf0}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--ink);font:15px/1.45 system-ui,-apple-system,Segoe UI,Roboto,sans-serif}
main{max-width:1180px;margin:0 auto;padding:24px 16px 64px}
h1{font-size:1.7rem;margin:0 0 4px}h2{font-size:1.25rem;margin:36px 0 12px}h3{font-size:1.02rem;margin:0}
.sub{color:var(--muted)}.facts{display:flex;flex-wrap:wrap;gap:8px;margin:14px 0 0}
.fact{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:8px 12px}.fact b{display:block;font-size:1.05rem}
.timeline{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:14px;overflow-x:auto}
.tl-row{display:flex;min-width:640px;gap:2px}.tl-ph{color:#fff;font-size:.78rem;font-weight:600;padding:6px 6px;border-radius:6px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.tl-wk{flex:1;height:26px;border-radius:4px;position:relative;font-size:.62rem;color:#fff;text-align:center;line-height:26px;opacity:.9}
.tl-wk.dl{background-image:repeating-linear-gradient(45deg,rgba(255,255,255,.45) 0 4px,transparent 4px 8px)}
.tl-wk.out{opacity:.25}.tl-wk.now{outline:2px solid var(--ink);outline-offset:1px}
.tl-meet{position:absolute;top:-15px;left:50%;transform:translateX(-50%);color:var(--ink);font-size:.8rem}
.legend{display:flex;flex-wrap:wrap;gap:10px 16px;margin:12px 0 0;font-size:.85rem;color:var(--muted)}
.dot{display:inline-block;width:11px;height:11px;border-radius:3px;margin-right:6px;vertical-align:-1px}
.cal{overflow-x:auto;border-radius:12px;border:1px solid var(--line);background:var(--card)}
.cal-grid{display:grid;grid-template-columns:150px repeat(7,minmax(108px,1fr));min-width:920px}
.cal-h{position:sticky;top:0;background:var(--card);font-size:.8rem;color:var(--muted);padding:8px 6px;border-bottom:1px solid var(--line);font-weight:600}
.cal-phase{grid-column:1/-1;padding:10px 12px;font-weight:700;color:#fff;font-size:.9rem}
.cal-wk{padding:7px 8px;border-bottom:1px solid var(--line);font-size:.78rem}.cal-wk b{font-size:.9rem}
.cal-wk.now{box-shadow:inset 4px 0 0 var(--ink)}
.cell{padding:4px;border-bottom:1px solid var(--line);border-left:1px solid var(--line);min-height:54px}
.chip{display:block;border-radius:7px;padding:4px 6px;margin-bottom:3px;font-size:.72rem;line-height:1.25;color:#fff;text-decoration:none}
.chip.medium{color:#2a1d00}.chip.done{opacity:.55}.chip.done::after{content:' ✓'}.chip.skipped{text-decoration:line-through;opacity:.45}
.high{background:var(--high)}.medium{background:var(--medium)}.low{background:var(--low)}.gym{background:var(--gym)}
.test{background:var(--test)}.race{background:var(--race);color:var(--bg)!important}.taper{background:var(--taper)}
.cards{display:grid;grid-template-columns:repeat(auto-fill,minmax(250px,1fr));gap:12px}
.card{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:12px 14px;border-top:5px solid var(--c)}
.card ul{margin:6px 0 0;padding-left:18px}.card li{margin:2px 0}
.week{background:var(--card);border:1px solid var(--line);border-radius:12px;margin:14px 0;overflow:hidden}
.week>header{padding:10px 14px;border-left:6px solid var(--c);display:flex;justify-content:space-between;gap:12px;flex-wrap:wrap}
.day{display:grid;grid-template-columns:96px 1fr;border-top:1px solid var(--line)}
.day .d{padding:10px 12px;font-weight:600;font-size:.85rem}.day .d small{display:block;color:var(--muted);font-weight:400}
.sess{padding:10px 14px 10px 12px;border-left:4px solid var(--k)}.sess+.sess{border-top:1px dashed var(--line)}
.sess .t{font-weight:600}.badge{display:inline-block;font-size:.68rem;font-weight:700;border-radius:20px;padding:1px 8px;margin-right:6px;color:#fff;vertical-align:1px}
.ex{margin:6px 0 0;padding:0;list-style:none;font-size:.86rem}.ex li{margin:3px 0}.ex .cat{color:var(--muted)}
.ex .how{font-size:.8rem;color:var(--muted);margin:1px 0 4px}.ex .how summary{cursor:pointer;width:max-content}
.ex .tg{color:var(--muted);font-size:.8rem}.target{color:var(--high);font-weight:600}
footer{margin-top:40px;color:var(--muted);font-size:.8rem}
a{color:inherit}.tl-wk,.chip,.cal-wk a{text-decoration:none}.code,.wk-short{display:none}
.facts{display:grid;grid-template-columns:repeat(auto-fill,minmax(150px,1fr))}
@media (max-width:640px){.day{grid-template-columns:1fr}.day .d{padding-bottom:0}h1{font-size:1.4rem}
.cal{overflow:visible}.cal-grid{grid-template-columns:54px repeat(7,1fr);min-width:0}
.cal-h{padding:6px 2px;text-align:center}.cal-wk{padding:6px 4px;font-size:.72rem}.cal-wk .sub,.wk-long{display:none}.wk-short{display:inline}
.cell{padding:2px;min-height:40px}.chip{padding:0;height:17px;line-height:17px;text-align:center;font-size:.7rem;font-weight:700;border-radius:4px;margin-bottom:2px}
.chip .lbl{display:none}.chip .code{display:inline}.chip.done::after{content:''}.chip.done .code::after{content:'✓'}
.cal-phase{font-size:.8rem;padding:8px}}
@media print{body{background:#fff}.cal,.timeline{overflow:visible}.week{break-inside:avoid}}
")

(defun sprint--export-html (weeks all-weeks cfg year spec)
  "HTML page for WEEKS (subset of ALL-WEEKS) of season YEAR."
  (let* ((today (sprint--today))
         (in (lambda (w) (memq w weeks)))
         (phases (sprint--phases cfg))
         (phase-name (lambda (id) (or (plist-get (cl-find id phases :key (lambda (p) (plist-get p :id)) :test #'equal) :name) id)))
         (races (sprint--races cfg))
         (kinds '(("high" . "Track · hard") ("medium" . "Track · moderate") ("low" . "Easy / tempo / outside")
                  ("gym" . "Gym") ("test" . "Testing") ("race" . "Race") ("taper" . "Taper")))

         (now-week (cl-find-if (lambda (w) (and (>= today (plist-get w :start)) (< today (+ 7 (plist-get w :start))))) all-weeks))
         (o (list)))
    (cl-flet ((out (&rest xs) (push (apply #'concat xs) o)))
      (out "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">"
           (format "<title>Sprint plan %d%s</title><style>%s</style></head><body><main>" year
                   (if spec (format " — %s" (sprint--h spec)) "") sprint--export-css))
      ;; header
      (out (format "<h1>Sprint training plan %d%s</h1><div class=\"sub\">%s → %s · %d weeks · track %s · gym %s</div>"
                   year (if spec (format " <span class=\"sub\">— %s</span>" (sprint--h spec)) "")
                   (sprint--short-date (plist-get (car weeks) :start) t)
                   (sprint--short-date (+ 6 (plist-get (car (last weeks)) :start)) t)
                   (length weeks)
                   (sprint--h (sprint--get cfg "TRACK_DAYS" "all"))
                   (sprint--h (mapconcat (lambda (d) (capitalize (downcase d)))
                                         (cl-remove-if-not (lambda (d) (equal (sprint--get cfg (concat "PATTERN_" d)) "gym"))
                                                           sprint--pattern-days)
                                         " "))))
      (out "<div class=\"facts\">"
           (format "<div class=\"fact\"><span class=\"sub\">100 m goal</span><b>%s s</b></div>" (sprint--h (sprint--get cfg "TARGET_100M" "?")))
           (format "<div class=\"fact\"><span class=\"sub\">Best so far</span><b>%s s</b></div>" (sprint--h (sprint--get cfg "PREV_100M_PB" "?")))
           (mapconcat (lambda (r) (format "<div class=\"fact\"><span class=\"sub\">%s</span><b>%s</b></div>"
                                          (sprint--h (cdr r)) (sprint--short-date (car r) t)))
                      races "")
           "</div>")
      ;; timeline
      (out "<h2>Season at a glance</h2><div class=\"timeline\"><div class=\"tl-row\" style=\"margin-bottom:6px\">")
      (dolist (p phases)
        (let ((n (cl-count (plist-get p :id) all-weeks :key (lambda (w) (plist-get w :phase)) :test #'equal)))
          (when (> n 0)
            (out (format "<div class=\"tl-ph\" style=\"flex:%d;background:var(--%s)\" title=\"%s\">%s · %s</div>"
                         n (downcase (plist-get p :id)) (sprint--h (plist-get p :name))
                         (plist-get p :id) (sprint--h (plist-get p :name)))))))
      (out "</div><div class=\"tl-row\" style=\"margin-top:16px\">")
      (dolist (w all-weeks)
        (let ((meet (cl-find-if (lambda (r) (and (>= (car r) (plist-get w :start)) (< (car r) (+ 7 (plist-get w :start))))) races)))
          (out (format "<a class=\"tl-wk%s%s%s\" style=\"background-color:var(--%s)\" href=\"#w%d\" title=\"Week %d · %s · %s%s\">%s</a>"
                       (if (string-prefix-p "DELOAD" (plist-get w :type)) " dl" "")
                       (if (funcall in w) "" " out") (if (eq w now-week) " now" "")
                       (downcase (plist-get w :phase)) (plist-get w :n) (plist-get w :n)
                       (sprint--short-date (plist-get w :start)) (sprint--h (plist-get w :block))
                       (if meet (concat " · " (sprint--h (cdr meet))) "")
                       (concat (number-to-string (plist-get w :n)) (if meet "<span class=\"tl-meet\">▲</span>" ""))))))
      (out "</div><div class=\"legend\"><span><span class=\"dot\" style=\"background:repeating-linear-gradient(45deg,#999 0 3px,#ddd 3px 6px)\"></span>deload / test week</span><span>▲ meet</span>"
           (if now-week "<span>outlined: this week</span>" "") "</div></div>")
      ;; phase cards
      (out "<h2>Phases</h2><div class=\"cards\">")
      (dolist (p phases)
        (let ((ws (cl-remove-if-not (lambda (w) (equal (plist-get w :phase) (plist-get p :id))) all-weeks)))
          (when (and ws (cl-some in ws))
            (out (format "<div class=\"card\" style=\"--c:var(--%s)\"><h3>%s · %s</h3><div class=\"sub\">weeks %d–%d · %s → %s</div><ul>"
                         (downcase (plist-get p :id)) (plist-get p :id) (sprint--h (plist-get p :name))
                         (plist-get (car ws) :n) (plist-get (car (last ws)) :n)
                         (sprint--short-date (plist-get (car ws) :start)) (sprint--short-date (+ 6 (plist-get (car (last ws)) :start))))
                 (mapconcat (lambda (b) (let ((bw (cl-remove-if-not (lambda (w) (equal (plist-get w :block) b)) ws)))
                                          (format "<li>%s <span class=\"sub\">(%d wk)</span></li>" (sprint--h b) (length bw))))
                            (delete-dups (mapcar (lambda (w) (plist-get w :block)) ws)) "")
                 "</ul></div>"))))
      (out "</div>")
      ;; calendar
      (out "<h2>Calendar</h2><div class=\"legend\" style=\"margin:0 0 10px\">"
           (mapconcat (lambda (k) (format "<span><span class=\"dot %s\"></span>%s<span class=\"wk-short\"> (%s)</span></span>" (car k) (cdr k)
                                          (pcase (car k) ("high" "H") ("medium" "M") ("low" "E") ("gym" "G")
                                                 ("test" "T") ("race" "R") (_ "P"))))
                      kinds "")
           "</div><div class=\"cal\"><div class=\"cal-grid\"><div class=\"cal-h\">Week</div>"
           (mapconcat (lambda (d) (format "<div class=\"cal-h\">%s</div>" d)) '("Mon" "Tue" "Wed" "Thu" "Fri" "Sat" "Sun") ""))
      (let (cur)
        (dolist (w weeks)
          (unless (equal cur (plist-get w :phase))
            (setq cur (plist-get w :phase))
            (out (format "<div class=\"cal-phase\" style=\"background:var(--%s)\">%s · %s</div>"
                         (downcase cur) cur (sprint--h (funcall phase-name cur)))))
          (out (format "<div class=\"cal-wk%s\"><b><a href=\"#w%d\">W%d</a></b><span class=\"wk-long\"> · </span><br class=\"wk-short\">%s<br><span class=\"sub\">%s · %s</span></div>"
                       (if (eq w now-week) " now" "") (plist-get w :n) (plist-get w :n)
                       (sprint--short-date (plist-get w :start)) (sprint--h (plist-get w :block))
                       (sprint--h (downcase (plist-get w :type)))))
          (dotimes (i 7)
            (let ((ss (cl-remove-if-not (lambda (s) (= (plist-get s :abs) (+ i (plist-get w :start)))) (plist-get w :sessions))))
              (out "<div class=\"cell\">"
                   (mapconcat (lambda (s)
                                (format "<a class=\"chip %s%s\" href=\"#d%s\" title=\"%s\"><span class=\"lbl\">%s</span><span class=\"code\">%s</span></a>"
                                        (sprint--session-kind s)
                                        (pcase (plist-get s :state) ("DONE" " done") ("SKIPPED" " skipped") (_ ""))
                                        (sprint--str (plist-get s :abs))
                                        (sprint--h (sprint--session-label s (plist-get s :lines)))
                                        (sprint--h (sprint--session-label s (plist-get s :lines)))
                                        (pcase (sprint--session-kind s)
                                          ("high" "H") ("medium" "M") ("low" "E") ("gym" "G")
                                          ("test" "T") ("race" "R") (_ "P"))))
                              ss "")
                   "</div>")))))
      (out "</div></div>")
      ;; details
      (out "<h2>Sessions</h2>")
      (dolist (w weeks)
        (out (format "<section class=\"week\" id=\"w%d\" style=\"--c:var(--%s)\"><header><h3>Week %d · %s – %s</h3><span class=\"sub\">%s · %s · %s</span></header>"
                     (plist-get w :n) (downcase (plist-get w :phase)) (plist-get w :n)
                     (sprint--short-date (plist-get w :start)) (sprint--short-date (+ 6 (plist-get w :start)))
                     (plist-get w :phase) (sprint--h (plist-get w :block)) (sprint--h (downcase (plist-get w :type)))))
        (dotimes (i 7)
          (let* ((abs (+ i (plist-get w :start)))
                 (ss (cl-remove-if-not (lambda (s) (= (plist-get s :abs) abs)) (plist-get w :sessions))))
            (out (format "<div class=\"day\" id=\"d%s\"><div class=\"d\">%s<small>%s</small></div><div>"
                         (sprint--str abs) (aref sprint--dow-names (sprint--dow abs)) (sprint--short-date abs)))
            (if (null ss) (out "<div class=\"sess sub\" style=\"--k:var(--line)\">rest / free</div>")
              (dolist (s ss)
                (let ((k (sprint--session-kind s)))
                  (out (format "<div class=\"sess\" style=\"--k:var(--%s)\"><div class=\"t\"><span class=\"badge %s\">%s</span>%s%s</div><ul class=\"ex\">"
                               k k (cdr (assoc k kinds))
                               (sprint--h (replace-regexp-in-string "\\`\\(?:DELOAD −50% volume: \\)?\\(?:Gym: \\)?" "" (plist-get s :content)))
                               (pcase (plist-get s :state) ("DONE" " ✓") ("SKIPPED" " <span class=\"sub\">(skipped)</span>") (_ "")))
                       (mapconcat
                        (lambda (l)
                          (cond ((string-match "\\`- Targets: \\(.*\\)" l)
                                 (format "<li class=\"tg\">Volume: %s</li>" (sprint--h (match-string 1 l))))
                                ((string-match "\\`- \\([^:]+\\): \\(.*\\)" l)
                                 (let* ((cat (match-string 1 l)) (txt (match-string 2 l))
                                        (how (and sprint-show-execution (plist-get (sprint--db-match txt) :how))))
                                   (format "<li><span class=\"cat\">%s:</span> %s%s</li>" (sprint--h cat)
                                           (replace-regexp-in-string
                                            "· target \\(~?[0-9.]+ s\\)\\(.*?\\)\\(;\\|$\\)"
                                            "· <span class=\"target\">target \\1</span>\\2\\3"
                                            (sprint--h txt))
                                           (if (and how (not (string-empty-p how)))
                                               (format "<details class=\"how\"><summary>how</summary>%s</details>" (sprint--h how))
                                             ""))))
                                (t "")))
                        (plist-get s :lines) "")
                       "</ul></div>"))))
            (out "</div></div>")))
        (out "</section>"))
      (out (format "<footer>Generated %s from the season plan. Volumes, loads and target times are indications; the day's readiness decides.</footer></main></body></html>"
                   (format-time-string "%Y-%m-%d"))))
    (apply #'concat (nreverse o))))

;;;###autoload
(defun sprint-export-schedule (&optional spec year)
  "Export the schedule as one self-contained, visual HTML page to share.
SPEC limits it to some weeks: \"1-10\", \"12\", a phase \"PH1\" or a block
\"PH1_SP2\"; nil exports the whole season.  Only the plan goes out: no log,
no readiness, no internal properties.  Returns the file name."
  (interactive
   (list (let ((a (string-trim (sprint--ask "Weeks to share (RET = whole season; e.g. 1-10, PH1): "))))
           (and (not (string-empty-p a)) a))))
  (let* ((year (or year (sprint-season)))
         (sprint--db nil)
         (cfg (sprint-config year))
         (range (and spec (sprint--resolve-weeks spec year)))
         (all (sprint--export-weeks year))
         (weeks (cl-remove-if-not (lambda (w) (or (null range) (<= (car range) (plist-get w :n) (cdr range)))) all))
         (dir (expand-file-name "export/" sprint-directory))
         (out (expand-file-name
               (format "training_plan_%d%s.html" year
                       (if spec (concat "_weeks_" (replace-regexp-in-string "[^A-Za-z0-9-]" "" spec)) ""))
               dir)))
    (unless weeks (user-error "No weeks match %s" spec))
    (make-directory dir t)
    (with-temp-file out
      (set-buffer-file-coding-system 'utf-8)
      (insert (sprint--export-html weeks all cfg year spec)))
    (message "Shareable plan: %s" out)
    out))

;;;; Keys

(defvar sprint-map
  (let ((m (make-sparse-keymap)))
    (define-key m "g" #'sprint-generate-schedule)
    (define-key m "v" #'sprint-validate)
    (define-key m "i" #'sprint-today-info)
    (define-key m "a" #'sprint-agenda)
    (define-key m "s" (lambda () (interactive) (org-capture nil "Ss")))
    (define-key m "t" #'sprint-show-today)
    (define-key m "T" (lambda () (interactive) (org-capture nil "St")))
    (define-key m "d" (lambda () (interactive) (org-capture nil "Sd")))
    (define-key m "r" (lambda () (interactive) (org-capture nil "Sr")))
    (define-key m "y" #'sprint-season-summary)
    (define-key m "n" #'sprint-new-season)
    (define-key m "e" #'sprint-export)
    (define-key m "E" #'sprint-export-schedule)
    (define-key m "l" #'sprint-lock-week)
    (define-key m "x" #'sprint-reroll-session)
    (define-key m "L" #'sprint-log)
    (define-key m "N" #'sprint-wizard)
    (define-key m "W" #'sprint-review-week)
    (define-key m "A" #'sprint-apply)
    (define-key m "F" #'sprint-fatigue)
    (define-key m "R" #'sprint-report)
    (define-key m "c" #'sprint-export-csv)
    (define-key m "X" #'sprint-reroll-week)
    (define-key m "w" #'sprint-swap-exercise)
    (define-key m "o" #'sprint-override)
    m)
  "Keymap for the sprint commands.")

(when (boundp 'glz/org-map)
  (define-key glz/org-map "S" sprint-map))

(with-eval-after-load 'which-key
  (which-key-add-keymap-based-replacements sprint-map
    "g" "generate schedule"   "v" "validate"
    "i" "today info"          "a" "sprint agenda"
    "s" "quick session"       "t" "today's training"
    "T" "log test"            "d" "not as planned today"
    "r" "log race"            "y" "season summary"
    "n" "new season"          "e" "export"
    "E" "share plan (HTML)"
    "l" "lock/unlock week"
    "x" "reroll session"      "X" "reroll week"
    "w" "swap exercise"       "o" "override weeks"
    "L" "log exercises"       "R" "report"
    "N" "season wizard"
    "W" "review week"         "A" "apply adjustments"
    "F" "fatigue estimate"
    "c" "export CSV"))

(provide 'sprint)
;;; sprint.el ends here
