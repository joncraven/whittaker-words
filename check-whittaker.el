;;; check-whittaker.el --- Smoke checks for t_d8caccbb  -*- lexical-binding: t; -*-
;; Run: emacs -Q --batch -l check-whittaker.el
(setq debug-on-error t)
(defvar whittaker-check-dir
  (file-name-directory (or load-file-name buffer-file-name)))
(add-to-list 'load-path whittaker-check-dir)
(require 'whittaker-mode)

(defun whittaker-check--assert (pred msg)
  (unless pred
    (error "FAIL: %s" msg))
  (message "ok: %s" msg))

(whittaker-check--assert (string-suffix-p "whittakers/whittakers.db"
                                          (expand-file-name whittaker-db-path))
                         "default db path ends with ~/.local/share/whittakers/whittakers.db")

(whittaker-check--assert (eq whittaker-popup-height 30)
                         "default popup height is 30")

(whittaker-check--assert (equal (whittaker-normalize-word "Amāvit!") "amavit")
                         "normalize Amāvit! → amavit")

(whittaker-check--assert (equal (whittaker-normalize-word "amā-vit") "amavit")
                         "normalize hyphenation amā-vit → amavit")

(with-temp-buffer
  (insert "xxx amāvit yyy")
  (goto-char (point-min))
  (search-forward "ā")
  (whittaker-check--assert (string= (whittaker-word-at-point) "amāvit")
                           "word-at-point on amāvit"))

(with-temp-buffer
  (whittaker-mode 1)
  (whittaker-check--assert (eq (lookup-key whittaker-mode-map (kbd "C-c C-w"))
                               #'whittaker-lookup-word-at-point)
                           "C-c C-w bound while mode on")
  (whittaker-mode -1)
  (whittaker-check--assert (null whittaker-mode)
                           "mode toggles off"))

(with-temp-buffer
  (delay-mode-hooks (latex-mode))
  (run-mode-hooks 'latex-mode-hook)
  (whittaker-check--assert whittaker-mode
                           "auto-enabled in latex-mode"))

(with-temp-buffer
  (insert "amāvit")
  (goto-char (point-min))
  (whittaker-mode 1)
  (whittaker-lookup-word-at-point)
  (let ((text (with-current-buffer whittaker-buffer-name (buffer-string))))
    (whittaker-check--assert (string-match-p "\\bamo\\b" text)
                             "lookup amāvit shows lemma amo")
    (whittaker-check--assert (string-match-p "love" text)
                             "lookup amāvit shows English definition")
    (whittaker-check--assert (string-match-p "PERF ACTIVE IND 3 S" text)
                             "lookup amāvit shows this-form tag")
    (whittaker-check--assert (and (string-match-p "amavit" text)
                                  (string-match-p "amas" text)
                                  (string-match-p "IND ACTIVE" text))
                             "lookup amāvit shows conjugation table")))

(whittaker-lookup-word "zzzznotaword")
(let ((text (with-current-buffer whittaker-buffer-name (buffer-string))))
  (whittaker-check--assert (string-match-p "Not found" text)
                           "unknown word shows not found"))

;;;; t_19ac43b0: stem fallback, compounds, timeout, cache, popup reuse

(whittaker-clear-cache)

;; Stem fallback: 'amantis' is not an indexed form; stripping -is
;; yields stem 'amant' which IS an indexed form of 'amo'.
(let ((hits (whittaker-query "amantis")))
  (whittaker-check--assert
   (and hits
        (member "amo" (mapcar (lambda (h)
                                (whittaker--alist-get 'lemma h))
                              hits)))
   "stem fallback: amantis resolves to amo"))

(whittaker-lookup-word "amantis")
(with-current-buffer whittaker-buffer-name
  (whittaker-check--assert (string-match-p "\n── amo" (buffer-string))
                           "lookup amantis popup shows amo block"))

;; Compound: two tokens -> one result block section per token.
(whittaker-lookup-word "intra se")
(with-current-buffer whittaker-buffer-name
  (let ((text (buffer-string)))
    (whittaker-check--assert (string-match-p "\nintra\n" text)
                             "compound 'intra se' shows intra section")
    (whittaker-check--assert (string-match-p "\nse\n" text)
                             "compound 'intra se' shows se section")
    (whittaker-check--assert (string-match-p "── intra" text)
                             "compound shows intra lemma block")
    (whittaker-check--assert (string-match-p "── zzz" text)
                             "compound shows se pronoun block")))

;; Cache: repeated lookup of the same word spawns no new sqlite3.
(whittaker-clear-cache)
(whittaker-query "amavit")
(let ((count-after-first whittaker--sql-query-count))
  (whittaker-check--assert (> count-after-first 0)
                           "first uncached query spawns sqlite3")
  (whittaker-query "amavit")
  (whittaker-query "amāvit")
  (whittaker-check--assert (= whittaker--sql-query-count count-after-first)
                           "repeat lookups served from cache (no new spawn)"))

;; Misses are cached too.
(whittaker-clear-cache)
(whittaker-query "qqzznotaword")
(let ((count-after-first whittaker--sql-query-count))
  (whittaker-query "qqzznotaword")
  (whittaker-check--assert (= whittaker--sql-query-count count-after-first)
                           "cache miss does not re-spawn"))

;; Timeout: slow sqlite3 stub is killed and shows 'lookup timed out'.
(let* ((stub (expand-file-name "whittaker-slow-sqlite.sh"
                               temporary-file-directory))
       (whittaker-sqlite-program stub)
       (whittaker-lookup-timeout 1))
  (with-temp-file stub
    (insert "#!/bin/sh\nsleep 30\n"))
  (set-file-modes stub #o755)
  (whittaker-clear-cache)
  (let ((start (float-time)))
    (whittaker-lookup-word "amo")
    (let ((elapsed (- (float-time) start))
          (text (with-current-buffer whittaker-buffer-name
                  (buffer-string))))
      (whittaker-check--assert (string-match-p "lookup timed out" text)
                               "slow query shows 'lookup timed out'")
      (whittaker-check--assert (< elapsed 5.0)
                               "timeout returns promptly (no hang)")
      (delete-file stub))))

;; Popup buffer is reused (same buffer object) and scrolled to top.
(let ((buf-first (get-buffer-create whittaker-buffer-name)))
  (with-current-buffer buf-first (goto-char (point-max)))
  (whittaker-lookup-word "amo")
  (whittaker-check--assert (eq buf-first (get-buffer whittaker-buffer-name))
                           "*Whittaker* buffer reused, not recreated")
  (with-current-buffer (get-buffer whittaker-buffer-name)
    (whittaker-check--assert (= (point) (point-min))
                             "new result scrolls to top")))

;; Empty word: gentle message, no error.
(with-temp-buffer
  (whittaker-mode 1)
  (goto-char (point-min))
  (let ((inhibit-message t))
    (whittaker-lookup-word-at-point))
  (whittaker-check--assert t "empty word-at-point does not error"))
(let ((inhibit-message t))
  (whittaker--lookup "   "))
(whittaker-check--assert t "blank phrase does not error")

(message "ALL CHECKS PASSED")
(kill-emacs 0)
