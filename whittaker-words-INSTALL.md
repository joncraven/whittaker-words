# Whittaker's Words for Emacs — install on a fresh machine

**Quick path:** `cd words-emacs && ./install.sh` does every step below
automatically and is idempotent. This document is the manual walkthrough
and troubleshooting reference.

Getting this folder onto the new machine is the only prerequisite:
`git clone` the latin-audiobooks repo, or just copy the `words-emacs/`
directory (it is self-contained — 5 files, ~90 KB) via scp/rsync.

Copy-paste this guide top to bottom. Lookups are fully offline after the one-time dictionary build.

This directory (`words-emacs/`) is the package: `whittaker-mode.el`, tests, and `extract.py`. No MELPA / `package.el` / straight.el / quelpa package is required.

Set this once in the shell you will paste into (the folder that contains this file):

```sh
export WORDS_SRC="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
```

If `$0` is not this file (interactive paste), set it by hand instead:

```sh
export WORDS_SRC="$HOME/src/words-emacs"
```

Do **not** copy paths from the original build machine (`/Users/hermes/...`, `/Volumes/RAID10/...`). Use `$HOME` / `$WORDS_SRC` only.

Original-build reference (do not reuse these paths): GNU Emacs 30.2, sqlite3 3.51.0, Python 3.9.6 on macOS; database ~294 MB, 35 671 lemmas, ~1.49 M indexed forms.

---

## A. System prerequisites

### 1. Confirm a Unix-like OS

macOS or Linux. The default database path is `$HOME/.local/share/whittakers/whittakers.db` (XDG). On Windows, skip that default and set `whittaker-db-path` in step 16 to something under `%APPDATA%`.

### 2. Confirm Emacs 27.1 or newer

```sh
emacs --version | head -1
```

Need GNU Emacs 27.1+ (`json-parse-string`, `lexical-binding`). `whittaker-mode.el` declares `Package-Requires: ((emacs "27.1"))`.

### 3. Confirm `sqlite3` with `-json`

```sh
sqlite3 -json :memory: "SELECT 1 AS n;"
```

Expect `[{"n":1}]`. The mode launches `sqlite3 -json <db> <sql>` via `start-process`. SQLite 3.33.0+ ships the `-json` CLI flag. macOS system `/usr/bin/sqlite3` is fine when that check passes.

### 4. Confirm Python 3.9+ (stdlib only)

```sh
python3 --version
```

`extract.py` uses only the stdlib (`json`, `sqlite3`, `pathlib`). No pip packages.

### 5. Confirm `git`

```sh
git --version
```

Needed once, to clone Whitaker's WORDS data.

### 6. Confirm disk headroom

```sh
df -h "$HOME"
```

Budget about **400 MB** under `$HOME/.local/share/whittakers/` (source tree + ~294 MB SQLite file). No extra fonts or environment variables.

### 7. Create the data directory

```sh
mkdir -p "$HOME/.local/share/whittakers"
```

### 8. Install the extractor next to that directory

```sh
cp "$WORDS_SRC/extract.py" "$HOME/.local/share/whittakers/extract.py"
```

`extract.py` writes `whittakers.db` **beside itself** and expects a checkout named `whitakers-words-src` in the same folder. That is why it lives here, not in `$WORDS_SRC`.

### 9. Clone Whitaker's WORDS (one-time network)

```sh
git clone --depth 1 https://github.com/mk270/whitakers-words.git "$HOME/.local/share/whittakers/whitakers-words-src"
```

Provenance: William Whitaker (1936–2010); permission freely given for any use of program and data (`LICENCE.txt` in that tree). Files used: `DICTLINE.GEN` (Latin-1), `INFLECTS.LAT`, `UNIQUES.LAT`.

### 10. Build the offline SQLite database

```sh
python3 "$HOME/.local/share/whittakers/extract.py"
```

Takes on the order of one minute. Success prints `wrote .../whittakers.db with 35671 entries` and a sample `amo` line. The file is `$HOME/.local/share/whittakers/whittakers.db`.

### 11. Verify the database

```sh
sqlite3 "$HOME/.local/share/whittakers/whittakers.db" "SELECT lemma, pos, substr(definition,1,60) FROM entries WHERE lemma='amo';"
```

Expect a row starting `amo|V|love, like;`.

---

## B. Emacs package installation

There is no ELPA package. The mode is one standalone file.

### 12. Create the personal lisp directory

```sh
mkdir -p "$HOME/.emacs.d/lisp"
```

### 13. Install the mode file

```sh
cp "$WORDS_SRC/whittaker-mode.el" "$HOME/.emacs.d/lisp/whittaker-mode.el"
```

### 14. Byte-compile it

```sh
emacs -Q --batch -f batch-byte-compile "$HOME/.emacs.d/lisp/whittaker-mode.el"
```

Expect no warnings. This writes `$HOME/.emacs.d/lisp/whittaker-mode.elc`.

---

## C. Configuration (`init.el` / `~/.emacs`)

