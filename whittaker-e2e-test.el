;;; whittaker-e2e-test.el --- End-to-end test for whittaker-mode  -*- lexical-binding: t; -*-
;;
;; Run: emacs -Q --batch -l whittaker-e2e-test.el
;; Exits 0 when every assertion passes.
;;
;; Covers the full user pipeline offline:
;; - C-c C-w on "Amant" in a Latin buffer -> *Whittaker* shows amo,
;;   gloss, this-form tag, conjugation table.
;; - Non-lemma form falls back to stem matching ("amantis" -> "amo").
;; - Popup header names the queried word and a lookup timestamp.
;; - A second press on another word replaces the popup.
;; - No network calls: network primitives are advised to record and
;;   abort; the pipeline must never touch them.
;; - Warm-cache repeat lookup answers in well under 1 second.

(setq debug-on-error t)

(defvar whittaker-e2e-dir
  (file-name-directory (or load-file-name buffer-file-name)))
(add-to-list 'load-path whittaker-e2e-dir)
(require 'whittaker-mode)

(defvar whittaker-e2e-network-hits 0
  "Count of attempted network calls during the e2e run.")

(defun whittaker-e2e--no-network (&rest _args)
  "Record an attempted network call and abort it."
  (cl-incf whittaker-e2e-network-hits)
  (signal 'whittaker-error (list "network call attempted in offline test")))

(dolist (fn '(make-network-process open-network-stream url-retrieve
              url-retrieve-synchronously url-open-file))
  (when (fboundp fn)
    (advice-add fn :before #'whittaker-e2e--no-network)))

(defun whittaker-e2e--assert (pred msg)
  (unless pred
    (error "FAIL: %s" msg))
  (message "ok: %s" msg))

;;;; 1. Real keypress pipeline: C-c C-w on "Amant"

(defun whittaker-e2e--latin-buffer (text)
  "Return a displayed buffer in latex-mode containing TEXT.
A real window-buffer: `execute-kbd-macro' resolves keys through the
selected window in batch, not just the current buffer.  Point is
left at point-min."
  (let ((buf (generate-new-buffer " *whittaker-e2e-latin*")))
    (with-current-buffer buf
      (insert text)
      (delay-mode-hooks (latex-mode))
      (whittaker-mode 1)
      (goto-char (point-min)))
    (switch-to-buffer buf)
    buf))

(defun whittaker-e2e--press-on (word)
  "Move point onto WORD in the current buffer and press C-c C-w."
  (goto-char (point-min))
  (search-forward word)
  (execute-kbd-macro (kbd "C-c C-w")))

(defun whittaker-e2e--popup-text ()
  (with-current-buffer whittaker-buffer-name (buffer-string)))

(whittaker-clear-cache)
(let ((buf (whittaker-e2e--latin-buffer "Amant amantur. Intra se disputant.")))
  (whittaker-e2e--press-on "Amant")
  (kill-buffer buf)
  (let ((text (whittaker-e2e--popup-text)))
    (whittaker-e2e--assert (string-match-p "\n── amo  \\[V\\]" text)
                           "C-c C-w on Amant shows lemma amo [V]")
    (whittaker-e2e--assert (string-match-p "love, like" text)
                           "shows English gloss")
    (whittaker-e2e--assert (string-match-p "PRES ACTIVE IND 3 P" text)
                           "shows this-form tag for amant")
    (whittaker-e2e--assert (and (string-match-p "amas" text)
                                (string-match-p "amatis" text)
                                (string-match-p "amantur" text))
                           "shows conjugation table (act+pass forms)")
    ;; Header: queried word + timestamp "[....-..-.. ..:..:..]"
    (whittaker-e2e--assert (string-match-p "\\`Whittaker's Words:  Amant " text)
                           "header names the queried word")
    (whittaker-e2e--assert (string-match-p "\\[....-..-.. ..:..:..\\]" text)
                           "header shows lookup timestamp")))

;;;; 2. Second press on another word replaces the popup

(let ((buf (whittaker-e2e--latin-buffer "Amant amantur. Intra se disputant.")))
  (whittaker-e2e--press-on "disputant")
  (kill-buffer buf)
  (let ((text (whittaker-e2e--popup-text)))
    (whittaker-e2e--assert (string-match-p "\\`Whittaker's Words:  disputant"
                                           text)
                           "popup reused and replaced for new query")
    (whittaker-e2e--assert (string-match-p "\n── disputo" text)
                           "disputant resolves to lemma disputo")))

;;;; 3. Non-lemma form: stem fallback via C-c C-w

(let ((buf (whittaker-e2e--latin-buffer "memoria amantis")))
  (whittaker-e2e--press-on "amantis")
  (kill-buffer buf)
  (let ((text (whittaker-e2e--popup-text)))
    (whittaker-e2e--assert (string-match-p "\n── amo" text)
                           "stem fallback: amantis resolves to amo")))

;;;; 4. Phrase lookup through the pipeline (prompt path, no completion)

(whittaker-lookup-word "intra se")
(let ((text (with-current-buffer whittaker-buffer-name (buffer-string))))
  (whittaker-e2e--assert (and (string-match-p "\n── intra" text)
                              (string-match-p "\n── zzz" text))
                         "phrase 'intra se' yields two lemma blocks"))

;;;; 5. Latency: uncached and cached lookups under one second

(whittaker-clear-cache)
(let ((start (float-time)))
  (whittaker-lookup-word "amavissent")
  (let ((uncached (- (float-time) start)))
    (whittaker-e2e--assert (< uncached 1.0)
                           (format "cold lookup under 1s (%.3fs)" uncached))
    (setq start (float-time))
    (whittaker-lookup-word "amavissent")
    (let ((warm (- (float-time) start)))
      (whittaker-e2e--assert (< warm 0.25)
                             (format "cached lookup near-instant (%.4fs)" warm)))))

;;;; 6. Fully offline: no network primitive was ever entered

(whittaker-e2e--assert (= whittaker-e2e-network-hits 0)
                       "zero network calls during full pipeline")

(message "E2E: ALL CHECKS PASSED")
(kill-emacs 0)

;;; whittaker-e2e-test.el ends here
