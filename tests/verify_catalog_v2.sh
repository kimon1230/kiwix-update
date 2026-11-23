#!/bin/bash
# Catalog OPDS-v2 migration verification (C1–C7).
# Exercises the REAL edited functions with a NON-VACUOUS arg-branching curl stub
# (honours --proto-redir, -L, and a CURL_RESOLVE_FAIL knob) + an argv-logging
# aria2c stub + inactive service stubs. sha256sum is REAL.
# Run from the repo root. Set KIWIX_LIVE=1 to also run the opt-in live smoke.

# shellcheck disable=SC2034  # harness globals (WORK_DIR, QUIET, MIRROR_SCHEME, …) are consumed by the sourced kiwix-update.sh, which shellcheck can't see across the dynamic `source` below

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/kiwix-catv2.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT
rm -rf "$ROOT"; mkdir -p "$ROOT/bin" "$ROOT/work/temp" "$ROOT/work/backups"

FAIL=0
pass(){ echo "PASS: $1"; }
fail(){ echo "FAIL: $1"; FAIL=1; }

# Capture the REAL curl before the stub bin is prepended to PATH (the live smoke
# must not hit the stub).
REAL_CURL="$(command -v curl)"
# Real aria2c (if installed) to validate the option names the script passes: the
# argv-logging stub accepts anything, so only the real binary can catch an
# unsupported flag (which makes aria2c exit 28 and fail every download).
REAL_ARIA2C="${REAL_ARIA2C:-$(command -v aria2c)}"

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

# aria2c: logs argv, writes $ARIA_CONTENT to --dir/--out
cat > "$ROOT/bin/aria2c" <<'S'
#!/bin/bash
echo "aria2c $*" >> "${ARIA_LOG:-/dev/null}"
# Opt-in: record whether the run-lock fd 9 leaked into this exec'd child.
[ -n "${ARIA_FD_LOG:-}" ] && { if [ -e /proc/self/fd/9 ]; then echo present; else echo "fd9 absent"; fi >> "$ARIA_FD_LOG"; }
dir=""; out=""
for a in "$@"; do case "$a" in --dir=*) dir="${a#--dir=}";; --out=*) out="${a#--out=}";; esac; done
[ -n "${STUB_ARIA_MSG:-}" ] && echo "$STUB_ARIA_MSG" >&2
# Opt-in: record whether the temp file / control file existed when aria2c started.
[ -n "${ARIA_PREEXIST_LOG:-}" ] && { [ -e "$dir/$out" ] && echo part; [ -e "$dir/$out.aria2" ] && echo ctl; echo end; } >> "$ARIA_PREEXIST_LOG"
[ "${STUB_ARIA_RC:-0}" -eq 0 ] && [ -n "$dir" ] && [ -n "$out" ] && printf '%s' "${ARIA_CONTENT:-data}" > "$dir/$out"
exit "${STUB_ARIA_RC:-0}"
S

# Service manager: always inactive (so manage_kiwix_service is inert in tests)
for c in systemctl service pidof; do
    cat > "$ROOT/bin/$c" <<'S'
