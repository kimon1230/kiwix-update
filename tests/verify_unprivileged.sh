#!/bin/bash
# Unprivileged/single-user mode (issue #2): determine_run_mode + trust gate +
# service guards + pre-flight. Each case runs in a fresh sub-bash so file-scope
# config (WORK_DIR/derived paths) and the PATH shims can be controlled per case.
# The REAL functions are exercised (not redefined) except where a stub is needed
# to isolate the unit under test. No network, no root required. Run from repo root.

SCRIPT="${SCRIPT:-$(dirname "$(readlink -f "$0")")/../kiwix-update.sh}"
export KUS="$SCRIPT"   # script path, read by in_script's child shell
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/kiwix-unpriv.XXXXXX")
trap 'rm -rf "$ROOT"' EXIT
mkdir -p "$ROOT/bin"

FAIL=0
pass(){ echo "PASS: $1"; }
fail(){ echo "FAIL: $1"; FAIL=1; }

# --- Load-bearing production message fragments -------------------------------
# Grep against THESE, never inline string literals, so a benign reword in
# kiwix-update.sh is a one-line test edit here instead of N scattered ones.
MSG_SERVING_RUNNING="kiwix-serve is running"   # pre-flight hard refusal
MSG_PROCEEDING="proceeding anyway"             # -y/-b override warning
MSG_CANNOT_PROCEED="Cannot proceed"            # do_smart_update stop-failure abort
MSG_NOT_WRITABLE="not writable"                # absent-leaf parent-not-writable error
MSG_PREPLANT="pre-plant"                       # absent-leaf symlink/file error
MSG_CHOWN_ROOT="chown root"                    # root-mode remediation (must NOT appear unpriv)
MSG_KIWIX_WORK_DIR="KIWIX_WORK_DIR"            # unprivileged remediation hint
MSG_FAILED_RESTORE="Failed to restore"         # restore start-failure
MSG_WARNING="WARNING"                          # any visible serving-guard override warning
MSG_WARNING_KIWIX="WARNING: kiwix-serve"       # the running-server override warning specifically
MSG_SYMLINK="symlink"                          # trust-gate symlink rejection
MSG_ROOT_ROOT="root:root"                      # chown target in root mode

# --- Single sub-bash seam ----------------------------------------------------
# in_script BODY: source the script (functions only — the BASH_SOURCE==$0 guard
# keeps main from running), then run BODY in a fresh shell. ALL inputs are passed
# as NAMED ENV VARS (never positional $1/$2, whose meaning used to differ per
# runner and was the main comprehension cost). $KUS (exported) is the script path.
# The body's own `$VAR` refs are NOT re-expanded by this shell — they reach the
# child intact — so a body may freely reference $UNPRIVILEGED, $WORK_DIR, etc.
in_script(){
    bash -c "source \"\$KUS\" >/dev/null 2>&1
$1"
}

# id-shim: `id -u` echoes $FAKE_UID (may be non-numeric/empty for the bad-id case);
# everything else delegates to the real id.
cat > "$ROOT/bin/id" <<'S'
#!/bin/bash
if [ "$1" = "-u" ]; then printf '%s\n' "${FAKE_UID-}"; exit 0; fi
exec /usr/bin/id "$@"
S
chmod +x "$ROOT/bin/id"

# stat-shim: honors `stat -c%u`/`-c%a` from a fixture map $STATMAP
# (path<TAB>uid<TAB>mode); any UNMAPPED path defaults to uid 0 / mode 755
# (trusted) so the real /tmp (1777) and / modes can't leak into the ancestor
# walk. Other stat forms delegate to the real binary. Lets the REAL
# is_trusted_dir run against simulated ownership without being root.
cat > "$ROOT/bin/stat" <<'S'
#!/bin/bash
fmt="$1"; path="${@: -1}"; field=""
case "$fmt" in
    -c%u) field=uid ;;
    -c%a) field=mode ;;
    *) exec /usr/bin/stat "$@" ;;
esac
if [ -n "${STATMAP:-}" ] && [ -f "$STATMAP" ]; then
    while IFS=$'\t' read -r p u m; do
        [ "$p" = "$path" ] || continue
        [ "$field" = uid ] && { printf '%s\n' "$u"; exit 0; }
        printf '%s\n' "$m"; exit 0
    done < "$STATMAP"
fi
[ "$field" = uid ] && printf '0\n' || printf '755\n'
exit 0
S
chmod +x "$ROOT/bin/stat"
SHIM_PATH="$ROOT/bin:$PATH"

# pidof/pgrep shims — report kiwix-serve "running" iff KSERVE_RUNNING=1. Kept in a
# SEPARATE dir (bin2) with REAL id/stat, so tests that call the real
# determine_run_mode / trust gate see true uid+ownership while still controlling
# kiwix-serve detection. Any non-kiwix-serve query returns "not found".
mkdir -p "$ROOT/bin2"
cat > "$ROOT/bin2/pidof" <<'S'
#!/bin/bash
if [ "$1" = "kiwix-serve" ]; then [ "${KSERVE_RUNNING:-0}" = "1" ] && exit 0; exit 1; fi
exit 1
S
cat > "$ROOT/bin2/pgrep" <<'S'
#!/bin/bash
if [ "$1" = "-x" ] && [ "$2" = "kiwix-serve" ]; then [ "${KSERVE_RUNNING:-0}" = "1" ] && exit 0; exit 1; fi
exit 1
S
chmod +x "$ROOT/bin2/pidof" "$ROOT/bin2/pgrep"
PID_PATH="$ROOT/bin2:$PATH"

