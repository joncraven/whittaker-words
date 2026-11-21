;;; whittaker-mode.el --- Offline Whitaker's Words lookup -*- lexical-binding: t; -*-

;; Copyright (C) 2026

;; Author: Jonathan Craven
;; Keywords: latin, languages, convenience
;; Version: 0.1.0
;; Package-Requires: ((emacs "27.1"))
;; URL: https://latin.craven.fr

;;; Commentary:
;;
;; Minor mode for looking up Latin words in a local Whitaker's Words
;; SQLite database (fully offline).
;;
;; Usage:
;;   M-x whittaker-mode
;;   With point on a Latin word, press C-c C-w.
;;   Results appear in the *Whittaker* buffer: lemma, English gloss,
;;   and a formatted inflection table.
;;
;; Auto-activation:
;;   Enabled in `latex-mode' / `LaTeX-mode' / `tex-mode'.
;;   Enabled in `org-mode' when the buffer declares Latin
;;   (`#+LANGUAGE: la' / `latin', a :lang: latin property, or a
;;   `latin' file tag).
;;   Enabled when `current-language-environment' is "Latin", when
;;   `ispell-local-dictionary' looks like Latin, when the file-local
;;   variable `whittaker-latin' is non-nil, or when the buffer text
;;   contains Latin vowels with macrons.
;;
;; Customization:
;;   `whittaker-db-path'       default ~/.local/share/whittakers/whittakers.db
;;   `whittaker-popup-height'  default 30
;;   `whittaker-lookup-key'    default C-c C-w
;;   `whittaker-lookup-timeout' default 5 (seconds per sqlite3 query)
;;   `whittaker-cache-size'    default 200 lookups kept in memory
;;
;; Queries run asynchronously (`start-process' + sentinel) so the UI
;; never blocks; a query slower than `whittaker-lookup-timeout' is
;; killed and reports "lookup timed out".  Results are cached in
;; memory (M-x whittaker-clear-cache to flush).  Space-separated
;; phrases ("intra se") are looked up token by token.  Unknown exact
;; forms fall back to stem matching (common endings stripped), so
;; 'amantis' finds 'amo' via 'amant'.
;;
;; Note: in Org, C-c C-w is also `org-refile'.  Customize
;; `whittaker-lookup-key' if that binding matters more.
;;
;; The database is produced by the Whittaker extract (kanban t_f8d8830f).
;; Schema: entries(lemma, definition, forms JSON, pos) and
;; form_index(form, lemma, tag).

;;; Code:

(require 'json)
(require 'seq)
(require 'cl-lib)

(defgroup whittaker nil
  "Offline Whitaker's Words lookup."
  :group 'languages
  :prefix "whittaker-")

(defcustom whittaker-db-path
  (expand-file-name "~/.local/share/whittakers/whittakers.db")
  "Path to the local Whitaker's Words SQLite database."
  :type 'file
  :group 'whittaker)

(defcustom whittaker-popup-height 30
  "Height in lines of the *Whittaker* popup window."
  :type 'integer
  :group 'whittaker)

(defcustom whittaker-lookup-key (kbd "C-c C-w")
  "Key sequence (in `whittaker-mode-map') for word-at-point lookup.
Changing this value rebuilds the mode map."
  :type 'key-sequence
  :group 'whittaker
  :set (lambda (symbol value)
         (set-default symbol value)
         (when (and (boundp 'whittaker-mode-map)
                    (keymapp whittaker-mode-map))
           (whittaker--rebuild-keymap))))

