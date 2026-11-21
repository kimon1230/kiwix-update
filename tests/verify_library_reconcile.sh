#!/bin/bash
# Library reconciler: update_kiwix_library (the single writer of library state),
# its use by do_smart_update, and the update-library command wrapper.
# kiwix-manage stores <book path> relative to dirname(library) and resolves "../"
# lexically; entries for ZIMs outside WORK_DIR are not ours and must survive.
# kiwix-manage is a logging stub; every case runs the REAL functions in a fresh
# sub-bash. No network, no root (H4, L22, L25f and D14 self-skip as root). Runnable from any
# directory; set SCRIPT= to test another copy of kiwix-update.sh.
# Case IDs are stable (gaps are retired cases), so fail-before/mutation records
# in the plan keep pointing at the same rows.

SCRIPT="${SCRIPT:-$(dirname "$(readlink -f "$0")")/../kiwix-update.sh}"
export KUS="$SCRIPT"
ROOT=$(realpath "$(mktemp -d "${TMPDIR:-/tmp}/kiwixlibXXXXXX")")
trap 'chmod -R u+rwX "$ROOT" 2>/dev/null; rm -rf "$ROOT"' EXIT

FAIL=0
pass(){ echo "PASS: $1"; }
fail(){ echo "FAIL: $1"; FAIL=1; }

MSG_COMPLETE="Library update complete"
MSG_UNRESOLVED="Could not resolve library paths"
MSG_SYMLINK_REFUSAL="it is a symlink"
MSG_PREFLIGHT_ABORT="aborting before any download"
MSG_DSU_OK="Smart update completed successfully"

# kiwix-manage stub: logs LIB<TAB>VERB<TAB>ARG (tab-separated so paths with spaces
# parse unambiguously). A successful `remove` appends a marker to the file it was
# given (after deleting that book, as kiwix-manage does), so a case can prove the
# temp copy was atomically mv'd over the library; a
# successful `add` appends a <book> line, so later reconciles in the same run see
# it as listed. KM_FAIL_VERB=add|remove makes that verb fail (exit 1, no write);
# KM_FAIL_ARG=<basename> makes any call on that one file fail (a bad bystander);
# KM_MODE_FILE=<path> records the library's mode at each add (no unreadable window);
# KM_TRUNCATE_ON_REMOVE=1 makes remove "succeed" but leave an empty file.
STUB="$ROOT/bin"; mkdir -p "$STUB"
cat > "$STUB/kiwix-manage" <<'S'
#!/bin/bash
printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$KM_LOG"
[ "${KM_FAIL_VERB:-}" = "$2" ] && exit 1
# Like kiwix-manage 3.7.0: a missing library is fine (created on add), a 0-byte
# one is not ("Cannot read the library").
[ -e "$1" ] && [ ! -s "$1" ] && exit 1
[ -n "${KM_FAIL_ARG:-}" ] && [ "${3##*/}" = "$KM_FAIL_ARG" ] && exit 1
if [ "$2" = remove ] && [ -n "${KM_TRUNCATE_ON_REMOVE:-}" ]; then : > "$1"; exit 0; fi
if [ "$2" = remove ]; then
    { grep -vF " id=\"$3\" " "$1" || true; } > "$1.km" && mv "$1.km" "$1"
    printf '<!-- km-removed %s -->\n' "$3" >> "$1"
fi
[ "$2" = add ] && [ -n "${KM_MODE_FILE:-}" ] && stat -c %a "$1" >> "$KM_MODE_FILE"
[ "$2" = add ] && printf '  <book id="km-added-%s" path="%s" />\n' "${3##*/}" "$3" >> "$1"
exit 0
S
chmod +x "$STUB/kiwix-manage"

# realpath stub for resolution-failure cases: fails any call carrying -z (the
# batched library resolution) and forwards everything else to the real binary,
# whose absolute path is baked in now, before any PATH change.
REAL_RP=$(command -v realpath)
RPFAIL="$ROOT/rpfail"; mkdir -p "$RPFAIL"
# With RPFAIL_FLAG set, it only starts failing once that file exists (lets a case
# pass the pre-flight and then fail a later reconcile).
cat > "$RPFAIL/realpath" <<S
#!/bin/bash
if [ -z "\${RPFAIL_FLAG:-}" ] || [ -e "\$RPFAIL_FLAG" ]; then
    for a in "\$@"; do [ "\$a" = "-z" ] && exit 1; done
fi
exec "$REAL_RP" "\$@"
S
chmod +x "$RPFAIL/realpath"

# write_lib FILE "id|path" ... — <book> lines in the attribute layout kiwix-manage
# 3.7.0 writes (captured from a real run; favicon trimmed). Paths are written as
# given, so callers pass them already XML-escaped where needed.
write_lib(){
    local file="$1" pair; shift
    mkdir -p "$(dirname "$file")"
    {
        printf '<library version="20110515">\n'
        for pair in "$@"; do
            printf '  <book id="%s" path="%s" title="t" description="d" language="eng" creator="Wikipedia" publisher="openZIM" name="n" flavour="maxi" tags="wikipedia" faviconMimeType="image/png" date="2026-11-01" articleCount="1" mediaCount="1" size="1" />\n' "${pair%%|*}" "${pair#*|}"
        done
        printf '</library>\n'
    } > "$file"
}
mkzim(){ mkdir -p "$(dirname "$1")"; printf 'ZIM' > "$1"; }

newcase(){ C="$ROOT/c$1"; WD="$C/var/local/zims"; USB="$C/mnt/usb"; mkdir -p "$WD" "$USB"
           C_WD="$WD"; C_LIB="$C/var/local/library_zim.xml"; C_CWD=""; C_PATH=""
           C_REFRESH=""; KM_FAIL_VERB=""; KM_FAIL_ARG=""; ORDER_CHECK=1; DL_FAIL_ON=""; DL_KILL_ON=""
           C_CONT=false; RPFAIL_FLAG=""; KM_MODE_FILE=""; KM_TRUNCATE_ON_REMOVE=""; C_UNPRIV=""; }

