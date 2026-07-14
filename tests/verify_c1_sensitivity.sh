#!/bin/bash
# C1 sensitivity harness (non-vacuity proof for the SHA-256 integrity assertions).
#
# The C1 cases in verify_catalog_v2.sh exercise an ALREADY-CORRECT integrity path,
# so "fail-before vs git HEAD" does not apply. Instead, prove the assertions bite:
# invert the sole hash comparison in verify_downloaded_file (`!=` -> `==`) in a COPY
# of the script and re-run the suite. Under the inverted gate a matching hash reads
# as a mismatch and a wrong hash reads as a match, so the two C1 verdicts must FLIP:
#   - "C1 happy" (matching hash installs) must now FAIL (install refused), and
#   - "C1 mismatch" (wrong hash blocks install) must now FAIL (wrongly installed).
# If either still PASSes, the corresponding assertion is not actually testing the
# hash comparison. Reproducible in place of a throwaway manual edit.
set -u
here=$(dirname "$(readlink -f "$0")")
repo=$(dirname "$here")
orig="$repo/kiwix-update.sh"
suite="$repo/tests/verify_catalog_v2.sh"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/kiwix-c1sens.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
inv="$tmp/kiwix-update.inverted.sh"

# Invert ONLY the SHA-256 comparison line. Anchor on the surrounding tokens so no
# other conditional is touched; fail loudly if the expected line is absent (the
# code moved) rather than silently producing a no-op copy.
if ! grep -q 'if \[ "\$actual_hash" != "\$expected_hash" \]; then' "$orig"; then
    echo "FAIL: could not locate the SHA-256 comparison line to invert (code moved?)"
    exit 1
fi
sed 's/if \[ "\$actual_hash" != "\$expected_hash" \]; then/if [ "$actual_hash" = "$expected_hash" ]; then/' \
    "$orig" > "$inv"

# Run the full suite against the inverted script; capture C1 verdict lines.
out=$(SCRIPT="$inv" bash "$suite" 2>&1)

check(){ # $1=grep pattern for the case  $2=human label
    local line
    line=$(printf '%s\n' "$out" | grep -F "$1" | head -1)
    if [ -z "$line" ]; then
        echo "FAIL: sensitivity: '$2' — case not found in output"
        return 1
    fi
    if printf '%s' "$line" | grep -q '^FAIL:'; then
        echo "PASS: sensitivity: '$2' flipped to FAIL under inverted gate (assertion is non-vacuous)"
        return 0
    fi
    echo "FAIL: sensitivity: '$2' did NOT flip (still: $line) — assertion may be vacuous"
    return 1
}

# Match on the shared label STEM (present in both the PASS and FAIL wording), so
# the grep finds the line whichever verdict it carries; then check() asserts FAIL.
rc=0
check "C1 happy:"          "C1 happy install"    || rc=1
check "C1 mismatch:"       "C1 mismatch block"   || rc=1
check "C1 mismatch e2e:"   "C1 mismatch e2e"     || rc=1

echo
[ "$rc" -eq 0 ] && echo "==== C1 SENSITIVITY PASSED (assertions bite) ====" \
                || echo "==== C1 SENSITIVITY FAILED ===="
exit "$rc"