(defcustom whittaker-sqlite-program "sqlite3"
  "Name or path of the sqlite3 executable."
  :type 'string
  :group 'whittaker)

(defcustom whittaker-lookup-timeout 5
  "Seconds to wait for a sqlite3 query before reporting a timeout.
The sqlite3 process is spawned asynchronously (`start-process');
this caps how long a single lookup may take."
  :type 'number
  :group 'whittaker)

(defcustom whittaker-cache-size 200
  "Approximate number of lookups kept in the in-memory cache.
When exceeded, the cache is flushed wholesale."
  :type 'integer
  :group 'whittaker)

(define-error 'whittaker-error "Whittaker lookup error")
(define-error 'whittaker-lookup-timeout "lookup timed out" 'whittaker-error)

(defvar whittaker--cache (make-hash-table :test 'equal)
  "In-memory cache of recent lookups: normalized word -> hits or miss marker.")

(defconst whittaker--cache-miss-sym 'whittaker-cache-miss
  "Hash value stored for words that are genuinely not in the database.")

(defconst whittaker--uncached-sym 'whittaker-uncached
  "Sentinel meaning \"not in cache\" when used as a `gethash' default.")

(defvar whittaker--sql-query-count 0
  "Number of sqlite3 processes spawned by `whittaker--run-sql'.
Instrumentation for tests; see `whittaker-clear-cache'.")

(defconst whittaker-buffer-name "*Whittaker*"
  "Name of the dedicated results buffer.")

(defconst whittaker--macron-replacements
  '(("ā" "a") ("ē" "e") ("ī" "i") ("ō" "o") ("ū" "u") ("ȳ" "y")
    ("Ā" "A") ("Ē" "E") ("Ī" "I") ("Ō" "O") ("Ū" "U") ("Ȳ" "Y")
    ("ă" "a") ("ĕ" "e") ("ĭ" "i") ("ŏ" "o") ("ŭ" "u")
    ("Ă" "A") ("Ĕ" "E") ("Ĭ" "I") ("Ŏ" "O") ("Ŭ" "U"))
  "Macron and breve replacements for insensitive matching.")

(defvar-local whittaker-latin nil
  "Non-nil to treat this buffer as Latin (file-local safe).")
(put 'whittaker-latin 'safe-local-variable #'booleanp)

(defvar whittaker-mode-map (make-sparse-keymap)
  "Keymap for `whittaker-mode'.")

(defun whittaker--rebuild-keymap ()
  "Rebuild `whittaker-mode-map' from `whittaker-lookup-key'."
  (let ((map (make-sparse-keymap)))
    (define-key map whittaker-lookup-key #'whittaker-lookup-word-at-point)
    (setq whittaker-mode-map map)
    (when (boundp 'minor-mode-map-alist)
      (let ((cell (assq 'whittaker-mode minor-mode-map-alist)))
        (when cell
          (setcdr cell map))))))

(whittaker--rebuild-keymap)

;;;###autoload
(define-minor-mode whittaker-mode
  "Toggle Whitaker's Words lookup (offline Latin dictionary).

When enabled, \\<whittaker-mode-map>\\[whittaker-lookup-word-at-point] \
looks up the word at point in the local SQLite
database (`whittaker-db-path') and shows the lemma, English definition,
and inflection table in the *Whittaker* buffer.

Usage examples:
- Open a Latin .tex file, move point onto \"Amant\", press C-c C-w:
  the *Whittaker* popup opens showing \"amo\", the gloss \"love, like;
  ...\", \"This form: PRES ACTIVE IND 3 P\", and the full conjugation
  table.
- With point on a non-lemma form like \"amantis\", the same key falls
  back to stem matching and still finds \"amo\".
- M-x whittaker-lookup-word prompts for a word or phrase in any
  buffer; \"intra se\" is looked up token by token.
- M-x whittaker-clear-cache flushes the in-memory lookup cache.

This mode does not bind keys globally; it only adds
`whittaker-mode-map' while it is on, so it will not fight other
minor modes beyond the usual prefix-key precedence.

Commands:
\\<whittaker-mode-map>
\\[whittaker-lookup-word-at-point]  look up the word at point
\\[whittaker-lookup-word]  prompt for a word (also M-x)
\\[whittaker-clear-cache]  flush the in-memory lookup cache

Lookups run asynchronously, are cached in memory, split space-
separated phrases token by token, and fall back to stem matching
for non-lemma forms.  Auto-activation: see the Commentary in
whittaker-mode.el."
  :lighter " Whit"
  :keymap whittaker-mode-map
  :group 'whittaker)

;;;###autoload
(define-derived-mode whittaker-results-mode special-mode "Whittaker-Results"
  "Major mode for the *Whittaker* results popup.
Derived from `special-mode' (read-only, q to quit)."
  (setq buffer-read-only t)
  (setq-local truncate-lines nil))

;;;; Word at point and normalisation

(defconst whittaker--word-char-re
  "A-Za-zĀĒĪŌŪȲāēīōūȳĂĔĬŎŬăĕĭŏŭÆŒæœÀÁÂÄÈÉÊËÌÍÎÏÒÓÔÖÙÚÛÜŸàáâäèéêëìíîïòóôöùúûüÿ-"
  "Character class for a Latin word, including macrons and hyphenation.")

(defun whittaker-word-at-point ()
  "Return the Latin word at point, or nil.
Includes letters with macrons/breves and internal hyphens (line-break
hyphenation).  Surrounding punctuation is not included."
  (let ((chars whittaker--word-char-re))
    (save-excursion
      (skip-chars-backward chars)
      (let ((start (point)))
        (skip-chars-forward chars)
        (let ((raw (buffer-substring-no-properties start (point))))
          (unless (string-empty-p raw)
            raw))))))

(defun whittaker--strip-combining (string)
  "Remove combining macron/breve/acute marks from STRING."
  (replace-regexp-in-string "[\u0300-\u0304\u0306\u0308]" "" string))

(defun whittaker--strip-macrons (string)
  "Replace Latin vowels with macrons/breves in STRING with plain vowels."
  (setq string (whittaker--strip-combining string))
  (dolist (pair whittaker--macron-replacements)
    (setq string (replace-regexp-in-string (regexp-quote (car pair))
                                           (cadr pair)
                                           string
                                           t t)))
  string)

(defun whittaker-normalize-word (word)
  "Lowercase WORD, drop hyphens and trailing punctuation, strip macrons."
  (when word
    (setq word (downcase (string-trim word)))
    (setq word (replace-regexp-in-string "[-‐‑‒–—]" "" word))
    (setq word (replace-regexp-in-string "[[:punct:]]+$" "" word))
    (setq word (whittaker--strip-macrons word))
    (string-trim word)))

(defun whittaker--form-candidates (word)
  "Candidate surface forms to query for WORD (macron-sensitive and not)."
  (let* ((trimmed (replace-regexp-in-string "[[:punct:]]+$" ""
                                            (string-trim (downcase word))))
         (nohy (replace-regexp-in-string "[-‐‑‒–—]" "" trimmed))
         (stripped (whittaker-normalize-word word)))
    (delete-dups (delq nil (list nohy stripped)))))

;;;; SQLite

(defun whittaker--sql-escape (string)
  "Escape STRING for a SQLite single-quoted literal."
  (replace-regexp-in-string "'" "''" string t t))

(defun whittaker--sqlite3 ()
  "Return the sqlite3 executable path, or signal an error."
  (or (executable-find whittaker-sqlite-program)
      (error "Whittaker: sqlite3 executable not found (%s)"
             whittaker-sqlite-program)))

(defun whittaker--db ()
  "Return the expanded DB path, or signal if it is missing."
  (let ((path (expand-file-name whittaker-db-path)))
    (unless (file-readable-p path)
      (error "Whittaker: database not found: %s" path))
    path))

(defun whittaker--parse-sql-json (raw)
  "Parse sqlite3 -json output RAW into a list of alists (or nil)."
  (setq raw (string-trim raw))
  (if (string-empty-p raw)
      nil
    (let ((parsed (json-parse-string raw
                                     :object-type 'alist
                                     :array-type 'list
                                     :null-object nil
                                     :false-object nil)))
      (if (listp parsed) parsed nil))))

(defun whittaker--run-sql-async (sql callback)
  "Run SQL against `whittaker-db-path' asynchronously via the sqlite3 CLI.
CALLBACK is invoked exactly once with either a list of result
alists (nil for no rows) on success, or the symbol
`whittaker-sql-error' / `whittaker-lookup-timeout' on failure.
The spawned process is killed after `whittaker-lookup-timeout'
seconds; each spawn increments `whittaker--sql-query-count'."
  (let* ((db (whittaker--db))
         (exe (whittaker--sqlite3))
         (buf (generate-new-buffer " *whittaker-sqlite*"))
         (timer nil)
         (finished nil)
         (err-flag nil)
         (proc nil))
    (cl-labels
        ((finish
          (value)
          (unless finished
            (setq finished t
                  err-flag (and (symbolp value)
                                (memq value '(whittaker-sql-error
                                              whittaker-lookup-timeout))
                                value))
            (when timer (cancel-timer timer))
            ;; Kill the process BEFORE its output buffer so batch
            ;; sessions don't prompt about killing-while-killing.
            (when (and proc (memq (process-status proc) '(run stop)))
              (delete-process proc))
            (when (buffer-live-p buf) (kill-buffer buf))
            (funcall callback value)))
         (sentinel
          (aproc _event)
          (when (memq (process-status aproc) '(exit signal))
            (let ((raw (if (buffer-live-p buf)
                           (with-current-buffer buf (buffer-string))
                         ""))
                  (code (process-exit-status aproc)))
              (if (eq code 0)
                  (condition-case nil
                      (finish (whittaker--parse-sql-json raw))
                    (error (finish 'whittaker-sql-error)))
                (message "Whittaker: sqlite3 exited %s: %s"
                         code (string-trim raw))
                (finish 'whittaker-sql-error))))))
      (setq proc
            (condition-case err
                (start-process "whittaker-sqlite" buf exe "-json" db sql)
              (error
               (when (buffer-live-p buf) (kill-buffer buf))
               (signal (car err) (cdr err)))))
      (cl-incf whittaker--sql-query-count)
      (set-process-coding-system proc 'utf-8-unix 'utf-8-unix)
      (set-process-sentinel proc #'sentinel)
      (setq timer
            (run-at-time whittaker-lookup-timeout nil
                         (lambda ()
                           (when (and proc
                                      (memq (process-status proc) '(run stop)))
                             (kill-process proc))
                           (finish 'whittaker-lookup-timeout))))
      ;; A synchronous immediate exit (rare) may already have run the
      ;; sentinel; report a hard failure instead of returning silently.
      (when err-flag (signal err-flag nil))
      proc)))

(defun whittaker--run-sql (sql)
  "Run SQL through the async sqlite3 layer, waiting for its result.
Returns a list of result alists, or nil for no rows.  Signals
`whittaker-lookup-timeout' (displayed as \"lookup timed out\") if
the query does not finish within `whittaker-lookup-timeout'
seconds, or `whittaker-error' on sqlite failure.  Waiting happens
in `accept-process-output', so input events (and the kill timer)
keep being processed instead of a blocking `call-process'."
  (let ((result 'unset)
        (done nil))
    (whittaker--run-sql-async
     sql
     (lambda (res)
       (unless done
         (setq result res
               done t))))
    (let ((deadline (+ (float-time) whittaker-lookup-timeout 1.0)))
      (while (and (not done) (< (float-time) deadline))
        (accept-process-output nil 0.02 nil 1)))
    (cond
     ((not done) (signal 'whittaker-lookup-timeout nil))
     ((eq result 'whittaker-lookup-timeout)
      (signal 'whittaker-lookup-timeout nil))
     ((eq result 'whittaker-sql-error)
      (signal 'whittaker-error (list "sqlite3 query failed")))
     (t result))))

;;;; Cache

(defun whittaker-clear-cache ()
  "Discard all cached Whittaker lookups (and reset spawn counters)."
  (interactive)
  (setq whittaker--cache (make-hash-table :test 'equal))
  (setq whittaker--sql-query-count 0)
  (message "Whittaker: cache cleared"))

(defun whittaker--cache-put (key value)
  "Store VALUE under KEY, flushing the cache past `whittaker-cache-size'."
  (when (>= (hash-table-count whittaker--cache) whittaker-cache-size)
    (clrhash whittaker--cache))
  (puthash key value whittaker--cache))

;;;; Stem fallback

(defconst whittaker--endings
  '("arum" "orum" "ibus" "iae" "ae" "us" "um" "is" "io" "os" "as" "er" "i" "a" "o")
  "Common Latin inflectional endings stripped for stem-matching fallback.
Longest first so -orum is tried before -or-style suffixes.")

(defun whittaker--stem-candidates (word)
  "Return plausible stems for WORD by stripping `whittaker--endings'.
Stems shorter than 3 letters are dropped to avoid nonsense matches.
Candidates are tried against the form index, so bad guesses simply
match nothing."
  (let ((stems nil))
    (dolist (end whittaker--endings)
      (when (and (> (length word) (+ (length end) 2))
                 (string-suffix-p end word t))
        (let ((stem (substring word 0 (- (length word) (length end)))))
          (unless (member stem stems)
            (push stem stems)))))
    (nreverse stems)))

;;;; Compound splitting

(defun whittaker--compound-words (phrase)
  "Split PHRASE into word tokens (whitespace and common separators).
Returns a list of non-empty tokens in order; single words yield a
one-element list so compound phrases like \\=\"intra se\\=\" are
looked up token by token."
  (let ((tokens (split-string (string-trim phrase) "[[:space:]:,;.!?]+")))
    (delq nil (mapcar #'string-trim tokens))))

;;;; Query layer (cached)

(defun whittaker-query (word &optional no-stem)
  "Query the local DB for WORD.  Return a list of result alists.
Each alist has keys lemma, definition, forms, pos, tags.
Matches every candidate spelling of WORD (raw, normalized,
macron-stripped).  When no exact form matches, falls back to
stem-matching (strip `whittaker--endings' and match those forms or
lemmas), so non-lemma forms like \\='amantis' resolve via \\='amant'
-> \\='amo'.  NO-STEM suppresses the fallback.  Results are served
from `whittaker--cache' when possible (no sqlite3 spawn on a cache
hit)."
  (let* ((key (concat (whittaker-normalize-word word)
                      (if no-stem "" "*")))
         (cached (gethash key whittaker--cache whittaker--uncached-sym)))
    (cond
     ((eq cached whittaker--uncached-sym)
      (let ((hits (whittaker--query-uncached word no-stem)))
        (whittaker--cache-put key (or hits whittaker--cache-miss-sym))
        hits))
     ((eq cached whittaker--cache-miss-sym) nil)
     (t cached))))

(defun whittaker--query-sql (exact-cands stem-cands)
  "One sqlite3 query: rows for EXACT-CANDS plus STEM-CANDS forms.
Rows from an exact form match sort first and carry their tags;
stem-derived rows carry no \\='This form\\=' tags."
  (let* ((all (append exact-cands stem-cands))
         (in-list (mapconcat (lambda (w)
                               (format "'%s'" (whittaker--sql-escape w)))
                             all ", "))
         (exact-list (mapconcat (lambda (w)
                                  (format "'%s'" (whittaker--sql-escape w)))
                                exact-cands ", "))
         (sql (format
               (concat
                "SELECT e.lemma AS lemma, e.definition AS definition, "
                "e.forms AS forms, e.pos AS pos, "
                "group_concat(CASE WHEN fi.form IN (%s) THEN fi.tag END, "
                "' | ') AS tags, "
                "MAX(fi.form IN (%s)) AS exact "
                "FROM form_index fi "
                "JOIN entries e ON e.lemma = fi.lemma "
                "WHERE fi.form IN (%s) "
                "GROUP BY e.lemma "
                "ORDER BY exact DESC, e.lemma")
               exact-list exact-list in-list)))
    (whittaker--run-sql sql)))

(defun whittaker--query-uncached (word &optional no-stem)
  "Uncached DB query for WORD; see `whittaker-query'."
  (let* ((candidates (whittaker--form-candidates word))
         (hits (whittaker--query-sql
                candidates
                (unless no-stem
                  (whittaker--stem-candidates
                   (or (car (last candidates)) word))))))
    (unless hits
      ;; No form matched: try WORD itself (and its normalized form)
      ;; as a lemma name, e.g. dictionary headwords stored as lemmas.
      (let ((in-list (mapconcat (lambda (w)
                                  (format "'%s'" (whittaker--sql-escape w)))
                                candidates ", ")))
        (setq hits
              (whittaker--run-sql
               (format
                (concat
                 "SELECT lemma, definition, forms, pos, NULL AS tags "
                 "FROM entries WHERE lemma IN (%s) ORDER BY lemma")
                in-list)))))
    hits))

;;;; Formatting

(defun whittaker--forms-data (forms)
  "Parse FORMS (JSON string or already-parsed object) to an alist."
  (cond
   ((null forms) nil)
   ((listp forms) forms)
   ((stringp forms)
    (condition-case nil
        (json-parse-string forms
                           :object-type 'alist
                           :array-type 'list
                           :null-object nil
                           :false-object nil)
      (error nil)))
   (t nil)))

(defun whittaker--alist-get (key alist)
  "Like `alist-get' but KEY may be a symbol or string."
  (or (alist-get key alist nil nil #'equal)
      (alist-get (if (symbolp key) (symbol-name key) (intern key))
                 alist nil nil #'equal)))

(defconst whittaker--tense-order
  '("PRES" "IMPF" "FUT" "PERF" "PLUP" "FUTP")
  "Row order for conjugation tables.")

(defconst whittaker--person-order
  '("1 S" "2 S" "3 S" "1 P" "2 P" "3 P")
  "Column order for finite verb tables.")

(defun whittaker--tag-parts (tag)
  "Split TAG into a list of tokens."
  (and tag (split-string tag)))

(defun whittaker--finite-key (parts)
  "Return (MOOD VOICE TENSE PERSON-NUMBER) for token list PARTS, or nil."
  (let ((mood (seq-find (lambda (p) (member p '("IND" "SUB"))) parts))
        (voice (seq-find (lambda (p) (member p '("ACTIVE" "PASSIVE"))) parts))
        (tense (seq-find (lambda (p) (member p whittaker--tense-order)) parts))
        (person (seq-find (lambda (p) (member p '("1" "2" "3"))) parts))
        (number (seq-find (lambda (p) (member p '("S" "P"))) parts)))
    (when (and mood voice tense person number)
      (list mood voice tense (concat person " " number)))))

(defun whittaker--other-kind (parts)
  "Classify non-finite PARTS as INF, IMP, or other."
  (cond
   ((member "INF" parts) 'inf)
   ((member "IMP" parts) 'imp)
   (t 'other)))

(defun whittaker--collect-forms (table)
  "From TABLE (list of {form,tag} alists) group finite and other forms."
  (let ((grid (make-hash-table :test 'equal))
        (others nil))
    (dolist (row table)
      (let* ((form (whittaker--alist-get 'form row))
             (tag (whittaker--alist-get 'tag row))
             (parts (whittaker--tag-parts tag))
             (key (whittaker--finite-key parts)))
        (cond
         ((not (and form tag)))
         (key
          (let ((cell (gethash key grid)))
            (unless (member form cell)
              (puthash key (append cell (list form)) grid))))
         (t
          (push (cons tag form) others)))))
    (cons grid (nreverse others))))

(defun whittaker--pad (string width)
  "Pad STRING on the right to WIDTH."
  (if (>= (length string) width)
      string
    (concat string (make-string (- width (length string)) ?\s))))

(defun whittaker--pad-row (cells widths)
  "Pad CELLS to WIDTHS (plus 2) and concatenate."
  (let ((out "")
        (cs cells)
        (ws widths))
    (while (and cs ws)
      (setq out (concat out (whittaker--pad (car cs) (+ (car ws) 2))))
      (setq cs (cdr cs)
            ws (cdr ws)))
    out))

(defun whittaker--format-grid (grid mood voice)
  "Format finite verb GRID for MOOD and VOICE as a text table."
  (let* ((rows
          (mapcar
           (lambda (tense)
             (cons tense
                   (mapcar
                    (lambda (pn)
                      (let ((forms (gethash (list mood voice tense pn) grid)))
                        (if forms (mapconcat #'identity forms "/") "-")))
                    whittaker--person-order)))
           whittaker--tense-order))
         (rows (seq-filter (lambda (r) (seq-some (lambda (c) (not (string= c "-")))
                                                 (cdr r)))
                           rows)))
    (when rows
      (let* ((headers (cons "" whittaker--person-order))
             (widths
              (let ((acc nil)
                    (cols (1+ (length whittaker--person-order))))
                (dotimes (i cols)
                  (let ((width (length (nth i headers))))
                    (dolist (r rows)
                      (let ((cell (nth i (cons (car r) (cdr r)))))
                        (setq width (max width (length cell)))))
                    (push width acc)))
                (nreverse acc))))
        (concat
         (format "  %s %s\n" mood voice)
         "  "
         (whittaker--pad-row headers widths)
         "\n  "
         (mapconcat (lambda (r)
                      (whittaker--pad-row (cons (car r) (cdr r)) widths))
                    rows
                    "\n  ")
         "\n")))))

(defun whittaker--format-forms (forms-raw)
  "Return a human-readable inflection table from FORMS-RAW."
  (let* ((data (whittaker--forms-data forms-raw))
         (parts (whittaker--alist-get 'principal_parts data))
         (table (whittaker--alist-get 'table data))
         (out ""))
    (when (and parts (listp parts))
      (let ((clean (seq-filter (lambda (p)
                                 (and (stringp p)
                                      (string-match-p "^[A-Za-zāēīōūȳ]+$" p)))
                               parts)))
        (when clean
          (setq out (concat out "  Principal parts: "
                            (mapconcat #'identity clean ", ")
                            "\n\n")))))
    (if (not (listp table))
        (if (and forms-raw (stringp forms-raw))
            (concat out forms-raw)
          out)
      (let* ((collected (whittaker--collect-forms table))
             (grid (car collected))
             (others (cdr collected)))
        (dolist (mood '("IND" "SUB"))
          (dolist (voice '("ACTIVE" "PASSIVE"))
            (let ((block (whittaker--format-grid grid mood voice)))
              (when block
                (setq out (concat out block "\n"))))))
        (when others
          (setq out (concat out "  Other forms:\n"))
          (dolist (pair others)
            (setq out (concat out (format "    %-28s %s\n"
                                          (car pair) (cdr pair))))))
        out))))

(defun whittaker--format-hits (word hits)
  "Format one token WORD with HITS as one result block."
  (let ((chunks nil))
    (push (format "%s\n" word) chunks)
    (if (null hits)
        (push (format "  Not found: %s\n" word) chunks)
      (dolist (hit hits)
        (let* ((lemma (whittaker--alist-get 'lemma hit))
               (def (or (whittaker--alist-get 'definition hit) ""))
               (pos (or (whittaker--alist-get 'pos hit) ""))
               (tags (whittaker--alist-get 'tags hit))
               (forms (whittaker--alist-get 'forms hit)))
          (push (format "\n── %s%s\n  %s\n%s\nInflection table:\n%s"
                        lemma
                        (if (and pos (not (string-empty-p pos)))
                            (format "  [%s]" pos)
                          "")
                        def
                        (if (and tags (not (string= tags "null"))
                                 (not (string= tags "None"))
                                 (not (string-empty-p tags)))
                            (format "  This form: %s\n" tags)
                          "")
                        (or (whittaker--format-forms forms)
                            "  (no inflection table)\n"))
                chunks))))
    (mapconcat #'identity (nreverse chunks) "")))

(defun whittaker--header (word)
  "Return the *Whittaker* header line for queried WORD.
Shows the word as queried (plus the normalized spelling when it
differs) and the lookup timestamp."
  (let ((norm (whittaker-normalize-word word)))
    (format "Whittaker's Words:  %s%s   [%s]\n"
            word
            (if (and norm (not (string= (downcase word) norm)))
                (format "  (normalized: %s)" norm)
              "")
            (format-time-string "%Y-%m-%d %H:%M:%S"))))

(defun whittaker--format-results (word sections)
  "Format WORD and SECTIONS (list of (TOKEN HITS...) ) for *Whittaker*.
One token per section; multi-token phrases (e.g. \"intra se\") get
one result block per token.  A header line names the query and the
lookup timestamp."
  (let ((chunks (list (whittaker--header word))))
    (dolist (section sections)
      (let ((token (car section))
            (hits (cdr section)))
        (push (whittaker--format-hits token hits) chunks)))
    (push "\nM-x whittaker-lookup-word to try another spelling.\n" chunks)
    (mapconcat #'identity (nreverse chunks) "")))

;;;; Display

(defun whittaker--show (text)
  "Show TEXT in the reusable *Whittaker* popup (~`whittaker-popup-height' lines)."
  (let ((buf (get-buffer-create whittaker-buffer-name)))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert text)
        (goto-char (point-min))
        (unless (eq major-mode 'whittaker-results-mode)
          (whittaker-results-mode))))
    (let ((window (display-buffer
                   buf
                   `((display-buffer-reuse-window
                      display-buffer-below-selected)
                     (window-height . ,whittaker-popup-height)
                     (reusable-frames . visible)))))
      (when (window-live-p window)
        (set-window-start window (with-current-buffer buf (point-min)))))
    buf))

;;;; Commands

(defun whittaker--lookup (phrase)
  "Look up PHRASE (one word, or a space-separated compound) and show it.
Phrases are split into tokens and each token is looked up
separately; results appear as one block per token in *Whittaker*.
Empty/blank PHRASE yields a gentle message, no error.  A sqlite3
query exceeding `whittaker-lookup-timeout' shows \"lookup timed
out\".  Returns the results buffer or nil."
  (let ((phrase (string-trim phrase)))
    (if (string-match-p "\\`[[:space:]]*\\'" phrase)
        (progn
          (message "Whittaker: no word at point")
          nil)
      (let ((tokens (whittaker--compound-words phrase))
            (sections nil)
            (failed nil))
        (dolist (token tokens)
          (condition-case err
              (push (cons token (whittaker-query token)) sections)
            (whittaker-lookup-timeout
             (setq failed 'timeout))
            (error
             (setq failed (error-message-string err)))))
        (cond
         (failed
          (if (eq failed 'timeout)
              (progn
                (whittaker--show
                 (concat (whittaker--header phrase)
                         "Whittaker: lookup timed out\n"))
                (message "Whittaker: lookup timed out"))
            (whittaker--show
             (concat (whittaker--header phrase)
                     (format "Whittaker error: %s\n" failed)))
            (message "Whittaker: %s" failed))
          (get-buffer whittaker-buffer-name))
         (t
          (setq sections (nreverse sections))
          (whittaker--show (whittaker--format-results phrase sections))
          (let ((found (seq-some (lambda (s) (cdr s)) sections)))
            (if found
                (message "Whittaker: %s → %s"
                         phrase
                         (mapconcat
                          (lambda (s)
                            (mapconcat (lambda (h)
                                         (whittaker--alist-get 'lemma h))
                                       (cdr s) "/"))
                          sections ", "))
              (message "Whittaker: %s not found" phrase)))
          (get-buffer whittaker-buffer-name)))))))

;;;###autoload
(defun whittaker-lookup-word-at-point ()
  "Look up the Latin word at point and show it in *Whittaker*.
Hyphenation and macrons are accepted; matching is macron-insensitive.
Nothing at point shows a gentle message (use M-x whittaker-lookup-word
to type a word or phrase, e.g. \"intra se\)."
  (interactive)
  (let ((word (whittaker-word-at-point)))
    (if (or (null word) (string-match-p "\\`[[:space:]]*\\'" word))
        (progn
          (message "Whittaker: no word at point")
          nil)
      (whittaker--lookup word))))

;;;###autoload
(defun whittaker-lookup-word (phrase)
  "Prompt for PHRASE and look it up in the local Whitaker database.
Works outside Latin buffers (bind it globally if you like).
Space-separated phrases such as \"intra se\" are looked up word by
word and shown as separate result blocks."
  (interactive "sWhitaker lookup: ")
  (whittaker--lookup phrase))

;;;; Latin detection / auto-activation

(defun whittaker--org-latin-p ()
  "Return non-nil if this Org buffer is tagged as Latin."
  (save-excursion
    (save-restriction
      (widen)
      (goto-char (point-min))
      (or (re-search-forward
           "^[ \t]*#\\+LANGUAGE:[ \t]*\\(la\\|latin\\)\\b" nil t)
          (re-search-forward
           "^[ \t]*#\\+\\(PROPERTY\\|property\\):[ \t]+lang[ \t]+latin\\b"
           nil t)
          (re-search-forward
           "^[ \t]*#\\+FILETAGS:.*:latin:" nil t)
          (and (fboundp 'org-get-tags)
               (let ((tags (ignore-errors (org-get-tags))))
                 (and tags
                      (seq-some (lambda (tg)
                                  (member (downcase tg) '("latin" "la")))
                                tags))))))))

(defun whittaker--ispell-latin-p ()
  "Return non-nil if ispell dictionary looks like Latin."
  (and (boundp 'ispell-local-dictionary)
       (stringp ispell-local-dictionary)
       (string-match-p "\\`lat" (downcase ispell-local-dictionary))))

(defun whittaker--buffer-has-macrons-p ()
  "Return non-nil if the accessible buffer contains Latin macron vowels."
  (save-excursion
    (save-restriction
      (widen)
      (goto-char (point-min))
      (re-search-forward "[āēīōūȳĀĒĪŌŪȲ]" nil t))))

(defun whittaker-latin-buffer-p ()
  "Return non-nil if the current buffer should use Whittaker."
  (or whittaker-latin
      (memq major-mode '(latex-mode LaTeX-mode tex-mode plain-tex-mode))
      (and (eq major-mode 'org-mode) (whittaker--org-latin-p))
      (and (stringp current-language-environment)
           (string-equal (downcase current-language-environment) "latin"))
      (whittaker--ispell-latin-p)
      (whittaker--buffer-has-macrons-p)))

;;;###autoload
(defun whittaker-mode-maybe-enable ()
  "Turn on `whittaker-mode' when this buffer looks like Latin."
  (when (whittaker-latin-buffer-p)
    (whittaker-mode 1)))

;;;###autoload
(add-hook 'latex-mode-hook #'whittaker-mode)
;;;###autoload
(add-hook 'LaTeX-mode-hook #'whittaker-mode)
;;;###autoload
(add-hook 'tex-mode-hook #'whittaker-mode)
;;;###autoload
(add-hook 'org-mode-hook #'whittaker-mode-maybe-enable)
;;;###autoload
(add-hook 'hack-local-variables-hook #'whittaker-mode-maybe-enable)

(defun whittaker--unload-function ()
  "Remove hooks when the feature is unloaded."
  (remove-hook 'latex-mode-hook #'whittaker-mode)
  (remove-hook 'LaTeX-mode-hook #'whittaker-mode)
  (remove-hook 'tex-mode-hook #'whittaker-mode)
  (remove-hook 'org-mode-hook #'whittaker-mode-maybe-enable)
  (remove-hook 'hack-local-variables-hook #'whittaker-mode-maybe-enable)
  nil)

(provide 'whittaker-mode)

;;; whittaker-mode.el ends here