# chown shim — logs its argv to $CHOWN_LOG so the chown-guard test can assert
# whether `chown root:root` was invoked, without needing to be root.
cat > "$ROOT/bin/chown" <<'S'
#!/bin/bash
printf 'CHOWN %s\n' "$*" >> "${CHOWN_LOG:-/dev/null}"
exit 0
S
chmod +x "$ROOT/bin/chown"

# bin3: pgrep-only (no pidof) — exercises _kiwix_serve_running's pgrep fallback.
mkdir -p "$ROOT/bin3"
cat > "$ROOT/bin3/pgrep" <<'S'
#!/bin/bash
if [ "$1" = "-x" ] && [ "$2" = "kiwix-serve" ]; then [ "${KSERVE_RUNNING:-0}" = "1" ] && exit 0; exit 1; fi
exit 1
S
chmod +x "$ROOT/bin3/pgrep"

# bin_nd: has date/tr/cat (so log() works) but NEITHER pidof NOR pgrep — exercises
# the pre-flight's fail-closed "cannot verify" branch.
mkdir -p "$ROOT/bin_nd"
for t in date tr cat; do ln -s "$(command -v "$t")" "$ROOT/bin_nd/$t" 2>/dev/null; done

echo "########## Issue #2 Batch 1 — determine_run_mode + config ##########"

# Run the REAL determine_run_mode under a given FAKE_UID; echo the resolved triple.
resolve(){ # env: FAKE_UID (+ optional KIWIX_*); PATH pinned to the id-shim
    FAKE_UID="$1" PATH="$SHIM_PATH" in_script '
        set -euo pipefail   # mirror production: strict mode AFTER source, before the call
        determine_run_mode
        printf "%s|%s|%s\n" "$UNPRIVILEGED" "$EXPECTED_OWNER_UID" "$ZIM_LIBRARY"'
}

# 1. Root: euid 0 -> root mode, EXPECTED_OWNER_UID pinned literal 0.
r=$(resolve 0)
[ "$r" = "false|0|/var/local/library_zim.xml" ] \
  && pass "B1.1 euid 0 -> root mode (UNPRIVILEGED=false, EXPECTED_OWNER_UID=0)" \
  || fail "B1.1 root mode wrong: '$r'"

# 2. Non-root: euid 1000 -> unprivileged, EXPECTED_OWNER_UID=1000, ZIM_LIBRARY under WORK_DIR default.
r=$(resolve 1000)
[ "$r" = "true|1000|/var/local/zims/library_zim.xml" ] \
  && pass "B1.2 euid 1000 -> unprivileged (uid anchor + ZIM_LIBRARY under WORK_DIR)" \
  || fail "B1.2 unprivileged wrong: '$r'"

# 3. Bad id -u (non-numeric) -> hard exit 1 (captured in the sub-bash).
FAKE_UID="notanumber" PATH="$SHIM_PATH" in_script 'determine_run_mode' >/dev/null 2>&1
[ $? -eq 1 ] && pass "B1.3 non-numeric id -u hard-exits 1" || fail "B1.3 bad id not rejected"
# 3b. Empty id -u -> hard exit 1.
FAKE_UID="" PATH="$SHIM_PATH" in_script 'determine_run_mode' >/dev/null 2>&1
[ $? -eq 1 ] && pass "B1.3b empty id -u hard-exits 1" || fail "B1.3b empty id not rejected"

# 4. Unprivileged honors an explicit KIWIX_ZIM_LIBRARY (does NOT re-default).
r=$(KIWIX_ZIM_LIBRARY="/home/u/lib.xml" resolve 1000)
[ "$r" = "true|1000|/home/u/lib.xml" ] \
  && pass "B1.4 unprivileged honors explicit KIWIX_ZIM_LIBRARY" \
  || fail "B1.4 explicit lib not honored: '$r'"

# 4b. Unprivileged + KIWIX_ZIM_LIBRARY set EMPTY -> treated as unset -> re-default under WORK_DIR.
r=$(KIWIX_ZIM_LIBRARY="" resolve 1000)
[ "$r" = "true|1000|/var/local/zims/library_zim.xml" ] \
  && pass "B1.4b empty KIWIX_ZIM_LIBRARY treated as unset (re-defaults)" \
  || fail "B1.4b empty lib not re-defaulted: '$r'"

# 5. Root mode is NOT affected by KIWIX_ZIM_LIBRARY re-default logic (stays as given).
r=$(KIWIX_ZIM_LIBRARY="" resolve 0)
[ "$r" = "false|0|/var/local/library_zim.xml" ] \
  && pass "B1.5 root mode keeps header default lib (no unprivileged re-default)" \
  || fail "B1.5 root lib wrong: '$r'"

