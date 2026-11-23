# shellcheck shell=bash
# shellcheck disable=SC2034  # knobs and paths (RS, RL, RM_NEW, …) are consumed by the sourcing suite and the child run
#
# Shared harness for suites that drive the REAL `main` end to end (a separate
# process per run) instead of calling download_file directly: a resume test that
# skips main misses main's clean_state/cleanup wiping TEMP_DIR around it.
#
# Source it with ROOT set to a fresh harness-private dir that already has a bin/
# subdirectory; prepend "$ROOT/bin" to PATH yourself. It provides:
#   - $ROOT/run_main.sh: `source "$KUS"; eval "$RM_PRE"; main "$@"`, an
#     executable so setsid can exec it (pass the full argv: smart-update -y …).
#   - stubs in $ROOT/bin: sleep (no-op), curl (catalog / metalink / resolve /
#     HEAD), inert systemctl/service/pidof, no-op kiwix-manage. aria2c is the
#     sourcing suite's.
#   - KIWIX_WORK_DIR, a 700 dir under $HOME (a /tmp dir fails the real trust
#     gate's ancestor walk: /tmp is 1777), with child-side paths RT RS RL RLOG.
#     Seed and assert only through those, never through the suite's own
#     post-source globals.
#   - RM_TRUST_ERR: empty when the real trust gate accepts KIWIX_WORK_DIR, else
#     the reason (the suite must fail its end-to-end cases on it, not skip).
#   - reset_case, rm_feed, and the EXIT trap (_lib_exit) that removes everything.
# Every harness-owned file lives under $ROOT, never under $RT.

: "${ROOT:?ROOT must be set before sourcing run_main.sh}"
# Dirs the child creates itself (download_file's mkdir -p) must pass the trust
# gate on the next run whatever the caller's umask (002 makes them 775).
umask 022
export KUS="${SCRIPT:-$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../kiwix-update.sh}"

