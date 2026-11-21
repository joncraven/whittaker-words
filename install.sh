#!/usr/bin/env bash
# One-command install of whittaker-mode (offline Whitaker's Words lookup)
# on a fresh macOS or Linux machine.
#
#   git clone <repo> && cd <repo>/words-emacs && ./install.sh
#
# Does everything: builds the SQLite dictionary under
# $HOME/.local/share/whittakers/, installs whittaker-mode.el into
# $HOME/.emacs.d/lisp/, byte-compiles it, appends the init snippet to
# ~/.emacs (or ~/.emacs.d/init.el, whichever you use), and runs both
# test suites. Idempotent: safe to re-run. Pass --rebuild to force a
# dictionary rebuild. Manual walkthrough: whittaker-words-INSTALL.md
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA="$HOME/.local/share/whittakers"
LISP="$HOME/.emacs.d/lisp"
DB="$DATA/whittakers.db"
REBUILD=0
[ "${1:-}" = "--rebuild" ] && REBUILD=1

say() { printf '==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# ---------- 1. prerequisites ----------
say "checking prerequisites"
command -v emacs   >/dev/null || die "emacs not on PATH (need GNU Emacs 27.1+)"
command -v python3 >/dev/null || die "python3 not on PATH (stdlib only, no pip)"
command -v git     >/dev/null || die "git not on PATH (needed once, for the dictionary clone)"
SQLITE3="$(command -v sqlite3)" || die "sqlite3 not on PATH"
sqlite3 -json :memory: "SELECT 1 AS n;" >/dev/null 2>&1 \
  || die "sqlite3 at $SQLITE3 lacks the -json flag (need SQLite 3.33.0+)"
say "ok: $(emacs --version | head -1), $(sqlite3 --version | cut -d' ' -f1) sqlite3, $(python3 --version 2>&1)"

# ---------- 2. dictionary database (one-time network, then fully offline) ----------
mkdir -p "$DATA"
cp "$SRC/extract.py" "$DATA/extract.py"
if [ ! -f "$DATA/whitakers-words-src/DICTLINE.GEN" ]; then
  say "cloning Whitaker's WORDS data (one-time network use)"
  git clone --depth 1 https://github.com/mk270/whitakers-words.git \
    "$DATA/whitakers-words-src"
else
  say "dictionary source already present, skipping clone"
fi
if [ "$REBUILD" = 1 ] || [ ! -f "$DB" ]; then
  say "building offline database (takes ~1 minute)"
  python3 "$DATA/extract.py"
else
  say "database already built at $DB (use --rebuild to redo)"
fi
sqlite3 "$DB" "SELECT lemma, pos FROM entries WHERE lemma='amo';" | grep -q '^amo' \
  || die "database verification failed: no 'amo' row in $DB"
say "database ok: $DB"

# ---------- 3. emacs package ----------
mkdir -p "$LISP"
cp "$SRC/whittaker-mode.el" "$LISP/whittaker-mode.el"
say "byte-compiling"
emacs -Q --batch -f batch-byte-compile "$LISP/whittaker-mode.el"

# ---------- 4. init snippet (idempotent) ----------
INIT="$HOME/.emacs"
[ -f "$HOME/.emacs.d/init.el" ] && INIT="$HOME/.emacs.d/init.el"
if grep -qs "whittaker-mode" "$INIT" 2>/dev/null; then
  say "init snippet already present in $INIT, leaving it alone"
else
  say "appending init snippet to $INIT"
  cat >> "$INIT" <<'SNIPPET'

;;;; Whittaker's Words: offline Latin lookup (whittaker-mode)
(add-to-list 'load-path "~/.emacs.d/lisp")
(require 'whittaker-mode)
SNIPPET
fi

# ---------- 5. verification ----------
say "running unit checks"
emacs -Q --batch -l "$SRC/check-whittaker.el"
say "running end-to-end checks"
emacs -Q --batch -l "$SRC/whittaker-e2e-test.el"
say "loading through your real init"
emacs --batch -l "$INIT" --eval '(message "whittaker-mode loaded: %s" (featurep (quote whittaker-mode)))' 2>&1 \
  | grep -q "whittaker-mode loaded: t" || die "whittaker-mode did not load from $INIT"

say "done. Open any .tex file in Emacs, put point on a Latin word, press C-c C-w."
say "From now on everything is offline: no network calls, ever."