#!/bin/bash
exit 1
S
done
# kiwix-manage: no-op success (post-success branch only; not reached by skip paths)
cat > "$ROOT/bin/kiwix-manage" <<'S'
#!/bin/bash
exit 0
S
chmod +x "$ROOT"/bin/*
export PATH="$ROOT/bin:$PATH"

# shellcheck source=/dev/null  # script-under-test is resolved dynamically at runtime
source "${SCRIPT:-$(dirname "$(readlink -f "$0")")/../kiwix-update.sh}"
echo "SOURCED OK (main did not auto-run)"
set +eu

WORK_DIR="$ROOT/work"; TEMP_DIR="$ROOT/work/temp"; BACKUP_DIR="$ROOT/work/backups"
LOG_FILE="$ROOT/work/log"; LIBRARY_CACHE="$ROOT/work/.cache"; ZIM_LIBRARY="$ROOT/work/library.xml"
QUIET=true; TIMEOUT=5; MAX_RETRIES=1
export CURL_LOG="$ROOT/curl.log" ARIA_LOG="$ROOT/aria.log"

# ======================================================================
echo; echo "########## C1 — <totalResults> truncation guard ##########"
# Entries are MULTI-LINE, matching the real pretty-printed v2 feed the awk
# getline-parser expects (publisher on its own line, <name> on the next; the
# top-level slug <name> and <author><name> must NOT be mistaken for publisher).
mk_feed(){ # $1=totalResults (or 'none'), $2=entry-emitter fn; -> $ROOT/feed.xml
    local tr="$1" emit="$2"
    { echo '<feed>'; [ "$tr" != none ] && echo "<totalResults>${tr}</totalResults>"
      "$emit"; echo '</feed>'; } > "$ROOT/feed.xml"
}
entry_full(){ cat <<'E'
<entry>
<name>a_2026-01</name>
<author>
<name>Auth</name>
</author>
<publisher>
<name>openZIM</name>
</publisher>
<link rel="http://opds-spec.org/image/thumbnail" href="/x"/>
<link type="text/html" href="https://browse/x"/>
<link rel="http://opds-spec.org/acquisition/open-access" type="application/x-zim" href="https://lb.download.kiwix.org/zim/a/a_2026-01.zim.meta4" length="500"/>
</entry>
E
}

# valid: totalResults=1, 1 entry -> parses, returns 0
mk_feed 1 entry_full; rm -f "$LIBRARY_CACHE"
: > "$CURL_LOG"
CATALOG="$ROOT/feed.xml" fetch_library_data >/dev/null 2>&1
{ [ $? -eq 0 ] && [ -s "$LIBRARY_CACHE" ]; } && pass "C1 valid feed parses (returns 0)" || fail "C1 valid feed rejected"
# The catalog fetch follows no redirect: -L with --max-redirs 0 makes any 3xx a
# hard error (without -L a 3xx body would be cached as the catalog).
CAT_ARGV=$(grep -F 'catalog/v2/entries' "$CURL_LOG" | head -1)
grep -qE -- ' -[a-zA-Z]*L[a-zA-Z]* ' <<< "$CAT_ARGV" && grep -qE -- ' --max-redirs 0( |$)' <<< "$CAT_ARGV" \
  && pass "C1b catalog curl: -L --max-redirs 0 (no redirect followed)" || fail "C1b catalog curl argv: $(grep -F 'catalog/v2' "$CURL_LOG" | head -1)"
# missing totalResults -> fail-closed
mk_feed none entry_full; rm -f "$LIBRARY_CACHE"
CATALOG="$ROOT/feed.xml" fetch_library_data >/dev/null 2>&1
[ $? -ne 0 ] && pass "C1 missing <totalResults> fails closed" || fail "C1 missing totalResults accepted"
# truncated: totalResults=3602 but only 1 entry -> fail loud
mk_feed 3602 entry_full; rm -f "$LIBRARY_CACHE"
CATALOG="$ROOT/feed.xml" fetch_library_data >/dev/null 2>&1
[ $? -ne 0 ] && pass "C1 truncated catalog (1 of 3602) fails loud" || fail "C1 truncation not detected"

# ======================================================================
echo; echo "########## M2 — truncation guard uses RAW <entry> count, not open-access count ##########"
# entry_count (the awk output) counts only OPEN-ACCESS entries; the guard now
# cross-checks the RAW <entry> count (raw_entries) against <totalResults>, so a
# complete feed carrying some non-open-access entries no longer trips a false
# "Catalog truncated" abort. Entry emitters below are printf-based so a loop can
# vary the count; one <entry> per line matches the awk's shape (grep -c is exact,
# and <entry> does not match </entry>).
m2_open(){   # $1=idx -> one open-access entry (awk emits a record)
    printf '<entry>\n<name>o%s_2026-01</name>\n<publisher>\n<name>openZIM</name>\n</publisher>\n<link rel="http://opds-spec.org/acquisition/open-access" type="application/x-zim" href="https://lb.download.kiwix.org/zim/o/o%s_2026-01.zim.meta4" length="100"/>\n</entry>\n' "$1" "$1"
}
m2_noopen(){ # $1=idx -> one entry with NO open-access link (awk emits nothing)
    printf '<entry>\n<name>n%s_2026-01</name>\n<publisher>\n<name>openZIM</name>\n</publisher>\n<link rel="http://opds-spec.org/image/thumbnail" href="/x"/>\n</entry>\n' "$1"
}
m2_mixed_6of10(){ local i; for i in 1 2 3 4 5 6; do m2_open "$i"; done; for i in 1 2 3 4; do m2_noopen "$i"; done; }
m2_five_open(){ local i; for i in 1 2 3 4 5; do m2_open "$i"; done; }
m2_no_entries(){ printf '<junk>no entry elements here</junk>\n'; }

# (1) Complete-but-non-open: totalResults=10, 10 <entry>, only 6 open-access.
#     Post-fix: raw_entries=10 (>= 99% of 10) -> NOT truncated -> returns 0, 6 lines.
#     FAIL-BEFORE (git HEAD, entry_count=6): 600 < 990 -> false "Catalog truncated".
mk_feed 10 m2_mixed_6of10; rm -f "$LIBRARY_CACHE"
CATALOG="$ROOT/feed.xml" fetch_library_data >/dev/null 2>&1; rc=$?
{ [ "$rc" -eq 0 ] && [ "$(wc -l < "$LIBRARY_CACHE")" -eq 6 ]; } \
  && pass "M2.1 complete feed w/ 6-of-10 open-access parses (no false truncation)" \
  || fail "M2.1 rc=$rc lines=$(wc -l < "$LIBRARY_CACHE" 2>/dev/null)"

# (2) Genuinely truncated: totalResults=1000, only 5 <entry> -> guard still fires.
: > "$LOG_FILE"
mk_feed 1000 m2_five_open; rm -f "$LIBRARY_CACHE"
LOGFILE_SAFE=true CATALOG="$ROOT/feed.xml" fetch_library_data >/dev/null 2>&1; rc=$?
{ [ "$rc" -ne 0 ] && grep -q 'Catalog truncated' "$LOG_FILE"; } \
  && pass "M2.2 genuinely truncated feed (5 of 1000) still fails loud" \
  || fail "M2.2 rc=$rc log='$(cat "$LOG_FILE" 2>/dev/null)'"

# (3) Format breakage: no parseable <entry> -> the zero-parsed guard fires,
#     independently of the truncation cross-check (which was left unchanged).
: > "$LOG_FILE"
mk_feed 10 m2_no_entries; rm -f "$LIBRARY_CACHE"
LOGFILE_SAFE=true CATALOG="$ROOT/feed.xml" fetch_library_data >/dev/null 2>&1; rc=$?
{ [ "$rc" -ne 0 ] && grep -q '0 entries' "$LOG_FILE"; } \
  && pass "M2.3 unparseable feed (0 entries) fails via zero-parsed guard" \
  || fail "M2.3 rc=$rc log='$(cat "$LOG_FILE" 2>/dev/null)'"

# ======================================================================
echo; echo "########## C2 — v2 layout parsing (publisher vs author/slug, first link, sparse) ##########"
mk_feed 1 entry_full; rm -f "$LIBRARY_CACHE"; CATALOG="$ROOT/feed.xml" fetch_library_data >/dev/null 2>&1
rec=$(head -n1 "$LIBRARY_CACHE")
[ "$(cut -d'|' -f1 <<<"$rec")" = "openZIM" ] && pass "C2 publisher=openZIM (NOT author 'Auth' or slug 'a_2026-01')" || fail "C2 wrong publisher: $rec"
[ "$(cut -d'|' -f2 <<<"$rec")" = "a_2026-01.zim" ] && pass "C2 filename parsed" || fail "C2 filename wrong: $rec"
[ "$(cut -d'|' -f3 <<<"$rec")" = "https://lb.download.kiwix.org/zim/a/a_2026-01.zim" ] && pass "C2 field-3 = absolute .zim URL" || fail "C2 field-3 wrong: $rec"
[ "$(cut -d'|' -f4 <<<"$rec")" = "500" ] && pass "C2 size parsed" || fail "C2 size wrong: $rec"
# multi-acquisition -> first wins
entry_multi(){ cat <<'E'
<entry>
<name>m</name>
<publisher>
<name>P</name>
</publisher>
<link rel="http://opds-spec.org/acquisition/open-access" href="https://lb.download.kiwix.org/zim/m/first.zim.meta4" length="1"/>
<link rel="http://opds-spec.org/acquisition/open-access" href="https://lb.download.kiwix.org/zim/m/second.zim.meta4" length="2"/>
</entry>
E
}
mk_feed 1 entry_multi; rm -f "$LIBRARY_CACHE"; CATALOG="$ROOT/feed.xml" fetch_library_data >/dev/null 2>&1
[ "$(head -n1 "$LIBRARY_CACHE" | cut -d'|' -f2)" = "first.zim" ] && pass "C2 first acquisition link wins" || fail "C2 multi-link: $(head -n1 "$LIBRARY_CACHE")"
# no-publisher and no-length -> still 4 fields
entry_nopub(){ cat <<'E'
<entry>
<name>np</name>
<link rel="http://opds-spec.org/acquisition/open-access" href="https://lb.download.kiwix.org/zim/n/np.zim.meta4" length="7"/>
</entry>
E
}
mk_feed 1 entry_nopub; rm -f "$LIBRARY_CACHE"; CATALOG="$ROOT/feed.xml" fetch_library_data >/dev/null 2>&1
[ "$(head -n1 "$LIBRARY_CACHE" | awk -F'|' '{print NF}')" = 4 ] && pass "C2 no-publisher entry still 4 fields" || fail "C2 no-publisher field count: $(head -n1 "$LIBRARY_CACHE")"
entry_nolen(){ cat <<'E'
<entry>
<name>nl</name>
<publisher>
<name>P</name>
</publisher>
<link rel="http://opds-spec.org/acquisition/open-access" href="https://lb.download.kiwix.org/zim/n/nl.zim.meta4"/>
</entry>
E
}
mk_feed 1 entry_nolen; rm -f "$LIBRARY_CACHE"; CATALOG="$ROOT/feed.xml" fetch_library_data >/dev/null 2>&1
[ "$(head -n1 "$LIBRARY_CACHE" | awk -F'|' '{print NF}')" = 4 ] && pass "C2 no-length entry still 4 fields" || fail "C2 no-length field count: $(head -n1 "$LIBRARY_CACHE")"

# ======================================================================
echo; echo "########## C4 — host-pin accept/reject (via analyze_updates) ##########"
UPDATE_CRITERIA=all; BACKGROUND=false
hostpin_test(){ # $1=url in cache field-3, $2=expect(accept|reject)
    local url="$1" expect="$2"
    rm -f "$WORK_DIR"/*.zim 2>/dev/null
    # Undated local file so find_latest_zim matches the dated catalog entry;
    # old mtime so the 'all' criterion flags it as an update.
    head -c 100 /dev/zero > "$WORK_DIR/pintest.zim"; touch -d 2020-01-01 "$WORK_DIR/pintest.zim"
    printf 'pub|pintest_2026-01.zim|%s|100\n' "$url" > "$LIBRARY_CACHE"; touch "$LIBRARY_CACHE"
    FILES_TO_UPDATE=()
    analyze_updates >/dev/null 2>&1
    local hit=no; printf '%s\n' "${FILES_TO_UPDATE[@]}" | grep -qF "$url" && hit=yes
    if [ "$expect" = accept ]; then
        [ "$hit" = yes ] && pass "C4 accepts $url" || fail "C4 wrongly rejected $url"
    else
        [ "$hit" = no ] && pass "C4 rejects $url" || fail "C4 wrongly accepted $url"
    fi
}
hostpin_test "https://lb.download.kiwix.org/zim/a/pintest_2026-01.zim" accept
hostpin_test "https://library.kiwix.org/zim/a/pintest_2026-01.zim"     accept
hostpin_test "http://lb.download.kiwix.org/zim/a/pintest_2026-01.zim"  reject
hostpin_test "https://evil.com/zim/a/pintest_2026-01.zim"              reject
hostpin_test "https://kiwix.org.evil.com/a/pintest_2026-01.zim"        reject
hostpin_test "https://evilkiwix.org/a/pintest_2026-01.zim"             reject
hostpin_test "https://lb.download.kiwix.org/../etc/pintest_2026-01.zim" reject

# ======================================================================
echo; echo "########## C5 — transport policy (relaxed / strict / resolve-fail / scheme) ##########"
mkzim(){ head -c 100 /dev/zero > "$1"; }
# relaxed default: http mirror ALLOWED, aria2c invoked
: > "$ARIA_LOG"; : > "$CURL_LOG"
HTTPS_ONLY=false ALLOW_UNVERIFIED=false YES_TO_ALL=true \
  EFFECTIVE_URL="http://m.invalid/f.zim" MIRROR_SCHEME=http SIZE_CL=100 \
  download_file "https://lb.download.kiwix.org/zim/x/o.zim" "$WORK_DIR/c5r.zim" 100 >/dev/null 2>&1
grep -q 'aria2c ' "$ARIA_LOG" && pass "C5 relaxed: http mirror hop allowed (aria2c invoked)" || fail "C5 relaxed: aria2c not invoked"
# Every long option passed to aria2c must exist in the real aria2c. Required in
# CI (which installs aria2); skipped locally when aria2c is not installed. The
# call above ran quiet with no speed cap; add a non-quiet, speed-capped call so
# the conditional options (-m:, progress readout) are checked too.
QUIET=false MAX_SPEED=1M HTTPS_ONLY=false ALLOW_UNVERIFIED=false YES_TO_ALL=true \
  EFFECTIVE_URL="https://m.invalid/f.zim" SIZE_CL=100 \
  download_file "https://lb.download.kiwix.org/zim/x/o.zim" "$WORK_DIR/c5o.zim" 100 >/dev/null 2>&1
MIN_ARIA_OPTS=10   # guards against a vacuous pass if argv extraction breaks (the script passes ~17)
if [ -n "$REAL_ARIA2C" ]; then
    aria_help=$("$REAL_ARIA2C" --help=#all 2>/dev/null)
    n_opts=0; bad_opts=""
    for o in $(grep -oE -- ' --[a-z][a-z-]*' "$ARIA_LOG" | sort -u); do
        n_opts=$((n_opts + 1))
        grep -qE -- "^ +(-[A-Za-z0-9], )?${o}(=|\[| |$)" <<<"$aria_help" || bad_opts="$bad_opts $o"
    done
    { [ "$n_opts" -ge "$MIN_ARIA_OPTS" ] && [ -z "$bad_opts" ] && grep -q -- '--max-download-limit=1M' "$ARIA_LOG"; } \
      && pass "aria2c accepts all ${n_opts} options the script passes (quiet + non-quiet + -m:)" \
      || fail "aria2c option check: checked=${n_opts} unrecognised:${bad_opts:- none}"
elif [ "${CI:-}" = true ]; then
    fail "aria2c not installed in CI; the option-name check cannot run"
else
    echo "SKIP: aria2c not installed; option-name check not run"
fi
# The curl resolve is capped at 1 hop.
grep -qE -- '--max-redirs 1( |$)' "$CURL_LOG" && pass "F1 curl resolve bounded to 1 hop (--max-redirs 1)" || fail "F1 curl --max-redirs not 1"
# The run lock (fd 9) must not leak into aria2c: download_file is defined with
# `} 9>&-`. This shell's fd 9 is NOT close-on-exec, so without that it would.
# rc is ignored (no metalink hash here, so the install is refused afterwards).
LKD="$ROOT/lockdl"; : > "$LKD"; : > "$ARIA_LOG"; ARIA_FD="$ROOT/aria.fd"; : > "$ARIA_FD"
exec 9>>"$LKD"; flock -n 9
HTTPS_ONLY=false ALLOW_UNVERIFIED=false YES_TO_ALL=true ARIA_FD_LOG="$ARIA_FD" \
  EFFECTIVE_URL="https://m.invalid/f.zim" SIZE_CL=100 \
  download_file "https://lb.download.kiwix.org/zim/x/o.zim" "$WORK_DIR/c5fd.zim" 100 >/dev/null 2>&1
held=$(bash -c 'exec 7>>"$1"; flock -n 7 && echo free || echo held' _ "$LKD")
exec 9>&-
{ grep -q 'aria2c ' "$ARIA_LOG" && [ "$(cat "$ARIA_FD")" = "fd9 absent" ] && [ "$held" = held ]; } \
  && pass "C5fd aria2c runs without the run-lock fd; the caller still holds the lock" \
  || fail "C5fd aria=$(grep -c 'aria2c ' "$ARIA_LOG") fd='$(tr '\n' ' ' < "$ARIA_FD")' lock=$held"
# strict (--https-only): http mirror REFUSED, aria2c not invoked
: > "$ARIA_LOG"
HTTPS_ONLY=true YES_TO_ALL=true EFFECTIVE_URL="http://m.invalid/f.zim" MIRROR_SCHEME=http \
  download_file "https://lb.download.kiwix.org/zim/x/o.zim" "$WORK_DIR/c5s.zim" >/dev/null 2>&1
rc=$?; { [ "$rc" -ne 0 ] && ! grep -q 'aria2c ' "$ARIA_LOG"; } && pass "C5 strict: http mirror refused (aria2c not invoked)" || fail "C5 strict: not refused (rc=$rc)"
# strict + https mirror: allowed, aria2c invoked
: > "$ARIA_LOG"
HTTPS_ONLY=true YES_TO_ALL=true EFFECTIVE_URL="https://m.invalid/f.zim" MIRROR_SCHEME=https SIZE_CL=100 \
  download_file "https://lb.download.kiwix.org/zim/x/o.zim" "$WORK_DIR/c5sh.zim" 100 >/dev/null 2>&1
grep -q 'aria2c ' "$ARIA_LOG" && pass "C5 strict https: https mirror allowed (aria2c invoked)" || fail "C5 strict https: aria2c not invoked"
# aria2c failure is diagnosable in both modes: its exit code and its error lines
# are logged (quiet = -q/-b/cron) and, when not quiet, also shown on stderr.
for c5e_quiet in true false; do
    : > "$LOG_FILE"
    c5e_err=$(LOGFILE_SAFE=true QUIET=$c5e_quiet STUB_ARIA_RC=28 STUB_ARIA_MSG="aria2c: unrecognized option '--bogus'" \
      HTTPS_ONLY=false YES_TO_ALL=true EFFECTIVE_URL="https://m.invalid/f.zim" SIZE_CL=100 \
      download_file "https://lb.download.kiwix.org/zim/x/o.zim" "$WORK_DIR/c5e.zim" 100 2>&1 >/dev/null)
    c5e_ok=true
    grep -q 'Download failed for c5e.zim (aria2c exit 28)' "$LOG_FILE" || c5e_ok=false
    grep -q "aria2c: aria2c: unrecognized option '--bogus'" "$LOG_FILE" || c5e_ok=false
    if [ "$c5e_quiet" = false ]; then
        grep -q "unrecognized option '--bogus'" <<<"$c5e_err" || c5e_ok=false
    fi
    $c5e_ok \
      && pass "C5e aria2c failure (quiet=$c5e_quiet): exit code and error line logged" \
      || fail "C5e aria2c failure not surfaced (quiet=$c5e_quiet) log: $(tr '\n' ' ' < "$LOG_FILE" | head -c 200) stderr: ${c5e_err:0:120}"
done
# resolve failure: WARN + return 1, aria2c never invoked
: > "$ARIA_LOG"
CURL_RESOLVE_FAIL=1 YES_TO_ALL=true \
  download_file "https://lb.download.kiwix.org/zim/x/o.zim" "$WORK_DIR/c5f.zim" >/dev/null 2>&1
rc=$?; { [ "$rc" -eq 1 ] && ! grep -q 'aria2c ' "$ARIA_LOG"; } && pass "C5 resolve-failure returns 1, aria2c not invoked" || fail "C5 resolve-failure (rc=$rc)"
# non-http(s) scheme refused at resolve layer
: > "$ARIA_LOG"
YES_TO_ALL=true EFFECTIVE_URL="file:///etc/passwd" \
  download_file "https://lb.download.kiwix.org/zim/x/o.zim" "$WORK_DIR/c5file.zim" >/dev/null 2>&1
rc=$?; { [ "$rc" -ne 0 ] && ! grep -q 'aria2c ' "$ARIA_LOG"; } && pass "C5 file:// redirect refused at resolve layer" || fail "C5 file:// not refused (rc=$rc)"

# ======================================================================
echo; echo "########## C5d — get_remote_size follows the LB redirect (disk guards) ##########"
# default path, http mirror, -L present -> real size
sz=$(HTTPS_ONLY=false ALLOW_UNVERIFIED=false MIRROR_SCHEME=http SIZE_CL=4242 get_remote_size "https://lb.download.kiwix.org/zim/x/o.zim")
[ "$sz" = 4242 ] && pass "C5d relaxed: get_remote_size returns real size across LB redirect" || fail "C5d relaxed size wrong: '$sz'"
# strict path, http mirror -> refused -> empty (correct fail-closed)
sz=$(HTTPS_ONLY=true MIRROR_SCHEME=http SIZE_CL=4242 get_remote_size "https://lb.download.kiwix.org/zim/x/o.zim"); rc=$?
{ [ -z "$sz" ] && [ "$rc" -ne 0 ]; } && pass "C5d strict: http mirror size refused (fail-closed)" || fail "C5d strict not fail-closed: '$sz' rc=$rc"

# ======================================================================
echo; echo "########## F2 — ulimit -f caps a hostile over-sized stream (disk-fill) ##########"
# expected_bytes=100 -> cap ~5 KiB; a mirror streaming 20 KiB must be killed
# (SIGXFSZ) and the download must fail (no install).
: > "$ARIA_LOG"
BIG=$(head -c 20000 /dev/zero | tr '\0' 'A')
: > "$CURL_LOG"
out=$(HTTPS_ONLY=false ALLOW_UNVERIFIED=false YES_TO_ALL=true \
  EFFECTIVE_URL="https://m.invalid/f.zim" MIRROR_SCHEME=https SIZE_CL=100 ARIA_CONTENT="$BIG" \
  download_file "https://lb.download.kiwix.org/zim/x/big.zim" "$WORK_DIR/big.zim" 100 2>&1)
rc=$?
{ [ "$rc" -ne 0 ] && [ ! -f "$WORK_DIR/big.zim" ]; } \
  && pass "F2 over-cap stream killed by ulimit -f => download fails, no install" \
  || fail "F2 over-cap stream not capped (rc=$rc, installed=$([ -f "$WORK_DIR/big.zim" ] && echo yes || echo no))"

# ======================================================================
echo; echo "########## C7 — download_file return-code contract + do_smart_update dispatch ##########"
: > "$CURL_LOG"; : > "$ARIA_LOG"
mkzim "$WORK_DIR/old1.zim"; mkzim "$WORK_DIR/old2.zim"
CONTINUE_ON_ERROR=false; MIRROR_SCHEME=https; SIZE_CL=100
# --- user-decline (rc==2 -> continue): drive the confirm via stdin ---
FILES_TO_UPDATE=(
  "$WORK_DIR/old1.zim|https://lb.download.kiwix.org/zim/x/new1_2026-01.zim|new1_2026-01|100"
  "$WORK_DIR/old2.zim|https://lb.download.kiwix.org/zim/x/new2_2026-01.zim|new2_2026-01|100"
)
YES_TO_ALL=false EFFECTIVE_URL="https://m.invalid/f.zim" \
  do_smart_update <<<"n" >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && pass "C7 decline: do_smart_update returns 0 (caller continued, not break)" || fail "C7 decline: rc=$rc (expected 0)"
{ [ -f "$WORK_DIR/old1.zim" ] && [ -f "$WORK_DIR/old2.zim" ]; } && pass "C7 decline: BOTH old files preserved (no destructive rm)" || fail "C7 decline: an old file was deleted"
grep -q 'new2_2026-01' "$CURL_LOG" && pass "C7 decline: loop reached the 2nd entry (proves continue != break)" || fail "C7 decline: 2nd entry never processed"
! grep -q 'aria2c ' "$ARIA_LOG" && pass "C7 decline: aria2c never invoked" || fail "C7 decline: aria2c ran on a declined download"
# --- resolve-failure (rc==1 -> failure branch, old file preserved) ---
: > "$ARIA_LOG"; mkzim "$WORK_DIR/old3.zim"
FILES_TO_UPDATE=("$WORK_DIR/old3.zim|https://lb.download.kiwix.org/zim/x/new3_2026-01.zim|new3_2026-01|100")
YES_TO_ALL=true CURL_RESOLVE_FAIL=1 do_smart_update >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && pass "C7 resolve-failure: do_smart_update reports failure" || fail "C7 resolve-failure: rc=$rc"
[ -f "$WORK_DIR/old3.zim" ] && pass "C7 resolve-failure: old file preserved" || fail "C7 resolve-failure: old file deleted"
! grep -q 'aria2c ' "$ARIA_LOG" && pass "C7 resolve-failure: aria2c not invoked" || fail "C7 resolve-failure: aria2c ran"
# --- numfmt guard: strict path empty size must not error the prompt ---
mkzim "$WORK_DIR/old4.zim"
out=$(printf 'n\n' | HTTPS_ONLY=true YES_TO_ALL=false MIRROR_SCHEME=http \
  download_file "https://lb.download.kiwix.org/zim/x/new4.zim" "$WORK_DIR/new4.zim" 2>&1)
rc=$?
{ [ "$rc" -eq 2 ] && ! grep -qi 'numfmt' <<<"$out"; } && pass "C7 numfmt guard: empty strict-path size => clean decline (rc=2, no numfmt error)" || fail "C7 numfmt guard: rc=$rc out='$out'"

# ======================================================================
echo; echo "########## Issue #1 — dated-local-file matching ##########"
# Local Kiwix files carry a trailing _YYYY-MM date; pre-fix find_latest_zim kept
# that date in base_name so a dated file only matched a *same-date* catalog entry
# (i.e. never when an update existed) -> "SKIPPED / No match". Every case rewrites
# $LIBRARY_CACHE from scratch (hermetic — C1–C7 leave it populated).
# The unit cases call find_latest_zim directly; the i1_e2e pair asserts the same
# behavior through analyze_updates and is the durable layer if matching later moves
# into analyze_updates (backlog Batch 3) — port the unit cases to i1_e2e then.
DEBUG=false

fl_expect(){ # $1=local filename  $2=expected catalog field-2  $3=label  $4..=cache records
    local lf="$1" exp="$2" label="$3"; shift 3
    printf '%s\n' "$@" > "$LIBRARY_CACHE"
    local out rc got; out=$(find_latest_zim "$lf"); rc=$?
    got=$(printf '%s' "$out" | cut -d'|' -f2)
    { [ "$rc" -eq 0 ] && [ "$got" = "$exp" ]; } && pass "$label" || fail "$label (rc=$rc got='$got' exp='$exp')"
}
fl_nomatch(){ # $1=local filename  $2=label  $3..=cache records
    local lf="$1" label="$2"; shift 2
    printf '%s\n' "$@" > "$LIBRARY_CACHE"
    local out rc; out=$(find_latest_zim "$lf"); rc=$?
    [ "$rc" -ne 0 ] && pass "$label" || fail "$label (unexpected match rc=$rc out='$out')"
}

# --- Group 1: bug-reproducing (rc!=0 or wrong entry pre-fix) -----------------
# 1. dated local, only NEWER catalog entry present -> the reported SKIP; must resolve to newer.
fl_expect "wikiquote_en_all_maxi_2025-08.zim" "wikiquote_en_all_maxi_2025-09.zim" \
  "Issue#1.1 dated local resolves to newer catalog entry (was SKIPPED)" \
  "pub|wikiquote_en_all_maxi_2025-09.zim|https://lb.download.kiwix.org/zim/w/wikiquote_en_all_maxi_2025-09.zim|9"
# 2. best_date: highest wins regardless of cache order.
fl_expect "wikivoyage_en_all_maxi_2025-05.zim" "wikivoyage_en_all_maxi_2025-09.zim" \
  "Issue#1.2 best_date picks highest (non-monotonic seed order)" \
  "pub|wikivoyage_en_all_maxi_2025-06.zim|u|1" \
  "pub|wikivoyage_en_all_maxi_2025-09.zim|u|1" \
  "pub|wikivoyage_en_all_maxi_2025-07.zim|u|1"
# 2b. best_date tie-break: on equal max date the first-seen record wins (locks the
#     strict '>' comparison — a switch to '>=' would flip this). Two entries share
#     the max date and filename, distinguished only by field-3 (path).
printf '%s\n' \
  "pub|dup_en_all_2025-09.zim|urlFIRST|1" \
  "pub|dup_en_all_2025-09.zim|urlSECOND|1" > "$LIBRARY_CACHE"
got=$(find_latest_zim "dup_en_all_2025-05.zim" | cut -d'|' -f3)
[ "$got" = "urlFIRST" ] && pass "Issue#1.2b best_date tie-break: first-seen wins on equal date" \
  || fail "Issue#1.2b tie-break got='$got' exp='urlFIRST'"
# 3. dotted-domain literal dot: a strictly-NEWER decoy must lose to the real entry (validates Edit B;
#    without dot-escaping the decoy matches via '.'-wildcard and wins best_date).
fl_expect "superuser.com_en_all_2025-08.zim" "superuser.com_en_all_2025-09.zim" \
  "Issue#1.3 dotted '.' matched literally; newer wildcard-decoy rejected (Edit B)" \
  "pub|superuser.com_en_all_2025-09.zim|u|1" \
  "pub|superuserXcom_en_all_2025-10.zim|u|1"
fl_expect "nhs.uk_en_medicines_2025-06.zim" "nhs.uk_en_medicines_2025-07.zim" \
  "Issue#1.3b dotted nhs.uk literal-dot match; newer decoy rejected" \
  "pub|nhs.uk_en_medicines_2025-07.zim|u|1" \
  "pub|nhsXuk_en_medicines_2025-10.zim|u|1"
# 4. special-case rename table now fires for dated locals (two structurally different arms).
fl_expect "teded_en_all_2025-06.zim" "ted_mul_ted-ed_2025-07.zim" \
  "Issue#1.4a rename teded_en_all->ted_mul_ted-ed (dated)" \
  "pub|ted_mul_ted-ed_2025-07.zim|u|1"
fl_expect "wikihow_en_maxi_2025-06.zim" "wikihow_en_all_2025-07.zim" \
  "Issue#1.4b rename wikihow_en_maxi->wikihow_en_all (dated)" \
  "pub|wikihow_en_all_2025-07.zim|u|1"
# 5. wiktionary maxi->nopic fallback now reachable for dated locals.
fl_expect "wiktionary_en_all_maxi_2025-06.zim" "wiktionary_en_all_nopic_2025-07.zim" \
  "Issue#1.5 wiktionary maxi->nopic fallback (dated)" \
  "pub|wiktionary_en_all_nopic_2025-07.zim|u|1"
# 6. exact-match precedence: an undated catalog entry wins the exact-match break over a
#    newer dated one. SYNTHETIC — the real OPDS-v2 catalog always derives filenames from
#    the dated acquisition href, so an undated entry never coexists with a dated one; this
#    only locks the tie-break, it is NOT asserting a desired "prefer undated over newer"
#    update policy. (Post-fix behavior: pre-fix returns rc!=0, so this is not a Group-3 guard.)
fl_expect "foo_en_all_2025-08.zim" "foo_en_all.zim" \
  "Issue#1.6 undated exact-match entry wins over newer dated (synthetic tie-break lock)" \
  "pub|foo_en_all.zim|u|1" \
  "pub|foo_en_all_2025-09.zim|u|1"

# --- Group 2: end-to-end through analyze_updates (the user-visible SKIP) -----
UPDATE_CRITERIA=all; BACKGROUND=false
i1_e2e(){ # $1=on-disk name  $2=catalog filename (newer)  $3=label
    local disk="$1" cat="$2" label="$3"
    rm -f "$WORK_DIR"/*.zim 2>/dev/null
    mkzim "$WORK_DIR/$disk"
    # printf's truncating redirect sets the cache mtime to now -> fresh, so
    # fetch_library_data reuses the seeded cache instead of hitting the network.
    printf 'pub|%s|https://lb.download.kiwix.org/zim/x/%s|100\n' "$cat" "$cat" > "$LIBRARY_CACHE"
    FILES_TO_UPDATE=()
    analyze_updates >/dev/null 2>&1
    printf '%s\n' "${FILES_TO_UPDATE[@]}" | grep -qF "$cat" \
      && pass "$label" || fail "$label (dated file not in FILES_TO_UPDATE — reported SKIPPED)"
}
i1_e2e "wikiquote_en_all_maxi_2025-08.zim" "wikiquote_en_all_maxi_2025-09.zim" \
  "Issue#1.7 dated local drives update via analyze_updates (was SKIPPED / No match)"
i1_e2e "superuser.com_en_all_2025-08.zim" "superuser.com_en_all_2025-09.zim" \
  "Issue#1.7b dotted-domain dated local drives update end-to-end (Edit B via public path)"

# --- Group 3: guards (green BOTH before and after the fix) -------------------
fl_expect "pintest.zim" "pintest_2026-01.zim" \
  "Issue#1.8 undated local still matches (no regression)" \
  "pub|pintest_2026-01.zim|u|1"
fl_nomatch "doesnotexist_en_all_2025-08.zim" \
  "Issue#1.9 genuine no-match returns non-zero" \
  "pub|somethingelse_en_all_2025-09.zim|u|1"
# 10. boundary lock: a _YYYY-MM-DD (full-date) suffix is NOT stripped (only _YYYY-MM is),
#     so the stem stays intact and matches its own exact catalog entry. Guards the
#     documented strip scope against a future broadening of the strip regex.
fl_expect "foo_en_all_2025-08-15.zim" "foo_en_all_2025-08-15.zim" \
  "Issue#1.10 _YYYY-MM-DD suffix left unstripped (strip-scope boundary)" \
  "pub|foo_en_all_2025-08-15.zim|u|1"

# ======================================================================
echo; echo "########## M1 — transient (rc2) stops retrying vs definitive (rc1) re-downloads ##########"
# verify_downloaded_file returns 2 for a TRANSIENT metalink fetch error and 1 for
# a DEFINITIVE integrity failure. download_file's retry loop must diverge on them:
#   rc 2 -> break WITHOUT re-running aria2c (fail this run; the hash is
#           unreachable, so a re-download could not be verified either).
#   rc 1 -> rm the .part and let the outer loop re-download from scratch.
# Either way the .part is discarded: partials are not resumed across runs.
# Both cases run at MAX_RETRIES=2 so the aria2c-invocation count is discriminating
# (the harness default MAX_RETRIES=1 runs aria2c exactly once either way -> vacuous).
DL_TMP="$TEMP_DIR/m1out.zim.part"

# --- Transient metalink (503 -> rc 2): aria2c run ONCE, payload discarded -------
: > "$ARIA_LOG"; rm -f "$WORK_DIR/m1out.zim" "$DL_TMP"
# Omit expected_bytes (no positive catalog size) so the disk-fill guard is skipped
# and aria2c is actually reached; SIZE_CL kept small/benign.
MAX_RETRIES=2 YES_TO_ALL=true MIRROR_SCHEME=https SIZE_CL=100 \
  EFFECTIVE_URL="https://m.invalid/f.zim" ARIA_CONTENT="transient-payload" \
  META4_CODE=503 \
  download_file "https://lb.download.kiwix.org/zim/x/m1out.zim" "$WORK_DIR/m1out.zim" >/dev/null 2>&1
rc=$?
n_aria=$(grep -c 'aria2c ' "$ARIA_LOG")
[ "$rc" -ne 0 ] && pass "M1 transient: download_file fails this run (rc=$rc)" || fail "M1 transient: rc=$rc (expected non-zero)"
[ "$n_aria" -eq 1 ] && pass "M1 transient: aria2c invoked exactly once (payload NOT re-downloaded)" || fail "M1 transient: aria2c ran $n_aria times (expected 1)"
[ ! -f "$DL_TMP" ] && pass "M1 transient: unverifiable .part discarded (not resumed across runs)" || fail "M1 transient: .part left behind"
[ ! -f "$WORK_DIR/m1out.zim" ] && pass "M1 transient: nothing installed (fail-closed on integrity)" || fail "M1 transient: an unverified file was installed"
# A leftover temp file and aria2c control file (e.g. from a killed run) must not
# be handed to aria2c: it resumes from a leftover control file on its own, and a
# stale or foreign temp file can yield correct-size, wrong-content data that
# size-only verification would accept.
M1_SEEN="$ROOT/m1.seen"; : > "$M1_SEEN"
printf 'stale' > "$DL_TMP"; printf 'ctl' > "$DL_TMP.aria2"
STUB_ARIA_RC=1 ARIA_PREEXIST_LOG="$M1_SEEN" YES_TO_ALL=true MIRROR_SCHEME=https SIZE_CL=100 \
  EFFECTIVE_URL="https://m.invalid/f.zim" \
  download_file "https://lb.download.kiwix.org/zim/x/m1out.zim" "$WORK_DIR/m1out.zim" >/dev/null 2>&1
{ [ "$(cat "$M1_SEEN")" = end ] && [ ! -e "$DL_TMP" ] && [ ! -e "$DL_TMP.aria2" ]; } \
  && pass "M1 leftover .part and .part.aria2 are gone before aria2c starts (and after it fails)" \
  || fail "M1 leftover temp files: seen-at-start='$(tr '\n' ' ' < "$M1_SEEN")' part=$([ -e "$DL_TMP" ]&&echo y||echo n) ctl=$([ -e "$DL_TMP.aria2" ]&&echo y||echo n)"

# --- Definitive hash-mismatch (200 + wrong hash -> rc 1): discard + re-download -
: > "$ARIA_LOG"; rm -f "$WORK_DIR/m1out.zim" "$DL_TMP"
WRONG_HASH=$(printf '%064d' 0)   # valid 64-hex shape, cannot match the real payload
MAX_RETRIES=2 YES_TO_ALL=true MIRROR_SCHEME=https SIZE_CL=100 \
  EFFECTIVE_URL="https://m.invalid/f.zim" ARIA_CONTENT="definitive-payload" \
  META4_CODE=200 META4_BODY='<hash type="sha-256">'"$WRONG_HASH"'</hash>' \
  download_file "https://lb.download.kiwix.org/zim/x/m1out.zim" "$WORK_DIR/m1out.zim" >/dev/null 2>&1
rc=$?
n_aria=$(grep -c 'aria2c ' "$ARIA_LOG")
[ "$rc" -ne 0 ] && pass "M1 definitive: download_file fails (rc=$rc)" || fail "M1 definitive: rc=$rc (expected non-zero)"
[ "$n_aria" -eq 2 ] && pass "M1 definitive: aria2c invoked twice (definitive failure DOES re-download == MAX_RETRIES)" || fail "M1 definitive: aria2c ran $n_aria times (expected 2)"
[ ! -f "$DL_TMP" ] && pass "M1 definitive: .part discarded (definitive => not kept)" || fail "M1 definitive: .part survived a definitive failure"
[ ! -f "$WORK_DIR/m1out.zim" ] && pass "M1 definitive: nothing installed" || fail "M1 definitive: a mismatched file was installed"
MAX_RETRIES=1   # restore the harness default so later groups are unaffected

# ======================================================================
echo; echo "########## C1 — SHA-256 integrity: happy / mismatch / no-hash-block ##########"
# Drive download_file with the metalink stub (META4_CODE/META4_BODY) + aria2c stub
# (ARIA_CONTENT); sha256sum is REAL, so the hash gate runs end-to-end. COVERAGE
# additions (the integrity path was correct but had no test asserting a SUCCESSFUL
# install or the mismatch-discard) — each carries a passing +/- control, not a
# fail-before. The `verify_downloaded_file != -> ==` sensitivity check is scripted
# in tests/verify_c1_sensitivity.sh (flips happy<->mismatch, proving non-vacuity).
C1_BYTES="c1-known-payload-abc"                    # ASCII => byte length == char length
C1_LEN=${#C1_BYTES}
C1_HASH=$(printf '%s' "$C1_BYTES" | sha256sum | awk '{print $1}')
C1_WRONG=$(printf '%064d' 0)                        # valid 64-hex shape, cannot match the payload

# --- Happy path: matching hash => install (rc 0, .zim installed, .part moved) ---
# SIZE_CL==expected_bytes keeps the mirror within the disk-fill ceiling so aria2c
# runs; the 19-byte payload is far under the ulimit -f cap.
: > "$ARIA_LOG"; rm -f "$WORK_DIR/c1.zim" "$TEMP_DIR/c1.zim.part"
YES_TO_ALL=true MIRROR_SCHEME=https EFFECTIVE_URL="https://m.invalid/f.zim" SIZE_CL="$C1_LEN" \
  ARIA_CONTENT="$C1_BYTES" META4_CODE=200 META4_BODY='<hash type="sha-256">'"$C1_HASH"'</hash>' \
  download_file "https://lb.download.kiwix.org/zim/x/c1.zim" "$WORK_DIR/c1.zim" "$C1_LEN" >/dev/null 2>&1
rc=$?
{ [ "$rc" -eq 0 ] && [ -f "$WORK_DIR/c1.zim" ] && [ ! -f "$TEMP_DIR/c1.zim.part" ]; } \
  && pass "C1 happy: matching SHA-256 installs (rc 0, .zim present, .part moved)" \
  || fail "C1 happy: rc=$rc installed=$([ -f "$WORK_DIR/c1.zim" ]&&echo y||echo n) part=$([ -f "$TEMP_DIR/c1.zim.part" ]&&echo y||echo n)"

# --- Hash mismatch (direct): blocks install, discards .part, logs the mismatch --
: > "$ARIA_LOG"; : > "$LOG_FILE"; rm -f "$WORK_DIR/c1m.zim" "$TEMP_DIR/c1m.zim.part"
LOGFILE_SAFE=true YES_TO_ALL=true MIRROR_SCHEME=https EFFECTIVE_URL="https://m.invalid/f.zim" SIZE_CL="$C1_LEN" \
  ARIA_CONTENT="$C1_BYTES" META4_CODE=200 META4_BODY='<hash type="sha-256">'"$C1_WRONG"'</hash>' \
  download_file "https://lb.download.kiwix.org/zim/x/c1m.zim" "$WORK_DIR/c1m.zim" "$C1_LEN" >/dev/null 2>&1
rc=$?
{ [ "$rc" -ne 0 ] && [ ! -f "$WORK_DIR/c1m.zim" ] && [ ! -f "$TEMP_DIR/c1m.zim.part" ] && grep -q 'SHA-256 mismatch' "$LOG_FILE"; } \
  && pass "C1 mismatch: wrong hash blocks install (rc!=0, no .zim, .part removed, mismatch logged)" \
  || fail "C1 mismatch: rc=$rc zim=$([ -f "$WORK_DIR/c1m.zim" ]&&echo y||echo n) part=$([ -f "$TEMP_DIR/c1m.zim.part" ]&&echo y||echo n) log='$(grep -o 'SHA-256 mismatch' "$LOG_FILE" 2>/dev/null)'"

# --- Hash mismatch via do_smart_update: old file must be PRESERVED --------------
: > "$ARIA_LOG"; rm -f "$WORK_DIR"/*.zim 2>/dev/null; rm -f "$TEMP_DIR/c1old_2025-09.zim.part"
mkzim "$WORK_DIR/c1old_2025-08.zim"
FILES_TO_UPDATE=("$WORK_DIR/c1old_2025-08.zim|https://lb.download.kiwix.org/zim/x/c1old_2025-09.zim|c1old_2025-09|$C1_LEN")
CONTINUE_ON_ERROR=false YES_TO_ALL=true MIRROR_SCHEME=https EFFECTIVE_URL="https://m.invalid/f.zim" SIZE_CL="$C1_LEN" \
  ARIA_CONTENT="$C1_BYTES" META4_CODE=200 META4_BODY='<hash type="sha-256">'"$C1_WRONG"'</hash>' \
  do_smart_update >/dev/null 2>&1
rc=$?
{ [ "$rc" -ne 0 ] && [ -f "$WORK_DIR/c1old_2025-08.zim" ] && [ ! -f "$WORK_DIR/c1old_2025-09.zim" ]; } \
  && pass "C1 mismatch e2e: old file preserved, new NOT installed (do_smart_update)" \
  || fail "C1 mismatch e2e: rc=$rc old=$([ -f "$WORK_DIR/c1old_2025-08.zim" ]&&echo y||echo n) new=$([ -f "$WORK_DIR/c1old_2025-09.zim" ]&&echo y||echo n)"

# --- No-hash block: 404 metalink + ALLOW_UNVERIFIED=false => blocked ------------
: > "$ARIA_LOG"; : > "$LOG_FILE"; rm -f "$WORK_DIR/c1nh.zim" "$TEMP_DIR/c1nh.zim.part"
LOGFILE_SAFE=true YES_TO_ALL=true ALLOW_UNVERIFIED=false MIRROR_SCHEME=https EFFECTIVE_URL="https://m.invalid/f.zim" SIZE_CL="$C1_LEN" \
  ARIA_CONTENT="$C1_BYTES" META4_CODE=404 \
  download_file "https://lb.download.kiwix.org/zim/x/c1nh.zim" "$WORK_DIR/c1nh.zim" "$C1_LEN" >/dev/null 2>&1
rc=$?
{ [ "$rc" -ne 0 ] && [ ! -f "$WORK_DIR/c1nh.zim" ] && grep -q 'No SHA-256 metalink' "$LOG_FILE"; } \
  && pass "C1 no-hash: 404 metalink + !ALLOW_UNVERIFIED blocks install (fail-closed)" \
  || fail "C1 no-hash: rc=$rc zim=$([ -f "$WORK_DIR/c1nh.zim" ]&&echo y||echo n)"

# --- No-hash + ALLOW_UNVERIFIED=true + matching size => size-fallback install ---
: > "$ARIA_LOG"; rm -f "$WORK_DIR/c1sf.zim" "$TEMP_DIR/c1sf.zim.part"
YES_TO_ALL=true ALLOW_UNVERIFIED=true MIRROR_SCHEME=https EFFECTIVE_URL="https://m.invalid/f.zim" SIZE_CL="$C1_LEN" \
  ARIA_CONTENT="$C1_BYTES" META4_CODE=404 \
  download_file "https://lb.download.kiwix.org/zim/x/c1sf.zim" "$WORK_DIR/c1sf.zim" "$C1_LEN" >/dev/null 2>&1
rc=$?
{ [ "$rc" -eq 0 ] && [ -f "$WORK_DIR/c1sf.zim" ]; } \
  && pass "C1 size-fallback: no hash but --allow-unverified + matching catalog size installs" \
  || fail "C1 size-fallback: rc=$rc installed=$([ -f "$WORK_DIR/c1sf.zim" ]&&echo y||echo n)"
# The catalog rounds sizes UP to a whole KiB, so size-only verification accepts a
# payload whose size rounds up to the catalog size (or equals it), nothing else.
c1kib(){ # $1=payload bytes $2=catalog size -> C1K_RC, C1K_INSTALLED, C1K_MISMATCH_LOGGED
    rm -f "$WORK_DIR/c1k.zim" "$TEMP_DIR/c1k.zim.part"; : > "$LOG_FILE"
    LOGFILE_SAFE=true YES_TO_ALL=true ALLOW_UNVERIFIED=true MIRROR_SCHEME=https \
      EFFECTIVE_URL="https://m.invalid/f.zim" SIZE_CL="$1" \
      ARIA_CONTENT="$(head -c "$1" /dev/zero | tr '\0' x)" META4_CODE=404 \
      download_file "https://lb.download.kiwix.org/zim/x/c1k.zim" "$WORK_DIR/c1k.zim" "$2" >/dev/null 2>&1
    C1K_RC=$?
    C1K_INSTALLED=no; [ -f "$WORK_DIR/c1k.zim" ] && C1K_INSTALLED=yes
    C1K_MISMATCH_LOGGED=no; grep -q 'Size mismatch' "$LOG_FILE" && C1K_MISMATCH_LOGGED=yes
}
for c1k_case in "100 1024 accept" "1024 1024 accept" "1025 1024 refuse" "100 2048 refuse"; do
    read -r c1k_bytes c1k_cat c1k_want <<< "$c1k_case"
    c1kib "$c1k_bytes" "$c1k_cat"
    if [ "$c1k_want" = accept ]; then
        { [ "$C1K_RC" -eq 0 ] && [ "$C1K_INSTALLED" = yes ]; } \
          && pass "C1 size-fallback: ${c1k_bytes}-byte payload vs catalog ${c1k_cat} => accepted" \
          || fail "C1 size-fallback: ${c1k_bytes}-byte payload vs catalog ${c1k_cat} rejected (rc=$C1K_RC)"
    else
        { [ "$C1K_RC" -ne 0 ] && [ "$C1K_INSTALLED" = no ] && [ "$C1K_MISMATCH_LOGGED" = yes ]; } \
          && pass "C1 size-fallback: ${c1k_bytes}-byte payload vs catalog ${c1k_cat} => refused by the size gate" \
          || fail "C1 size-fallback: ${c1k_bytes}-byte payload vs catalog ${c1k_cat} rc=$C1K_RC installed=$C1K_INSTALLED mismatch_logged=$C1K_MISMATCH_LOGGED"
    fi
done

# --- M1: no hash + --allow-unverified + NO catalog size => fail closed ----------
# Regression for security-audit M1 (crypto CWE-345): under --allow-unverified with
# no authoritative catalog `length`, the pre-fix code compared the payload against
# the SAME mirror's self-reported size (circular, zero integrity) and installed.
# The fix refuses. SIZE_CL == payload length is LOAD-BEARING: it makes the pre-fix
# mirror-size check PASS so the HEAD copy INSTALLS — the flip install->refuse is
# only observable when the mirror size matches the bytes. expected_bytes is OMITTED
# (no catalog size) to force the mirror-fallback arm and skip the disk-fill guard so
# aria2c is reached. Fail-before (HEAD installs, rc 0, .zim present):
#   git show HEAD:kiwix-update.sh > "$SCRATCH/head.sh"; SCRIPT="$SCRATCH/head.sh" bash "$0"
# The mirror-size-MISMATCH sub-case is intentionally NOT tested: the fix DELETES the
# mirror-fallback branch, so post-fix no mirror-size comparison exists to exercise.
: > "$ARIA_LOG"; : > "$LOG_FILE"; rm -f "$WORK_DIR/c1m1.zim" "$TEMP_DIR/c1m1.zim.part"
M1_BYTES="m1-mirror-only-size-payload"
LOGFILE_SAFE=true HTTPS_ONLY=false YES_TO_ALL=true ALLOW_UNVERIFIED=true MIRROR_SCHEME=https \
  EFFECTIVE_URL="https://m.invalid/f.zim" SIZE_CL="${#M1_BYTES}" ARIA_CONTENT="$M1_BYTES" META4_CODE=404 \
  download_file "https://lb.download.kiwix.org/zim/x/c1m1.zim" "$WORK_DIR/c1m1.zim" >/dev/null 2>&1
rc=$?
{ [ "$rc" -ne 0 ] && [ ! -f "$WORK_DIR/c1m1.zim" ] && grep -q 'No authoritative catalog size' "$LOG_FILE"; } \
  && pass "M1: no hash + --allow-unverified + no catalog size => fail closed (mirror-only size refused)" \
  || fail "M1: rc=$rc zim=$([ -f "$WORK_DIR/c1m1.zim" ]&&echo y||echo n) log='$(grep -o 'No authoritative catalog size' "$LOG_FILE" 2>/dev/null)'"

ALLOW_UNVERIFIED=false   # restore the harness default

# ======================================================================
echo; echo "########## M9 — mirror-size disk-fill guard (over-ceiling refuse vs within-ceiling pass) ##########"
# The guard (kiwix-update.sh ~1062-1071) fires ONLY when expected_bytes is a
# positive int AND get_remote_size(final_url) returns a numeric mirror size that
# exceeds catalog+1%+4K. Pin MIRROR_SCHEME/EFFECTIVE_URL/SIZE_CL so a Content-Length
# actually comes back, else the case passes vacuously (guard skipped on empty size).
# --- Over-ceiling: mirror advertises >> catalog => refuse, aria2c NOT invoked ---
: > "$ARIA_LOG"; : > "$LOG_FILE"; rm -f "$WORK_DIR/m9.zim" "$TEMP_DIR/m9.zim.part"
LOGFILE_SAFE=true YES_TO_ALL=true MIRROR_SCHEME=https EFFECTIVE_URL="https://m.invalid/f.zim" SIZE_CL=1000000 \
  ARIA_CONTENT="m9-bytes" \
  download_file "https://lb.download.kiwix.org/zim/x/m9.zim" "$WORK_DIR/m9.zim" 100 >/dev/null 2>&1
rc=$?
{ [ "$rc" -ne 0 ] && ! grep -q 'aria2c ' "$ARIA_LOG" && grep -q 'possible disk-fill' "$LOG_FILE"; } \
  && pass "M9 over-ceiling: mirror ≫ catalog refused before download (rc!=0, aria2c not invoked, disk-fill logged)" \
  || fail "M9 over-ceiling: rc=$rc aria2c=$(grep -c 'aria2c ' "$ARIA_LOG") log='$(grep -o 'possible disk-fill' "$LOG_FILE" 2>/dev/null)'"

# --- Within-ceiling control: mirror ~= catalog => guard silent, aria2c invoked --
: > "$ARIA_LOG"; : > "$LOG_FILE"; rm -f "$WORK_DIR/m9c.zim" "$TEMP_DIR/m9c.zim.part"
LOGFILE_SAFE=true YES_TO_ALL=true MIRROR_SCHEME=https EFFECTIVE_URL="https://m.invalid/f.zim" SIZE_CL=100 \
  ARIA_CONTENT="m9-bytes" \
  download_file "https://lb.download.kiwix.org/zim/x/m9c.zim" "$WORK_DIR/m9c.zim" 100 >/dev/null 2>&1
{ grep -q 'aria2c ' "$ARIA_LOG" && ! grep -q 'possible disk-fill' "$LOG_FILE"; } \
  && pass "M9 within-ceiling: mirror ≈ catalog => guard silent, aria2c invoked (guard is non-vacuous)" \
  || fail "M9 within-ceiling: aria2c=$(grep -c 'aria2c ' "$ARIA_LOG") disk-fill-logged=$(grep -q 'possible disk-fill' "$LOG_FILE" && echo y || echo n)"

# ======================================================================
echo; echo "########## M8 — analyze_updates decision arms (size / newer) ##########"
# remote_size comes from catalog cache FIELD-4 (cut -d'|' -f4), NOT a HEAD; control
# it purely by the seeded record. Each case resets FILES_TO_UPDATE=()/stray .zim,
# sets UPDATE_CRITERIA to the arm under test (the harness 'all' leaks), and keeps a
# valid https://*.kiwix.org field-3 (the host-pin gate else skips before any arm).
# local_size is the seeded on-disk .zim (100 bytes unless m8_run's 5th argument
# says otherwise; the size arms compare against it rounded up to a whole KiB,
# i.e. 1024, because the catalog rounds sizes up). newer-arm cases date BOTH the
# local and catalog names (catalog strictly newer) so is_newer=true and the <50%
# veto is actually reachable. UPDATE_CRITERIA restored to all at the end (leak is
# bidirectional).
BACKGROUND=false
m8_run(){ # $1=local dated .zim  $2=catalog field-2 dated .zim  $3=field-4  $4=criteria  [$5=local bytes, default 100] -> M8_HIT
    rm -f "$WORK_DIR"/*.zim 2>/dev/null
    head -c "${5:-100}" /dev/zero > "$WORK_DIR/$1"
    printf 'pub|%s|https://lb.download.kiwix.org/zim/x/%s|%s\n' "$2" "$2" "$3" > "$LIBRARY_CACHE"
    FILES_TO_UPDATE=()
    UPDATE_CRITERIA="$4" analyze_updates >/dev/null 2>&1
    M8_HIT=no; printf '%s\n' "${FILES_TO_UPDATE[@]}" | grep -qF "$2" && M8_HIT=yes
}

# --- size arm: field-4 vs local size rounded up to a whole KiB (NOT size_ratio) --
m8_run "m8s_2025-08.zim" "m8s_2025-09.zim" 2048 size
[ "$M8_HIT" = yes ] && pass "M8 size: field-4 (2048) > local (100, 1 KiB) => Update needed (in FILES_TO_UPDATE)" || fail "M8 size: 2048>100 not flagged"
m8_run "m8s2_2025-08.zim" "m8s2_2025-09.zim" 100 size
[ "$M8_HIT" = no ] && pass "M8 size: field-4 (100) == local (100) => Up to date (not flagged)" || fail "M8 size: equal size wrongly flagged"
# The catalog rounds sizes UP to a whole KiB (live: 230348-byte file listed as
# 230400). An unchanged file must not be re-downloaded on every run.
for crit in all size; do
    m8_run m8k_2026-11.zim m8k_2026-11.zim 230400 "$crit" 230348
    [ "$M8_HIT" = no ] && pass "M8 KiB ($crit): catalog 230400 for a 230348-byte file => up to date" || fail "M8 KiB ($crit): KiB-rounded catalog size flagged an unchanged file"
    m8_run m8k_2026-11.zim m8k_2026-11.zim 230400 "$crit" 229376
    [ "$M8_HIT" = yes ] && pass "M8 KiB ($crit): catalog exactly 1 KiB larger (229376 -> 230400) => update needed" || fail "M8 KiB ($crit): a 1 KiB-larger catalog file was not flagged"
done

# --- size arm "Unknown" (non-numeric field-4 => size_known=false): WARN + no update
# Membership alone is vacuous here (Unknown 'not updated' == ordinary up-to-date),
# so assert the WARN in LOG_FILE. Needs a matching local so find_latest_zim resolves
# and the loop reaches the WARN (a non-matching local hits SKIPPED/continue first).
rm -f "$WORK_DIR"/*.zim 2>/dev/null; : > "$LOG_FILE"
mkzim "$WORK_DIR/m8u_2025-08.zim"
printf 'pub|m8u_2025-09.zim|https://lb.download.kiwix.org/zim/x/m8u_2025-09.zim|NA\n' > "$LIBRARY_CACHE"
FILES_TO_UPDATE=()
LOGFILE_SAFE=true UPDATE_CRITERIA=size analyze_updates >/dev/null 2>&1
m8u_hit=no; printf '%s\n' "${FILES_TO_UPDATE[@]}" | grep -qF 'm8u_2025-09.zim' && m8u_hit=yes
{ [ "$m8u_hit" = no ] && grep -q 'No catalog size for' "$LOG_FILE"; } \
  && pass "M8 size Unknown: non-numeric field-4 => not flagged + 'No catalog size' WARN logged" \
  || fail "M8 size Unknown: hit=$m8u_hit warn=$(grep -q 'No catalog size for' "$LOG_FILE" && echo y || echo n)"

# --- newer arm: single <50% size_ratio veto; both names dated (catalog newer) ---
# local=100B; field-4=40 => ratio 40 < 50 => VETOED (not flagged); field-4=60 =>
# ratio 60 => Update needed. Off the 50 boundary; identical date seeding so the
# ONLY variable is the ratio.
m8_run "m8n_2025-08.zim" "m8n_2025-09.zim" 40 newer
[ "$M8_HIT" = no ] && pass "M8 newer: newer catalog but ratio 40<50 => vetoed as different content (not flagged)" || fail "M8 newer: <50% veto did not fire"
m8_run "m8n2_2025-08.zim" "m8n2_2025-09.zim" 60 newer
[ "$M8_HIT" = yes ] && pass "M8 newer: newer catalog + ratio 60>=50 => Update needed (flagged)" || fail "M8 newer: 60% not flagged"
UPDATE_CRITERIA=all   # restore the harness global (leak is bidirectional)

# ======================================================================
if [ "${KIWIX_LIVE:-0}" = 1 ]; then
  echo; echo "########## LIVE smoke (KIWIX_LIVE=1) ##########"
  T="$ROOT/catv2_live.xml"   # private temp dir, removed by the EXIT trap
  # Watch the URL production actually uses (sourced above), not a copy of it.
  LIVE_FEED="${KIWIX_LIBRARY_API%%\?*}?count=1"
  # One fetch, deliberately WITHOUT -L — the drift alarm: production refuses any
  # redirect (-L --max-redirs 0), so a catalog move would break every run. A 3xx
  # here names the new location first; no response at all
  # is a network problem, not a move, and is skipped like any unreachable endpoint.
  live=$(timeout 30 "$REAL_CURL" -s --proto '=https' -o "$T" \
    -w '%{http_code}\t%{content_type}\t%{redirect_url}' "$LIVE_FEED" 2>/dev/null)
  IFS=$'\t' read -r feed_code ct feed_redirect <<<"$live"
  if [[ "$feed_code" == 3?? ]]; then
    fail "LIVE catalog URL redirects ($feed_code -> ${feed_redirect:-?}) — catalog moved? update KIWIX_LIBRARY_API"
  elif [[ "$feed_code" == 4?? ]]; then
    fail "LIVE catalog URL returns $feed_code — endpoint retired? update KIWIX_LIBRARY_API"
  elif [ "$feed_code" = 200 ]; then
    pass "LIVE catalog URL serves 200 directly (no redirect)"
    if grep -qi 'xml' <<<"$ct"; then pass "LIVE feed is XML"; else fail "LIVE feed not XML: $ct"; fi
    grep -q '<totalResults>' "$T" && pass "LIVE <totalResults> present" || fail "LIVE totalResults missing"
    href=$(grep -oE 'href="https://lb\.download\.kiwix\.org[^"]+\.zim\.meta4"' "$T" | head -1 | sed 's/href="//;s/"$//')
    if [ -n "$href" ]; then
      hash=$(timeout 30 "$REAL_CURL" -sL "$href" 2>/dev/null | grep -oiE '<hash[^>]*sha-?256[^>]*>[0-9a-f]{64}' | grep -oiE '[0-9a-f]{64}' | head -1)
      [[ "$hash" =~ ^[0-9a-fA-F]{64}$ ]] && pass "LIVE .meta4 yields a 64-hex sha-256" || fail "LIVE no sha-256 from $href"
      # F1 assumption check: the .zim must resolve to 200 within ONE redirect
      # (LB -> mirror). A Kiwix-side multi-redirect change would fail-closed under
      # curl's --max-redirs 1 resolve, breaking every download — catch it here.
      zurl="${href%.meta4}"
      zcode=$(timeout 30 "$REAL_CURL" -sLI --max-redirs 1 --proto '=http,https' --proto-redir '=http,https' -o /dev/null -w '%{http_code}' "$zurl" 2>/dev/null)
      [ "$zcode" = 200 ] && pass "LIVE .zim resolves 200 within 1 redirect (LB->mirror; F1 budget holds)" || fail "LIVE .zim did not resolve in 1 hop (code=$zcode) — Kiwix may use multi-redirect; revisit --max-redirs"
    else
      fail "LIVE no acquisition href found"
    fi
  else
    echo "SKIP: live endpoint unreachable/timeout (code ${feed_code:-none}; non-flaky opt-in)"
  fi
fi

echo
[ "$FAIL" -eq 0 ] && echo "==== ALL CATALOG-V2 CHECKS PASSED ====" || echo "==== SOME CATALOG-V2 CHECKS FAILED ===="
exit "$FAIL"