# The real sleep, for the blocking aria2c stub and the suite's polls (the stub
# below shadows sleep on PATH).
REAL_SLEEP=$(PATH=/usr/bin:/bin command -v sleep)
case "$REAL_SLEEP" in
    /*) case "$REAL_SLEEP" in "$ROOT"/*) echo "FATAL: REAL_SLEEP resolved to the stub ($REAL_SLEEP)" >&2; exit 1 ;; esac ;;
    *) echo "FATAL: no real sleep binary found" >&2; exit 1 ;;
esac
export REAL_SLEEP

# ---------- stubs ----------
cat > "$ROOT/bin/sleep" <<'S'
#!/bin/bash
exit 0
S

# Non-vacuous curl stub. Logs full argv to $CURL_LOG. Branches:
#   catalog fetch (-o, no -w, no head)  -> cp $CATALOG to -o target
#   metalink (-w %{http_code})          -> write $META4_BODY, echo $META4_CODE
#   resolve  (-w %{url_effective})      -> honour --proto-redir on EFFECTIVE_URL's
#                                          scheme (refuse if out of set), and the
#                                          CURL_RESOLVE_FAIL knob (network fail)
#   HEAD probe (-sI/-sLI)               -> only returns Content-Length when -L is
#                                          present AND the simulated mirror scheme
#                                          ($MIRROR_SCHEME) is within --proto-redir
cat > "$ROOT/bin/curl" <<'S'
#!/bin/bash
echo "curl $*" >> "${CURL_LOG:-/dev/null}"
ofile=""; wfmt=""; head=false; proto_redir=""; hasL=false
args=("$@"); i=0
while [ $i -lt ${#args[@]} ]; do
    a="${args[$i]}"
    case "$a" in
        -o) i=$((i+1)); ofile="${args[$i]}" ;;
        -w) i=$((i+1)); wfmt="${args[$i]}" ;;
        --proto-redir) i=$((i+1)); proto_redir="${args[$i]}" ;;
        -sI|-I) head=true ;;
        -sLI) head=true; hasL=true ;;
        -L|--location) hasL=true ;;
    esac
    i=$((i+1))
done
scheme_of(){ printf '%s' "${1%%://*}"; }
scheme_allowed(){ # $1 scheme, $2 like '=http,https'
    local sch="$1" pv="${2#=}" t; local IFS=','
    for t in $pv; do [ "$t" = "$sch" ] && return 0; done
    return 1
}
if [[ "$wfmt" == *'%{http_code}'* ]]; then
    [ -n "$ofile" ] && printf '%s' "${META4_BODY:-}" > "$ofile"
    printf '%s' "${META4_CODE:-200}"; exit "${META4_EXIT:-0}"
elif [[ "$wfmt" == *'%{url_effective}'* ]]; then
    [ "${CURL_RESOLVE_FAIL:-0}" = 1 ] && exit 7          # simulate network failure
    eff="${EFFECTIVE_URL:-https://mirror.invalid/final.zim}"
    if [ -n "$proto_redir" ] && ! scheme_allowed "$(scheme_of "$eff")" "$proto_redir"; then
        exit 1                                            # curl refuses out-of-set scheme
    fi
    printf '%s' "$eff"; exit 0
elif $head; then
    # Simulate the LB 302 -> mirror. Only follow (and return a size) when -L is
    # present AND the mirror scheme is within the redirect proto set.
    ms="${MIRROR_SCHEME:-https}"
    if $hasL && { [ -z "$proto_redir" ] || scheme_allowed "$ms" "$proto_redir"; }; then
        printf 'HTTP/1.1 200 OK\r\nContent-Length: %s\r\n\r\n' "${SIZE_CL:-0}"
    else
        printf 'HTTP/1.1 302 Found\r\nLocation: %s://m/x\r\n\r\n' "$ms"   # no Content-Length
    fi
    exit 0
fi
[ -n "$CATALOG" ] && [ -n "$ofile" ] && cp "$CATALOG" "$ofile"
exit 0
S

# Service manager: always inactive (so manage_kiwix_service is inert in tests)
for c in systemctl service pidof; do
    cat > "$ROOT/bin/$c" <<'S'
#!/bin/bash
exit 1
S
done
# kiwix-manage: no-op success
cat > "$ROOT/bin/kiwix-manage" <<'S'
#!/bin/bash
exit 0
S

cat > "$ROOT/run_main.sh" <<'S'
#!/bin/bash
source "$KUS"; eval "${RM_PRE:-}"; main "$@"
S
chmod +x "$ROOT"/bin/* "$ROOT/run_main.sh"

# ---------- child environment ----------
KIWIX_WORK_DIR=$(mktemp -d "$HOME/.kiwix-resume-test.XXXXXX") || { echo "FATAL: cannot create a work dir under \$HOME" >&2; exit 1; }
chmod 700 "$KIWIX_WORK_DIR"
export KIWIX_WORK_DIR
export KIWIX_ZIM_LIBRARY="$KIWIX_WORK_DIR/library_zim.xml"
RT="$KIWIX_WORK_DIR/temp"
RS="$KIWIX_WORK_DIR/.kiwix_update_status"
RL="$KIWIX_ZIM_LIBRARY"
RLOG="$KIWIX_WORK_DIR/kiwix_update.log"

# Post-source assignments for the child (the script hard-codes MAX_RETRIES=3).
# Extend, don't replace: RM_PRE="$RM_DEFAULT; MAX_RETRIES=2".
export RM_DEFAULT='QUIET=true; TIMEOUT=5; MAX_RETRIES=1'
export RM_PRE="$RM_DEFAULT"
export ARIA_LOG="$ROOT/aria.log" ARIA_PREEXIST_LOG="$ROOT/aria.preexist"
export STUB_ARIA_RC_SEQ_FILE="$ROOT/aria.rcseq"
: > "$ARIA_LOG"; : > "$ARIA_PREEXIST_LOG"

_lib_exit() {
    rm -rf "$ROOT" "$KIWIX_WORK_DIR"
}
trap _lib_exit EXIT

# EXPECTED_OWNER_UID is 0 until determine_run_mode runs.
RM_TRUST_ERR=""
if ! RM_TRUST_ERR=$(bash -c 'source "$KUS" >/dev/null 2>&1; determine_run_mode
    is_trusted_dir "$KIWIX_WORK_DIR" || { echo "$TRUST_FAIL_REASON"; exit 1; }' 2>&1); then
    RM_TRUST_ERR="real trust gate rejects $KIWIX_WORK_DIR: ${RM_TRUST_ERR:-no reason given}"
else
    RM_TRUST_ERR=""
fi

# The catalog offers RM_NEW (newer than the seeded local X_2025-01.zim).
RM_OLD="X_2025-01.zim"
RM_NEW="X_2026-01.zim"
RM_URL="https://lb.download.kiwix.org/zim/x/$RM_NEW"
# rm_feed FILE LENGTH: one-entry OPDS v2 feed for RM_NEW.
rm_feed() {
    local len=" length=\"$2\""
    printf '<feed>\n<totalResults>1</totalResults>\n<entry>\n<name>%s</name>\n<publisher>\n<name>openZIM</name>\n</publisher>\n<link rel="http://opds-spec.org/acquisition/open-access" type="application/x-zim" href="%s.meta4"%s/>\n</entry>\n</feed>\n' \
        "${RM_NEW%.zim}" "$RM_URL" "$len" > "$1"
}

# Fresh per-case state: empty harness logs, no partials, just the old ZIM and a
# library listing it. Cases that need a partial pair seed it themselves.
reset_case() {
    : > "$ARIA_LOG"; : > "$ARIA_PREEXIST_LOG"
    rm -f -- "$STUB_ARIA_RC_SEQ_FILE"
    rm -f -- "$KIWIX_WORK_DIR"/*.zim
    rm -rf -- "$RT"
    head -c 100 /dev/zero > "$KIWIX_WORK_DIR/$RM_OLD"
    printf '<library version="20110515">\n  <book id="x-2025" path="%s"/>\n</library>\n' "$RM_OLD" > "$RL"
}
