# whittaker-mode

Emacs minor mode for offline Whitaker's Words lookup.

**License & data source.** This code is released under the GNU GPL v3
(see [LICENSE](LICENSE)). The Latin dictionary data it queries is
**Whitaker's Words** by Michael Koenig
([github.com/mk270/whitakers-words](https://github.com/mk270/whitakers-words));
the dictionary is **not** bundled here — `install.sh` clones it once at
install time. `whittaker-mode` is a thin lookup front-end over that data.

## Fresh machine: one command

Everything (dictionary build, package install, init snippet, tests) is
automated by `install.sh` in this folder:

```sh
cd words-emacs && ./install.sh     # add --rebuild to force a DB rebuild
```

It clones the dictionary data once (the only network use, ever), builds
`~/.local/share/whittakers/whittakers.db` (~294 MB, ~1 min), installs and
byte-compiles `~/.emacs.d/lisp/whittaker-mode.el`, appends the
`(require 'whittaker-mode)` snippet to `~/.emacs` (or `init.el`) if not
already present, and runs both test suites. Idempotent — safe to re-run.
Step-by-step manual walkthrough and troubleshooting:
`whittaker-words-INSTALL.md`.

## Usage

- Open a Latin `.tex` file (any LaTeX buffer auto-enables; also Org
  buffers with `#+LANGUAGE: latin`, a `latin` filetag, or macron
  vowels).
- Move point onto a word and press `C-c C-w`. The `*Whittaker*`
  popup (≈30 lines, `q` quits) shows a header naming the queried
  word and lookup timestamp, then the lemma + part of speech, the
  English gloss, a "This form:" tag for the exact form, and the
  full inflection table.
- `M-x whittaker-lookup-word` prompts for a word or phrase in any
  buffer; `M-x whittaker-clear-cache` flushes the in-memory cache.

Lookups are fully offline (local sqlite3), asynchronous, cached —
measured at ~0.09 s cold and ~0.003 s warm on this machine.

Manual load alternative:

```elisp
(add-to-list 'load-path "/path/to/words-emacs")
(require 'whittaker-mode)
```

## Database

`whittaker-db-path` defaults to `~/.local/share/whittakers/whittakers.db`.

Schema (from extract t_f8d8830f):

- `entries(lemma PRIMARY KEY, definition, forms JSON, pos)`
- `form_index(form, lemma, tag)` with index on `form`

Lookup runs `sqlite3 -json` asynchronously (`start-process` +
sentinel), so the UI never blocks; a query slower than
`whittaker-lookup-timeout` (default 5 s) is killed and reports
"lookup timed out". Results are cached in memory
(`whittaker-cache-size`, flush with `M-x whittaker-clear-cache`).
No network.

## Lookup behaviour (t_19ac43b0)

- Macron-insensitive matching: `Amāvit` and `amavit` both hit `amo`.
- Non-lemma forms fall back to stem matching (common endings
  stripped, e.g. `-us -um -is -i -a -ae -orum -arum -os -as -ibus`),
  so `amantis` resolves to `amo` via the stem `amant`.
- Space-separated phrases (`M-x whittaker-lookup-word` accepts
  `intra se`) are looked up token by token; one result block per
  token.
- Empty / whitespace-only input shows a gentle message, no error.
- The `*Whittaker*` popup buffer is reused across lookups and
  scrolled to top on each new result.
- `M-x whittaker-lookup-word` prompts for a word or phrase and works
  in any buffer, not just Latin ones.

Org note: `C-c C-w` is also `org-refile`. Customize `whittaker-lookup-key`
if that matters.

## Check

```
emacs -Q --batch -l words-emacs/check-whittaker.el     # unit checks
emacs -Q --batch -l words-emacs/whittaker-e2e-test.el  # end-to-end
```

The e2e test simulates real `C-c C-w` keypresses in a latex buffer,
asserts the popup header (word + timestamp), stem fallback, phrase
splitting, sub-second latency, and advises the network primitives
(`make-network-process`, `url-retrieve`, …) to prove the whole
pipeline never touches the network.