### 15. Append this snippet to `$HOME/.emacs` (or `$HOME/.emacs.d/init.el` if that is what you use)

```elisp
;;;; Whittaker's Words: offline Latin lookup (whittaker-mode)
(add-to-list 'load-path "~/.emacs.d/lisp")
(require 'whittaker-mode)
```

Optional `use-package` wrapper (same files; still no archive):

```elisp
(use-package whittaker-mode
  :load-path "~/.emacs.d/lisp"
  :demand t)
```

Do not set `whittaker-db-path` unless the database is not at `$HOME/.local/share/whittakers/whittakers.db`.

### 16. (Optional) Windows / non-XDG database path

```elisp
(setq whittaker-db-path (expand-file-name "whittakers/whittakers.db" (or (getenv "XDG_DATA_HOME") "~/.local/share")))
```

On Windows, point that at `%APPDATA%/whittakers/whittakers.db` after copying the `.db` there.

### 17. Reload init (or restart Emacs)

```sh
emacs --batch -l "$HOME/.emacs" --eval "(message \"whittaker-mode loaded: %s\" (featurep 'whittaker-mode))"
```

Expect `whittaker-mode loaded: t`. If you use `$HOME/.emacs.d/init.el` instead of `$HOME/.emacs`, pass `-l "$HOME/.emacs.d/init.el"`.

---

## D. First-run verification

### 18. Run the unit checks (needs the database from step 10)

```sh
emacs -Q --batch -l "$WORDS_SRC/check-whittaker.el"
```

Expect a stream of `ok:` lines and exit 0.

### 19. Run the end-to-end checks

```sh
emacs -Q --batch -l "$WORDS_SRC/whittaker-e2e-test.el"
```

Expect exit 0 (14 assertions: `C-c C-w` on `Amant` → lemma `amo`, gloss, inflection table, stem fallback, no network).

### 20. Interactive smoke test

1. Start Emacs as you normally do (so init loads).
2. Open a new file whose name ends in `.tex` (LaTeX/tex buffers auto-enable the mode).
3. Type `Amant` and leave point on that word.
4. Press `C-c C-w`.

The `*Whittaker*` popup (~30 lines, `q` quits) should show a header with the queried word and a timestamp, then `amo [V]`, the gloss `love, like; …`, a “This form:” tag, and the conjugation table. The mode line lighter is ` Whit`.

Other buffers: `M-x whittaker-lookup-word` prompts for a word or phrase anywhere. `M-x whittaker-clear-cache` flushes the in-memory cache.

Auto-enable also happens in Org when the buffer has `#+LANGUAGE: latin` (or `la`), a `latin` filetag, or macron vowels; or when you set the file-local `whittaker-latin: t`.

---

## E. Troubleshooting

### 21. `Whittaker: database not found: …/whittakers.db`

The mode does not download a dictionary. Re-run steps 7–11. Confirm:

```sh
test -r "$HOME/.local/share/whittakers/whittakers.db" && echo readable
```

If you put the file somewhere else:

```elisp
(setq whittaker-db-path "/absolute/path/to/whittakers.db")
```

If extract.py died with `error: missing …/whitakers-words-src/DICTLINE.GEN`, the clone in step 9 is missing or not named `whitakers-words-src`.

### 22. `Whittaker: sqlite3 executable not found` — or the popup stays empty / JSON parse errors

Emacs GUI on macOS often has a smaller `exec-path` than your terminal (Homebrew `sqlite3` is invisible). Point at the binary you tested in step 3:

```elisp
(setq whittaker-sqlite-program "/usr/bin/sqlite3")
```

If `sqlite3 -json :memory: "SELECT 1 AS n;"` failed in the shell, the CLI is older than 3.33. Install a newer sqlite3 (Homebrew `sqlite`, distro package) and set `whittaker-sqlite-program` to that binary. The Python `sqlite3` module used by `extract.py` is unrelated to this CLI flag.

### 23. `C-c C-w` does nothing, runs `org-refile`, or is undefined

The key lives only in `whittaker-mode-map`. The mode auto-enables in `latex-mode` / `LaTeX-mode` / `tex-mode`, not in a random text buffer.

- Check the lighter: `Whit` should appear. If not: `M-x whittaker-mode`.
- In Org, `C-c C-w` is also `org-refile`. Either enable the mode and accept the override, or pick another key:

```elisp
(setq whittaker-lookup-key (kbd "C-c C-l"))
```

- Always available: `M-x whittaker-lookup-word`.

---

## What you should not install

- Not an Emacs package archive. Do not `package-install` a similarly named package.
- Not the Ada `words` binary. The Emacs mode talks to SQLite, not to Whitaker's interactive program.
- No network after step 9. A lookup that hits the network is a bug.

## Rebuild later

```sh
python3 "$HOME/.local/share/whittakers/extract.py"
```

That overwrites `$HOME/.local/share/whittakers/whittakers.db`. Then `M-x whittaker-clear-cache` in Emacs.
