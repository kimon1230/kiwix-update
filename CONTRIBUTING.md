# Contributing

Thanks for helping improve `kiwix-update`. This is a single-file Bash tool
(`kiwix-update.sh`) with a set of offline test harnesses under `tests/`. The
notes below cover the few conventions that aren't obvious from reading the code.

## Development environment

The script targets **Bash on Linux with GNU coreutils**. It depends on
GNU-specific behaviour (`stat -c`, `df --output`, `numfmt`), so it will not run
unmodified on BSD/macOS userland — develop and test on Linux (or a Linux
container).

Runtime commands the script itself requires (checked at startup):

```
aria2c  kiwix-manage  curl  find  stat  numfmt  awk  df  grep  sha256sum  readlink
```

You do **not** need these installed to run the test suites — the harnesses stub
`curl`/`aria2c`/service managers and drive the real functions offline.

Enable the pre-commit hooks once after cloning:

```bash
pre-commit install
```

This runs [gitleaks](https://github.com/gitleaks/gitleaks) (blocks committed
secrets) and ShellCheck with the same flags CI uses (see below).

## Running the tests

Run every suite from the repo root:

```bash
for t in tests/*.sh; do bash "$t" || break; done
```

Each suite prints `PASS:`/`FAIL:` lines and a summary; a non-zero exit means a
failure. The suites are hermetic and need no network.

An **opt-in live smoke** (hits the real Kiwix catalog) is gated behind an env
var, off by default:

```bash
KIWIX_LIVE=1 bash tests/verify_catalog_v2.sh
```

## Linting

CI gates the build with ShellCheck at **warning** level:

```bash
shellcheck --severity=warning --exclude=SC2155 kiwix-update.sh
```

`SC2155` (declare-and-assign) is an intentional, pervasive style choice and is
the only excluded code. The same gate is applied to **every** `tests/*.sh`
harness.

### Test-harness ShellCheck convention

A harness that `source`s the script under test trips two false positives that
would otherwise fail the gate: `SC2034` (harness globals look "unused" because
ShellCheck can't follow the dynamic `source` to see the script consume them) and
`SC1090` (can't follow a non-constant `source`). If you add a new harness that
sources `kiwix-update.sh`, quarantine those with **file-scoped directives** —
not a broad CI exclude — so the checks stay live for every other file:

```bash
# shellcheck disable=SC2034  # harness globals are consumed by the sourced script
...
# shellcheck source=/dev/null  # script-under-test is resolved dynamically
source "${SCRIPT:-.../kiwix-update.sh}"
```

## Writing tests

- **CI auto-discovers suites.** The workflow loops over `tests/*.sh`, so a new
  suite gates CI automatically — no workflow edit needed.

- **Prove new-behaviour tests fail *before* the fix.** A test that only passes on
  the fixed code doesn't prove it catches the bug. Each harness sources the
  script via `source "${SCRIPT:-.../kiwix-update.sh}"`, so you can point it at a
  baseline copy and confirm the new assertions fail there:

  ```bash
  git show HEAD:kiwix-update.sh > /tmp/base.sh
  SCRIPT=/tmp/base.sh bash tests/verify_catalog_v2.sh   # new assertions should FAIL here
  ```

  If the code you're changing is itself **unmerged** (not yet in `HEAD`), diff
  against a working-tree copy with only *your* change reverted instead — `HEAD`
  won't contain the function and the harness will error out, which is not a valid
  "fail-before."

- **Keep assertions non-vacuous.** Pair a positive case with a negative control,
  or invert the condition under test and confirm the assertion flips (see
  `tests/verify_c1_sensitivity.sh` for the pattern).

## The root / unprivileged invariant

The script auto-selects a run mode from the effective UID (`determine_run_mode`):
euid 0 → **root mode**, anything else → **unprivileged mode**. Existing
deployments run as root, so:

- **Root-mode behaviour must stay identical.** Gate any new mutating behaviour
  (service management, `chown`, etc.) behind `${UNPRIVILEGED}` so root keeps the
  original path. The offline suites assert this; keep them green.
- Security-sensitive changes (the trust gate, download integrity, privilege
  handling) should carry a fail-before test and keep ShellCheck clean at the CI
  gate.

## Submitting a change

1. Branch off `main`.
2. Make the change; add/adjust tests and prove them fail-before where behaviour
   changed.
3. Run all suites + ShellCheck locally (or let `pre-commit` and CI do it).
4. Keep user-facing docs in sync — both `README.md` and the in-script
   `show_help()` — when you add or change a flag, command, or default.
5. Open a pull request describing the change and how you verified it.