# 6. Env-override of WORK_DIR/ZIM_LIBRARY reflected in derived paths (fresh source).
r=$(KIWIX_WORK_DIR="/tmp/uZ" KIWIX_ZIM_LIBRARY="/tmp/uL/lib.xml" in_script '
        printf "%s|%s|%s|%s\n" "$WORK_DIR" "$TEMP_DIR" "$BACKUP_DIR" "$ZIM_LIBRARY"')
[ "$r" = "/tmp/uZ|/tmp/uZ/temp|/tmp/uZ/backups|/tmp/uL/lib.xml" ] \
  && pass "B1.6 KIWIX_WORK_DIR/KIWIX_ZIM_LIBRARY flow into derived paths" \
  || fail "B1.6 env-override derived paths wrong: '$r'"

# 7. help/-h/--help/bare print help and exit 0 regardless of uid (before mode resolution).
for arg in "help" "-h" "--help" ""; do
    out=$(FAKE_UID=1000 PATH="$SHIM_PATH" ARG="$arg" in_script 'main $ARG' 2>&1); rc=$?
    { [ $rc -eq 0 ] && printf '%s' "$out" | grep -qi "usage\|command\|help"; } \
      && pass "B1.7 'main ${arg:-<bare>}' prints help, rc 0 (non-root)" \
      || fail "B1.7 help failed for '${arg:-<bare>}' (rc=$rc)"
done
# 7b. help works even with a broken id -u (help must not need a mode).
out=$(FAKE_UID="bad" PATH="$SHIM_PATH" in_script 'main --help' 2>&1); rc=$?
[ $rc -eq 0 ] && pass "B1.7b --help works despite broken id -u" || fail "B1.7b --help aborted by bad id (rc=$rc)"

echo
echo "########## Issue #2 Batch 2 — trusted-dir gate (real is_trusted_dir + stat shim) ##########"
# Fixtures are REAL dirs (is_trusted_dir does -L/-d/readlink -f on the real path);
# ownership/mode is simulated via the stat shim's $STATMAP. Unmapped ancestors
# default to root-owned 755 (trusted), so only the mapped paths drive each case.
FT="$ROOT/ft"; mkdir -p "$FT/home/me/zims"
LEAF="$FT/home/me/zims"; HOME_ANC="$FT/home"
MAP="$ROOT/statmap"

# Run the REAL is_trusted_dir with EXPECTED_OWNER_UID=$1 on dir $2 (uses $MAP);
# echoes "rc reason". Sets EXPECTED_OWNER_UID AFTER sourcing (source pins it to 0).
td(){ # $1=EXPECTED_OWNER_UID $2=dir ; env: PATH=id/stat shim, STATMAP=$MAP
    EXP="$1" DIR="$2" PATH="$SHIM_PATH" STATMAP="$MAP" in_script '
        set -euo pipefail   # mirror production: strict mode AFTER source, before the call
        EXPECTED_OWNER_UID="$EXP"
        rc=0; is_trusted_dir "$DIR" || rc=$?
        printf "%s %s\n" "$rc" "${TRUST_FAIL_REASON:-}"'
}

# B2.1 root regression: euid-0 anchor, fully root-owned chain -> trusted.
: > "$MAP"
r=$(td 0 "$LEAF"); [ "$r" = "0 " ] && pass "B2.1 root: root-owned chain trusted" || fail "B2.1 got '$r'"
# B2.1b root regression (CRITICAL): a non-root-owned ancestor is STILL rejected under euid 0.
printf '%s\t1000\t755\n' "$HOME_ANC" > "$MAP"
r=$(td 0 "$LEAF"); [ "$r" = "1 ancestor" ] && pass "B2.1b root: non-root ancestor still rejected (rule not weakened)" || fail "B2.1b got '$r'"

# B2.2 unprivileged: user-owned leaf + root-owned ancestors -> trusted (the ~/zims case).
printf '%s\t1000\t755\n' "$LEAF" > "$MAP"
r=$(td 1000 "$LEAF"); [ "$r" = "0 " ] && pass "B2.2 unpriv: user leaf + root ancestors trusted (~/zims works)" || fail "B2.2 got '$r'"
# B2.3 unprivileged: root-owned leaf -> rejected (owner); the leaf must be user-owned.
printf '%s\t0\t755\n' "$LEAF" > "$MAP"
r=$(td 1000 "$LEAF"); [ "$r" = "1 owner" ] && pass "B2.3 unpriv: root-owned leaf rejected (owner)" || fail "B2.3 got '$r'"
# B2.4 unprivileged: a THIRD-uid ancestor -> rejected (proves {EXPECTED_OWNER_UID,0} is a set).
{ printf '%s\t1000\t755\n' "$LEAF"; printf '%s\t2000\t755\n' "$HOME_ANC"; } > "$MAP"
r=$(td 1000 "$LEAF"); [ "$r" = "1 ancestor" ] && pass "B2.4 unpriv: third-uid ancestor rejected ({uid,0} is a set)" || fail "B2.4 got '$r'"
# B2.5 unprivileged: root-owned but group-writable ancestor -> rejected (writable check universal).
{ printf '%s\t1000\t755\n' "$LEAF"; printf '%s\t0\t775\n' "$HOME_ANC"; } > "$MAP"
r=$(td 1000 "$LEAF"); [ "$r" = "1 ancestor" ] && pass "B2.5 unpriv: group-writable root ancestor rejected" || fail "B2.5 got '$r'"

# B2.6 env-immutability: hostile env preset + euid 0 -> determine_run_mode pins
# EXPECTED_OWNER_UID=0, and a non-root ancestor is still rejected.
printf '%s\t1000\t755\n' "$HOME_ANC" > "$MAP"
r=$(FAKE_UID=0 KIWIX_WORK_DIR=/evil EXPECTED_OWNER_UID=1000 DIR="$LEAF" PATH="$SHIM_PATH" STATMAP="$MAP" in_script '
        determine_run_mode
        is_trusted_dir "$DIR"; rc=$?
        printf "%s %s %s\n" "$EXPECTED_OWNER_UID" "$rc" "$TRUST_FAIL_REASON"')
[ "$r" = "0 1 ancestor" ] && pass "B2.6 root env-immutability: EXPECTED_OWNER_UID pinned 0, non-root ancestor rejected" || fail "B2.6 got '$r'"

# B2.7 mode-aware refusal wording: unprivileged owner-refusal must NOT say "chown root".
printf '%s\t0\t755\n' "$LEAF" > "$MAP"
msg=$(DIR="$LEAF" PATH="$SHIM_PATH" STATMAP="$MAP" in_script '
        EXPECTED_OWNER_UID=1000
        is_trusted_dir "$DIR" || _trust_refuse "$DIR"' 2>&1)
{ printf '%s' "$msg" | grep -qi "$MSG_KIWIX_WORK_DIR" && ! printf '%s' "$msg" | grep -qi "$MSG_CHOWN_ROOT"; } \
  && pass "B2.7 unpriv refusal is mode-aware (own-dir guidance, no 'chown root')" \
  || fail "B2.7 wording wrong: '$msg'"

echo
echo "########## Issue #2 Batch 3 — privileged-op guards + service pre-flight ##########"

# --- chown guard: root mode chowns root:root; unprivileged mode must not. -------
# Drive the REAL update_kiwix_library to its chmod/chown tail with minimal state
# (empty library + empty WORK_DIR -> no adds/removes), backup stubbed out.
chown_case(){ # $1=UNPRIVILEGED(true/false) -> echoes chown log
    local WD LIB LOG
    WD=$(mktemp -d "$ROOT/chown.XXXXXX"); LIB="$WD/library_zim.xml"; : > "$LIB"; LOG="$WD/chown.log"; : > "$LOG"
    # ZIM_LIBRARY/WORK_DIR are (re)assigned by the config block at source time, so
    # they must be set INSIDE the body (after source), not as env prefixes.
    CHOWN_LOG="$LOG" CH_LIB="$LIB" CH_WD="$WD" CH_UNPRIV="$1" PATH="$SHIM_PATH" in_script '
        backup_library_xml(){ :; }
        ZIM_LIBRARY="$CH_LIB"; WORK_DIR="$CH_WD"; UNPRIVILEGED="$CH_UNPRIV"
        update_kiwix_library' >/dev/null 2>&1
    cat "$LOG"
}
r=$(chown_case false)
printf '%s' "$r" | grep -q "$MSG_ROOT_ROOT" \
  && pass "B3.1 root: update_kiwix_library invokes 'chown root:root' (positive control)" \
  || fail "B3.1 root chown not invoked: '$r'"
r=$(chown_case true)
[ -z "$r" ] \
  && pass "B3.2 unpriv: update_kiwix_library does NOT chown" \
  || fail "B3.2 unpriv chown leaked: '$r'"

# --- service pre-flight: require_service_stopped_if_unprivileged --------------
pf(){ # $1=UNPRIVILEGED $2=explicit-yes ($2 models `-y`: sets BOTH YES_TO_ALL and
      # EXPLICIT_YES) $3=KSERVE_RUNNING -> sets PF_RC/PF_OUT. The `-b`-alone case
      # (YES_TO_ALL=true but EXPLICIT_YES=false) is covered separately below.
    PF_OUT=$(UNPRIV="$1" YES="$2" KSERVE_RUNNING="$3" PATH="$PID_PATH" in_script '
        UNPRIVILEGED="$UNPRIV"; YES_TO_ALL="$YES"; EXPLICIT_YES="$YES"
        require_service_stopped_if_unprivileged && echo PROCEEDED' 2>&1); PF_RC=$?
}
pf true false 1
{ [ "$PF_RC" -eq 1 ] && printf '%s' "$PF_OUT" | grep -qi "$MSG_SERVING_RUNNING" \
  && ! printf '%s' "$PF_OUT" | grep -q PROCEEDED; } \
  && pass "B3.3 unpriv + running + no -y -> refuse (exit 1, 'stop it' message)" \
  || fail "B3.3 wrong: rc=$PF_RC out='$PF_OUT'"
pf true true 1
{ [ "$PF_RC" -eq 0 ] && printf '%s' "$PF_OUT" | grep -q PROCEEDED \
  && printf '%s' "$PF_OUT" | grep -qi "$MSG_PROCEEDING"; } \
  && pass "B3.4 unpriv + running + -y -> WARN and proceed" \
  || fail "B3.4 wrong: rc=$PF_RC out='$PF_OUT'"
pf true false 0
{ [ "$PF_RC" -eq 0 ] && printf '%s' "$PF_OUT" | grep -q PROCEEDED; } \
  && pass "B3.5 unpriv + not running -> proceed" \
  || fail "B3.5 wrong: rc=$PF_RC out='$PF_OUT'"
pf false false 1
{ [ "$PF_RC" -eq 0 ] && printf '%s' "$PF_OUT" | grep -q PROCEEDED; } \
  && pass "B3.6 root mode exempt: kiwix-serve running but pre-flight proceeds" \
  || fail "B3.6 wrong: rc=$PF_RC out='$PF_OUT'"

# --- service choreography via REAL main (update-library): manages in root mode
# only. determine_run_mode is overridden to force the mode; everything but the
# guarded block is stubbed; manage_kiwix_service logs its calls; kiwix-serve
# reported not-running so the pre-flight is a no-op.
svc_case(){ # $1=UNPRIVILEGED(true/false) -> echoes manage_kiwix_service call log
    local WD LOG
    WD=$(mktemp -d "$ROOT/svc.XXXXXX"); LOG="$WD/svc.calls"; : > "$LOG"
    KIWIX_WORK_DIR="$WD" SVC_LOG="$LOG" KSERVE_RUNNING=0 MODE="$1" PATH="$PID_PATH" in_script '
        determine_run_mode(){ UNPRIVILEGED="$MODE"; EXPECTED_OWNER_UID=0; RUN_UID=0; }
        ensure_trusted_dirs(){ return 0; }
        check_dependencies(){ return 0; }
        read_trusted_pid(){ return 1; }
        clean_state(){ return 0; }
        _restrict_state_file(){ return 0; }
        update_kiwix_library(){ return 0; }
        # Emulate the REAL manage_kiwix_service: `stop` writes the .kiwix_was_running
        # marker on success (the single writer) so restore_service_if_managed fires.
        manage_kiwix_service(){ printf "%s\n" "$1" >> "$SVC_LOG"; [ "$1" = stop ] && touch "${WORK_DIR}/.kiwix_was_running"; return 0; }
        main update-library -y' >/dev/null 2>&1
    cat "$LOG"
}
r=$(svc_case false)
{ printf '%s' "$r" | grep -q 'status' && printf '%s' "$r" | grep -q 'stop' && printf '%s' "$r" | grep -q 'start'; } \
  && pass "B3.9 root: update-library manages kiwix-serve stop+start (positive control: '$(printf '%s' "$r" | tr '\n' ',')')" \
  || fail "B3.9 root did not run full stop/start: '$r'"
r=$(svc_case true)
[ -z "$r" ] \
  && pass "B3.10 unpriv: update-library does NOT touch kiwix-serve" \
  || fail "B3.10 unpriv managed service: '$r'"

# --- absent leaf under a non-writable parent: actionable, mode-aware error ----
# The forgot-KIWIX_WORK_DIR case (non-root left at the root-owned /var/local/zims)
# must NOT surface a misleading "pre-plant race" — it must point at the fix.
NW=$(mktemp -d "$ROOT/nw.XXXXXX"); chmod 555 "$NW"   # parent not writable by us
out=$(NW="$NW" in_script 'EXPECTED_OWNER_UID=1000; UNPRIVILEGED=true; ensure_trusted_dirs "$NW/zims"' 2>&1); rc=$?
chmod 755 "$NW"   # restore so the EXIT trap can rm it
{ [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -qi "$MSG_NOT_WRITABLE" \
  && printf '%s' "$out" | grep -qi "$MSG_KIWIX_WORK_DIR" \
  && ! printf '%s' "$out" | grep -qi "$MSG_PREPLANT"; } \
  && pass "B3.11 absent leaf + non-writable parent -> actionable unpriv remediation (no 'pre-plant')" \
  || fail "B3.11 wrong: rc=$rc out='$out'"

# --- -b implies YES_TO_ALL (the auto-override link) ---------------------------
# Reach the getopts arm through REAL main, then short-circuit at check_dependencies
# (which runs right after getopts) to read the resolved YES_TO_ALL.
optb(){ # $1=extra-args -> echoes "Y=<val>"
    FAKE_UID=1000 ARG="$1" PATH="$SHIM_PATH" in_script '
        check_dependencies(){ printf "Y=%s\n" "$YES_TO_ALL"; exit 9; }
        main check-updates $ARG' 2>&1
}
[ "$(optb -b)" = "Y=true" ] \
  && pass "B3.7 getopts '-b' sets YES_TO_ALL=true (auto-override link intact)" \
  || fail "B3.7 -b did not set YES_TO_ALL: '$(optb -b)'"
[ "$(optb '')" = "Y=false" ] \
  && pass "B3.7b control: no -b/-y leaves YES_TO_ALL=false" \
  || fail "B3.7b baseline wrong: '$(optb '')'"

# --- End-to-end pre-flight through main: refusal writes NOTHING ---------------
# Uses the REAL trust gate against a home-dir WORK_DIR (owned by us, root-owned
# non-writable ancestors) so main reaches the pre-flight; deps stubbed. Skipped
# when running as root (the real gate + euid-0 anchor would reject a user leaf).
if [ "$(id -u)" -ne 0 ]; then
    WD="$HOME/.kiwix-b3-preflight.$$"; rm -rf "$WD"
    out=$(KSERVE_RUNNING=1 KIWIX_WORK_DIR="$WD" PATH="$PID_PATH" in_script '
        check_dependencies(){ return 0; }
        main smart-update' 2>&1); rc=$?
    empty=1
    [ -n "$(ls -A "$WD/temp" 2>/dev/null)" ] && empty=0
    [ -n "$(ls -A "$WD/backups" 2>/dev/null)" ] && empty=0
    { [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -qi "$MSG_SERVING_RUNNING" && [ "$empty" -eq 1 ]; } \
      && pass "B3.8 e2e: unpriv smart-update refuses (running, no -y) and writes nothing to temp/backups" \
      || fail "B3.8 e2e wrong: rc=$rc empty=$empty out='$out'"
    rm -rf "$WD"
else
    pass "B3.8 skipped (running as root — home-dir gate case is non-root only)"
fi

# --- status/clean gate in unprivileged mode: refuse foreign-owned WORK_DIR ----
# The simple-command gate must reject a root-owned (foreign) WORK_DIR BEFORE
# clean_state/check_status touch anything (Batch-1 wiring + Batch-2 gate).
FT2="$ROOT/ft2"; mkdir -p "$FT2/home/me/zims"; LEAF2="$FT2/home/me/zims"
printf '%s\t0\t755\n' "$LEAF2" > "$MAP"   # WORK_DIR owned by root -> rejected for uid 1000
SENT="$ROOT/act.sentinel"
for cmd in clean status; do
    rm -f "$SENT"
    # main exit-1s on gate failure, which exits the sub-bash — capture ITS rc.
    FAKE_UID=1000 KIWIX_WORK_DIR="$LEAF2" CMD="$cmd" SENT="$SENT" PATH="$SHIM_PATH" STATMAP="$MAP" in_script '
        clean_state(){ touch "$SENT"; }
        check_status(){ touch "$SENT"; }
        main "$CMD"' >/dev/null 2>&1
    rc=$?
    { [ "$rc" -eq 1 ] && [ ! -e "$SENT" ]; } \
      && pass "B3.12 unpriv '$cmd' refuses foreign-owned WORK_DIR before acting" \
      || fail "B3.12 '$cmd' wrong: rc=$rc sentinel=$([ -e "$SENT" ] && echo present || echo absent)"
done

echo
echo "########## Issue #2 Batch 3 (code-review follow-up) ##########"

# --- service-guard helpers directly (covers ALL 4 call sites' guard logic) -----
# stop_service_if_managed / restore_service_if_managed are the single seam every
# service call site now delegates to; testing them covers the do_smart_update
# guards (unreachable via offline main) as well as update-library.
svc_helper(){ # $1=fn $2=UNPRIVILEGED $3=marker(yes/no) $4=bg(yes/no) -> echoes call log
    local WD LOG bg=""
    WD=$(mktemp -d "$ROOT/svch.XXXXXX"); LOG="$WD/calls"; : > "$LOG"
    [ "$3" = yes ] && touch "$WD/.kiwix_was_running"
    [ "${4:-no}" = yes ] && bg=1
    KIWIX_WORK_DIR="$WD" SVC_LOG="$LOG" KIWIX_BACKGROUND="$bg" FN="$1" UNPRIV="$2" PATH="$PID_PATH" in_script '
        UNPRIVILEGED="$UNPRIV"
        manage_kiwix_service(){ printf "%s\n" "$1" >> "$SVC_LOG"; return 0; }
        _restrict_state_file(){ :; }
        "$FN"' >/dev/null 2>&1
    cat "$LOG"
}
r=$(svc_helper stop_service_if_managed false no no)
{ printf '%s' "$r" | grep -q status && printf '%s' "$r" | grep -q stop; } \
  && pass "B3.13 root: stop_service_if_managed stops a running service" || fail "B3.13 got '$r'"
r=$(svc_helper stop_service_if_managed true no no)
[ -z "$r" ] && pass "B3.14 unpriv: stop_service_if_managed is a no-op" || fail "B3.14 got '$r'"
# The KIWIX_BACKGROUND skip is a do_smart_update CALL-SITE policy (see B3.24/25),
# NOT part of the helper — so the helper manages regardless of KIWIX_BACKGROUND
# (update-library -b must still act). Was a bug: it had been baked into the helper.
r=$(svc_helper stop_service_if_managed false no yes)
{ printf '%s' "$r" | grep -q status && printf '%s' "$r" | grep -q stop; } \
  && pass "B3.15 stop_service_if_managed ignores KIWIX_BACKGROUND (skip is a call-site concern)" \
  || fail "B3.15 got '$r'"
# B3.15b root + service NOT running: status is checked, but no stop is issued.
WD=$(mktemp -d "$ROOT/svchb.XXXXXX"); LOG="$WD/calls"; : > "$LOG"
KIWIX_WORK_DIR="$WD" SVC_LOG="$LOG" in_script '
    UNPRIVILEGED=false
    manage_kiwix_service(){ printf "%s\n" "$1" >> "$SVC_LOG"; [ "$1" = status ] && return 1; return 0; }
    stop_service_if_managed' >/dev/null 2>&1
r=$(cat "$LOG")
{ printf '%s' "$r" | grep -q status && ! printf '%s' "$r" | grep -q stop; } \
  && pass "B3.15b root + not running: status checked, no stop issued" || fail "B3.15b got '$r'"
r=$(svc_helper restore_service_if_managed false yes no)
printf '%s' "$r" | grep -q start \
  && pass "B3.16 root + marker: restore_service_if_managed restarts" || fail "B3.16 got '$r'"
r=$(svc_helper restore_service_if_managed false no no)
[ -z "$r" ] && pass "B3.17 root + no marker: restore_service_if_managed is a no-op" || fail "B3.17 got '$r'"
r=$(svc_helper restore_service_if_managed true yes no)
[ -z "$r" ] && pass "B3.18 unpriv: restore_service_if_managed is a no-op even with marker" || fail "B3.18 got '$r'"
# B3.18b root + marker + start FAILS -> logs the error and clears the marker (no abort).
WD=$(mktemp -d "$ROOT/svcr.XXXXXX"); touch "$WD/.kiwix_was_running"
out=$(KIWIX_WORK_DIR="$WD" in_script '
    UNPRIVILEGED=false; LOGFILE_SAFE=false; QUIET=false
    manage_kiwix_service(){ [ "$1" = start ] && return 1; return 0; }
    restore_service_if_managed' 2>&1)
{ printf '%s' "$out" | grep -qi "$MSG_FAILED_RESTORE" && [ ! -f "$WD/.kiwix_was_running" ]; } \
  && pass "B3.18b root: restore start-failure logs the error and clears the marker" || fail "B3.18b got '$out' (marker: $([ -f "$WD/.kiwix_was_running" ] && echo present || echo cleared))"

# --- do_smart_update stop CALL SITE (drives the real function, not just helper) -
# Covers the "Cannot proceed" error wrapper and the KIWIX_BACKGROUND skip that is
# unique to smart-update. is_safe_zim_name->1 makes the download loop a no-op.
dsu(){ # $1=bg(yes/no) $2=stop_rc -> log (STOP/RESTORE/rc + captured stderr)
    local WD LOG bg=""
    WD=$(mktemp -d "$ROOT/dsu.XXXXXX"); LOG="$WD/log"; : > "$LOG"
    [ "$1" = yes ] && bg=1
    KIWIX_WORK_DIR="$WD" DSU_LOG="$LOG" KIWIX_BACKGROUND="$bg" STOP_RC="$2" in_script '
        UNPRIVILEGED=false
        FILES_TO_UPDATE=("x|u|n|0")
        update_status(){ :; }; update_progress(){ :; }; backup_library_xml(){ :; }
        update_kiwix_library(){ :; }; is_safe_zim_name(){ return 1; }
        stop_service_if_managed(){ printf "STOP\n" >> "$DSU_LOG"; return "$STOP_RC"; }
        restore_service_if_managed(){ printf "RESTORE\n" >> "$DSU_LOG"; return 0; }
        do_smart_update; printf "rc=%s\n" "$?" >> "$DSU_LOG"' 2>>"$LOG"
    cat "$LOG"
}
out=$(dsu no 1)
{ printf '%s' "$out" | grep -q STOP && printf '%s' "$out" | grep -q "rc=1" && printf '%s' "$out" | grep -qi "$MSG_CANNOT_PROCEED"; } \
  && pass "B3.24 do_smart_update: stop failure -> 'Cannot proceed' message + abort (rc=1)" \
  || fail "B3.24 wrong: '$out'"
out=$(dsu no 0)
# The foreground path must run STOP then RESTORE in order. (rc here is 1 because the
# stubbed is_safe_zim_name->1 counts the entry as a failed update — orthogonal to the
# service seam; the point is the stop->restore choreography actually fires.)
seq=$(printf '%s' "$out" | grep -E '^(STOP|RESTORE)$' | tr '\n' ',')
[ "$seq" = "STOP,RESTORE," ] \
  && pass "B3.24b do_smart_update foreground: STOP then RESTORE (choreography; positive control for B3.25)" \
  || fail "B3.24b wrong seq='$seq' out='$out'"
out=$(dsu yes 1)
# B3.24b above is the positive control: the body DOES log STOP when not skipped,
# so this STOP-absent assertion genuinely proves the background skip.
! printf '%s' "$out" | grep -q STOP \
  && pass "B3.25 do_smart_update -b child: skips service management (smart-update -b policy preserved)" \
  || fail "B3.25 stop called under background: '$out'"

# --- positive control for the status/clean gate (guards the destructive rm path
# against a vacuously-always-refusing gate) --------------------------------------
FT3="$ROOT/ft3"; mkdir -p "$FT3/home/me/zims"; LEAF3="$FT3/home/me/zims"
printf '%s\t1000\t755\n' "$LEAF3" > "$MAP"   # leaf owned by uid 1000 -> trusted for FAKE_UID=1000
for cmd in clean status; do
    rm -f "$SENT"
    FAKE_UID=1000 KIWIX_WORK_DIR="$LEAF3" CMD="$cmd" SENT="$SENT" PATH="$SHIM_PATH" STATMAP="$MAP" in_script '
        clean_state(){ touch "$SENT"; }
        check_status(){ touch "$SENT"; }
        main "$CMD"' >/dev/null 2>&1
    rc=$?
    { [ "$rc" -eq 0 ] && [ -e "$SENT" ]; } \
      && pass "B3.12b unpriv '$cmd' on a TRUSTED WORK_DIR runs (gate isn't vacuously refusing)" \
      || fail "B3.12b '$cmd' wrong: rc=$rc sentinel=$([ -e "$SENT" ] && echo present || echo absent)"
done

# --- root-mode variant: status/clean gate must also fire under euid 0 -----------
printf '%s\t1000\t755\n' "$LEAF2" > "$MAP"   # WORK_DIR owned by uid 1000, euid 0 -> reject
rm -f "$SENT"
FAKE_UID=0 KIWIX_WORK_DIR="$LEAF2" SENT="$SENT" PATH="$SHIM_PATH" STATMAP="$MAP" in_script '
    clean_state(){ touch "$SENT"; }
    main clean' >/dev/null 2>&1
rc=$?
{ [ "$rc" -eq 1 ] && [ ! -e "$SENT" ]; } \
  && pass "B3.12c root: clean refuses a non-root-owned WORK_DIR before acting" \
  || fail "B3.12c wrong: rc=$rc sentinel=$([ -e "$SENT" ] && echo present || echo absent)"

# --- pre-plant via symlinked WORK_DIR is refused up front (deterministic) -------
SL="$ROOT/sl"; mkdir -p "$SL/real"; ln -s "$SL/real" "$SL/link"
out=$(FAKE_UID=1000 KIWIX_WORK_DIR="$SL/link" PATH="$SHIM_PATH" STATMAP="$MAP" in_script 'main status' 2>&1); rc=$?
{ [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -qi "$MSG_SYMLINK"; } \
  && pass "B3.19 symlinked WORK_DIR refused (pre-plant, deterministic)" \
  || fail "B3.19 wrong: rc=$rc out='$out'"

# --- detection fallback: pgrep works when pidof is absent -----------------------
# (bash resolved via the normal PATH; the RESTRICTED PATH is set INSIDE the shell.)
detect(){ # $1=KSERVE_RUNNING -> RUN/NOTRUN, with only pgrep available
    ONLYPGREP="$ROOT/bin3" KSERVE_RUNNING="$1" in_script '
        export PATH="$ONLYPGREP"
        _kiwix_serve_running && echo RUN || echo NOTRUN'
}
r1=$(detect 1); r0=$(detect 0)
{ [ "$r1" = RUN ] && [ "$r0" = NOTRUN ]; } \
  && pass "B3.20 _kiwix_serve_running uses the pgrep fallback when pidof is absent" \
  || fail "B3.20 r1='$r1' r0='$r0'"

# --- fail-closed: no pidof/pgrep -> refuse (unless -y) --------------------------
# Guard: the fail-closed assertions rely on log() finding date/tr in bin_nd.
{ [ -x "$ROOT/bin_nd/date" ] && [ -x "$ROOT/bin_nd/tr" ]; } \
  || fail "B3.21-pre: bin_nd shim incomplete (date/tr symlink missing) — fail-closed test unreliable"
NODETECT="$ROOT/bin_nd" in_script '
    export PATH="$NODETECT"
    UNPRIVILEGED=true; YES_TO_ALL=false; LOGFILE_SAFE=false; QUIET=false
    require_service_stopped_if_unprivileged' >/dev/null 2>&1
rc=$?
[ "$rc" -eq 1 ] && pass "B3.21 unpriv + no pidof/pgrep + no -y -> fail closed (refuse)" || fail "B3.21 rc=$rc"
out=$(NODETECT="$ROOT/bin_nd" in_script '
    export PATH="$NODETECT"
    UNPRIVILEGED=true; YES_TO_ALL=true; EXPLICIT_YES=true; LOGFILE_SAFE=false; QUIET=true
    require_service_stopped_if_unprivileged && echo OK' 2>&1); rc=$?
{ [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q OK && printf '%s' "$out" | grep -qi "$MSG_WARNING"; } \
  && pass "B3.22 no pidof/pgrep + explicit -y -> proceed with a VISIBLE warning (even under QUIET)" \
  || fail "B3.22 wrong: rc=$rc out='$out'"

# --- #1: override warning reaches real stderr even under -y's/-b's QUIET --------
out=$(KSERVE_RUNNING=1 PATH="$PID_PATH" in_script '
    UNPRIVILEGED=true; YES_TO_ALL=true; EXPLICIT_YES=true; QUIET=true; LOGFILE_SAFE=false
    require_service_stopped_if_unprivileged >/dev/null' 2>&1)
printf '%s' "$out" | grep -qi "$MSG_WARNING_KIWIX" \
  && pass "B3.23 serving-guard override warning is visible on stderr under QUIET (-b -y)" \
  || fail "B3.23 warning not on stderr: '$out'"

# --- M2 decouple: -b sets YES_TO_ALL but NOT EXPLICIT_YES, so it must NOT disarm
# the serving-guard. -b alone fails closed; -b -y overrides. (Fail-before vs git
# HEAD: HEAD keyed the override on YES_TO_ALL, so -b alone PROCEEDED — these two
# refusal assertions flip.) ------------------------------------------------------
out=$(KSERVE_RUNNING=1 PATH="$PID_PATH" in_script '
    UNPRIVILEGED=true; YES_TO_ALL=true; EXPLICIT_YES=false; QUIET=false; LOGFILE_SAFE=false
    require_service_stopped_if_unprivileged && echo PROCEEDED' 2>&1); rc=$?
{ [ "$rc" -eq 1 ] && ! printf '%s' "$out" | grep -q PROCEEDED && printf '%s' "$out" | grep -qi "$MSG_SERVING_RUNNING"; } \
  && pass "B3.26 M2: -b alone (YES_TO_ALL w/o EXPLICIT_YES) + running -> fail closed (not overridden)" \
  || fail "B3.26 wrong: rc=$rc out='$out'"
out=$(NODETECT="$ROOT/bin_nd" in_script '
    export PATH="$NODETECT"
    UNPRIVILEGED=true; YES_TO_ALL=true; EXPLICIT_YES=false; LOGFILE_SAFE=false; QUIET=true
    require_service_stopped_if_unprivileged && echo PROCEEDED' 2>&1); rc=$?
{ [ "$rc" -eq 1 ] && ! printf '%s' "$out" | grep -q PROCEEDED; } \
  && pass "B3.27 M2: -b alone + no pidof/pgrep -> fail closed (background does not disarm the no-detection branch)" \
  || fail "B3.27 wrong: rc=$rc out='$out'"
out=$(KSERVE_RUNNING=1 PATH="$PID_PATH" in_script '
    UNPRIVILEGED=true; YES_TO_ALL=true; EXPLICIT_YES=true; QUIET=true; LOGFILE_SAFE=false
    require_service_stopped_if_unprivileged && echo PROCEEDED' 2>&1); rc=$?
{ [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q PROCEEDED && printf '%s' "$out" | grep -qi "$MSG_PROCEEDING"; } \
  && pass "B3.28 M2 control: -b -y (EXPLICIT_YES) + running -> WARN and proceed (explicit override preserved)" \
  || fail "B3.28 wrong: rc=$rc out='$out'"

echo
echo "########## Code-review fixes Batch 1 ##########"

# --- clean_state clears a stale .kiwix_was_running marker (Batch-1 item 2) ------
# A hard-killed prior run can leave .kiwix_was_running behind. clean_state runs in
# main BEFORE command dispatch, so it must clear that stale marker — otherwise
# restore_service_if_managed later starts a service THIS run never stopped. The
# .kiwix_update* glob does NOT match .kiwix_was_running, so it must be listed
# explicitly. Exercise the REAL clean_state (never stubbed) so the check bites.
# Fail-before (git HEAD): the marker survives clean_state and this FAILs.
WDC=$(mktemp -d "$ROOT/cleanmark.XXXXXX")
touch "$WDC/.kiwix_was_running"
KIWIX_WORK_DIR="$WDC" in_script 'clean_state' >/dev/null 2>&1
[ ! -e "$WDC/.kiwix_was_running" ] \
  && pass "CR1.1 clean_state clears stale .kiwix_was_running marker" \
  || fail "CR1.1 .kiwix_was_running survived clean_state"

echo
[ "$FAIL" -eq 0 ] && echo "==== ALL UNPRIVILEGED CHECKS PASSED ====" || echo "==== SOME UNPRIVILEGED CHECKS FAILED ===="
exit "$FAIL"