# run_reconcile: env C_WD C_LIB [C_CWD C_PATH C_REFRESH KM_FAIL_VERB KM_MODE_FILE
#   KM_TRUNCATE_ON_REMOVE C_UNPRIV=true|false (default true)]
#   -> OUT (stdout+stderr), RC, KM_LOG. update_kiwix_library is the body's final
#   statement under set -euo pipefail, so an abort would surface as a bad rc.
N=0
run_reconcile(){
    N=$((N + 1)); KM_LOG="$ROOT/km.$N.log"; : > "$KM_LOG"
    OUT=$(cd "${C_CWD:-$ROOT}" && KM_LOG="$KM_LOG" KM_FAIL_VERB="$KM_FAIL_VERB" KM_MODE_FILE="${KM_MODE_FILE:-}" KM_TRUNCATE_ON_REMOVE="${KM_TRUNCATE_ON_REMOVE:-}" C_UNPRIV="${C_UNPRIV:-true}" \
        C_WD="$C_WD" C_LIB="$C_LIB" C_REFRESH="$C_REFRESH" \
        PATH="${C_PATH:-$STUB:$PATH}" bash -c '
        source "$KUS" >/dev/null 2>&1
        set -euo pipefail
        backup_library_xml(){ :; }
        WORK_DIR="$C_WD"; ZIM_LIBRARY="$C_LIB"; UNPRIVILEGED="$C_UNPRIV"; DEBUG=false
        update_kiwix_library ${C_REFRESH:+"$C_REFRESH"}' 2>&1); RC=$?
}

# check RC "add-path;…" "remove-id;…" COMPLETION(1/0) [REQUIRED-MSG] -> sets WHY.
# Exact: add/remove line counts must equal the expected lists; adds must target
# the real library and removes the temp copy; every expected removal must have
# landed in the real library (the atomic mv happened); removes precede adds.
check(){
    local erc="$1" eadds="$2" erms="$3" ecomp="$4" emsg="${5:-}" x
    local -a adds=() rms=()
    WHY=""
    [ -n "$eadds" ] && IFS=';' read -ra adds <<< "$eadds"
    [ -n "$erms" ] && IFS=';' read -ra rms <<< "$erms"
    [ "$RC" -eq "$erc" ] || WHY+=" rc=$RC(want $erc)"
    local nadd nrm
    nadd=$(awk -F'\t' '$2=="add"' "$KM_LOG" | wc -l); nrm=$(awk -F'\t' '$2=="remove"' "$KM_LOG" | wc -l)
    [ "$nadd" -eq "${#adds[@]}" ] || WHY+=" adds=$nadd(want ${#adds[@]})"
    [ "$nrm" -eq "${#rms[@]}" ] || WHY+=" removes=$nrm(want ${#rms[@]})"
    for x in "${adds[@]}"; do
        awk -F'\t' -v p="$x" -v l="$C_LIB" '$2=="add" && $3==p && $1==l {f=1} END{exit !f}' "$KM_LOG" \
          || WHY+=" missing-add-to-library:$x"
    done
    for x in "${rms[@]}"; do
        awk -F'\t' -v i="$x" '$2=="remove" && $3==i && $1 ~ /\.library_zim_temp\./ {f=1} END{exit !f}' "$KM_LOG" \
          || WHY+=" missing-remove-on-temp:$x"
        [ -n "$KM_FAIL_VERB" ] || (cd "${C_CWD:-$ROOT}" && grep -q "km-removed $x " "$C_LIB") \
          || WHY+=" removal-not-in-library:$x"
    done
    local last_rm first_add
    last_rm=$(awk -F'\t' '$2=="remove"{n=NR} END{print n+0}' "$KM_LOG")
    first_add=$(awk -F'\t' '$2=="add"{print NR; exit}' "$KM_LOG")
    # Within ONE reconcile, removes precede adds (multi-reconcile runs opt out).
    [ "$ORDER_CHECK" != 1 ] || [ -z "$first_add" ] || [ "$last_rm" -lt "$first_add" ] || WHY+=" add-before-remove"
    if [ "$ecomp" = 1 ]; then grep -q "$MSG_COMPLETE" <<< "$OUT" || WHY+=" no-completion-log"
    else grep -q "$MSG_COMPLETE" <<< "$OUT" && WHY+=" unexpected-completion-log"; fi
    [ -z "$emsg" ] || grep -q "$emsg" <<< "$OUT" || WHY+=" missing-msg:'$emsg'"
    if [ -n "$(cd "${C_CWD:-$ROOT}" && find "$(dirname "$C_LIB")" -maxdepth 1 -name '.library_zim_temp.*' 2>/dev/null)" ]; then
        WHY+=" temp-left"
    fi
}
report(){ if [ -z "$WHY" ]; then pass "$1"; else fail "$1:$WHY | log: $(tr '\t\n' ' /' < "$KM_LOG")"; fi; }
# expect_ok NAME "adds" "removes" [MSG] — rc 0, completion logged.
expect_ok(){ check 0 "$2" "$3" 1 "${4:-}"; report "$1"; }
# expect_refused NAME MSG — rc 1, nothing added/removed, no completion, MSG logged.
expect_refused(){ check 1 "" "" 0 "$2"; report "$1"; }

echo "########## update_kiwix_library — outside-WORK_DIR entries survive ##########"
# Every negative case carries a positive control: a missing zims/gone.zim that MUST
# be removed, proving the remove loop actually ran.

newcase 1; mkzim "$USB/y.zim"
write_lib "$C_LIB" "gone|zims/gone.zim" "usb|../../mnt/usb/y.zim"
run_reconcile; expect_ok "L1 relative ../ entry outside WORK_DIR kept" "" "gone"

newcase 2; mkzim "$USB/y.zim"
write_lib "$C_LIB" "gone|zims/gone.zim" "usb|$USB/y.zim"
run_reconcile; expect_ok "L2 absolute entry outside WORK_DIR kept" "" "gone"

newcase 3
write_lib "$C_LIB" "gone|zims/gone.zim" "usb|../../mnt/usb/y.zim"
run_reconcile; expect_ok "L3 missing file outside WORK_DIR (unmounted disk) kept" "" "gone"

newcase 4; C_WD="$WD/"
write_lib "$C_LIB" "gone|zims/gone.zim"
run_reconcile; expect_ok "L4 missing WORK_DIR entry removed (WORK_DIR with trailing slash)" "" "gone"

newcase 5; mkzim "$WD/a.zim"
write_lib "$C_LIB" "gone|zims/gone.zim" "a|zims/a.zim"
run_reconcile; expect_ok "L5 present WORK_DIR entry neither re-added nor removed" "" "gone"

newcase 6; mkzim "$WD/new.zim"
write_lib "$C_LIB" "gone|zims/gone.zim"
run_reconcile; expect_ok "L6 unlisted WORK_DIR file added (after removals)" "$WD/new.zim" "gone"

newcase 7; mkzim "$WD/y.zim"; mkzim "$USB/y.zim"
write_lib "$C_LIB" "gone|zims/gone.zim" "usb|../../mnt/usb/y.zim"
run_reconcile; expect_ok "L7 WORK_DIR y.zim added despite same-name entry on another disk" "$WD/y.zim" "gone"

newcase 8; C_LIB="$C/var/local/lib/library_zim.xml"
write_lib "$C_LIB" "gone|../zims/gone.zim"
run_reconcile; expect_ok "L8 ../ path normalized against the library's own dir" "" "gone"

newcase 9; mkzim "$WD/sub/x.zim"   # a PRESENT subdirectory ZIM must not be added either
write_lib "$C_LIB" "gone|zims/gone.zim" "sub|zims/sub/z.zim"
run_reconcile; expect_ok "L9 WORK_DIR subdirectory not managed: missing entry kept, present ZIM not added" "" "gone"

newcase 10; mkdir -p "$C/real/libdir" "$C/var/local"; ln -s "$C/real/libdir" "$C/var/local/lnk"
mkzim "$WD/a.zim"; C_LIB="$C/var/local/lnk/library_zim.xml"
write_lib "$C_LIB" "gone|../zims/gone.zim" "a|../zims/a.zim"
run_reconcile; expect_ok "L10 symlinked library ancestor: ../ resolved lexically (kiwix semantics)" "" "gone"

newcase 11; WD="$C/r&d/zims"; C_WD="$WD"; mkzim "$WD/a.zim"; C_LIB="$C/lib/library_zim.xml"
write_lib "$C_LIB" "gone|../r&amp;d/zims/gone.zim" "a|../r&amp;d/zims/a.zim"
run_reconcile; expect_ok "L11 XML-escaped (&amp;) paths decoded before comparing" "" "gone"

newcase 12; ln -s "$USB/missing.zim" "$WD/link.zim"
write_lib "$C_LIB" "link|zims/link.zim"
run_reconcile; expect_ok "L12 dangling symlink in WORK_DIR: entry removed" "" "link"

newcase 13; mkzim "$WD/a.zim"; : > "$C_LIB"
run_reconcile; expect_ok "L13 empty library file: WORK_DIR file added (set -u safe)" "$WD/a.zim" ""

newcase 15; mkzim "$WD/b.zim"; mkdir -p "$C/elsewhere"; write_lib "$C/elsewhere/real.xml"
ln -s "$C/elsewhere/real.xml" "$C_LIB"
run_reconcile; expect_refused "L15 symlinked library refused BEFORE any add/remove" "$MSG_SYMLINK_REFUSAL"

newcase 16; mkzim "$WD/a.zim"; write_lib "$C_LIB" "gone|zims/gone.zim" "a|zims/a.zim"
C_CWD="$C/var/local"; C_LIB="library_zim.xml"
run_reconcile; expect_ok "L16 relative KIWIX_ZIM_LIBRARY resolved from cwd like kiwix-manage" "" "gone"

newcase 17; mkzim "$WD/a.zim"; write_lib "$C_LIB" "gone|zims/gone.zim" "a|zims/a.zim"
if [ "$(PATH="$RPFAIL:$PATH" realpath -ms -- /x)" = "/x" ]; then
    C_PATH="$RPFAIL:$STUB:$PATH"
    run_reconcile; expect_refused "L17 path-resolution failure under set -e: clean rc 1 + ERROR, no changes" "$MSG_UNRESOLVED"
else
    fail "L17 setup: realpath stub does not forward single-operand calls"
fi

newcase 18; write_lib "$C_LIB" "gone|zims/gone.zim"; KM_FAIL_VERB=remove
cp "$C_LIB" "$C/before.xml"
run_reconcile; check 2 "" "gone" 1 "Failed to remove"
cmp -s "$C/before.xml" "$C_LIB" || WHY+=" library-changed-despite-failed-remove"
report "L18 kiwix-manage remove fails: ERROR, library unchanged, temp cleaned, rc 2 (completed with failures)"

newcase 53; mkzim "$WD/new.zim"; write_lib "$C_LIB" "gone|zims/gone.zim"; cp "$C_LIB" "$C/before.xml"
mkdir -p "$C/mvbin"; real_mv=$(command -v mv)
cat > "$C/mvbin/mv" <<S
#!/bin/bash
for a in "\$@"; do last="\$a"; done
[ "\$last" = "$C_LIB" ] && exit 1
exec "$real_mv" "\$@"
S
chmod +x "$C/mvbin/mv"; C_PATH="$C/mvbin:$STUB:$PATH"
run_reconcile; WHY=""
[ "$RC" -eq 1 ] || WHY+=" rc=$RC(want 1)"
grep -q "Cannot replace .* removals not applied" <<< "$OUT" || WHY+=" no-msg"
cmp -s "$C/before.xml" "$C_LIB" || WHY+=" library-changed"
awk -F'\t' '$2=="add"' "$KM_LOG" | grep -q . && WHY+=" added-anyway"
[ -z "$(find "$(dirname "$C_LIB")" -maxdepth 1 -name '.library_zim_temp.*')" ] || WHY+=" temp-left"
report "L18b committing the removals fails: rc 1, library byte-identical, no adds, temp cleaned"

newcase 54; mkzim "$WD/a.zim"; write_lib "$C_LIB" "old-uuid|zims/a.zim"; C_REFRESH="$WD/a.zim"
cp "$C_LIB" "$C/before.xml"; KM_TRUNCATE_ON_REMOVE=1
run_reconcile; WHY=""
[ "$RC" -eq 1 ] || WHY+=" rc=$RC(want 1)"
grep -q "left an empty temp library" <<< "$OUT" || WHY+=" no-msg"
cmp -s "$C/before.xml" "$C_LIB" || WHY+=" library-changed"
awk -F'\t' '$2=="add"' "$KM_LOG" | grep -q . && WHY+=" re-added-next-to-stale-entry"
[ -z "$(find "$(dirname "$C_LIB")" -maxdepth 1 -name '.library_zim_temp.*')" ] || WHY+=" temp-left"
report "L18c remove 'succeeds' but empties the temp: refused (rc 1), library untouched, no re-add"

newcase 19; mkzim "$WD/new.zim"; write_lib "$C_LIB"; KM_FAIL_VERB=add
run_reconcile; check 2 "$WD/new.zim" "" 1 "Failed to add"
report "L19 kiwix-manage add fails: ERROR logged, reconcile reports rc 2 (completed with failures)"

newcase 20; mkzim "$WD/a.zim"; write_lib "$C_LIB" "old-uuid|zims/a.zim"; C_REFRESH="$WD/a.zim"
run_reconcile; expect_ok "L20 refresh: replaced-in-place file's entry removed then re-added" "$WD/a.zim" "old-uuid"

newcase 52; C_WD="$WD/"; mkzim "$WD/a.zim"; write_lib "$C_LIB" "old-uuid|zims/a.zim"; C_REFRESH="$C_WD/a.zim"
run_reconcile; expect_ok "L20b refresh path with a trailing-slash WORK_DIR (zims//a.zim) still matches" "$WD/a.zim" "old-uuid"

# WORK_DIR reached through a symlinked ANCESTOR (e.g. /home -> /var/home): kiwix
# stores and we compare lexical (-s) paths, so nothing may be resolved physically.
newcase 56; mkdir -p "$C/real/zims"; ln -s "$C/real" "$C/lnk"; mkzim "$C/real/zims/a.zim"
C_WD="$C/lnk/zims"; C_LIB="$C/lnk/library_zim.xml"; write_lib "$C_LIB" "gone|zims/gone.zim" "a|zims/a.zim"
run_reconcile; expect_ok "L20c WORK_DIR via symlinked ancestor: stale entry removed, listed file not re-added" "" "gone"

newcase 57; mkdir -p "$C/real/zims"; ln -s "$C/real" "$C/lnk"; mkzim "$C/real/zims/a.zim"
C_WD="$C/lnk/zims"; C_LIB="$C/lnk/library_zim.xml"; write_lib "$C_LIB" "a|zims/a.zim"; C_REFRESH="$C/lnk/zims/a.zim"
run_reconcile; expect_ok "L20d refresh through a symlinked ancestor still matches (stale UUID dropped)" "$C/lnk/zims/a.zim" "a"

newcase 58; mkzim "$WD/a.zim"; C_WD="$WD/../zims"; write_lib "$C_LIB" "gone|zims/gone.zim" "a|zims/a.zim"
run_reconcile; expect_ok "L20e WORK_DIR containing '..': listed file not re-added, stale entry removed" "" "gone"

# Root mode hands the library to root:root; unprivileged mode never chowns.
newcase 61; mkzim "$WD/a.zim"; write_lib "$C_LIB" "a|zims/a.zim"; mkdir -p "$C/cobin"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s"\nexit 0\n' "$C/chown.log" > "$C/cobin/chown"; chmod +x "$C/cobin/chown"
C_PATH="$C/cobin:$STUB:$PATH"; C_UNPRIV=false
run_reconcile
[ "$RC" -eq 0 ] && [ "$(cat "$C/chown.log" 2>/dev/null)" = "--no-dereference root:root $C_LIB" ] \
  && pass "L28 root mode: library chowned root:root (no-dereference), exactly once" \
  || fail "L28 rc=$RC chown calls: '$(tr '\n' '|' < "$C/chown.log" 2>/dev/null)'"
newcase 62; mkzim "$WD/a.zim"; write_lib "$C_LIB" "a|zims/a.zim"; mkdir -p "$C/cobin"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s"\nexit 0\n' "$C/chown.log" > "$C/cobin/chown"; chmod +x "$C/cobin/chown"
C_PATH="$C/cobin:$STUB:$PATH"
run_reconcile
[ "$RC" -eq 0 ] && [ ! -e "$C/chown.log" ] && ! grep -q "Cannot chown" <<< "$OUT" \
  && pass "L28b unprivileged mode: no chown attempted" || fail "L28b chown called in unprivileged mode"

# Killed mid-reconcile (SIGTERM while kiwix-manage works on the temp): the trap's
# cleanup() must remove the temp copy; the library itself stays untouched.
newcase 63; write_lib "$C_LIB" "gone|zims/gone.zim"; cp "$C_LIB" "$C/before.xml"; mkdir -p "$C/kmkill"
printf '#!/bin/bash\n: > "%s"; kill -TERM "$PPID"; sleep 1; exit 0\n' "$C/km-ran" > "$C/kmkill/kiwix-manage"; chmod +x "$C/kmkill/kiwix-manage"
kmpath="$C/kmkill:$PATH"
out=$(C="$C" C_WD="$C_WD" C_LIB="$C_LIB" PATH="$kmpath" bash -c 'source "$KUS" >/dev/null 2>&1
    set -euo pipefail; trap cleanup EXIT; trap "cleanup 143" SIGTERM; trap "cleanup 130" SIGINT; trap "cleanup 129" SIGHUP
    backup_library_xml(){ :; }
    WORK_DIR="$C_WD"; ZIM_LIBRARY="$C_LIB"; UNPRIVILEGED=true; DEBUG=false; QUIET=true
    TEMP_DIR="$C/tmpdir"; STATUS_FILE="$C/status"; PID_FILE="$C/pid"
    update_kiwix_library; echo "NOT-KILLED"' 2>&1)
{ [ -e "$C/km-ran" ] && ! grep -q NOT-KILLED <<< "$out" && cmp -s "$C/before.xml" "$C_LIB" &&
  [ -z "$(find "$(dirname "$C_LIB")" -maxdepth 1 -name '.library_zim_temp.*')" ]; } \
  && pass "L29 SIGTERM mid-reconcile: cleanup() removes the temp copy, library untouched" \
  || fail "L29 kill-reached=$([ -e "$C/km-ran" ] && echo y || echo n) temps: '$(find "$(dirname "$C_LIB")" -maxdepth 1 -name '.library_zim_temp.*' -printf '%f ')' out: $(tail -2 <<< "$out" | tr '\n' ' ')"

newcase 21; mkzim "$WD/s p]c.zim"; write_lib "$C_LIB" "odd|zims/s p]c.zim"; C_REFRESH="$WD/s p]c.zim"
run_reconcile; expect_ok "L21 refresh with space and ']' in the filename" "$WD/s p]c.zim" "odd"

if [ "$(id -u)" -eq 0 ]; then
    echo "SKIP: L22 (root bypasses directory permissions)"
else
    newcase 23; mkzim "$WD/new.zim"; write_lib "$C_LIB" "gone|zims/gone.zim"; chmod 555 "$C/var/local"
    run_reconcile; chmod 755 "$C/var/local"
    expect_refused "L22 library dir not writable: reconcile refused, nothing changed" "Cannot create a temp"
fi

newcase 24   # no library file: newcase never creates C_LIB
mkdir -p "$C/mtbin"; printf '#!/bin/bash\nexit 1\n' > "$C/mtbin/mktemp"; chmod +x "$C/mtbin/mktemp"
C_PATH="$C/mtbin:$STUB:$PATH"
run_reconcile; expect_refused "L23 refusal leaves no side effect: a missing library is not created" "Cannot create a temp"
[ ! -e "$C_LIB" ] && pass "L23b missing library still absent after the refused reconcile" \
  || fail "L23b refused reconcile created $C_LIB"

newcase 25; mkzim "$WD/a.zim"   # fresh install: no library yet, normal tools
run_reconcile; expect_ok "L24 missing library is created and populated" "$WD/a.zim" ""
{ [ -f "$C_LIB" ] && grep -q "Library file does not exist" <<< "$OUT"; } \
  && pass "L24b library file created (WARN logged)" || fail "L24b library not created / no WARN"

newcase 29   # no library and nothing to add: the skeleton write is the only thing that creates it
run_reconcile; expect_ok "L24c missing library + empty WORK_DIR: reconcile succeeds" "" ""
grep -q '^<library version=' "$C_LIB" 2>/dev/null && grep -q '^</library>' "$C_LIB" \
  && [ -z "$(find "$(dirname "$C_LIB")" -maxdepth 1 -name '.library_zim_temp.*')" ] \
  && pass "L24d valid empty <library> created even with nothing to add (kiwix rejects 0-byte), no temp left" \
  || fail "L24d no valid library file created for an empty WORK_DIR"

newcase 47; mkzim "$WD/a.zim"; : > "$C_LIB"   # 0-byte library left by an earlier version
run_reconcile; expect_ok "L27 0-byte library is initialised, then populated" "$WD/a.zim" ""
grep -q "Library file is empty" <<< "$OUT" && grep -q '^<library version=' "$C_LIB" \
  && pass "L27b 0-byte library healed to a valid <library> (WARN logged)" \
  || fail "L27b 0-byte library not initialised"

newcase 26; mkzim "$WD/a.zim"; write_lib "$C_LIB" "wd-a|zims/a.zim"; cp "$C_LIB" "$C/before.xml"
mkdir -p "$C/cpbin"; printf '#!/bin/bash\nexit 1\n' > "$C/cpbin/cp"; chmod +x "$C/cpbin/cp"
C_PATH="$C/cpbin:$STUB:$PATH"
run_reconcile; expect_refused "L25 cp fails on an EXISTING library: refused" "Cannot copy"
{ [ -f "$C_LIB" ] && cmp -s "$C_LIB" "$C/before.xml"; } \
  && pass "L25b existing library left byte-identical (never deleted) when cp fails" \
  || fail "L25b existing library deleted or changed after a cp failure"

newcase 28; mkzim "$WD/a.zim"; mkdir -p "$C/cpbin"   # no library + a cp that always fails
printf '#!/bin/bash\nexit 1\n' > "$C/cpbin/cp"; chmod +x "$C/cpbin/cp"; C_PATH="$C/cpbin:$STUB:$PATH"
run_reconcile; expect_ok "L25c missing library: nothing to copy, cp never needed — created and populated" "$WD/a.zim" ""

newcase 46; mkzim "$WD/a.zim"; mkdir -p "$C/mvbin"   # no library + an mv that always fails
printf '#!/bin/bash\nexit 1\n' > "$C/mvbin/mv"; chmod +x "$C/mvbin/mv"; C_PATH="$C/mvbin:$STUB:$PATH"
run_reconcile; expect_refused "L25d library cannot be initialised: refused, temp cleaned, nothing added" "Cannot create ${C_LIB}"
[ ! -e "$C_LIB" ] && pass "L25e failed initialisation leaves no library file (atomic)" \
  || fail "L25e failed initialisation left $C_LIB behind"

if [ "$(id -u)" -eq 0 ]; then
    echo "SKIP: L25f (root bypasses file permissions)"
else
    newcase 48; mkzim "$WD/a.zim"; : > "$C_LIB"; chmod 444 "$C_LIB"   # 0-byte, read-only file, writable dir
    run_reconcile; f_mode=$(stat -c %a "$C_LIB")   # read before any test-side cleanup
    expect_ok "L25f read-only 0-byte library in a writable dir: healed by atomic rename" "$WD/a.zim" ""
    { [ "$f_mode" = 644 ] && grep -q '^<library version=' "$C_LIB" &&
      [ -z "$(find "$(dirname "$C_LIB")" -maxdepth 1 -name '.library_zim_temp.*')" ]; } \
      && pass "L25f2 healed library is mode 644, a valid <library>, no temp left" \
      || fail "L25f2 healed library mode $f_mode / content / temps wrong"
fi

# mktemp files are always 0600; the temp must be 644 BEFORE it is renamed into
# place, so the live library is never unreadable by kiwix-serve — not even
# during the adds (an interrupted run would otherwise leave it 0600).
newcase 49; mkzim "$WD/a.zim"; KM_MODE_FILE="$C/modes"   # init path
run_reconcile
{ [ "$(stat -c %a "$C_LIB" 2>/dev/null)" = 644 ] && [ "$(sort -u "$C/modes" 2>/dev/null)" = 644 ]; } \
  && pass "L24e newly created library is 644 during the adds and after" \
  || fail "L24e modes during add: '$(tr '\n' ' ' < "$C/modes" 2>/dev/null)', final $(stat -c %a "$C_LIB" 2>/dev/null)"

newcase 50; mkzim "$WD/a.zim"; write_lib "$C_LIB" "gone|zims/gone.zim"; chmod 644 "$C_LIB"; KM_MODE_FILE="$C/modes"   # removal mv path
run_reconcile
{ [ "$(stat -c %a "$C_LIB" 2>/dev/null)" = 644 ] && [ "$(sort -u "$C/modes" 2>/dev/null)" = 644 ]; } \
  && pass "L24f library rewritten by the removal mv is 644 during the adds and after" \
  || fail "L24f modes during add: '$(tr '\n' ' ' < "$C/modes" 2>/dev/null)', final $(stat -c %a "$C_LIB" 2>/dev/null)"

newcase 51; mkzim "$WD/a.zim"; write_lib "$C_LIB" "wd-a|zims/a.zim"; chmod 600 "$C_LIB"   # 0600 left by an earlier version; no temp path taken
ino0=$(stat -c %i "$C_LIB"); cp "$C_LIB" "$C/before.xml"
run_reconcile
[ "$RC" -eq 0 ] && [ ! -s "$KM_LOG" ] && [ "$(stat -c %i "$C_LIB")" = "$ino0" ] && cmp -s "$C_LIB" "$C/before.xml" \
  && [ "$(stat -c %a "$C_LIB" 2>/dev/null)" = 644 ] && pass "L24g pre-existing 0600 library (no removals/adds) is healed to 644 by the final chmod" \
  || fail "L24g rc=$RC km-calls=$(wc -l < "$KM_LOG") inode-same=$([ "$(stat -c %i "$C_LIB")" = "$ino0" ] && echo y || echo n) mode=$(stat -c %a "$C_LIB" 2>/dev/null) (want rc 0, 0 calls, same inode/content, 644)"

newcase 27; mkzim "$WD/a.zim"; mkdir "$C_LIB"
run_reconcile; check 1 "" "" 0 "not a regular file"
grep -q "Cannot copy" <<< "$OUT" && WHY+=" refused-by-cp-not-guard"
report "L26 library path is a directory: refused by the guard (not by a later cp)"

echo
echo "########## helpers ##########"
if ! bash -c 'source "$KUS" >/dev/null 2>&1; declare -F _lib_load >/dev/null'; then
    echo "SKIP: H4–H6 (_lib_* helpers not defined in $SCRIPT)"
else
    if [ "$(id -u)" -eq 0 ]; then
        echo "SKIP: H4 (root bypasses file permissions)"
    else
        newcase 22; write_lib "$C_LIB" "a|zims/a.zim"; chmod 000 "$C_LIB"
        out=$(C_LIB="$C_LIB" bash -c 'source "$KUS" >/dev/null 2>&1
            ZIM_LIBRARY="$C_LIB"; ids=(x); paths=(x); rc=0
            _lib_load ids paths 2>/dev/null || rc=$?
            echo "$rc ${#ids[@]} ${#paths[@]}"'); chmod 600 "$C_LIB"
        [ "$out" = "2 0 0" ] && pass "H4 unreadable library -> rc 2, empty arrays (never 'empty library')" \
          || fail "H4 got '$out' (want '2 0 0')"
    fi
    for patsub in on off; do
        # shellcheck disable=SC2016  # single quotes are deliberate: expanded by the child bash
        out=$(PATSUB="$patsub" bash -c 'source "$KUS" >/dev/null 2>&1
            if [ "$PATSUB" = on ]; then shopt -s patsub_replacement 2>/dev/null || true
            else shopt -u patsub_replacement 2>/dev/null || true; fi
            s="a&lt;b&gt;c&quot;d&apos;e&amp;f&amp;lt;"; _lib_unescape s; printf "%s" "$s"')
        [ "$out" = "a<b>c\"d'e&f&lt;" ] && pass "H5 all five XML entities decoded once (patsub_replacement $patsub)" \
          || fail "H5 patsub $patsub: got '$out'"
    done
    out=$(bash -c 'source "$KUS" >/dev/null 2>&1
        _lib_resolve_paths /lib "x.zim" "/abs/y.zim" "../z.zim" | tr "\0" "|"')
    [ "$out" = "/lib/x.zim|/abs/y.zim|/z.zim|" ] && pass "H6 relative/absolute/../ paths resolved in order, one record each" \
      || fail "H6 got '$out'"
fi
# H7: a bare `log "DEBUG"` with DEBUG=false must not abort an errexit caller.
out=$(bash -c 'source "$KUS" >/dev/null 2>&1
    set -euo pipefail; DEBUG=false; QUIET=false
    log "DEBUG" "hidden"; echo AFTER' 2>&1)
[ "$out" = "AFTER" ] && pass "H7 bare log DEBUG (DEBUG=false) returns 0 under set -e" \
  || fail "H7 got '$out'"
# H8: a 0-byte library is not backed up (nothing restorable; would rotate out a real backup).
H8="$ROOT/h8"; mkdir -p "$H8"; : > "$H8/lib.xml"
out=$(H8="$H8" bash -c 'source "$KUS" >/dev/null 2>&1
    set -euo pipefail; DEBUG=false; QUIET=true; LOGFILE_SAFE=false
    ZIM_LIBRARY="$H8/lib.xml"; BACKUP_DIR="$H8/bk"
    backup_library_xml; echo "RC=$?"; find "$H8/bk" -type f | wc -l' 2>&1 | tail -2 | tr '\n' ' ')
[ "$out" = "RC=0 0 " ] && pass "H8 0-byte library: backup skipped (rc 0, no backup file)" \
  || fail "H8 got '$out'"
# H8b: positive control — a non-empty library IS backed up, byte-identical.
write_lib "$H8/lib2.xml" "a|zims/a.zim"
out=$(H8="$H8" bash -c 'source "$KUS" >/dev/null 2>&1
    set -euo pipefail; DEBUG=false; QUIET=true; LOGFILE_SAFE=false
    ZIM_LIBRARY="$H8/lib2.xml"; BACKUP_DIR="$H8/bk2"
    backup_library_xml; echo "RC=$?"' 2>&1 | tail -1)
mapfile -t H8B < <(find "$H8/bk2" -type f -name 'library_zim_*.xml' 2>/dev/null)
{ [ "$out" = "RC=0" ] && [ "${#H8B[@]}" -eq 1 ] && cmp -s "${H8B[0]}" "$H8/lib2.xml"; } \
  && pass "H8b non-empty library: exactly one byte-identical backup" \
  || fail "H8b got '$out', ${#H8B[@]} backup(s)"
# H8c: a FAILED backup must refuse the reconcile (no rewrite without a restore point).
if [ "$(id -u)" -eq 0 ]; then
    echo "SKIP: H8c (root bypasses directory permissions)"
else
    mkdir -p "$H8/bk3"; chmod 555 "$H8/bk3"; cp "$H8/lib2.xml" "$H8/lib2.before"
    out=$(H8="$H8" bash -c 'source "$KUS" >/dev/null 2>&1
        set -euo pipefail; DEBUG=false; QUIET=false; LOGFILE_SAFE=false
        ZIM_LIBRARY="$H8/lib2.xml"; BACKUP_DIR="$H8/bk3"; LIB_BACKED_UP=false
        rc=0; _lib_guard || rc=$?; echo "RC=$rc FLAG=$LIB_BACKED_UP"' 2>&1)
    chmod 755 "$H8/bk3"
    { grep -q "RC=1 FLAG=false" <<< "$out" && grep -q "Library backup failed" <<< "$out" &&
      cmp -s "$H8/lib2.xml" "$H8/lib2.before" && [ -z "$(ls -A "$H8/bk3")" ]; } \
      && pass "H8c backup failure: guard refuses (rc 1), flag stays false, library untouched" \
      || fail "H8c got '$(tail -2 <<< "$out" | tr '\n' ' ')'"
fi
# H8c2: same refusal for ANY uid (root too): BACKUP_DIR under a regular file, so mkdir -p fails.
: > "$H8/notadir"
out=$(H8="$H8" bash -c 'source "$KUS" >/dev/null 2>&1
    set -euo pipefail; DEBUG=false; QUIET=false; LOGFILE_SAFE=false
    ZIM_LIBRARY="$H8/lib2.xml"; BACKUP_DIR="$H8/notadir/bk"; LIB_BACKED_UP=false
    rc=0; _lib_guard || rc=$?; echo "RC=$rc FLAG=$LIB_BACKED_UP"' 2>&1)
{ grep -q "RC=1 FLAG=false" <<< "$out" && grep -q "Library backup failed" <<< "$out"; } \
  && pass "H8c2 backup failure (any uid): guard refuses, flag stays false" \
  || fail "H8c2 got '$(tail -2 <<< "$out" | tr '\n' ' ')'"
# H8d: rotation keeps the 5 NEWEST backups (incl. the one just taken).
mkdir -p "$H8/bk4"
for n in 1 2 3 4 5 6; do : > "$H8/bk4/library_zim_2000010${n}_000000.xml"; touch -d "2000-01-0${n}" "$H8/bk4/library_zim_2000010${n}_000000.xml"; done
out=$(H8="$H8" bash -c 'source "$KUS" >/dev/null 2>&1
    set -euo pipefail; DEBUG=false; QUIET=true; LOGFILE_SAFE=false
    ZIM_LIBRARY="$H8/lib2.xml"; BACKUP_DIR="$H8/bk4"
    backup_library_xml; echo "RC=$?"' 2>&1 | tail -1)
mapfile -t H8D < <(find "$H8/bk4" -type f -name 'library_zim_*.xml' -printf '%f\n' | sort)
{ [ "$out" = "RC=0" ] && [ "${#H8D[@]}" -eq 5 ] &&
  [ ! -e "$H8/bk4/library_zim_20000101_000000.xml" ] && [ ! -e "$H8/bk4/library_zim_20000102_000000.xml" ] &&
  [ -n "$(find "$H8/bk4" -newer "$H8/bk4/library_zim_20000106_000000.xml" -name 'library_zim_*.xml')" ]; } \
  && pass "H8d rotation: 5 newest kept (new backup included), 2 oldest deleted" \
  || fail "H8d got '$out', kept: ${H8D[*]}"
# H8e: rotation with spaces in BACKUP_DIR — whitespace-split rm would hit "$H8/bk5"
# (a decoy file) and never rotate the real backups.
B5="$H8/bk5 dir  x"; mkdir -p "$B5"; : > "$H8/bk5"
for n in 1 2 3 4 5 6; do : > "$B5/library_zim_2000010${n}_000000.xml"; touch -d "2000-01-0${n}" "$B5/library_zim_2000010${n}_000000.xml"; done
out=$(H8="$H8" B5="$B5" bash -c 'source "$KUS" >/dev/null 2>&1
    set -euo pipefail; DEBUG=false; QUIET=true; LOGFILE_SAFE=false
    ZIM_LIBRARY="$H8/lib2.xml"; BACKUP_DIR="$B5"
    backup_library_xml; echo "RC=$?"' 2>&1 | tail -1)
n5=$(find "$B5" -type f -name 'library_zim_*.xml' | wc -l)
{ [ "$out" = "RC=0" ] && [ "$n5" -eq 5 ] && [ -e "$H8/bk5" ] &&
  [ ! -e "$B5/library_zim_20000101_000000.xml" ] && [ ! -e "$B5/library_zim_20000102_000000.xml" ]; } \
  && pass "H8e rotation with spaces in BACKUP_DIR: 5 newest kept, nothing outside touched" \
  || fail "H8e got '$out', $n5 kept, decoy $([ -e "$H8/bk5" ] && echo kept || echo DELETED)"

echo
echo "########## do_smart_update — reconciler is the single library writer ##########"
# Real do_smart_update + real update_kiwix_library; only I/O edges are stubbed.
# download_file drops a marker so a case can prove nothing was downloaded.
run_dsu(){ # env: C_WD C_LIB D_ENTRIES (one "f|url|name|bytes" per line)
           #      [C_PATH KM_FAIL_VERB KM_FAIL_ARG C_CONT=true|false RPFAIL_FLAG
           #       DL_FAIL_ON=N DL_KILL_ON=N (Nth download)]
    N=$((N + 1)); KM_LOG="$ROOT/km.$N.log"; : > "$KM_LOG"; DL_MARK="$ROOT/dl.$N"; BK_MARK="$ROOT/bk.$N"
    OUT=$(KM_LOG="$KM_LOG" KM_FAIL_VERB="$KM_FAIL_VERB" KM_FAIL_ARG="$KM_FAIL_ARG" \
        DL_MARK="$DL_MARK" BK_MARK="$BK_MARK" DL_FAIL_ON="$DL_FAIL_ON" DL_KILL_ON="$DL_KILL_ON" \
        C_CONT="$C_CONT" RPFAIL_FLAG="$RPFAIL_FLAG" \
        C_WD="$C_WD" C_LIB="$C_LIB" D_ENTRIES="$D_ENTRIES" \
        PATH="${C_PATH:-$STUB:$PATH}" bash -c '
        source "$KUS" >/dev/null 2>&1
        set -euo pipefail
        backup_library_xml(){ printf x >> "$BK_MARK"; }
        update_status(){ :; }; update_progress(){ :; }
        get_remote_size(){ return 1; }
        download_file(){
            printf x >> "$DL_MARK"; local n; n=$(wc -c < "$DL_MARK")
            [ "$n" = "${DL_KILL_ON:-}" ] && kill -9 $$
            [ "$n" = "${DL_FAIL_ON:-}" ] && return 1
            [ -z "${RPFAIL_FLAG:-}" ] || : > "$RPFAIL_FLAG"
            printf "ZIM" > "$2"
        }
        WORK_DIR="$C_WD"; ZIM_LIBRARY="$C_LIB"; UNPRIVILEGED=true; DEBUG=false
        CONTINUE_ON_ERROR="$C_CONT"
        mapfile -t FILES_TO_UPDATE <<< "$D_ENTRIES"
        do_smart_update && echo DSU_DONE' 2>&1); RC=$?
}

newcase 30; mkzim "$WD/y.zim"; mkzim "$USB/y.zim"
write_lib "$C_LIB" "usb|../../mnt/usb/y.zim" "wd|zims/y.zim"
D_ENTRIES="$WD/y.zim|http://x|y2|0"; run_dsu
check 0 "$WD/y2.zim" "wd" 1 "$MSG_DSU_OK"
[ ! -e "$WD/y.zim" ] || WHY+=" old-file-not-deleted"
report "D1 rename update: old WORK_DIR entry dropped, new added, usb same-name entry untouched"

newcase 31; mkzim "$WD/y.zim"; mkzim "$USB/y.zim"
write_lib "$C_LIB" "usb|../../mnt/usb/y.zim"
D_ENTRIES="$WD/y.zim|http://x|y|0"; run_dsu
check 0 "$WD/y.zim" "" 1 "$MSG_DSU_OK"
report "D2 same-name update: WORK_DIR y.zim added though another disk's y.zim is listed"

newcase 32; mkzim "$WD/y.zim"; mkzim "$USB/y.zim"
write_lib "$C_LIB" "usb|../../mnt/usb/y.zim" "old-uuid|zims/y.zim"
D_ENTRIES="$WD/y.zim|http://x|y|0"; run_dsu
check 0 "$WD/y.zim" "old-uuid" 1 "$MSG_DSU_OK"
report "D3 same-name update replaces the stale book entry (old UUID/metadata)"

newcase 33; mkzim "$WD/y.zim"; write_lib "$C_LIB" "wd|zims/y.zim"
C_PATH="$RPFAIL:$STUB:$PATH"; D_ENTRIES="$WD/y.zim|http://x|y2|0"; run_dsu
check 1 "" "" 0 "$MSG_PREFLIGHT_ABORT"
[ ! -e "$DL_MARK" ] || WHY+=" downloaded-anyway"
[ -e "$WD/y.zim" ] || WHY+=" old-file-deleted"
report "D4 unresolvable library: abort before any download; old file and library untouched"

newcase 34; mkzim "$WD/y.zim"; mkdir -p "$C/elsewhere"; write_lib "$C/elsewhere/real.xml" "wd|../../var/local/zims/y.zim"
ln -s "$C/elsewhere/real.xml" "$C_LIB"
D_ENTRIES="$WD/y.zim|http://x|y2|0"; run_dsu
check 1 "" "" 0 "$MSG_PREFLIGHT_ABORT"
[ ! -e "$DL_MARK" ] || WHY+=" downloaded-anyway"
[ -e "$WD/y.zim" ] || WHY+=" old-file-deleted"
report "D5 symlinked library: refused in pre-flight, before any download or deletion"

newcase 55; mkzim "$WD/y.zim"; mkdir -p "$C_LIB"
D_ENTRIES="$WD/y.zim|http://x|y2|0"; run_dsu
check 1 "" "" 0 "$MSG_PREFLIGHT_ABORT"
[ ! -e "$DL_MARK" ] || WHY+=" downloaded-anyway"
[ -e "$WD/y.zim" ] || WHY+=" old-file-deleted"
report "D5b library path is a directory: refused in pre-flight, before any download or deletion"

newcase 35; mkzim "$WD/y.zim"; mkzim "$WD/z.zim"
write_lib "$C_LIB" "wd-y|zims/y.zim" "z-old|zims/z.zim"; ORDER_CHECK=0
D_ENTRIES="$WD/y.zim|http://x|y2|0
$WD/z.zim|http://x|z|0"; run_dsu
check 0 "$WD/y2.zim;$WD/z.zim" "wd-y;z-old" 1 "$MSG_DSU_OK"
[ "$(wc -c < "$BK_MARK" 2>/dev/null || echo 0)" -eq 1 ] || WHY+=" backups=$(wc -c < "$BK_MARK" 2>/dev/null)(want 1)"
report "D6 one run, rename + in-place update: both reconciled, stale UUID refreshed, ONE backup"

newcase 36; mkzim "$WD/y.zim"; mkzim "$WD/z.zim"
write_lib "$C_LIB" "wd-y|zims/y.zim" "wd-z|zims/z.zim"; DL_FAIL_ON=2
D_ENTRIES="$WD/y.zim|http://x|y2|0
$WD/z.zim|http://x|z2|0"; run_dsu
check 1 "$WD/y2.zim" "wd-y" 1
[ -e "$WD/z.zim" ] || WHY+=" z-deleted"
report "D7 second download fails (no -c): first update already reconciled, run fails rc 1"

newcase 37; mkzim "$WD/y.zim"; mkzim "$WD/z.zim"
write_lib "$C_LIB" "wd-y|zims/y.zim" "wd-z|zims/z.zim"; DL_KILL_ON=2
D_ENTRIES="$WD/y.zim|http://x|y2|0
$WD/z.zim|http://x|z2|0"; run_dsu
check 137 "$WD/y2.zim" "wd-y" 1
[ -e "$WD/z.zim" ] || WHY+=" z-deleted"
report "D8 run killed (-9) during the second download: first update's library state is consistent"

newcase 38; mkzim "$WD/y.zim"; write_lib "$C_LIB" "wd|zims/y.zim"; KM_FAIL_VERB=add
D_ENTRIES="$WD/y.zim|http://x|y2|0"; run_dsu
check 1 "$WD/y2.zim" "wd" 1 "Failed to add"
grep -q "$MSG_DSU_OK" <<< "$OUT" && WHY+=" reported-success"
report "D9 kiwix-manage add fails during smart-update: run reports failure, rc 1"

newcase 39; mkzim "$WD/y.zim"; mkzim "$WD/y2.zim"
write_lib "$C_LIB" "wd|zims/y.zim" "y2-old|zims/y2.zim"
D_ENTRIES="$WD/y.zim|http://x|y2|0"; run_dsu
check 0 "$WD/y2.zim" "wd;y2-old" 1 "$MSG_DSU_OK"
report "D10 rename onto an existing listed target: target overwritten in place gets its stale entry refreshed"

newcase 40; mkzim "$WD/y.zim"; mkzim "$WD/z.zim"; mkzim "$WD/bad.zim"
write_lib "$C_LIB" "wd-y|zims/y.zim" "wd-z|zims/z.zim"; KM_FAIL_ARG=bad.zim; ORDER_CHECK=0
D_ENTRIES="$WD/y.zim|http://x|y2|0
$WD/z.zim|http://x|z2|0"; run_dsu
check 1 "$WD/y2.zim;$WD/bad.zim;$WD/z2.zim;$WD/bad.zim" "wd-y;wd-z" 1 "Library operations failed during 2 reconcile(s)"
[ "$(wc -c < "$DL_MARK")" -eq 2 ] || WHY+=" downloads=$(wc -c < "$DL_MARK")(want 2)"
grep -q "$MSG_DSU_OK" <<< "$OUT" && WHY+=" reported-success"
report "D11 unaddable bystander ZIM: every update still downloaded + reconciled; run fails and counts it"

newcase 41; mkzim "$WD/y.zim"; mkzim "$WD/z.zim"; write_lib "$C_LIB" "wd-y|zims/y.zim" "wd-z|zims/z.zim"
C_PATH="$RPFAIL:$STUB:$PATH"; RPFAIL_FLAG="$C/rpflag"
D_ENTRIES="$WD/y.zim|http://x|y2|0
$WD/z.zim|http://x|z2|0"; run_dsu
check 1 "" "" 0 "Library reconcile refused"
[ "$(wc -c < "$DL_MARK")" -eq 1 ] || WHY+=" downloads=$(wc -c < "$DL_MARK")(want 1: stop after a refused reconcile)"
report "D12 reconcile refused mid-run (no -c): run stops after that file, rc 1"

newcase 42; mkzim "$WD/y.zim"; mkzim "$WD/z.zim"; write_lib "$C_LIB" "wd-y|zims/y.zim" "wd-z|zims/z.zim"
C_PATH="$RPFAIL:$STUB:$PATH"; RPFAIL_FLAG="$C/rpflag"; C_CONT=true
D_ENTRIES="$WD/y.zim|http://x|y2|0
$WD/z.zim|http://x|z2|0"; run_dsu
check 1 "" "" 0 "Stopped early: 1 file(s) not attempted"
grep -q "Library reconcile was refused" <<< "$OUT" || WHY+=" no-refused-hint"
[ "$(wc -c < "$DL_MARK")" -eq 1 ] || WHY+=" downloads=$(wc -c < "$DL_MARK")(want 1: a refused reconcile stops even with -c)"
[ -e "$WD/z.zim" ] || WHY+=" z-deleted"
report "D13 reconcile refused mid-run WITH -c: still stops (library-wide cause); remaining old files kept"

newcase 44; mkzim "$WD/y.zim"; write_lib "$C_LIB" "wd-y|zims/y.zim"
C_PATH="$RPFAIL:$STUB:$PATH"; RPFAIL_FLAG="$C/rpflag"
D_ENTRIES="$WD/y.zim|http://x|y2|0"; run_dsu
check 1 "" "" 0 "Library reconcile was refused"
grep -q "file(s) not attempted" <<< "$OUT" && WHY+=" claims-skipped-files-when-none-remain"
report "D15 refusal on the LAST entry: refusal hint, no 'not attempted' line"

newcase 45; mkzim "$WD/y.zim"; mkzim "$WD/z.zim"; write_lib "$C_LIB" "wd-y|zims/y.zim" "wd-z|zims/z.zim"
DL_FAIL_ON=1; ORDER_CHECK=0
D_ENTRIES="$WD/y.zim|http://x|y2|0
$WD/z.zim|http://x|z2|0"; run_dsu
check 1 "" "" 0 "Stopped early: 1 file(s) not attempted"
grep -q "Library reconcile was refused" <<< "$OUT" && WHY+=" wrong-refusal-hint"
report "D16 download failure without -c: summary reports the files not attempted"

newcase 64; mkzim "$WD/y.zim"; mkzim "$WD/z.zim"; write_lib "$C_LIB" "wd-y|zims/y.zim" "wd-z|zims/z.zim"
DL_FAIL_ON=1; C_CONT=true
D_ENTRIES="$WD/y.zim|http://x|y2|0
$WD/z.zim|http://x|z2|0"; run_dsu
check 1 "$WD/z2.zim" "wd-z" 1 "Files updated: 1, failed: 1"
grep -q "$MSG_DSU_OK" <<< "$OUT" && WHY+=" reported-success"
grep -q "not attempted" <<< "$OUT" && WHY+=" claims-stopped-early"
[ "$(wc -c < "$DL_MARK")" -eq 2 ] || WHY+=" downloads=$(wc -c < "$DL_MARK")(want 2: -c continues)"
report "D17 download failure WITH -c: keeps going, but the run exits 1 (cron sees it)"

if [ "$(id -u)" -eq 0 ]; then
    echo "SKIP: D14 (root bypasses directory permissions)"
else
    newcase 43; mkzim "$WD/y.zim"; write_lib "$C_LIB" "wd|zims/y.zim"; chmod 555 "$C/var/local"
    D_ENTRIES="$WD/y.zim|http://x|y2|0"; run_dsu; chmod 755 "$C/var/local"
    check 1 "" "" 0 "Cannot create a temp file"
    [ ! -e "$DL_MARK" ] || WHY+=" downloaded-anyway"
    [ -e "$WD/y.zim" ] || WHY+=" old-file-deleted"
    report "D14 library dir not writable: smart-update pre-flight (temp probe) aborts before any download"
fi

echo
echo "########## update-library command ##########"
if ! bash -c 'source "$KUS" >/dev/null 2>&1; declare -F cmd_update_library >/dev/null'; then
    echo "SKIP: U1–U2 (cmd_update_library not defined in $SCRIPT)"
else
    for want in 1 0; do
        out=$(UL_RC="$want" bash -c 'source "$KUS" >/dev/null 2>&1
            set -euo pipefail
            stop_service_if_managed(){ echo STOP; }
            restore_service_if_managed(){ echo RESTORE; }
            update_kiwix_library(){ return "$UL_RC"; }
            rc=0; cmd_update_library || rc=$?; echo "RC=$rc"' 2>&1)
        { grep -qx STOP <<< "$out" && grep -qx RESTORE <<< "$out" && grep -qx "RC=$want" <<< "$out"; } \
          && pass "U$((want == 1 ? 1 : 2)) update-library restores the service and returns rc $want (reconcile rc $want)" \
          || fail "U$((want == 1 ? 1 : 2)) got: $(tr '\n' '/' <<< "$out")"
    done
fi

echo "########## backup mode, temp tracking, late symlink swap ##########"
# H8f: the backup is created mode 644 regardless of umask and the library's mode.
H8F_D="$ROOT/h8f"; write_lib "$H8F_D/lib.xml" "a|zims/a.zim"; chmod 666 "$H8F_D/lib.xml"
out=$(H8="$H8F_D" bash -c 'source "$KUS" >/dev/null 2>&1
    set -euo pipefail; umask 000; DEBUG=false; QUIET=true; LOGFILE_SAFE=false
    ZIM_LIBRARY="$H8/lib.xml"; BACKUP_DIR="$H8/bk"
    backup_library_xml; echo "RC=$?"' 2>&1 | tail -1)
mapfile -t H8F < <(find "$H8F_D/bk" -type f -name 'library_zim_*.xml' 2>/dev/null)
{ [ "$out" = "RC=0" ] && [ "${#H8F[@]}" -eq 1 ] && [ "$(stat -c %a "${H8F[0]}")" = 644 ]; } \
  && pass "H8f backup is mode 644 under umask 000 from a mode-666 library" \
  || fail "H8f got '$out', mode '$(stat -c %a "${H8F[0]:-/nonexistent}" 2>/dev/null)'"

# L25g: a refused reconcile leaves no stale LIB_TEMP behind (cleanup would rm it).
newcase 66; mkzim "$WD/a.zim"; write_lib "$C_LIB" "wd-a|zims/a.zim"
mkdir -p "$C/cpbin"; printf '#!/bin/bash\nexit 1\n' > "$C/cpbin/cp"; chmod +x "$C/cpbin/cp"
out=$(C_WD="$C_WD" C_LIB="$C_LIB" KM_LOG="$ROOT/km.l25g" PATH="$C/cpbin:$STUB:$PATH" bash -c 'source "$KUS" >/dev/null 2>&1
    set -euo pipefail; backup_library_xml(){ :; }
    WORK_DIR="$C_WD"; ZIM_LIBRARY="$C_LIB"; UNPRIVILEGED=true; DEBUG=false
    rc=0; update_kiwix_library || rc=$?; printf "RC=%s LIB_TEMP=[%s]\n" "$rc" "$LIB_TEMP"' 2>&1)
grep -qx 'RC=1 LIB_TEMP=\[\]' <<< "$out" \
  && pass "L25g refused reconcile (cp failure) clears LIB_TEMP" \
  || fail "L25g got: $(tail -1 <<< "$out")"

# L30: the library is swapped for a symlink during the reconcile (after the entry
# guard): the final chmod/chown must not follow it, and rc is 2 (modified), not 1.
newcase 65; mkzim "$WD/new.zim"; write_lib "$C_LIB"
printf 'secret\n' > "$C/target"; chmod 600 "$C/target"; mkdir -p "$C/kmswap"
cat > "$C/kmswap/kiwix-manage" <<S
#!/bin/bash
[ "\$2" = add ] && { rm -f "\$1"; ln -s "$C/target" "\$1"; }
exit 0
S
chmod +x "$C/kmswap/kiwix-manage"
out=$(C_WD="$C_WD" C_LIB="$C_LIB" PATH="$C/kmswap:$PATH" bash -c 'source "$KUS" >/dev/null 2>&1
    set -euo pipefail; backup_library_xml(){ :; }
    WORK_DIR="$C_WD"; ZIM_LIBRARY="$C_LIB"; UNPRIVILEGED=true; DEBUG=false
    rc=0; update_kiwix_library || rc=$?; echo "RC=$rc"' 2>&1)
{ grep -qx 'RC=2' <<< "$out" && grep -q "no longer a regular file" <<< "$out" &&
  [ "$(stat -c %a "$C/target")" = 600 ] &&
  [ -z "$(find "$(dirname "$C_LIB")" -maxdepth 1 -name '.library_zim_temp.*')" ]; } \
  && pass "L30 library swapped for a symlink mid-reconcile: chmod skipped, rc 2" \
  || fail "L30 target mode $(stat -c %a "$C/target"); out: $(tail -3 <<< "$out" | tr '\n' ' ')"

echo "########## run lock ##########"
# Every sub-bash gets KIWIX_WORK_DIR at source time, so LOCK_FILE is the test's.
LK="$ROOT/lock"; mkdir -p "$LK"; LKF="$LK/.kiwix_run.lock"
MSG_LOCKED="Another kiwix-update run is in progress"
lockrun(){ # lockrun BODY -> stdout+stderr; pass extra env by prefixing the call (VAR=x lockrun ...)
    KIWIX_WORK_DIR="$LK" bash -c 'source "$KUS" >/dev/null 2>&1
        set -euo pipefail; DEBUG=false; QUIET=false; LOGFILE_SAFE=false
        '"$1" 2>&1
}
exec 8>>"$LKF"; chmod 644 "$LKF"; flock -n 8
out=$(lockrun 'rc=0; acquire_run_lock || rc=$?; echo "RC=$rc"')
{ grep -qx 'RC=1' <<< "$out" && grep -q "$MSG_LOCKED (a run without a PID file" <<< "$out" &&
  ! grep -q "Cannot open lock" <<< "$out"; } \
  && pass "K1 lock held by another process: refused with the in-progress error" \
  || fail "K1 got: $(tr '\n' ' ' <<< "$out")"
# K5: a leaked KIWIX_BACKGROUND plus an unrelated fd 9 must not pass as the lock
# (background-mode log() writes only to the log file, so the rc is the signal;
# K5b is its positive control with the lock free).
K5_BODY='exec 9>>"$KIWIX_WORK_DIR/other"; rc=0; KIWIX_BACKGROUND=1 acquire_run_lock || rc=$?; echo "RC=$rc"'
out=$(lockrun "$K5_BODY")
grep -qx 'RC=1' <<< "$out" \
  && pass "K5 KIWIX_BACKGROUND with an unrelated fd 9: fresh-lock path, still refused" \
  || fail "K5 got: $(tr '\n' ' ' <<< "$out")"
exec 8>&-
out=$(lockrun "$K5_BODY")
grep -qx 'RC=0' <<< "$out" && pass "K5b positive control: same call with the lock free is acquired" \
  || fail "K5b got: $(tr '\n' ' ' <<< "$out")"
out=$(lockrun 'rc=0; acquire_run_lock || rc=$?; echo "RC=$rc"')
{ grep -qx 'RC=0' <<< "$out" && [ "$(stat -c %a "$LKF")" = 600 ]; } \
  && pass "K2 free lock: acquired; the pre-existing 644 lock file is tightened to 600 (no other user can hold it)" \
  || fail "K2 got: $(tr '\n' ' ' <<< "$out") mode=$(stat -c %a "$LKF")"
# K3: a symlinked lock path is refused (never opened through the link).
LK3="$ROOT/lock3"; mkdir -p "$LK3"; : > "$ROOT/lock3-target"; ln -s "$ROOT/lock3-target" "$LK3/.kiwix_run.lock"
out=$(KIWIX_WORK_DIR="$LK3" bash -c 'source "$KUS" >/dev/null 2>&1
    set -euo pipefail; DEBUG=false; QUIET=false; LOGFILE_SAFE=false
    rc=0; acquire_run_lock || rc=$?; echo "RC=$rc"' 2>&1)
{ grep -qx 'RC=1' <<< "$out" && grep -q "not a regular file" <<< "$out"; } \
  && pass "K3 symlinked lock file refused" || fail "K3 got: $(tr '\n' ' ' <<< "$out")"

# K4: -b hand-off. Process A takes the lock and starts a KIWIX_BACKGROUND child
# (inheriting fd 9), and stays alive until the child reports — the window in which
# a child that reopened the lock file would be refused. Every wait is bounded.
HF="$ROOT/handoff"; mkdir -p "$HF"; mkfifo "$HF/report" "$HF/go"
exec 5<>"$HF/report" 6<>"$HF/go"   # held open read-write: no open() ever blocks
cat > "$HF/child.sh" <<'S'
source "$KUS" >/dev/null 2>&1
DEBUG=false; QUIET=false; LOGFILE_SAFE=false
rc=0; acquire_run_lock || rc=$?
echo "CHILD=$rc" > "$HF/report"
read -r -t 20 _ <> "$HF/go"
S
out=$(HF="$HF" lockrun 'acquire_run_lock
    HF="$HF" KIWIX_BACKGROUND=1 bash "$HF/child.sh" >/dev/null 2>&1 &
    line=""; read -r -t 10 line <> "$HF/report" || true
    echo "A-SAW=$line"')
out3=$(lockrun 'rc=0; acquire_run_lock || rc=$?; echo "RC=$rc"')
echo go >&6
out4=$(lockrun 'rc=0; acquire_run_lock 10 || rc=$?; echo "RC=$rc"')
exec 5>&- 6>&-
{ grep -qx 'A-SAW=CHILD=0' <<< "$out" && grep -qx 'RC=1' <<< "$out3" && grep -qx 'RC=0' <<< "$out4"; } \
  && pass "K4 -b hand-off: child holds the inherited lock while the parent lives and after it exits" \
  || fail "K4 A: $(tr '\n' ' ' <<< "$out") | third: $(tr '\n' ' ' <<< "$out3") | after: $(tr '\n' ' ' <<< "$out4")"

# K6: nothing the service helper starts inherits the lock (a sysvinit-started
# kiwix-serve would otherwise hold it forever).
mkdir -p "$ROOT/sysd"; FDLOG="$ROOT/sysd/fd.log"; : > "$FDLOG"
cat > "$ROOT/sysd/systemctl" <<S
#!/bin/bash
case "\$1" in
    start|stop) if [ -e /proc/self/fd/9 ]; then echo present; else echo "fd9 absent"; fi >> "$FDLOG" ;;
esac
exit 0
S
chmod +x "$ROOT/sysd/systemctl"
out=$(PATH="$ROOT/sysd:$PATH" lockrun 'acquire_run_lock; echo LOCKED; _kiwix_service_do start; echo "RC=$?"')
{ grep -qx LOCKED <<< "$out" && grep -qx 'RC=0' <<< "$out" && [ "$(cat "$FDLOG")" = "fd9 absent" ]; } \
  && pass "K6 service start runs without the run-lock fd" \
  || fail "K6 got: $(tr '\n' ' ' <<< "$out") fdlog: $(tr '\n' ' ' < "$FDLOG")"

echo
if [ "$FAIL" -eq 0 ]; then echo "==== ALL LIBRARY-RECONCILE CHECKS PASSED ===="; else echo "==== LIBRARY-RECONCILE FAILURES ===="; fi
exit "$FAIL"
