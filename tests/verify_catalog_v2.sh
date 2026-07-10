#!/bin/bash
# Catalog OPDS-v2 migration verification (C1–C7).
# Exercises the REAL edited functions with a NON-VACUOUS arg-branching curl stub
# (honours --proto-redir, -L, and a CURL_RESOLVE_FAIL knob) + an argv-logging
# aria2c stub + inactive service stubs. sha256sum is REAL.
# Run from the repo root. Set KIWIX_LIVE=1 to also run the opt-in live smoke.

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/kiwix-catv2.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT
rm -rf "$ROOT"; mkdir -p "$ROOT/bin" "$ROOT/work/temp" "$ROOT/work/backups"

FAIL=0
pass(){ echo "PASS: $1"; }
fail(){ echo "FAIL: $1"; FAIL=1; }

# Capture the REAL curl before the stub bin is prepended to PATH (the live smoke
# must not hit the stub).
REAL_CURL="$(command -v curl)"

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
dir=""; out=""
for a in "$@"; do case "$a" in --dir=*) dir="${a#--dir=}";; --out=*) out="${a#--out=}";; esac; done
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
CATALOG="$ROOT/feed.xml" fetch_library_data >/dev/null 2>&1
{ [ $? -eq 0 ] && [ -s "$LIBRARY_CACHE" ]; } && pass "C1 valid feed parses (returns 0)" || fail "C1 valid feed rejected"
# missing totalResults -> fail-closed
mk_feed none entry_full; rm -f "$LIBRARY_CACHE"
CATALOG="$ROOT/feed.xml" fetch_library_data >/dev/null 2>&1
[ $? -ne 0 ] && pass "C1 missing <totalResults> fails closed" || fail "C1 missing totalResults accepted"
# truncated: totalResults=3602 but only 1 entry -> fail loud
mk_feed 3602 entry_full; rm -f "$LIBRARY_CACHE"
CATALOG="$ROOT/feed.xml" fetch_library_data >/dev/null 2>&1
[ $? -ne 0 ] && pass "C1 truncated catalog (1 of 3602) fails loud" || fail "C1 truncation not detected"

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
# relaxed default: http mirror ALLOWED, aria2c invoked with --max-redirect=2
: > "$ARIA_LOG"; : > "$CURL_LOG"
HTTPS_ONLY=false ALLOW_UNVERIFIED=false YES_TO_ALL=true \
  EFFECTIVE_URL="http://m.invalid/f.zim" MIRROR_SCHEME=http SIZE_CL=100 \
  download_file "https://lb.download.kiwix.org/zim/x/o.zim" "$WORK_DIR/c5r.zim" 100 >/dev/null 2>&1
grep -q 'aria2c ' "$ARIA_LOG" && pass "C5 relaxed: http mirror hop allowed (aria2c invoked)" || fail "C5 relaxed: aria2c not invoked"
# F1 (SSRF hardening): aria2c gets --max-redirect=0 on ALL paths (curl already
# resolved the terminal URL), and the curl resolve is capped at 1 hop.
grep -qE -- '--max-redirect=0( |$)' "$ARIA_LOG" && pass "F1 aria2c --max-redirect=0 (no attacker-injectable redirect leg)" || fail "F1 aria2c --max-redirect not 0 ($(grep -o -- '--max-redirect=[0-9]*' "$ARIA_LOG"|head -1))"
grep -qE -- '--max-redirs 1( |$)' "$CURL_LOG" && pass "F1 curl resolve bounded to 1 hop (--max-redirs 1)" || fail "F1 curl --max-redirs not 1"
# strict (--https-only): http mirror REFUSED, aria2c not invoked
: > "$ARIA_LOG"
HTTPS_ONLY=true YES_TO_ALL=true EFFECTIVE_URL="http://m.invalid/f.zim" MIRROR_SCHEME=http \
  download_file "https://lb.download.kiwix.org/zim/x/o.zim" "$WORK_DIR/c5s.zim" >/dev/null 2>&1
rc=$?; { [ "$rc" -ne 0 ] && ! grep -q 'aria2c ' "$ARIA_LOG"; } && pass "C5 strict: http mirror refused (aria2c not invoked)" || fail "C5 strict: not refused (rc=$rc)"
# strict + https mirror: allowed, aria2c --max-redirect=0
: > "$ARIA_LOG"
HTTPS_ONLY=true YES_TO_ALL=true EFFECTIVE_URL="https://m.invalid/f.zim" MIRROR_SCHEME=https SIZE_CL=100 \
  download_file "https://lb.download.kiwix.org/zim/x/o.zim" "$WORK_DIR/c5sh.zim" 100 >/dev/null 2>&1
grep -qE -- '--max-redirect=0( |$)' "$ARIA_LOG" && pass "C5 strict https: aria2c --max-redirect=0" || fail "C5 strict: --max-redirect not 0"
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
: > "$ARIA_LOG"; mkzim(){ head -c 100 /dev/zero > "$1"; }
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
if [ "${KIWIX_LIVE:-0}" = 1 ]; then
  echo; echo "########## LIVE smoke (KIWIX_LIVE=1) ##########"
  T=/tmp/catv2_live.xml
  if timeout 30 "$REAL_CURL" -sL --proto '=https' "https://library.kiwix.org/catalog/v2/entries?count=1" -o "$T" 2>/dev/null; then
    ct=$(timeout 30 "$REAL_CURL" -sIL "https://library.kiwix.org/catalog/v2/entries?count=1" 2>/dev/null | grep -i '^content-type')
    grep -qi 'xml' <<<"$ct" && pass "LIVE feed is XML" || fail "LIVE feed not XML: $ct"
    grep -q '<totalResults>' "$T" && pass "LIVE <totalResults> present" || fail "LIVE totalResults missing"
    href=$(grep -oE 'href="https://lb\.download\.kiwix\.org[^"]+\.zim\.meta4"' "$T" | head -1 | sed 's/href="//;s/"$//')
    if [ -n "$href" ]; then
      hash=$(timeout 30 "$REAL_CURL" -sL "$href" 2>/dev/null | grep -oiE '<hash[^>]*sha-?256[^>]*>[0-9a-f]{64}' | grep -oiE '[0-9a-f]{64}' | head -1)
      [[ "$hash" =~ ^[0-9a-fA-F]{64}$ ]] && pass "LIVE .meta4 yields a 64-hex sha-256" || fail "LIVE no sha-256 from $href"
      # F1 assumption check: the .zim must resolve to 200 within ONE redirect
      # (LB -> mirror). A Kiwix-side multi-redirect change would fail-closed under
      # --max-redirs 1 / --max-redirect=0, breaking every download — catch it here.
      zurl="${href%.meta4}"
      zcode=$(timeout 30 "$REAL_CURL" -sLI --max-redirs 1 --proto '=http,https' --proto-redir '=http,https' -o /dev/null -w '%{http_code}' "$zurl" 2>/dev/null)
      [ "$zcode" = 200 ] && pass "LIVE .zim resolves 200 within 1 redirect (LB->mirror; F1 budget holds)" || fail "LIVE .zim did not resolve in 1 hop (code=$zcode) — Kiwix may use multi-redirect; revisit --max-redirs"
    else
      fail "LIVE no acquisition href found"
    fi
  else
    echo "SKIP: live endpoint unreachable/timeout (non-flaky opt-in)"
  fi
fi

echo
[ "$FAIL" -eq 0 ] && echo "==== ALL CATALOG-V2 CHECKS PASSED ====" || echo "==== SOME CATALOG-V2 CHECKS FAILED ===="
exit "$FAIL"
