#!/bin/bash

# Note: strict mode (set -euo pipefail) is enabled inside main(), not at file
# scope, so the script can be sourced for testing without imposing those options
# on the caller's shell.

# File & URL locations
WORK_DIR="${KIWIX_WORK_DIR:-/var/local/zims}" # where your .zim files live (override: KIWIX_WORK_DIR)
ZIM_LIBRARY="${KIWIX_ZIM_LIBRARY:-/var/local/library_zim.xml}" # library_zim.xml (override: KIWIX_ZIM_LIBRARY)
TEMP_DIR="${WORK_DIR}/temp"
PARTIAL_MAX_AGE_DAYS=14   # resumable partial downloads untouched this long are pruned
SERVICE_STOP_POLLS=20     # kiwix-serve stop is awaited up to this many 0.5 s polls (>= 10 s)
BACKUP_DIR="${WORK_DIR}/backups"
LOG_FILE="${WORK_DIR}/kiwix_update.log"
STATUS_FILE="${WORK_DIR}/.kiwix_update_status"
PID_FILE="${WORK_DIR}/.kiwix_update.pid" 
CRITERIA_FILE="${WORK_DIR}/.kiwix_update_criteria"
# Exclusive run lock (flock on fd 9). Deliberately outside clean_state's
# .kiwix_update* glob so a starting run can never delete a held lock.
LOCK_FILE="${WORK_DIR}/.kiwix_run.lock"
LIBRARY_CACHE="${WORK_DIR}/.kiwix_library_cache"
KIWIX_LIBRARY_API="https://opds.library.kiwix.org/catalog/v2/entries?count=-1"
# Version tag of a Kiwix file name: _YYYY-MM, plus one lowercase letter for a
# same-month rebuild (_2026-09b). Compares correctly as a string. Use UNQUOTED on
# the right of =~ (quoted, it would match literally).
ZIM_VER_RE='[0-9]{4}-[0-9]{2}[[:lower:]]?'

# Default values
YES_TO_ALL=false
# EXPLICIT_YES tracks whether -y was passed on its own. It is NOT implied by -b:
# -b sets YES_TO_ALL (to suppress interactive prompts a background job can't answer)
# but must NOT silently disarm the unprivileged kiwix-serve safety refusal. Only an
# explicit -y overrides that refusal. See require_service_stopped_if_unprivileged.
EXPLICIT_YES=false
CONTINUE_ON_ERROR=false
QUIET=false
PARALLEL_CONNECTIONS=5
MAX_SPEED=""
BACKGROUND=false
TIMEOUT=30
MAX_RETRIES=3
UPDATE_CRITERIA="all"
DEBUG=false
# Run mode (resolved by determine_run_mode from the effective uid). false = root
# mode (today's behavior); true = unprivileged/single-user mode against a
# user-owned WORK_DIR. Default false so any pre-resolution reference is safe.
UNPRIVILEGED=false
# Integrity opt-out (default OFF = fail-closed). Only set via --allow-unverified
# for operators knowingly using a size-only / non-Kiwix mirror with no metalink.
ALLOW_UNVERIFIED=false
# Force HTTPS-only for the bulk .zim transfer even when a SHA-256 hash is present.
# Default OFF: the metalink hash (fetched over HTTPS from the kiwix.org anchor)
# gates integrity, so an HTTP mirror hop on the default path is caught after
# download. Set via --https-only for operators who want strict transport anyway.
HTTPS_ONLY=false
# Guard: log() must NOT append to LOG_FILE (which lives under WORK_DIR) until the
# trusted-dir gate has confirmed WORK_DIR is not an attacker-planted symlink.
# Otherwise a pre-gate/gate-failure log write follows the symlink and lets root
# create/append an arbitrary file (e.g. /etc/sudoers.d/...). Set true only after
# ensure_trusted_dirs succeeds; pre-gate messages go to stderr only.
LOGFILE_SAFE=false

declare -g CLEANUP_IN_PROGRESS=false
declare -g FILES_TO_UPDATE=()
# One library backup per run (taken by _lib_guard on the run's first reconcile or
# pre-flight), so per-file reconciles
# don't rotate real history out of the 5-backup window with identical copies.
declare -g LIB_BACKED_UP=false
# The reconcile's in-flight temp copy of the library, removed by cleanup() if the
# run is killed mid-reconcile (empty when none is in flight).
declare -g LIB_TEMP=""
# True while the library may disagree with WORK_DIR (an old ZIM removed or a
# reconcile in flight): only then does an interrupt suggest 'update-library'.
# Set by the callers of update_kiwix_library, so no return path inside it has
# to clear it.
declare -g LIB_BUSY=false

# Commands checked at preflight so a run fails fast rather than mid-operation.
# Listed: the core externals (aria2c, kiwix-manage, curl) plus tools whose
# GNU-specific flags this script depends on (stat -c, df --output, numfmt) and
# the parsers it cannot run without (awk, grep). Deliberately NOT listed:
# 'service'/'pgrep'/'nohup' — used only on the privileged mutate/background
# paths, so requiring them globally would break the read-only check-updates
# command on systemd-only hosts.
REQUIRED_COMMANDS=(
    "aria2c"
    "kiwix-manage"
    "curl"
    "find"
    "stat"
    "numfmt"
    "awk"
    "df"
    "grep"
    "sha256sum"
    "readlink"
    "realpath"
    "flock"
    "setsid"
)

log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    # Basic log injection prevention - remove C0 control characters and DEL.
    # (Deliberately NOT stripping the C1 range \200-\237: those are legitimate
    # UTF-8 continuation bytes and removing them would mangle accented text.)
    message=$(printf '%s' "$message" | tr -d '\000-\037\177')

    # Write to log file — ONLY after the trusted-dir gate has validated WORK_DIR
    # (LOG_FILE lives under WORK_DIR; writing through an unvalidated, possibly
    # symlinked WORK_DIR would let root write an attacker-chosen file).
    if ${LOGFILE_SAFE}; then
        printf '[%s] [%s] %s\n' "${timestamp}" "${level}" "${message}" >> "${LOG_FILE}" 2>/dev/null || true
    fi

    # Errors go to stderr even under -q. Not once KIWIX_BACKGROUND is set (the -b
    # child, and the -b parent after it exports it just before redirecting to the
    # log): stderr is the log file there, which already has the line. `|| true` on
    # every console write: a closed stdout/stderr (an SSH session that dropped
    # mid-run) must not abort the run under set -e — inside cleanup that would
    # skip the service restore.
    if [ -n "${KIWIX_BACKGROUND:-}" ]; then
        :
    elif [ "${level}" = "ERROR" ]; then
        printf 'ERROR: %s\n' "${message}" >&2 || true
    elif ! ${QUIET}; then
        if [ "${level}" != "DEBUG" ] || ${DEBUG}; then
            printf '%s\n' "${message}" || true
        fi
    fi
    return 0
}

# --- Library path helpers -----------------------------------------------------
# kiwix-manage stores each <book path="..."> RELATIVE to dirname(library) (absolute
# when the library sits at /), XML-escaped, and kiwix resolves "../" LEXICALLY
# (symlinked ancestors are NOT followed). These helpers reproduce exactly that so
# the reconciler compares the same path kiwix-serve opens. None of them write to
# stdout except their data, so they are safe inside $(...).

# VARNAME -> decode the five predefined XML entities of $VARNAME in place (no fork).
_lib_unescape() {
    local -n _ue_s=$1
    _ue_s="${_ue_s//&lt;/<}"
    _ue_s="${_ue_s//&gt;/>}"
    _ue_s="${_ue_s//&quot;/\"}"
    _ue_s="${_ue_s//&apos;/\'}"
    # &amp; MUST be last (decoding it first would turn "&amp;lt;" into "<"), and the
    # replacement MUST be "\&": under bash >= 5.2's default patsub_replacement a bare
    # "&" in the replacement means "the matched text", which would make this a no-op.
    _ue_s="${_ue_s//&amp;/\&}"
}

# LIB_DIR P... -> NUL-separated lexical absolute paths: no per-entry forks, one
# realpath call total. Makes no validation claims: _lib_load's count check is the
# only error gate (a process-substitution consumer cannot see this rc).
_lib_resolve_paths() {
    local _rp_dir="$1" _rp_p; shift
    [ $# -gt 0 ] || return 0
    local -a _rp_abs=()
    for _rp_p in "$@"; do
        _lib_unescape _rp_p
        [[ "$_rp_p" == /* ]] || _rp_p="$_rp_dir/$_rp_p"
        _rp_abs+=("$_rp_p")
    done
    realpath -ms -z -- "${_rp_abs[@]}"
}

# ARR_IDS ARR_PATHS -> parallel arrays of book ids and resolved absolute paths.
# rc 0 = ok (empty when the library file is absent); rc 2 = could not read/resolve.
# Namerefs and locals are _ll_-prefixed so no caller name can collide with them.
_lib_load() {
    local -n _ll_ids=$1 _ll_paths=$2
    _ll_ids=(); _ll_paths=()
    [ -f "$ZIM_LIBRARY" ] || return 0
    local _ll_dir="" _ll_line _ll_id _ll_path
    local -a _ll_raw=() _ll_resolved=()
    _ll_dir=$(realpath -ms -- "$(dirname -- "$ZIM_LIBRARY")") && [ -n "$_ll_dir" ] || return 2
    while IFS= read -r _ll_line || [ -n "$_ll_line" ]; do
        [[ "$_ll_line" =~ \<book ]] || continue
        _ll_id=""; _ll_path=""
        [[ "$_ll_line" =~ [[:space:]]id=\"([^\"]+)\" ]]   && _ll_id="${BASH_REMATCH[1]}"
        [[ "$_ll_line" =~ [[:space:]]path=\"([^\"]+)\" ]] && _ll_path="${BASH_REMATCH[1]}"
        if [ -n "$_ll_id" ] && [ -n "$_ll_path" ]; then
            _ll_ids+=("$_ll_id"); _ll_raw+=("$_ll_path")
        fi
    done < "$ZIM_LIBRARY" || return 2   # unreadable library = error, never "empty"
    mapfile -d '' _ll_resolved < <(_lib_resolve_paths "$_ll_dir" "${_ll_raw[@]}")
    if [ "${#_ll_resolved[@]}" -ne "${#_ll_raw[@]}" ]; then
        _ll_ids=(); _ll_paths=(); return 2
    fi
    _ll_paths=("${_ll_resolved[@]}")
    return 0
}

# `update-library` command: reconcile with the service stopped, and ALWAYS restore
# the service afterwards — a failed reconcile must not leave kiwix-serve down.
# (Calling update_kiwix_library in this || context suspends errexit inside it,
# which is why it checks every step itself.)
cmd_update_library() {
    stop_service_if_managed || return 1
    local rc=0
    LIB_BUSY=true
    update_kiwix_library || rc=$?
    # A refused reconcile (1) leaves the library inconsistent: keep the hint.
    [ "$rc" -eq 1 ] || LIB_BUSY=false
    # A failed restart (server left down) fails an otherwise successful run.
    restore_service_if_managed || [ "$rc" -ne 0 ] || rc=1
    return "$rc"
}

# Gate run by EVERY library reconcile: refuse a symlinked library (defense-in-
# depth; the trusted-dir gate covers the directory, not this file — _lib_load and
# cp would read straight through it) or one that is not a regular file (e.g. a
# directory), and take the run's single backup.
# Returns 0 to proceed, 1 (with an ERROR logged) otherwise.
_lib_guard() {
    if [ -L "${ZIM_LIBRARY}" ]; then
        log "ERROR" "Refusing to update ${ZIM_LIBRARY}: it is a symlink — library not modified"
        return 1
    fi
    # Present but not a regular file (e.g. a directory): _lib_load would read it
    # as "absent" and the pre-flight would pass, then the first reconcile's cp
    # would refuse only after an old ZIM was already deleted.
    if [ -e "${ZIM_LIBRARY}" ] && [ ! -f "${ZIM_LIBRARY}" ]; then
        log "ERROR" "Refusing to update ${ZIM_LIBRARY}: not a regular file — library not modified"
        return 1
    fi
    if ! ${LIB_BACKED_UP}; then
        if ! backup_library_xml; then
            log "ERROR" "Library backup failed — library not modified"
            return 1
        fi
        LIB_BACKED_UP=true
    fi
    return 0
}

# The library-level conditions update_kiwix_library refuses on (symlink,
# non-regular file, backup, unparseable/unresolvable library, unwritable library
# dir), checked up front so a caller (smart-update) can fail BEFORE stopping the
# service or touching any file.
# A later reconcile can still refuse on transient I/O (cp/mv or the empty-library
# initialisation failing) or on kiwix-manage leaving an empty temp library.
# Returns 0 if reconciles can proceed, 1 (with an ERROR logged) otherwise.
_lib_preflight() {
    _lib_guard || return 1
    # shellcheck disable=SC2034  # filled via nameref by _lib_load; only its rc matters here
    local -a _pf_ids=() _pf_paths=()
    if ! _lib_load _pf_ids _pf_paths; then
        log "ERROR" "Could not resolve library paths in ${ZIM_LIBRARY} — library not modified"
        return 1
    fi
    local _pf_tmp=""
    _pf_tmp=$(mktemp -p "$(dirname "${ZIM_LIBRARY}")" .library_zim_temp.XXXXXX) || {
        log "ERROR" "Cannot create a temp file next to ${ZIM_LIBRARY} — library not modified"
        return 1
    }
    rm -f "$_pf_tmp"
    return 0
}

# Remove the reconcile's temp copy of the library (LIB_TEMP), if any, and forget it.
_lib_temp_discard() {
    [ -z "${LIB_TEMP}" ] || rm -f -- "${LIB_TEMP}"
    LIB_TEMP=""
}

# Update Kiwix library — the SOLE writer of library state. Drops entries for
# WORK_DIR ZIMs that no longer exist, then adds WORK_DIR ZIMs that are not listed.
# Entries for ZIMs anywhere else (another disk, a WORK_DIR subdirectory) are not
# ours and are left untouched.
#   Args (optional): REFRESH_PATH... — WORK_DIR files replaced in place under the
#   same name (same path, new book UUID/metadata). Their entries are removed and
#   re-added, which path-based reconciling could not otherwise detect.
# Returns 0 on success; 1 if it refused or aborted (library not modified, or
# removals not applied); 2 if it completed but some kiwix-manage add/remove failed
# (the ERROR lines name each file — it may be a bystander, not the REFRESH target).
# Every step checks its own status: callers run this with errexit suspended.
# Callers set LIB_BUSY=true around this call (and any old-file removal before
# it) so an interrupt suggests 'update-library'.
update_kiwix_library() {
    log "INFO" "Updating Kiwix library..."

    # Symlink / non-regular-file refusal + the run's one backup. (The parse and
    # temp-dir checks of _lib_preflight are not repeated here: the body below
    # fails closed on both.)
    _lib_guard || return 1

    local wd_abs=""
    wd_abs=$(realpath -ms -- "${WORK_DIR}") && [ -n "$wd_abs" ] || {
        log "ERROR" "Cannot resolve WORK_DIR ${WORK_DIR} — library not modified"
        return 1
    }
    wd_abs="${wd_abs%/}"   # WORK_DIR=/ -> "" so the key and dirname rules agree

    local -a lib_ids=() lib_paths=()
    if ! _lib_load lib_ids lib_paths; then
        log "ERROR" "Could not resolve library paths in ${ZIM_LIBRARY} — library not modified"
        return 1
    fi
    log "INFO" "Found ${#lib_paths[@]} files in library"

    local -A in_lib=() refresh=()
    local p r
    for p in "${lib_paths[@]}"; do in_lib["$p"]=1; done
    for p in "$@"; do
        r=$(realpath -ms -- "$p") && [ -n "$r" ] && refresh["$r"]=1
    done

    # Removals FIRST (on a temp copy, then one atomic mv), adds second: if a ZIM
    # was renamed in place (same book UUID), kiwix-manage `add` rewrites that UUID's
    # entry, and a later remove-by-id would then delete the freshly added book.
    # The temp lives in ZIM_LIBRARY's OWN directory (not WORK_DIR, which may be a
    # different mount) so the mv is an intra-device rename, never a copy.
    local removed_count=0 external_count=0 failed_count=0 temp_library i
    temp_library=$(mktemp -p "$(dirname "${ZIM_LIBRARY}")" .library_zim_temp.XXXXXX) || {
        log "ERROR" "Cannot create a temp library — library not modified"; return 1; }
    # Every later path renames it or calls _lib_temp_discard; cleanup() covers a kill.
    LIB_TEMP="$temp_library"
    # Seed the temp from the existing library. A missing or 0-byte library has
    # nothing to copy (the mktemp file is already empty) and must be initialised
    # as an empty <library>: kiwix-manage and kiwix-serve both reject a 0-byte
    # file ("Cannot read the library"), so a bare touch would make every add
    # fail. A 0-byte one is what earlier versions of this script created on a
    # fresh install. The skeleton is written into our temp and renamed into
    # place (atomic: a failed write never leaves a partial or new empty file).
    # There are no entries here, so the temp has no other use. No path here
    # ever deletes a library.
    if [ -s "${ZIM_LIBRARY}" ]; then
        if ! cp "${ZIM_LIBRARY}" "$temp_library"; then
            _lib_temp_discard
            log "ERROR" "Cannot copy ${ZIM_LIBRARY} — library not modified"
            return 1
        fi
    else
        if [ -e "${ZIM_LIBRARY}" ]; then
            log "WARN" "Library file is empty (unreadable by kiwix), initialising it"
        else
            log "WARN" "Library file does not exist, creating new one"
        fi
        if ! { printf '<library version="20110515">\n</library>\n' > "$temp_library" &&
               chmod 644 "$temp_library" && mv "$temp_library" "${ZIM_LIBRARY}"; }; then
            _lib_temp_discard
            log "ERROR" "Cannot create ${ZIM_LIBRARY} — library not modified"
            return 1
        fi
        LIB_TEMP=""   # renamed into place: nothing left for cleanup() to remove
    fi
    for i in "${!lib_paths[@]}"; do
        p="${lib_paths[$i]}"
        if [ "${p%/*}" != "$wd_abs" ]; then
            external_count=$((external_count + 1))
            continue
        fi
        if [ -f "$p" ] && [ -z "${refresh["$p"]:-}" ]; then
            continue
        fi
        if [ -f "$p" ]; then
            log "INFO" "Refreshing ${p##*/} (ID: ${lib_ids[$i]}) - replaced in place"
        else
            log "INFO" "Removing ${p##*/} (ID: ${lib_ids[$i]}) from library - file no longer exists"
        fi
        if kiwix-manage "$temp_library" remove "${lib_ids[$i]}"; then
            removed_count=$((removed_count + 1))
            unset 'in_lib[$p]'   # a refreshed file is then re-added below
        else
            log "ERROR" "Failed to remove ${p##*/} from library"
            failed_count=$((failed_count + 1))
        fi
    done
    if [ "$removed_count" -gt 0 ] && [ ! -s "$temp_library" ]; then
        # kiwix-manage "succeeded" yet left nothing: never install that, and
        # never pretend the removals happened (refreshed files would be
        # re-added next to their stale entries).
        _lib_temp_discard
        log "ERROR" "kiwix-manage left an empty temp library — removals not applied, library not modified"
        return 1
    elif [ "$removed_count" -gt 0 ]; then
        if ! { chmod 644 "$temp_library" && mv "$temp_library" "${ZIM_LIBRARY}"; }; then
            _lib_temp_discard
            log "ERROR" "Cannot replace ${ZIM_LIBRARY} — removals not applied"
            return 1
        fi
        LIB_TEMP=""   # renamed into place: nothing left for cleanup() to remove
    else
        _lib_temp_discard   # (already gone if the library was just initialised)
    fi

    local found_files=() file_path filename added_count=0
    while IFS= read -r -d '' file_path; do
        found_files+=("$file_path")
    done < <(find "${WORK_DIR}" -maxdepth 1 -type f -name "*.zim" -print0 | sort -z)
    log "INFO" "Found ${#found_files[@]} ZIM files in directory"

    for file_path in "${found_files[@]}"; do
        filename="${file_path##*/}"
        [ -n "${in_lib["$wd_abs/$filename"]:-}" ] && continue
        log "INFO" "Adding $filename to library"
        if kiwix-manage "${ZIM_LIBRARY}" add "$file_path"; then
            added_count=$((added_count + 1))
        else
            log "ERROR" "Failed to add $filename to library"
            failed_count=$((failed_count + 1))
        fi
    done

    log "INFO" "Library update complete: $added_count added, $removed_count removed, $failed_count failed, $external_count outside WORK_DIR left untouched"

    # chmod and chown follow symlinks: re-check right before them. Best effort:
    # this narrows the window rather than closing it (only the trusted dir's owner
    # can swap the file). The library was already modified above, so a swap here
    # is rc 2 (completed, an op failed), never rc 1 ("library not modified").
    if [ -L "${ZIM_LIBRARY}" ] || [ ! -f "${ZIM_LIBRARY}" ]; then
        log "ERROR" "${ZIM_LIBRARY} is no longer a regular file — chmod/chown skipped; check it"
        return 2
    fi
    chmod 644 "${ZIM_LIBRARY}" || log "WARN" "Cannot chmod 644 ${ZIM_LIBRARY}"
    # Only root can (and should) hand the library to root:root. In unprivileged
    # mode the file stays owned by the running user — the trust gate already
    # requires WORK_DIR and its ancestors to be owned by that same user or root.
    if ! ${UNPRIVILEGED}; then
        chown --no-dereference root:root "${ZIM_LIBRARY}" || log "WARN" "Cannot chown root:root ${ZIM_LIBRARY}"
    fi

    # A failed kiwix-manage add/remove means a book is missing or stale: report it.
    if [ "$failed_count" -gt 0 ]; then
        log "ERROR" "$failed_count library operation(s) failed — run 'update-library' after fixing the cause"
        return 2
    fi
    return 0
}


fetch_library_data() {
    local cache_age=3600  # Cache for 1 hour
    
    # Check if cache exists and is recent
    if [ -f "$LIBRARY_CACHE" ]; then
        local cache_time=$(stat -c%Y "$LIBRARY_CACHE")
        local current_time=$(date +%s)
        if [ $((current_time - cache_time)) -lt $cache_age ]; then
            if [ -s "$LIBRARY_CACHE" ]; then
                log "DEBUG" "Using cached library data"
                return 0
            fi
            rm -f "$LIBRARY_CACHE"   # empty/corrupt cache — fall through to refetch
        fi
    fi
    
    log "INFO" "Fetching latest library data from Kiwix..."
    
    # Get the root catalog with basic error handling
    # -L with --max-redirs 0: any redirect is a hard error (curl 47). Without -L a
    # 3xx is not an error under --fail and its body would be cached as the catalog.
    if curl -sL --max-redirs 0 --proto '=https' --proto-redir '=https' --connect-timeout "$TIMEOUT" --max-time 60 --max-filesize 209715200 --fail "$KIWIX_LIBRARY_API" -o "${LIBRARY_CACHE}.tmp"; then
        # Parse the ATOM feed
        awk '
            length($0) > 100000 { next }   # skip absurdly long lines (DoS guard)
            /<entry>/ { in_entry=1; publisher=""; link=""; size=""; }
            /<\/entry>/ { 
                if (link != "") {
                    # The v2 acquisition href is already the absolute
                    # .zim.meta4 URL (on lb.download.kiwix.org). Drop only the
                    # .meta4 suffix so path becomes the full absolute .zim URL;
                    # the host-pin in analyze_updates validates it before use.
                    path = link
                    gsub(/\.meta4$/, "", path);
                    filename = path
                    gsub(/.*\//, "", filename);
                    # Sanitize fields so a hostile catalog cannot inject the pipe
                    # delimiter, control bytes, or whitespace into the record. A
                    # URL legitimately contains ':' and '/', which are preserved.
                    gsub(/[|[:cntrl:][:space:]]/, "", publisher);
                    gsub(/[|[:cntrl:][:space:]]/, "", filename);
                    gsub(/[|[:cntrl:][:space:]]/, "", path);
                    gsub(/[|[:cntrl:][:space:]]/, "", size);
                    print publisher "|" filename "|" path "|" size
                }
                in_entry=0; 
            }
            in_entry && /<publisher>/ {
                getline;
                if (/<name>/) {
                    gsub(/.*<name>/, "", $0);
                    gsub(/<\/name>.*/, "", $0);
                    publisher=$0;
                }
            }
            in_entry && link=="" && /rel="http:\/\/opds-spec.org\/acquisition\/open-access"/ {
                # First open-access acquisition link wins (deterministic if a
                # future entry ever groups multiple flavours in one <entry>).
                match($0, /href="[^"]+"/);
                link=substr($0, RSTART+6, RLENGTH-7);
                match($0, /length="[^"]+"/);
                if (RSTART > 0) {
                    size=substr($0, RSTART+8, RLENGTH-9);
                }
            }
        ' "${LIBRARY_CACHE}.tmp" > "$LIBRARY_CACHE"
        
        # Capture the feed's advertised total before removing the raw response.
        # The tag is un-namespaced <totalResults> on the live feed; tolerate an
        # opensearch: prefix defensively.
        local total_results
        total_results=$(grep -oiE '<(opensearch:)?totalResults>[0-9]+' "${LIBRARY_CACHE}.tmp" \
            | grep -oE '[0-9]+' | head -n1)

        # Count the RAW <entry> elements in the feed BEFORE removing the raw
        # response — this is the honest truncation signal. entry_count below counts
        # only OPEN-ACCESS entries (the awk emits a line only when an open-access
        # acquisition link is present), so a complete feed with some non-open entries
        # has entry_count < total_results and would falsely trip the guard. One
        # <entry> per line is the feed shape the awk already relies on (open/close
        # tags on separate lines), so grep -c is exact here. `|| true`: grep -c exits
        # 1 on zero matches, which would abort under set -e (masked today only by the
        # sole `if ! fetch_library_data` caller); raw_entries=0 then feeds the
        # zero-parsed guard below rather than trapping.
        local raw_entries
        raw_entries=$(grep -c '<entry>' "${LIBRARY_CACHE}.tmp" || true)

        rm -f "${LIBRARY_CACHE}.tmp"

        # The awk emits one line per OPEN-ACCESS entry, so 0 lines means the parser
        # broke (feed format changed) — checked independently of the truncation guard.
        local entry_count
        entry_count=$(wc -l < "$LIBRARY_CACHE")
        if [ "$entry_count" -eq 0 ]; then
            log "ERROR" "Catalog parse produced 0 entries — feed format may have changed"
            rm -f "$LIBRARY_CACHE"
            return 1
        fi

        # Truncation guard: validate <totalResults> is a positive integer and
        # cross-check it against the RAW <entry> count in the feed (raw_entries),
        # NOT the open-access-only parsed count. A future silent cap on count=-1
        # would return >0 but far-fewer entries, and without this the zero-entry
        # guard would not trip — nearly every local file would be silently marked
        # "no match". Fail loud (fail-closed) rather than drop updates or let an
        # empty operand disable the check.
        # Bound the digit count too: a hostile feed could otherwise supply a
        # 20+-digit value that overflows the 64-bit `* 99` arithmetic below and
        # silently disables the truncation cross-check. 9 digits (<1e9) is far
        # above any real catalog (~3602) yet safe from overflow.
        if ! [[ "$total_results" =~ ^[0-9]+$ ]] || [ "${#total_results}" -gt 9 ] || [ "$total_results" -le 0 ]; then
            log "ERROR" "Catalog <totalResults> missing or unparseable — feed format may have changed"
            rm -f "$LIBRARY_CACHE"
            return 1
        fi
        if [ $(( raw_entries * 100 )) -lt $(( total_results * 99 )) ]; then
            log "ERROR" "Catalog truncated: feed carried ${raw_entries} of ${total_results} entries — Kiwix may have capped count=-1 (pagination needed)"
            rm -f "$LIBRARY_CACHE"
            return 1
        fi
        log "INFO" "Library data updated - found ${entry_count} entries"
        return 0
    else
        log "ERROR" "Failed to fetch library data"
        return 1
    fi
}

find_latest_zim() {
    local local_filename="$1"
    local base_name="${local_filename%.zim}"
    # Kiwix names its files with a trailing version (_YYYY-MM, or _YYYY-MMx for a
    # same-month rebuild; see ZIM_VER_RE). Strip it so the undated title stem can
    # match the catalog's (newer-)dated entries via the dated-version branch below.
    # Without this, a dated local file only matched a catalog entry of the *same*
    # date — i.e. only when no update existed (issue #1). Undated local names are a
    # no-op here; _YYYY-MM-DD / year-only forms are not handled.
    if [[ "$base_name" =~ ^(.+)_${ZIM_VER_RE}$ ]]; then
        base_name="${BASH_REMATCH[1]}"
    fi
    local alt_name=""

    if [ ! -f "$LIBRARY_CACHE" ]; then
        log "ERROR" "Library cache not found"
        return 1
    fi
    
    ${DEBUG} && log "DEBUG" "Looking for matches for: $base_name"
    
    # Titles Kiwix renamed upstream (the catalog carries no "replaces" link, so
    # these are listed by hand; analyze_updates WARNs about local files that
    # match nothing, which is how a new rename shows up). Only same-content
    # renames belong here: the old file is deleted once the new one installs.
    case "$base_name" in
        wiktionary_*_all_maxi)
            alt_name="${base_name%_maxi}"
            ;;
        teded_en_all)
            alt_name="ted_mul_ted-ed"
            ;;
        tedmed_en_all)
            alt_name="ted_mul_tedmed"
            ;;
        wikihow_en_maxi)
            alt_name="wikihow_en_all"
            ;;
        cogsci.stackexchange.com_en_all)      # site renamed Psychology & Neuroscience
            alt_name="psychology.stackexchange.com_en_all"
            ;;
        health.stackexchange.com_en_all)      # site renamed Medical Sciences
            alt_name="medicalsciences.stackexchange.com_en_all"
            ;;
        fas-military-medicine_en)
            alt_name="irp.fas.org_en_military-medicine"
            ;;
        www.ready.gov_en)
            alt_name="ready.gov_en_all"
            ;;
    esac

    # Dot-safe stems: a literal '.' in a title (e.g. nhs.uk, superuser.com) must
    # match '.', not any char, when interpolated into the =~ patterns below. '.' is
    # the only ERE metacharacter that occurs in Kiwix names ([A-Za-z0-9._-]), so a
    # dot-only escape is complete for this domain. It applies to rename-table
    # targets too (several contain dots).
    local base_re="${base_name//./\\.}"
    local alt_re="${alt_name//./\\.}"

    # Search for matching entry in library
    local result=""
    local best_match=""
    local best_date=""
    
    while IFS='|' read -r publisher filename path size; do
        local file_base="${filename%.zim}"
        
        # Exact match
        if [ "$file_base" = "$base_name" ]; then
            result="${publisher}|${filename}|${path}|${size}"
            break
        fi
        
        # Alternative name match
        if [ -n "${alt_name}" ] && [[ "$file_base" =~ ^${alt_re}(_${ZIM_VER_RE})?$ ]]; then
            if [[ "$file_base" =~ _${ZIM_VER_RE}$ ]]; then
                local date_part="${file_base##*_}"
                if [ -z "$best_date" ] || [[ "$date_part" > "$best_date" ]]; then
                    best_date="$date_part"
                    best_match="${publisher}|${filename}|${path}|${size}"
                fi
            else
                result="${publisher}|${filename}|${path}|${size}"
                break
            fi
        fi
        
        # Dated version match
        if [[ "$file_base" =~ ^${base_re}_${ZIM_VER_RE}$ ]]; then
            local date_part="${file_base##*_}"
            if [ -z "$best_date" ] || [[ "$date_part" > "$best_date" ]]; then
                best_date="$date_part"
                best_match="${publisher}|${filename}|${path}|${size}"
            fi
        fi
    done < "$LIBRARY_CACHE"
    
    # Use best match if no exact match found
    if [ -z "$result" ] && [ -n "$best_match" ]; then
        result="$best_match"
    fi
    
    if [ -z "$result" ]; then
        # Try nopic version for wiktionary
        if [[ "$base_name" =~ ^wiktionary_.*_all(_maxi)?$ ]]; then
            local nopic_name="${base_name%_maxi}_nopic"
            local nopic_re="${nopic_name//./\\.}"
            while IFS='|' read -r publisher filename path size; do
                local file_base="${filename%.zim}"
                if [[ "$file_base" =~ ^${nopic_re}(_${ZIM_VER_RE})?$ ]]; then
                    result="${publisher}|${filename}|${path}|${size}"
                    break
                fi
            done < "$LIBRARY_CACHE"
        fi
        
        if [ -z "$result" ]; then
            log "DEBUG" "No match found for $base_name in library"
            return 1
        fi
    fi
    
    echo "$result"
    return 0
}

# $1 = exit code to use (the signal traps pass 128+signo); default: the status
# that triggered the EXIT trap.
cleanup() {
    local exit_code=${1:-$?}
    if ${CLEANUP_IN_PROGRESS}; then
        return
    fi
    CLEANUP_IN_PROGRESS=true

    # Skip cleanup if parent process launching background job
    if [ "${BACKGROUND}" = "true" ] && [ -z "${KIWIX_BACKGROUND:-}" ]; then
        exit "$exit_code"
    fi

    # Never leave kiwix-serve down because the run ended (or was signalled) after
    # stopping it: the .kiwix_was_running marker is the single record of that, and
    # restore is a no-op without it. Restore first, before any other cleanup step
    # (or console output) can fail or stall in between. A no-op handler (NOT
    # trap '': SIG_IGN is inherited across exec, so systemctl/service and a
    # sysvinit-started kiwix-serve would ignore SIGTERM) keeps a second Ctrl-C from
    # aborting the restart sequence (a child it hits directly can still die).
    if [ -f "${WORK_DIR}/.kiwix_was_running" ]; then
        trap ':' INT TERM HUP
        restore_service_if_managed || true   # errexit: a failed start must not abort cleanup
    fi

    if [ -z "${KIWIX_BACKGROUND:-}" ] && ! ${QUIET}; then
        log "INFO" "Cleaning up..."
    fi

    # Remove our own PID file, ownership-gated (via read_trusted_pid, which
    # rejects symlinks/non-root/non-numeric) so we never delete another run's or
    # follow a planted symlink (e.g. a foreground run must not clobber a live
    # background child's PID file).
    if [ "$(read_trusted_pid 2>/dev/null)" = "$$" ]; then
        rm -f "${PID_FILE}"
    fi

    # A reconcile's temp copy of the library (set only while one is in flight).
    _lib_temp_discard

    if [ -n "${1:-}" ] && ${LIB_BUSY}; then
        log "WARN" "Interrupted during a library update — run 'update-library'"
    fi

    # Clean up transient files if not in background mode (resumable partials stay)
    if [ -z "${KIWIX_BACKGROUND:-}" ]; then
        _prune_temp_dir
        [ -f "${STATUS_FILE}" ] && rm -f "${STATUS_FILE}"
    fi

    # NB: do not reset CLEANUP_IN_PROGRESS here — leaving it true short-circuits
    # the EXIT-trap re-entry after a signal, preventing a double cleanup.
    exit "$exit_code"
}

show_help() {
   cat << EOF
Usage: $(basename "$0") [OPTIONS] COMMAND

Commands:
   check-updates        Check which ZIM files need updating
   smart-update         Only download and update ZIM files that need updating
   update-library       Update Kiwix library to match ZIM files in directory
                        (entries for ZIMs outside the directory are left alone)
   status               Show current update status
   stop                 Stop a running update process
   clean                Remove all logs and state files, and discard partial
                        downloads (otherwise kept to resume on the next run)
   help                 Show this help message

Options:
   -h                   Show this help message
   -y                   Automatic yes to all prompts
   -c                   Continue past per-file download errors (the run still
                        exits non-zero; a library that cannot be written still
                        stops the run)
   -b                   Run in background
   -q                   Quiet: hide progress, info and warnings (errors and the
                        safety warnings still go to stderr)
   -v                   Verbose/debug mode
   -p:[NUM]             Parallel connections (1-50)
   -m:[NUM[M|K]]        Max download speed
   -u:[size|newer|all]  Update criteria
   --allow-unverified   Permit installs when no SHA-256 metalink is available,
                        falling back to size-only verification against the
                        authoritative catalog size (default: OFF — a missing
                        hash blocks the download). If neither a hash nor a
                        catalog size is available the download is refused
                        (a mirror-reported size is not accepted — it is circular)
   --https-only         Force HTTPS-only for the .zim download even when a
                        SHA-256 hash is present (default: OFF — an HTTP mirror
                        hop is permitted and verified by the hash)

Environment:
   KIWIX_WORK_DIR       Directory holding the ZIM files and state
                        (default: /var/local/zims)
   KIWIX_ZIM_LIBRARY    Path to library_zim.xml
                        (default: /var/local/library_zim.xml in root mode;
                        \$KIWIX_WORK_DIR/library_zim.xml in unprivileged mode)

Examples:
   $(basename "$0") check-updates
   $(basename "$0") smart-update -u:size -m:5M
   $(basename "$0") smart-update -y -b
   KIWIX_WORK_DIR=\$HOME/zims $(basename "$0") smart-update

Run modes (selected automatically from the effective UID):
   root          Manages the kiwix-serve service, chowns the library to
                 root:root, and defaults to /var/local. WORK_DIR and all its
                 ancestors must be root-owned and not group/other-writable.
   unprivileged  Any non-root user, against a WORK_DIR they own (e.g. under
                 \$HOME). Does no chown and does not touch the service. WORK_DIR
                 and its ancestors must be owned by that user or root and not be
                 group/other-writable — so keep WORK_DIR out of world-writable
                 locations such as /tmp. kiwix-serve must be stopped first: the
                 script refuses to run while it is up (or while it cannot check)
                 unless you pass an explicit -y. Note -b alone does NOT override
                 this safety refusal; use -b -y to override it in background.

Notes:
   * A non-root run against the default root-owned /var/local fails with a clear
     permission error rather than silently downgrading; set KIWIX_WORK_DIR to a
     directory you own to use unprivileged mode.
   * Trust checks are ownership/permission based only (no ACL/NFS awareness) and
     assume a local filesystem; the threat model is peer users, not root.
   * Under sudo, pass -E (or set the KIWIX_* vars in the sudo environment) if you
     need your KIWIX_WORK_DIR/KIWIX_ZIM_LIBRARY overrides to survive.
EOF
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

check_dependencies() {
    local missing_commands=()
    
    for cmd in "${REQUIRED_COMMANDS[@]}"; do
        if ! command_exists "$cmd"; then
            missing_commands+=("$cmd")
        fi
    done
    
    if [ ${#missing_commands[@]} -ne 0 ]; then
        echo "Error: Missing required commands: ${missing_commands[*]}" >&2
        echo "Please install the missing dependencies." >&2
        return 1
    fi

    # Capabilities, not just presence: library path handling needs bash >= 4.4
    # (namerefs, mapfile -d) and GNU coreutils realpath (-m -s -z). BusyBox/BSD
    # realpath would otherwise make every library reconcile fail at run time.
    if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
        echo "Error: bash >= 4.4 required (found ${BASH_VERSION})" >&2
        return 1
    fi
    if ! realpath -ms -z -- /a/../b >/dev/null 2>&1; then
        echo "Error: GNU coreutils realpath (supporting -m -s -z) is required" >&2
        return 1
    fi

    return 0
}

check_disk_space() {
    local required_space="$1"
    local available_space=$(df --output=avail -B 1 "$WORK_DIR" | tail -n 1)
    
    if [ "$available_space" -lt "$required_space" ]; then
        log "ERROR" "Insufficient disk space"
        log "ERROR" "Required: $(numfmt --to=iec-i --suffix=B "$required_space")"
        log "ERROR" "Available: $(numfmt --to=iec-i --suffix=B "$available_space")"
        return 1
    fi
    
    return 0
}

get_free_space() {
    df --output=avail -B 1 "$WORK_DIR" | tail -n 1
}

update_progress() {
    local current="$1"
    local total="$2"
    local filename="$3"
    
    local percentage=0
    if [ "$total" -gt 0 ]; then
        percentage=$((current * 100 / total))
    fi
    
    printf '%s\n' "${percentage}:${filename}" > "${WORK_DIR}/.progress"
    _restrict_state_file "${WORK_DIR}/.progress"

    if ! $QUIET; then
        printf "\rProgress: [%-50s] %d%% (%d/%d) - %-30s\033[K" \
            "$(printf '#%.0s' $(seq 1 $((percentage / 2))))" \
            "$percentage" "$current" "$total" "$filename"
    fi
}

# Is the Kiwix server active, as seen by the SERVICE MANAGER (systemctl unit /
# service(8)), with a pidof fallback on hosts that have neither? Uses an
# init-system-agnostic chain so a false "stopped" (which would let us modify .zim
# files the server holds open -> corruption) is avoided on non-systemd hosts.
# Contrast _kiwix_serve_running, which checks the bare PROCESS only and is what
# the unprivileged pre-flight uses. pidof matches the exact kiwix-serve binary
# (unlike `pgrep -f`, which could match this updater's own command line).
_kiwix_service_active() {
    local unit
    if command -v systemctl >/dev/null 2>&1; then
        for unit in kiwix-serve kiwix; do
            systemctl is-active --quiet "$unit" 2>/dev/null && return 0
        done
        return 1
    elif command -v service >/dev/null 2>&1; then
        service kiwix status >/dev/null 2>&1 && return 0
        return 1
    elif command -v pidof >/dev/null 2>&1; then
        pidof kiwix-serve >/dev/null 2>&1
        return $?
    fi
    # No known service manager -> report inactive (caller decides).
    return 1
}

# Start/stop the Kiwix service via systemctl (trying both unit names) then
# service(8). Returns 0 on the first mechanism that succeeds. `9>&-` on the
# definition: nothing started from here (e.g. a sysvinit kiwix-serve) may inherit
# the run lock, while this script keeps holding it.
_kiwix_service_do() {
    local action="$1" unit
    if command -v systemctl >/dev/null 2>&1; then
        for unit in kiwix-serve kiwix; do
            if systemctl list-unit-files "${unit}.service" >/dev/null 2>&1 \
               && systemctl "$action" "$unit" 2>/dev/null; then
                return 0
            fi
        done
    fi
    if command -v service >/dev/null 2>&1; then
        service kiwix "$action" >/dev/null 2>&1 && return 0
    fi
    return 1
} 9>&-

manage_kiwix_service() {
    local action="$1"

    case "$action" in
        stop)
            # Poll (bounded by a count, not a clock): a sysvinit stop can take
            # longer than a fixed wait. Start keeps its fixed settle below, which
            # also catches a kiwix-serve that starts and then dies at once.
            log "INFO" "Stopping Kiwix service"
            if _kiwix_service_do stop; then
                local n=0
                while [ "$n" -lt "$SERVICE_STOP_POLLS" ]; do
                    sleep 0.5
                    if ! _kiwix_service_active; then
                        log "INFO" "Kiwix service stopped"
                        return 0
                    fi
                    n=$((n + 1))
                done
            fi
            log "ERROR" "Failed to stop Kiwix service"
            return 1
            ;;
        start)
            log "INFO" "Starting Kiwix service"
            if _kiwix_service_do start; then
                sleep 2
                if _kiwix_service_active; then
                    log "INFO" "Kiwix service started"
                    return 0
                fi
            fi
            log "ERROR" "Failed to start Kiwix service"
            return 1
            ;;
        status)
            _kiwix_service_active
            return $?
            ;;
    esac
}

# True iff a tool to detect a running process (pidof or pgrep) is available.
_kiwix_detection_available() {
    command -v pidof >/dev/null 2>&1 || command -v pgrep >/dev/null 2>&1
}

# Direct detection of a running kiwix-serve process. Deliberately does NOT go
# through _kiwix_service_active: that helper is systemctl-first and, on a systemd
# host, returns after checking the kiwix-serve system UNIT — so it would miss a
# bare, user-launched `kiwix-serve` process (exactly the case unprivileged mode
# must catch). pidof/pgrep -x match the exact binary name. Callers must first
# confirm _kiwix_detection_available: a bare "return 1" here means BOTH "no such
# process" AND "no tool to check", which the pre-flight must not conflate.
_kiwix_serve_running() {
    if command -v pidof >/dev/null 2>&1; then
        pidof kiwix-serve >/dev/null 2>&1 && return 0
    fi
    if command -v pgrep >/dev/null 2>&1; then
        pgrep -x kiwix-serve >/dev/null 2>&1 && return 0
    fi
    return 1
}

# Announce that the running-server safety guard was overridden. Emitted to the
# REAL stderr with printf — NOT via log(), whose WARN/INFO console output is gated
# behind `! ${QUIET}` (only ERROR bypasses it); -b sets QUIET, so a log()-only
# warning would be buried in the log file and the operator would never see that
# the guard was bypassed.
_warn_serving_override() {
    printf 'WARNING: %s; proceeding anyway (-y). Updated files may be served inconsistently until kiwix-serve is restarted.\n' "$1" >&2
    log "WARN" "Serving guard overridden: $1; proceeding (-y)."
}

# Unprivileged mode cannot stop/restart kiwix-serve (service management is
# root-only) and must not rewrite .zim/library files while a server is reading
# them. So for the mutating commands, refuse to run while kiwix-serve is up (or
# while we cannot even check — fail closed). This refusal is a DATA-SAFETY gate,
# not an interactive prompt, so it is overridden only by an EXPLICIT -y — NOT by
# the YES_TO_ALL that -b sets for prompt-suppression. A background (-b) run that
# finds kiwix-serve up (or can't detect it) therefore fails closed rather than
# silently corrupting a served collection; pass -b -y to override. Root mode is
# unaffected — it stops and restarts the service itself.
require_service_stopped_if_unprivileged() {
    ${UNPRIVILEGED} || return 0

    if ! _kiwix_detection_available; then
        if ${EXPLICIT_YES}; then
            _warn_serving_override "cannot verify kiwix-serve is stopped (no pidof/pgrep available)"
            return 0
        fi
        log "ERROR" "Cannot verify kiwix-serve is stopped (install procps for pidof/pgrep, or pass -y to override)."
        exit 1
    fi

    _kiwix_serve_running || return 0

    if ${EXPLICIT_YES}; then
        _warn_serving_override "kiwix-serve appears to be running"
        return 0
    fi
    log "ERROR" "kiwix-serve is running, please stop it and try again"
    exit 1
}

# Stop kiwix-serve before a mutation — ROOT MODE ONLY (unprivileged mode required
# it already be stopped via the pre-flight and cannot manage the service). Returns
# non-zero only when a running service could not be stopped. This is the single
# writer of the .kiwix_was_running marker that restore keys off. It is written
# BEFORE the stop: bash defers a signal trap until the foreground systemctl/sleep
# returns, so a marker written after the stop would miss a signal that arrived
# during it and leave kiwix-serve down. Starting an already-running service is
# harmless; the marker is withdrawn only if a failed stop left it running.
# This is the shared seam for the mode gate. When smart-update stops the service
# is a do_smart_update call-site policy (see there: up front in the foreground, at
# the end under -b), NOT part of this helper, so `update-library -b` still manages
# the service exactly as it did before.
stop_service_if_managed() {
    if ${UNPRIVILEGED}; then return 0; fi
    manage_kiwix_service status || return 0   # not running -> nothing to stop
    if ! touch "${WORK_DIR}/.kiwix_was_running"; then
        log "ERROR" "Cannot write ${WORK_DIR}/.kiwix_was_running — not stopping kiwix-serve"
        return 1
    fi
    _restrict_state_file "${WORK_DIR}/.kiwix_was_running"
    if ! manage_kiwix_service stop; then
        if manage_kiwix_service status; then rm -f "${WORK_DIR}/.kiwix_was_running"; fi
        return 1
    fi
}

# Restart kiwix-serve after a mutation iff we stopped it — ROOT MODE ONLY. The
# single seam for the restore guard (mirror of stop_service_if_managed). Returns
# non-zero when the start failed (the server is left down), so callers can fail
# the run; the marker is cleared either way.
restore_service_if_managed() {
    if ${UNPRIVILEGED} || [ ! -f "${WORK_DIR}/.kiwix_was_running" ]; then
        return 0
    fi
    log "INFO" "Restarting Kiwix service..."
    local rc=0
    manage_kiwix_service start || { rc=1; log "ERROR" "Failed to restore Kiwix service"; }
    rm -f "${WORK_DIR}/.kiwix_was_running"
    return "$rc"
}

# True when the bulk .zim transfer must stay HTTPS-only: either the operator
# forced it (--https-only) or there is no integrity hash to fall back on
# (--allow-unverified drops the SHA-256 gate, so transport is the only control).
# The transport decision is a function of these flags, NOT of per-file hash
# presence — the metalink hash is only fetched post-download, so hash presence
# is unknowable at resolve time. With ALLOW_UNVERIFIED=false (default) the hash
# is mandatory and fail-closed, so a tampered HTTP-mirror file is caught anyway.
_download_strict() {
    ${HTTPS_ONLY} || ${ALLOW_UNVERIFIED}
}

# The catalog 'length' is the file size rounded UP to a whole KiB (a 230348-byte
# ZIM is listed as 230400). Every catalog-vs-local size comparison goes through
# this. $1 = bytes -> echoes bytes rounded up to the next multiple of 1024.
_kib_ceil() {
    echo $(( ($1 + 1023) / 1024 * 1024 ))
}

get_remote_size() {
    local url="$1"
    local size
    # The .zim GET on the LB 302-redirects to a (possibly HTTP) mirror, so the
    # HEAD must follow the redirect (-L, bounded) to return a real size — else
    # the disk-fill ceiling and disk-space guards silently see "0 bytes". Scheme
    # policy mirrors the download: strict paths pin https and refuse an HTTP
    # mirror (correct fail-closed); the default path allows an HTTP mirror hop.
    local proto='=https'
    _download_strict || proto='=http,https'

    if [ -z "$url" ]; then
        return 1
    fi

    # --max-redirs 1: the only legitimate hop is the LB (kiwix.org, TLS) -> mirror.
    # Allowing a 2nd hop would let a (possibly HTTP) mirror redirect this root HEAD
    # at an internal/link-local/metadata host (SSRF); one hop can only be steered
    # by the TLS-authenticated kiwix.org LB.
    if size=$(curl -sLI --proto "$proto" --proto-redir "$proto" --max-redirs 1 --connect-timeout "$TIMEOUT" --max-time "$TIMEOUT" --fail -- "$url" | grep -i content-length | tail -n1 | awk '{print $2}' | tr -d '\r'); then
        # Mirror-supplied (possibly over HTTP) and used in $(( )): bound the
        # digits (no 64-bit wrap) and force base 10 (a leading 0 is octal in
        # bash, and "08" is a fatal arithmetic error that aborts the run).
        if [[ "$size" =~ ^[0-9]{1,15}$ ]]; then
            echo $(( 10#$size ))
            return 0
        fi
    fi

    return 1
}

# Fetch the Kiwix metalink (.meta4) for a canonical .zim URL and echo its
# SHA-256. The metalink is fetched from the canonical origin (lb.download.kiwix.org),
# NOT a mirror redirect, so the hash is authoritative even when the bytes come
# from a mirror.
# Return codes: 0 = 64-hex hash echoed on stdout;
#               2 = transient error (network/TLS/DNS/5xx) — caller may retry;
#               3 = definitive "no verifiable hash" (404/3xx/200-without-sha256).
fetch_metalink_sha256() {
    local zim_url="$1"
    # The integrity anchor MUST be fetched over authenticated transport; refuse a
    # non-https canonical URL rather than trust a MITM-forgeable hash.
    [[ "$zim_url" =~ ^https:// ]] || return 3
    local meta4_url="${zim_url}.meta4"
    local meta4_tmp="${TEMP_DIR}/$(basename "$zim_url").meta4"
    local code

    mkdir -p "${TEMP_DIR}" || return 2
    rm -f "$meta4_tmp"

    # No --fail: it collapses 404 and transient 5xx into one exit code. Capture
    # the HTTP status so retry (network/5xx) is distinguishable from block (4xx).
    # --proto pins https; --max-filesize bounds a hostile/oversized .meta4.
    # DELIBERATELY NO -L: the integrity anchor must come 200-direct from the
    # host analyze_updates already pinned to *.kiwix.org. Following a redirect
    # (even HTTPS-pinned) would let an off-kiwix host — reachable via an
    # open-redirect on any kiwix.org endpoint — supply the SHA-256, defeating the
    # sole integrity control. A redirected .meta4 therefore fails closed (rc 3).
    if ! code=$(curl -sS --connect-timeout "$TIMEOUT" --max-time "$TIMEOUT" \
        --proto '=https' --proto-redir '=https' --max-filesize 5242880 \
        -o "$meta4_tmp" -w '%{http_code}' -- "$meta4_url"); then
        rm -f "$meta4_tmp"
        return 2
    fi

    case "$code" in
        000|5??) rm -f "$meta4_tmp"; return 2 ;;  # network/TLS/DNS or server error -> retry
        200)     ;;                                # fall through to hash extraction
        *)       rm -f "$meta4_tmp"; return 3 ;;   # 4xx / 3xx / anything else -> block (fail-closed)
    esac

    # Extract <hash type="sha-256">HEX</hash> (ignore any md5/sha-1 hashes).
    # Strip whitespace first so a hash split across lines/indented in valid
    # metalink XML is still matched.
    local hash
    hash=$(tr -d '\n\r\t ' < "$meta4_tmp" \
        | grep -oiE '<hash[^>]*type="sha-?256"[^>]*>[0-9a-fA-F]{64}' \
        | grep -oiE '[0-9a-f]{64}' | head -n1 | tr 'A-F' 'a-f')
    rm -f "$meta4_tmp"

    if [[ "$hash" =~ ^[0-9a-f]{64}$ ]]; then
        echo "$hash"
        return 0
    fi
    return 3  # 200 but no usable sha-256 -> block
}

verify_downloaded_file() {
    local file="$1"
    local temp_file="$2"
    local canonical_url="$3"    # origin URL (for the authoritative metalink)
    local expected_bytes="${4:-}"  # authoritative catalog size — required; no mirror fallback

    log "INFO" "Verifying downloaded file: $file"

    if [ ! -r "$temp_file" ] || [ ! -s "$temp_file" ]; then
        log "ERROR" "Downloaded file is empty or unreadable"
        return 1
    fi

    # --- Integrity: SHA-256 from the Kiwix metalink (authoritative gate) ---
    local expected_hash rc
    expected_hash=$(fetch_metalink_sha256 "$canonical_url")
    rc=$?
    if [ "$rc" -eq 0 ]; then
        local actual_hash
        actual_hash=$(sha256sum "$temp_file" | awk '{print $1}')
        if [ "$actual_hash" != "$expected_hash" ]; then
            log "ERROR" "SHA-256 mismatch for $file — expected ${expected_hash}, got ${actual_hash} (tampered or corrupt)"
            return 1
        fi
        log "INFO" "SHA-256 verification passed"
        return 0
    elif [ "$rc" -eq 2 ]; then
        # Transient metalink-fetch error (rc 2): NOT a definitive integrity
        # failure. Signal the caller with a distinct rc 2 so it stops retrying
        # this file (a re-download could not be verified either while the
        # metalink is unreachable) instead of re-downloading a multi-GB .zim.
        log "WARN" "Transient error fetching metalink for $file — cannot verify this run"
        return 2
    else
        # rc == 3: no verifiable hash (404 / 3xx / 200 without sha-256).
        if ! ${ALLOW_UNVERIFIED}; then
            log "ERROR" "No SHA-256 metalink for $file — blocking install (pass --allow-unverified to accept size-only verification)"
            return 1
        fi
        log "WARN" "No SHA-256 metalink for $file — falling back to size-only check (--allow-unverified)"
    fi

    # --- Size fallback (reached ONLY under --allow-unverified) ---
    # Size-only verification requires an AUTHORITATIVE catalog size (from
    # opds.library.kiwix.org). A mirror-reported size is REFUSED: the mirror that
    # served the bytes would supply both the payload and its "expected" size,
    # which is circular and provides no integrity. With no catalog size we fail
    # closed rather than rubber-stamp the download.
    local expected_size actual_size
    if [[ "$expected_bytes" =~ ^[0-9]+$ ]] && [ "$expected_bytes" -gt 0 ]; then
        expected_size="$expected_bytes"
    else
        log "ERROR" "No authoritative catalog size for $file — refusing size-only install against a mirror-supplied size (circular, no integrity)"
        return 1
    fi
    actual_size=$(stat -c%s "$temp_file" 2>/dev/null) || return 1
    # Match at the catalog's KiB granularity (an exact match is accepted too).
    # Accepted limit of size-only mode: a payload up to 1023 bytes short of the
    # real file still passes, since the catalog cannot express anything finer.
    if [ "$actual_size" -ne "$expected_size" ] \
       && [ "$(_kib_ceil "$actual_size")" -ne "$expected_size" ]; then
        log "ERROR" "Size mismatch - expected: $expected_size, got: $actual_size"
        return 1
    fi
    log "WARN" "Size-only verification passed for $file (integrity NOT cryptographically verified)"
    return 0
}

backup_library_xml() {
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_file="${BACKUP_DIR}/library_zim_${timestamp}.xml"
    
    mkdir -p "${BACKUP_DIR}" || return 1
    
    # A missing or 0-byte library has nothing restorable (kiwix rejects 0-byte);
    # backing it up would only push a real backup out of the rotation.
    if [ ! -s "${ZIM_LIBRARY}" ]; then
        log "WARN" "No (non-empty) library file to backup"
        return 0
    fi
    
    if ! install -m 644 -- "${ZIM_LIBRARY}" "$backup_file"; then
        log "ERROR" "Failed to create backup"
        return 1
    fi
    
    log "INFO" "Library backed up to: $backup_file"
    
    # Keep only the 5 newest backups. NUL-separated end to end, so a BACKUP_DIR
    # with spaces or other odd characters rotates correctly.
    if ! find "${BACKUP_DIR}" -maxdepth 1 -type f -name 'library_zim_*.xml' -printf '%T@ %p\0' |
            sort -zrn | tail -zn +6 | cut -zd' ' -f2- | xargs -0r rm -f --; then
        log "WARN" "Could not rotate old library backups in ${BACKUP_DIR}"
    fi
    
    return 0
}

# Run aria2c under a hard file-size cap (ulimit -f, in 1024-byte blocks) so a
# hostile/MITM mirror cannot stream unbounded bytes to root's disk before the
# post-download hash runs (the HEAD-based ceiling is spoofable). Exceeding the
# cap raises SIGXFSZ, which kills aria2c (non-zero exit) and truncates the
# .part; the retry loop then fails cleanly. cap<=0 means "uncapped".
# $1 = cap in KiB; remaining args = aria2c argv.
_aria2c_capped() {
    local cap="$1"; shift
    if [ "$cap" -gt 0 ]; then
        # Fail closed: if the rlimit cannot be set, do NOT run aria2c uncapped.
        ( ulimit -f "$cap" 2>/dev/null || exit 1; aria2c "$@" )
    else
        aria2c "$@"
    fi
}

# A partial is the pair X.part + X.part.aria2 (aria2c's control file), both
# regular files and neither a symlink.
_is_pair() {
    local f
    for f in "$1" "$1.aria2"; do
        [ -f "$f" ] && [ ! -L "$f" ] || return 1
        # Ours and singly linked: a .part that predates the trust gate (foreign
        # owner) or is hard-linked elsewhere must not be written into by aria2c
        # and renamed into place as the served .zim.
        [ "$(stat -c '%u %h' -- "$f" 2>/dev/null)" = "${EXPECTED_OWNER_UID} 1" ] || return 1
    done
}

# A pair this run may resume. Never under --allow-unverified: with only a size
# check left, a spliced or foreign .part could pass verification.
_resumable_pair() {
    ! ${ALLOW_UNVERIFIED} && _is_pair "$1"
}

# Bytes already allocated on disk by a resumable partial of $1 (the final .zim
# path), else 0. Allocated, not apparent: partials are sparse. Always prints one
# integer and returns 0 (callers run under set -e and do arithmetic on it).
_partial_alloc_bytes() {
    local part="${TEMP_DIR}/$(basename "$1").part"
    local blocks="" bsize=""
    if _resumable_pair "$part"; then
        read -r blocks bsize < <(stat -c '%b %B' -- "$part" 2>/dev/null) || true
    fi
    if [[ "$blocks" =~ ^[0-9]+$ ]] && [[ "$bsize" =~ ^[0-9]+$ ]]; then
        echo $(( 10#$blocks * 10#$bsize ))
    else
        echo 0
    fi
}

# Empty TEMP_DIR except recent partials: a *.zim.part pair (_is_pair) whose
# control file is under PARTIAL_MAX_AGE_DAYS old is kept (both halves); orphans,
# metalinks, .err files, symlinks and subdirectories are removed. Deliberately
# ignores --allow-unverified, so such a run leaves other files' partials for the
# next verified run. find without -L does not descend a symlinked TEMP_DIR.
# Always returns 0 (runs from cleanup/clean_state under set -e).
_prune_temp_dir() {
    [ -d "${TEMP_DIR}" ] || return 0
    local entry part
    while IFS= read -r -d '' entry; do
        case "$entry" in
            *.zim.part) part="$entry" ;;
            *.zim.part.aria2) part="${entry%.aria2}" ;;
            *) part="" ;;
        esac
        if [ -n "$part" ] && _is_pair "$part" &&
            [ -n "$(find "$part.aria2" -maxdepth 0 -mtime "-${PARTIAL_MAX_AGE_DAYS}" 2>/dev/null)" ]; then
            continue
        fi
        rm -rf -- "$entry" 2>/dev/null || true
    done < <(find "${TEMP_DIR}" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)
    return 0
}

# Undated stem of a .zim name, as find_latest_zim matches it: X_2025-01.zim and
# X_2025-01a.zim -> X.
_zim_stem() {
    local stem="${1%.zim}"
    [[ "$stem" =~ ^(.+)_${ZIM_VER_RE}$ ]] && stem="${BASH_REMATCH[1]}"
    printf '%s' "$stem"
}

# Space is short: discard partials of files the catalog no longer offers (e.g.
# a version it has since replaced). They can never resume, yet would otherwise
# refuse every run until pruned by age. Each argument protects partials:
# <name>.zim.part of a file the catalog offers (exact), or the stem of a local
# file skipped this run (<stem>.zim.part, <stem>_YYYY-MM[x].zim.part), so a
# transient catalog glitch does not cost a skipped file its progress (except a
# title find_latest_zim maps to an alias name, e.g. wikihow_en_maxi; at worst a
# re-download). Echoes bytes freed.
_drop_dead_partials() {
    local part base keep alive blocks freed=0
    while IFS= read -r -d '' part; do
        base=$(basename "$part")
        alive=false
        for keep in "$@"; do
            case "$base" in
                "$keep"|"$keep.zim.part"|"$keep"_[0-9][0-9][0-9][0-9]-[0-9][0-9].zim.part|"$keep"_[0-9][0-9][0-9][0-9]-[0-9][0-9][[:lower:]].zim.part) alive=true; break ;;
            esac
        done
        if $alive; then continue; fi
        blocks=$(stat -c '%b' -- "$part" 2>/dev/null) || blocks=0
        [[ "$blocks" =~ ^[0-9]+$ ]] || blocks=0
        if rm -f -- "$part" "$part.aria2"; then
            freed=$(( freed + blocks * 512 ))
        fi
    done < <(find "${TEMP_DIR}" -maxdepth 1 -type f -name '*.zim.part' -print0 2>/dev/null)
    echo "$freed"
}

download_file() {
    local url="$1"
    local output="$2"
    local expected_bytes="${3:-}"   # authoritative catalog size (0/empty = unknown)
    local filename=$(basename "$output")
    local temp_file="${TEMP_DIR}/$(basename "$output").part"

    # URL validation — require HTTPS (reject plain http: a network attacker
    # could strip TLS and serve tampered content; the metalink hash below only
    # helps if the transport itself is authenticated).
    if [[ ! "$url" =~ ^https:// ]]; then
        log "ERROR" "Refusing non-HTTPS URL: $url"
        return 1
    fi

    mkdir -p "${TEMP_DIR}" || return 1

    # Resume an interrupted download: aria2c resumes from the .part only when its
    # .aria2 control file is present. --continue is never passed, so without the
    # control file aria2c restarts from 0 and a stale or foreign .part is never
    # blindly appended to. Under --allow-unverified (size-only verification) or
    # with an incomplete pair, start clean. A kept pair that hits an early return
    # below (resolve failure, mirror size, user decline) waits for the next run.
    if _resumable_pair "$temp_file"; then
        log "INFO" "Resuming ${filename} ($(numfmt --to=iec-i --suffix=B "$(_partial_alloc_bytes "$output")") already on disk)"
    else
        rm -f -- "$temp_file" "$temp_file.aria2"
    fi

    # Confirm download if not auto-yes
    if ! ${YES_TO_ALL}; then
        # Guard the size BY VALUE, not by exit status: `local size=$(...)` always
        # returns 0 (local masks the command-substitution exit, SC2155), so a
        # strict-path empty size would still reach numfmt and error. On the
        # strict path an HTTP-only mirror correctly yields no size.
        local size
        size=$(get_remote_size "$url")
        [[ "$size" =~ ^[0-9]+$ ]] || size=0
        read -p "Download $filename ($(numfmt --to=iec-i --suffix=B "$size"))? [y/N] " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log "INFO" "Skipping $filename"
            # return 2 = user-declined skip (NOT a failure). The caller treats 2
            # as a clean 'continue'; a return 0 here would be read as success and
            # trigger the destructive rm -f/library-transition on a file that was
            # never downloaded.
            return 2
        fi
    fi
    
    # Resolve the final URL after redirects. Constrain the resolve AT THE CURL
    # LAYER: non-http(s) schemes (file://, gopher://, ...) are refused during
    # resolution — before any post-hoc regex — and the redirect budget is capped
    # at ONE hop (--max-redirs 1): the only legitimate hop is the LB (kiwix.org,
    # TLS) -> mirror. Allowing a 2nd hop would let a (possibly HTTP) mirror
    # redirect this root request at an internal/metadata host (SSRF); a single
    # hop can only be steered by the TLS-authenticated kiwix.org LB. On the
    # default (hash-gated) path an HTTP mirror hop is allowed; strict paths pin
    # https.
    local resolve_proto='=http,https'
    _download_strict && resolve_proto='=https'

    local final_url
    if ! final_url=$(curl -sLI --proto "$resolve_proto" --proto-redir "$resolve_proto" \
        --max-redirs 1 -o /dev/null -w '%{url_effective}' -- "$url") || [ -z "$final_url" ]; then
        # Do NOT fall back to the un-resolved LB URL: the LB always 302s the
        # .zim, and aria2c would follow that redirect unchecked (it cannot
        # restrict redirect schemes or hops). The hash still gates integrity,
        # but transport safety comes from resolving here — so a resolve failure
        # is a genuine failure: WARN + return 1.
        log "ERROR" "Failed to resolve download URL for $filename — skipping"
        return 1
    fi

    # Validate the resolved scheme. https is always fine; http only on the
    # default (hash-gated) path; anything else is refused (anchored so
    # 'httpfoo://' can't slip through).
    if _download_strict; then
        if [[ ! "$final_url" =~ ^https:// ]]; then
            log "ERROR" "Refusing non-HTTPS redirect target under strict transport: $final_url"
            return 1
        fi
    elif [[ ! "$final_url" =~ ^https?:// ]]; then
        log "ERROR" "Refusing non-HTTP(S) redirect target: $final_url"
        return 1
    fi

    # Mirror size sanity (M4): if the authoritative catalog size is known, refuse
    # a mirror that advertises materially more than it (a hostile mirror padding
    # Content-Length to fill the disk as root). 1% slack absorbs benign variance.
    if [[ "$expected_bytes" =~ ^[0-9]+$ ]] && [ "$expected_bytes" -gt 0 ]; then
        local mirror_bytes
        if mirror_bytes=$(get_remote_size "$final_url") && [[ "$mirror_bytes" =~ ^[0-9]+$ ]]; then
            local ceiling=$(( expected_bytes + expected_bytes / 100 + 4096 ))
            if [ "$mirror_bytes" -gt "$ceiling" ]; then
                log "ERROR" "Mirror advertises ${mirror_bytes} bytes for ${filename}, exceeds catalog size ${expected_bytes} — refusing (possible disk-fill)"
                return 1
            fi
        fi
    fi
    
    # Aria2c options
    local aria_opts=(
        --max-connection-per-server="${PARALLEL_CONNECTIONS}"
        --min-split-size=1M
        --file-allocation=none
        --dir="$(dirname "$temp_file")"
        --out="$(basename "$temp_file")"
        --check-certificate=true
        --allow-overwrite=true
        --max-tries=3
        --retry-wait=3
        --connect-timeout=60
        --remote-time=true
        --console-log-level=error
        # Plain (uncoloured) error lines, so they can be copied into the log.
        --enable-color=false
        # The URL is already the curl-resolved terminal mirror URL (served
        # 200-direct), so aria2c normally sees no redirect. aria2c has NO option
        # to disable or bound redirects (there is no --max-redirect; passing one
        # makes it exit 28 before downloading), so a mirror re-redirect would be
        # followed. Integrity does not depend on this: the payload is gated by the
        # metalink SHA-256 (or, with --allow-unverified, the catalog size) before
        # it replaces anything, and the response body never leaves this host.
    )
    
    [ -n "${MAX_SPEED}" ] && aria_opts+=(--max-download-limit="${MAX_SPEED}")

    # Apply output-verbosity opts once, before the retry loop (appending them
    # inside the loop would duplicate flags on every retry). Quiet mode hides
    # the progress readout but NOT aria2c's error lines (no --quiet), so the
    # cause of a failure still reaches the log in -q/-b/cron runs.
    if ! ${QUIET}; then
        aria_opts+=(--show-console-readout=true)
    else
        aria_opts+=(--show-console-readout=false)
    fi
    local aria_err="${temp_file}.err"

    # Compute the hard download byte cap (KiB) for _aria2c_capped. Prefer the
    # authoritative catalog ceiling (expected + 1% + 4K); if the catalog size is
    # unknown, bound by free space minus a 512 MiB margin so an unbounded hostile
    # stream still can't fully exhaust the disk. cap=0 => leave uncapped (already
    # low on space, where check_disk_space governs, or free space unreadable).
    local fcap_kib=0
    if [[ "$expected_bytes" =~ ^[0-9]+$ ]] && [ "$expected_bytes" -gt 0 ]; then
        fcap_kib=$(( (expected_bytes + expected_bytes / 100 + 4096) / 1024 + 1 ))
    else
        # Unknown catalog size: bound by free space, reserving a margin (the
        # smaller of 512 MiB or 10% of free) so a hostile unbounded stream can
        # never drive the disk to 0 — even when free space is already low. The
        # cap bounds the whole file, so a resumed partial's bytes count toward it.
        local free_kib reserve_kib alloc_kib
        free_kib=$(( $(get_free_space) / 1024 ))
        if [ "$free_kib" -gt 0 ]; then
            reserve_kib=$(( 512 * 1024 ))
            [ "$reserve_kib" -gt $(( free_kib / 10 )) ] && reserve_kib=$(( free_kib / 10 ))
            alloc_kib=$(( $(_partial_alloc_bytes "$output") / 1024 ))
            fcap_kib=$(( free_kib + alloc_kib - reserve_kib ))
        fi
        # df unreadable (free_kib=0) or the subtraction non-positive: fall back to
        # a large absolute ceiling that exceeds any real .zim (~110 GiB max) yet
        # still bounds a truly-infinite hostile stream, rather than uncapped.
        [ "$fcap_kib" -le 0 ] && fcap_kib=$(( 256 * 1024 * 1024 ))
    fi

    local retry_count=0
    local success=false

    while [ $retry_count -lt $MAX_RETRIES ] && [ "$success" = false ]; do
        retry_count=$((retry_count + 1))
        
        if [ $retry_count -gt 1 ]; then
            log "INFO" "Retry attempt $retry_count for $filename"
            sleep 5
        fi
        
        # download_file is called via `if download_file ...; then dl_rc=0; else
        # dl_rc=$?; fi`, whose `if` condition suspends set -e/pipefail in this
        # body, so a failed aria2c pipeline falls through to the retry logic
        # below instead of aborting the script.
        # One filter for both modes: it draws the progress bar (non-quiet only)
        # and collects aria2c's error lines into $aria_err, which is logged
        # below if the download fails.
        local aria_rc
        : > "$aria_err"
        _aria2c_capped "$fcap_kib" "${aria_opts[@]}" -- "$final_url" 2>&1 | \
            awk -v filename="$filename" -v quiet="${QUIET}" -v errfile="$aria_err" '
            /\[#.*\]/ {
                if (quiet == "true") next
                match($0, /([0-9]+)%/)
                pct = substr($0, RSTART, RLENGTH-1)
                match($0, /DL:([0-9.]+[KMGT]?i?B\/s)/)
                speed = substr($0, RSTART+3, RLENGTH-3)
                bar = ""
                for(i=0; i<pct/2; i++) bar = bar "#"
                for(i=pct/2; i<50; i++) bar = bar "-"
                printf "\rDownloading %s: [%s] %3d%% %s", filename, bar, pct, speed
                fflush()
                next
            }
            /ERROR|errorCode=|unrecognized option/ { print >> errfile }'
        aria_rc=${PIPESTATUS[0]}
        ${QUIET} || echo

        if [ "$aria_rc" -eq 0 ] && [ -f "$temp_file" ] && [ -s "$temp_file" ]; then
            # Three-way branch on the verify exit code (this whole body runs with
            # set -e suspended — download_file is called via `if download_file`),
            # so verify_downloaded_file's non-zero rc does NOT abort here:
            #   0 => verified            -> install (mv temp_file -> output)
            #   2 => TRANSIENT metalink  -> fail this file WITHOUT re-downloading:
            #        the hash is unreachable right now, so another multi-GB
            #        download could not be verified either. Break the OUTER retry
            #        loop; the next scheduled run tries again from scratch.
            #   1 => DEFINITIVE failure  -> discard (rm) and let the outer loop
            #        re-download from scratch (hash mismatch / no-hash-block / size).
            local vrc
            verify_downloaded_file "$output" "$temp_file" "$url" "$expected_bytes"
            vrc=$?
            case "$vrc" in
                0)
                    success=true
                    if mv "$temp_file" "$output"; then
                        log "INFO" "Successfully downloaded $filename"
                    else
                        log "ERROR" "Failed to move $temp_file to $output"
                        success=false
                    fi
                    ;;
                2)
                    log "ERROR" "Metalink temporarily unavailable for $filename — not installing unverified; will retry on the next run"
                    rm -f -- "$temp_file" "$temp_file.aria2"
                    success=false
                    break   # exit the OUTER retry loop; do NOT re-run aria2c
                    ;;
                *)
                    log "ERROR" "File verification failed for $filename"
                    rm -f -- "$temp_file" "$temp_file.aria2"   # definitive => discard, allow outer re-download
                    ;;
            esac
        else
            log "ERROR" "Download failed for $filename (aria2c exit ${aria_rc})"
            local aria_line
            while IFS= read -r aria_line; do
                log "ERROR" "aria2c: ${aria_line}"
            done < "$aria_err"
            # Keep the pair for resuming only after a transient failure (2 timeout,
            # 6 network, 7 interrupted, 19 DNS, 29 server busy, or a signal other
            # than SIGXFSZ=153). Anything else (1 e.g. remote size changed, 8 no
            # Range support, 28 bad option, cap overflow, rc 0 with no data) would
            # fail the same way again, so start over.
            local keep=false
            case "$aria_rc" in
                2|6|7|19|29) keep=true ;;
                *) [ "$aria_rc" -gt 128 ] && [ "$aria_rc" -ne 153 ] && keep=true ;;
            esac
            if ! $keep || ! _resumable_pair "$temp_file"; then
                rm -f -- "$temp_file" "$temp_file.aria2"
            fi
        fi
    done
    rm -f -- "$aria_err"

    [ "$success" = true ]
} 9>&-   # aria2c and its helpers must not inherit the run lock (see acquire_run_lock)

check_status() {
    local pid
    if ! pid=$(read_trusted_pid); then
        echo "No active update process found"
        return 1
    fi

    if ! kill -0 "$pid" 2>/dev/null; then
        echo "No active update process found"
        rm -f "${PID_FILE}"
        return 1
    fi

    echo "Update process is running (PID: $pid)"
    
    if [ -f "${STATUS_FILE}" ]; then
        local status=$(cat "${STATUS_FILE}")
        if [ -f "${CRITERIA_FILE}" ]; then
            local criteria=$(cat "${CRITERIA_FILE}")
            echo "Current status: ${status} (criteria: ${criteria})"
        else
            echo "Current status: ${status}"
        fi
    fi
    
    return 0
}

update_status() {
    local status="$1"
    printf '%s\n' "$status" > "${STATUS_FILE}"
    _restrict_state_file "${STATUS_FILE}"
    date +%s > "${WORK_DIR}/.heartbeat"
    _restrict_state_file "${WORK_DIR}/.heartbeat"
}

analyze_updates() {
    FILES_TO_UPDATE=()

    # Early exit for parent process
    if [ "${BACKGROUND}" = "true" ] && [ -z "${KIWIX_BACKGROUND:-}" ]; then
        return 0
    fi
    
    log "INFO" "Analyzing available updates (criteria: ${UPDATE_CRITERIA})..."
    update_status "Analyzing updates (${UPDATE_CRITERIA})"
    
    local total_updates=0
    local total_download_size=0
    local total_partial_credit=0   # bytes already on disk in resumable partials
    local kept_parts=()            # partials _drop_dead_partials must keep (offered names, skipped stems)
    local skipped_files=0
    local unmatched=()             # local ZIMs the catalog no longer lists (renamed or withdrawn)
    local unknown_sizes=0
    
    # Show table header
    if [ -z "${KIWIX_BACKGROUND:-}" ] && [ "${QUIET}" != "true" ]; then
        printf "%-40s %-15s %-15s %-15s %s\n" \
            "File" "Local Size" "Remote Size" "Status" "Details"
        echo "------------------------------------------------------------------------------------------------"
    fi

    # Find ZIM files
    local zim_files=()
    while IFS= read -r -d '' file; do
        zim_files+=("$file")
    done < <(find "${WORK_DIR}" -maxdepth 1 -type f -name "*.zim" -print0 | sort -z)
    
    if [ ${#zim_files[@]} -eq 0 ]; then
        log "INFO" "No ZIM files found in ${WORK_DIR}"
        return 0
    fi
    
    # Fetch library data
    if ! fetch_library_data; then
        log "ERROR" "Failed to fetch library data"
        return 1
    fi

    # Process each file
    for f in "${zim_files[@]}"; do
        local filename=$(basename "$f")
        local local_size=0
        
        if [ -f "$f" ]; then
            local_size=$(stat -c%s "$f")
        fi
        
        # Find latest version in library
        local latest_info
        if ! latest_info=$(find_latest_zim "$filename"); then
            printf "%-40s %-15s %-15s %-15s %s\n" \
                "$(_disp "$filename")" \
                "$(numfmt --to=iec-i --suffix=B "$local_size")" \
                "-" \
                "SKIPPED" \
                "No match in library"
            skipped_files=$((skipped_files + 1))
            unmatched+=("$(_disp "$filename")")
            kept_parts+=("$(_zim_stem "$filename")")
            continue
        fi
        
        # Parse the result
        local latest_filename latest_path remote_size
        latest_filename=$(echo "$latest_info" | cut -d'|' -f2)
        latest_path=$(echo "$latest_info" | cut -d'|' -f3)
        remote_size=$(echo "$latest_info" | cut -d'|' -f4)

        # The catalog 'length' attribute is optional. When it is missing, the
        # 'size' criterion reports "Unknown" (it has no other signal); 'newer'
        # and 'all' fall back to date-only comparison rather than letting an
        # empty value drive a wrong "up to date" verdict or an arithmetic error.
        # Bounded and forced to base 10 before any $(( )): see get_remote_size.
        local size_known=true
        if [[ "$remote_size" =~ ^[0-9]{1,15}$ ]]; then
            remote_size=$(( 10#$remote_size ))
        else
            size_known=false
            remote_size=0
            unknown_sizes=$((unknown_sizes + 1))
            log "WARN" "No catalog size for ${filename} — using date-only comparison"
        fi
        # An unchanged file is 1-1023 bytes "smaller" than its KiB-rounded catalog
        # entry. "Larger" therefore means larger than the local size rounded up
        # (see _kib_ceil), or every up-to-date file is re-downloaded each run.
        local local_kib_size
        local_kib_size=$(_kib_ceil "$local_size")

        # latest_path now holds the absolute acquisition URL from the v2 feed.
        local latest_url="$latest_path"
        # Host-pin (supersedes the old relative-path allowlist): the feed hands
        # us an absolute URL on the kiwix.org domain (the LB). Require a literal
        # lowercase https:// scheme (consistent with the downstream
        # case-sensitive checks in download_file / fetch_metalink_sha256), pin
        # the host to *.kiwix.org, and reject any '..' traversal or
        # whitespace/control char. A hostile catalog cannot steer the download
        # or the metalink anchor off-domain. NB: this pins the URL the FEED hands
        # us (the LB/metalink), not the eventual rotating mirror (see C5).
        local _url_host=""
        if [[ "$latest_url" =~ ^https://([^/]+)(/|$) ]]; then
            _url_host="${BASH_REMATCH[1],,}"   # lowercase the host only
        fi
        if [[ ! "$latest_url" =~ ^https:// ]] \
           || [ -z "$_url_host" ] \
           || [[ ! "$_url_host" =~ ^([a-z0-9-]+\.)*kiwix\.org$ ]] \
           || [[ "$latest_url" == *..* ]] \
           || [[ "$latest_url" =~ [[:space:][:cntrl:]] ]]; then
            log "WARN" "Skipping ${filename}: untrusted catalog URL '$(_disp "$latest_url")'"
            skipped_files=$((skipped_files + 1))
            kept_parts+=("$(_zim_stem "$filename")")
            continue
        fi
        local latest_name="${latest_filename%.zim}"
        # Validate the catalog-derived name before it builds any path (the
        # partial-download credit below stats TEMP_DIR/<name>.zim.part).
        if ! is_safe_zim_name "$latest_name"; then
            log "WARN" "Skipping ${filename}: unsafe catalog name '$(_disp "$latest_name")'"
            skipped_files=$((skipped_files + 1))
            kept_parts+=("$(_zim_stem "$filename")")
            continue
        fi
        kept_parts+=("${latest_name}.zim.part")   # the catalog offers this file: its partial can resume

        local status="Up to date"
        local details=""
        local update_needed=false
        
        # Check based on criteria
        case "$UPDATE_CRITERIA" in
            size)
                if ! $size_known; then
                    status="Unknown"
                    details="missing catalog size"
                elif [ "$remote_size" -gt "$local_kib_size" ]; then
                    status="Update needed"
                    local size_diff=$((remote_size - local_kib_size))
                    details="Size increased by $(numfmt --to=iec-i --suffix=B $size_diff)"
                    update_needed=true
                    if [ "$latest_name.zim" != "$filename" ]; then
                        details="$details (new: $latest_name)"
                    fi
                elif [ "$remote_size" -lt "$local_size" ]; then
                    status="Up to date"
                    details="Remote is smaller"
                else
                    status="Up to date"
                    details="Same size"
                fi
                ;;

            newer)
                local remote_date="" local_date="" local_timestamp="" remote_timestamp=""
                
                # Extract version from remote filename (the timestamp drops a
                # same-month suffix letter: `date` cannot parse 2026-11a-01)
                if [[ "$latest_name" =~ _(${ZIM_VER_RE})$ ]]; then
                    remote_date="${BASH_REMATCH[1]}"
                    remote_timestamp=$(date -d "${remote_date%[[:lower:]]}-01" +%s 2>/dev/null || echo "0")
                fi

                # Extract version from local filename
                if [[ "${filename%.zim}" =~ _(${ZIM_VER_RE})$ ]]; then
                    local_date="${BASH_REMATCH[1]}"
                    local_timestamp=$(date -d "${local_date%[[:lower:]]}-01" +%s 2>/dev/null || echo "0")
                else
                    local_timestamp=$(stat -c%Y "$f")
                fi
                
                local is_newer=false
                if [ -n "$local_date" ] && [ -n "$remote_date" ]; then
                    [[ "$remote_date" > "$local_date" ]] && is_newer=true
                elif [ -n "$remote_timestamp" ] && [ "$remote_timestamp" -gt "$local_timestamp" ]; then
                    is_newer=true
                fi
                
                if $is_newer; then
                    # Check if suspiciously smaller (only when the remote size is known)
                    local size_ratio=100
                    if $size_known && [ "$local_size" -gt 0 ]; then
                        size_ratio=$(( (remote_size * 100) / local_size ))
                    fi

                    if $size_known && [ "$size_ratio" -lt 50 ]; then
                        status="Up to date"
                        details="Newer but different content"
                    else
                        status="Update needed"
                        details="Newer version: $latest_name"
                        update_needed=true
                    fi
                else
                    status="Up to date"
                    details="Not newer"
                fi
                ;;
                
            all)
                local should_update=false
                local reasons=()
                
                # Check size (only when the remote size is known)
                if $size_known && [ "$remote_size" -gt "$local_kib_size" ]; then
                    local size_diff=$((remote_size - local_kib_size))
                    reasons+=("size +$(numfmt --to=iec-i --suffix=B $size_diff)")
                    should_update=true
                fi
                
                # Check if newer
                local remote_date="" local_date="" local_timestamp="" remote_timestamp=""

                if [[ "$latest_name" =~ _(${ZIM_VER_RE})$ ]]; then
                    remote_date="${BASH_REMATCH[1]}"
                    remote_timestamp=$(date -d "${remote_date%[[:lower:]]}-01" +%s 2>/dev/null || echo "0")
                fi

                if [[ "${filename%.zim}" =~ _(${ZIM_VER_RE})$ ]]; then
                    local_date="${BASH_REMATCH[1]}"
                    local_timestamp=$(date -d "${local_date%[[:lower:]]}-01" +%s 2>/dev/null || echo "0")
                else
                    local_timestamp=$(stat -c%Y "$f")
                fi

                # Both versioned: compare as strings, like the newer arm, so a
                # same-month rebuild (2026-11 -> 2026-11a) counts as newer.
                local is_newer=false
                if [ -n "$local_date" ] && [ -n "$remote_date" ]; then
                    [[ "$remote_date" > "$local_date" ]] && is_newer=true
                elif [ -n "$remote_timestamp" ] && [ "$remote_timestamp" -gt "$local_timestamp" ]; then
                    is_newer=true
                fi

                if $is_newer; then
                    reasons+=("newer: $latest_name")
                    if [ ${#reasons[@]} -eq 1 ]; then  # Only newer, not bigger
                        local size_ratio=100
                        if $size_known && [ "$local_size" -gt 0 ]; then
                            size_ratio=$(( (remote_size * 100) / local_size ))
                        fi
                        # Unknown size can't veto a newer version, so treat as pass
                        if ! $size_known || [ "$size_ratio" -ge 90 ]; then
                            should_update=true
                        fi
                    else
                        should_update=true
                    fi
                fi

                if $should_update; then
                    status="Update needed"
                    details=$(IFS=","; echo "${reasons[*]}")
                    update_needed=true
                else
                    status="Up to date"
                    if $size_known && [ "$remote_size" -lt "$local_size" ]; then
                        details="Remote is smaller"
                    else
                        details="Same version"
                    fi
                fi
                ;;
        esac
        
        if $update_needed; then
            total_updates=$((total_updates + 1))
            total_download_size=$((total_download_size + remote_size))
            if $size_known; then
                local credit
                credit=$(_partial_alloc_bytes "${WORK_DIR}/${latest_name}.zim")
                [ "$credit" -gt "$remote_size" ] && credit=$remote_size
                total_partial_credit=$((total_partial_credit + credit))
            fi
            FILES_TO_UPDATE+=("$f|$latest_url|$latest_name|$remote_size")
        fi
        
        # Print status line
        local remote_size_disp="-"
        $size_known && remote_size_disp=$(numfmt --to=iec-i --suffix=B "$remote_size")
        if [ -z "${KIWIX_BACKGROUND:-}" ] && [ "${QUIET}" != "true" ]; then
            printf "%-40s %-15s %-15s %-15s %s\n" \
                "$(_disp "$filename")" \
                "$(numfmt --to=iec-i --suffix=B "$local_size")" \
                "$remote_size_disp" \
                "$status" \
                "$details"
        fi
    done
    
    # Print summary
    if [ -z "${KIWIX_BACKGROUND:-}" ] && [ "${QUIET}" != "true" ]; then
        echo
    fi
    
    log "INFO" "Updates needed: ${total_updates}"
    [ $skipped_files -gt 0 ] && log "INFO" "Files skipped: ${skipped_files}"
    # They never update again. A rename needs a find_latest_zim rename-table
    # entry; a withdrawn title stays at its last version.
    if [ ${#unmatched[@]} -gt 0 ]; then
        local unmatched_list
        printf -v unmatched_list '%s, ' "${unmatched[@]}"
        log "WARN" "${#unmatched[@]} local ZIM(s) match nothing in the Kiwix catalog (renamed or withdrawn upstream): ${unmatched_list%, }"
    fi
    log "INFO" "Total download size needed: $(numfmt --to=iec-i --suffix=B "${total_download_size}")"
    [ $unknown_sizes -gt 0 ] && log "INFO" "Note: ${unknown_sizes} file(s) had no catalog size — total is a lower bound; per-file space is re-checked at download time"
    
    # Check available space
    if [ $total_updates -gt 0 ]; then
        local free_space=$(get_free_space)
        # Bytes already on disk in resumable partials need no new space.
        local still_needed=$((total_download_size - total_partial_credit))
        [ "$still_needed" -lt 0 ] && still_needed=0
        # Never on check-updates (it only reports). Skipped files' partials are
        # protected by stem in kept_parts (a skip may be a transient glitch).
        if [ "${still_needed}" -gt "${free_space}" ] && [ "${COMMAND:-}" != check-updates ]; then
            local freed
            freed=$(_drop_dead_partials "${kept_parts[@]}")
            if [ "$freed" -gt 0 ]; then
                log "INFO" "Discarded partial downloads of files the catalog no longer offers ($(numfmt --to=iec-i --suffix=B "$freed"))"
                free_space=$(get_free_space)
            fi
        fi
        if [ "${still_needed}" -gt "${free_space}" ]; then
            log "ERROR" "Not enough free space for updates"
            log "ERROR" "Required: $(numfmt --to=iec-i --suffix=B "${still_needed}")"
            log "ERROR" "Available: $(numfmt --to=iec-i --suffix=B "${free_space}")"
            return 1
        fi
    fi
    
    return 0
}

do_smart_update() {
    local update_success=true
    local total_updated=0
    local total_failed=0
    local reconcile_partial=0 attempted=0 stopped_early=false

    log "INFO" "Starting smart update process"
    update_status "Starting update process"

    if [ ${#FILES_TO_UPDATE[@]} -eq 0 ]; then
        log "INFO" "No files need updating"
        return 0
    fi

    # Pre-flight, before the service is stopped or any file is touched: every
    # per-file reconcile below must be able to succeed, or old files would be
    # deleted with their entries left dangling. Also takes the run's one backup.
    # (This function runs with errexit suspended, so each check is explicit.)
    if ! _lib_preflight; then
        log "ERROR" "Library pre-flight failed — aborting before any download"
        return 1
    fi

    # Stop Kiwix service if running (root mode only; see stop_service_if_managed).
    # The background CHILD skips this so kiwix-serve keeps serving through long
    # downloads; it restarts the service once at the end instead (below).
    if [ -z "${KIWIX_BACKGROUND:-}" ] && ! stop_service_if_managed; then
        log "ERROR" "Cannot proceed without stopping Kiwix service"
        return 1
    fi

    # Process updates
    for entry in "${FILES_TO_UPDATE[@]}"; do
        attempted=$((attempted + 1))
        local f remote_url new_name expected_bytes
        f=$(echo "$entry" | cut -d'|' -f1)
        remote_url=$(echo "$entry" | cut -d'|' -f2)
        new_name=$(echo "$entry" | cut -d'|' -f3)
        expected_bytes=$(echo "$entry" | cut -d'|' -f4)   # authoritative catalog size (0/empty = unknown)

        # Reject a catalog-derived name that isn't a safe bare filename before
        # it is used to build an on-disk path (C2 — traversal/option injection).
        if ! is_safe_zim_name "$new_name"; then
            log "WARN" "Skipping entry with unsafe name: '${new_name}'"
            total_failed=$((total_failed + 1))
            if ! $CONTINUE_ON_ERROR; then
                break
            fi
            continue
        fi

        local filename=$(basename "$f")
        local new_filepath="${WORK_DIR}/${new_name}.zim"

        log "INFO" "Updating ${filename} to ${new_name}.zim"
        
        # Check space if different files
        if [ "$f" != "$new_filepath" ]; then
            local remote_size needed
            if remote_size=$(get_remote_size "$remote_url"); then
                # A resumable partial's bytes are already on disk.
                needed=$(( remote_size - $(_partial_alloc_bytes "$new_filepath") ))
                [ "$needed" -lt 0 ] && needed=0
                if ! check_disk_space "$needed"; then
                    log "ERROR" "Not enough space for ${new_name}.zim"
                    total_failed=$((total_failed + 1))
                    if ! $CONTINUE_ON_ERROR; then
                        break
                    fi
                    continue
                fi
            fi
        fi
        
        # Download (pass the authoritative catalog size for the mirror sanity
        # check and the size-fallback comparison). Capture the exit code with a
        # set -e-robust form (NOT `local dl_rc=$(...)`), then dispatch on the
        # three-way contract: 0=downloaded, 2=user-declined (skip cleanly),
        # 1/other=genuine failure.
        local dl_rc
        if download_file "$remote_url" "$new_filepath" "$expected_bytes"; then
            dl_rc=0
        else
            dl_rc=$?
        fi

        if [ "$dl_rc" -eq 2 ]; then
            # User declined this download: preserve the old file, do not count as
            # updated or failed, and move on (do NOT fall into the success branch
            # below, which would rm -f the old file).
            log "INFO" "Skipped ${filename} (declined by operator)"
            continue
        elif [ "$dl_rc" -ne 0 ]; then
            log "ERROR" "Failed to update ${filename}"
            total_failed=$((total_failed + 1))
            if ! $CONTINUE_ON_ERROR; then
                break
            fi
        else
            total_updated=$((total_updated + 1))
            # From here until the reconcile returns, the library may list a
            # removed old file (or a replaced book's stale UUID). The install mv
            # inside download_file, just before, is outside this window (accepted).
            LIB_BUSY=true

            if [ "$f" != "$new_filepath" ] && [ -f "$f" ]; then
                log "INFO" "Transitioning from $filename to ${new_name}.zim"
                log "INFO" "Removing old file: $filename"
                rm -f "$f"
            fi

            # Reconcile NOW, per file, through the single library writer: an
            # interrupted run (stop/SIGTERM/kill) then leaves every finished file
            # consistent. Always refresh the target — it may have been overwritten
            # in place (same path, new book UUID), which path matching cannot see;
            # refreshing an unlisted file is just an add.
            local rec_rc=0
            update_kiwix_library "$new_filepath" || rec_rc=$?
            # A refused reconcile (1) leaves the library inconsistent: keep the hint.
            [ "$rec_rc" -eq 1 ] || LIB_BUSY=false
            if [ "$rec_rc" -eq 2 ]; then
                # Reconcile ran; some kiwix-manage operation failed (possibly on an
                # unrelated file — the ERROR above names it). Downloads are
                # unaffected, so keep going; the run still ends as failed.
                reconcile_partial=$((reconcile_partial + 1))
                update_success=false
                log "WARN" "Library reconcile after ${new_name}.zim completed with errors — continuing"
            elif [ "$rec_rc" -ne 0 ]; then
                # Refused: the library could not be safely rewritten (library-wide or
                # tool-level cause),
                # so ALWAYS stop — even with -c, which is for per-file download
                # failures. Continuing would delete each remaining old file before a
                # reconcile that is refused again, leaving N dangling entries.
                update_success=false
                log "ERROR" "Library reconcile refused after ${new_name}.zim — stopping"
                stopped_early=true
                break
            fi
        fi

        # Update progress
        local current=$((total_updated + total_failed))
        local total=${#FILES_TO_UPDATE[@]}
        update_progress "$current" "$total" "$filename"
    done

    # A -b child left kiwix-serve running through the downloads, so it still has
    # the old library and the replaced files open: restart it once if anything was
    # installed. stop_service_if_managed writes the .kiwix_was_running marker first,
    # so a signal between the stop and the start is still restored by cleanup(); the
    # restore_service_if_managed below completes the restart.
    if [ -n "${KIWIX_BACKGROUND:-}" ] && [ "$total_updated" -gt 0 ]; then
        if ! stop_service_if_managed; then
            log "ERROR" "Could not stop kiwix-serve to reload the library — it is still serving the old files; restart it manually"
            update_success=false
        fi
    fi

    # Restore Kiwix service (root mode only; see restore_service_if_managed). A
    # failed start leaves the server down: fail the run so cron sees it.
    restore_service_if_managed || update_success=false

    # Final status. Any failed file fails the run — also under -c, which only
    # decides whether to keep going, not what the run reports (cron must see it).
    if [ "$total_failed" -gt 0 ]; then
        update_success=false
    fi
    if $update_success; then
        log "INFO" "Smart update completed successfully"
        log "INFO" "Files updated: ${total_updated}"
        return 0
    else
        log "ERROR" "Smart update completed with errors"
        log "ERROR" "Files updated: ${total_updated}, failed: ${total_failed}"
        [ "$reconcile_partial" -gt 0 ] && log "ERROR" "Library operations failed during ${reconcile_partial} reconcile(s) — see the ERROR lines naming the files"
        local remaining=$(( ${#FILES_TO_UPDATE[@]} - attempted ))
        [ "$remaining" -gt 0 ] && log "ERROR" "Stopped early: ${remaining} file(s) not attempted"
        if $stopped_early; then
            log "ERROR" "Library reconcile was refused — run 'update-library' after fixing the cause"
        fi
        return 1
    fi
}

# True when PID $1 holds this WORK_DIR's run lock open, i.e. it IS the live run
# (identity by the lock, not by name: a symlinked or renamed invocation still
# matches). A PID file left by a killed run can name a reused PID; stop_update
# signals a whole process group, so it must never act on an unrelated process.
# Every fd is checked: while download_file/_kiwix_service_do run (`} 9>&-`),
# bash parks the lock on a different fd number.
_is_our_run() {
    local fd
    for fd in /proc/"$1"/fd/*; do
        [ "$fd" -ef "${LOCK_FILE}" ] && return 0
    done
    return 1
}

stop_update() {
    local pid
    if ! pid=$(read_trusted_pid); then
        log "ERROR" "No PID file found"
        return 1
    fi
    if kill -0 "${pid}" 2>/dev/null && _is_our_run "${pid}"; then
        log "INFO" "Stopping update process (PID: ${pid})"
        # A -b run leads its own process group (setsid): signal the whole group,
        # so aria2c/sha256sum die with it and its trap runs at once (bash defers
        # a trap until the foreground child exits) instead of being orphaned.
        # The per-PID fallback is only defensive (a run that leads no group).
        kill -TERM -- "-${pid}" 2>/dev/null || kill "${pid}"

        # Wait for a graceful shutdown: 30s, or 120s when its cleanup will
        # restart kiwix-serve (a systemd start can take a while).
        local count=0 limit=30
        [ -f "${WORK_DIR}/.kiwix_was_running" ] && limit=120
        while kill -0 "${pid}" 2>/dev/null && [ $count -lt $limit ]; do
            sleep 1
            count=$((count + 1))
        done

        # Force kill if still running
        if kill -0 "${pid}" 2>/dev/null; then
            log "WARN" "Forcing process termination"
            kill -9 -- "-${pid}" 2>/dev/null || kill -9 "${pid}"
            rm -f "${PID_FILE}"   # its cleanup never ran
            if [ -f "${WORK_DIR}/.kiwix_was_running" ]; then
                log "WARN" "The stopped run had stopped kiwix-serve and may not have restarted it — check it is running"
            fi
        fi

        log "INFO" "Update process stopped"
        return 0
    elif kill -0 "${pid}" 2>/dev/null; then
        # Alive but not holding the run lock: a reused PID. Leave the file (the
        # next run's clean_state clears it under the lock) and signal nothing.
        log "WARN" "PID ${pid} is alive but is not a kiwix-update run — not signalling it"
        return 1
    else
        log "WARN" "No running update process found (stale PID file removed)"
        rm -f "${PID_FILE}"
        return 1
    fi
}

# Take the exclusive per-WORK_DIR run lock on fd 9, held until this process
# exits. $1 = seconds to wait (default: refuse at once). A -b child re-asserts
# the lock it inherited from its parent on the same open file description —
# reopening would conflict with the parent's lock while the parent is still
# alive. Long-lived children are started with fd 9 closed (see `} 9>&-`).
acquire_run_lock() {
    local wait_secs="${1:-}" pid holder="a run without a PID file, e.g. a foreground run"
    if ! command -v flock >/dev/null 2>&1; then
        log "ERROR" "flock not found (util-linux) — cannot take the run lock"
        return 1
    fi
    if [ -n "${KIWIX_BACKGROUND:-}" ]; then
        if [ ! -d /proc/self/fd ]; then
            log "ERROR" "Cannot verify the inherited run lock (/proc not mounted)"
            return 1
        fi
        if [ /proc/self/fd/9 -ef "${LOCK_FILE}" ] && flock -n 9; then
            return 0
        fi
    fi
    if [ -L "${LOCK_FILE}" ] || { [ -e "${LOCK_FILE}" ] && [ ! -f "${LOCK_FILE}" ]; }; then
        log "ERROR" "Refusing lock file ${LOCK_FILE}: not a regular file"
        return 1
    fi
    # Owner-only: flock works on a read-only fd, so a readable lock file would let
    # any local user hold it and block every run. chmod also tightens an old one.
    local um; um=$(umask)
    umask 077
    if ! { exec 9>>"${LOCK_FILE}"; } 2>/dev/null; then
        umask "$um"
        log "ERROR" "Cannot open lock file ${LOCK_FILE}"
        return 1
    fi
    umask "$um"
    chmod 600 "${LOCK_FILE}" 2>/dev/null || log "WARN" "Cannot chmod 600 ${LOCK_FILE}"
    if [ -n "$wait_secs" ]; then
        flock -n 9 && return 0
        log "INFO" "Waiting up to ${wait_secs}s for the previous run to release the lock..."
        flock -w "$wait_secs" 9 && return 0
    else
        flock -n 9 && return 0
    fi
    exec 9>&-
    if pid=$(read_trusted_pid 2>/dev/null) && kill -0 "$pid" 2>/dev/null; then
        holder="PID $pid"
    fi
    log "ERROR" "Another kiwix-update run is in progress (${holder}) — try again later"
    return 1
}

# $1 = "full" (the clean command) also discards resumable partial downloads.
clean_state() {
    # Create work directory if it doesn't exist
    mkdir -p "${WORK_DIR}" 2>/dev/null || true
    
    # Clean up state files (use || true to prevent failures).
    # .kiwix_was_running is listed explicitly: the .kiwix_update* glob does NOT
    # match it, so a stale marker from a hard-killed prior run would otherwise
    # survive and make restore_service_if_managed start a service this run never
    # stopped. Safe to clear here: clean_state runs under the run lock before
    # command dispatch, so only a stale marker is removed; the legitimate marker
    # is written later by stop_service_if_managed. A stale one means a previous
    # run was killed after stopping kiwix-serve, so kiwix-serve may be down: note
    # it, wipe the state (the log included), then warn into the fresh log, and on
    # stderr under -q.
    local stale_marker=false
    [ -f "${WORK_DIR}/.kiwix_was_running" ] && stale_marker=true
    rm -f "${WORK_DIR}"/.kiwix_update* \
          "${WORK_DIR}"/.kiwix_was_running \
          "${WORK_DIR}"/kiwix_update.log* \
          "${WORK_DIR}"/.heartbeat \
          "${WORK_DIR}"/.progress \
          "${STATUS_FILE}" \
          "${LIBRARY_CACHE}" 2>/dev/null || true
    if $stale_marker; then
        local msg="A previous run stopped kiwix-serve and did not restart it — start it if it should be running"
        log "WARN" "$msg"
        if ${QUIET}; then
            printf 'WARNING: %s\n' "$msg" >&2
        fi
    fi

    # Clear the temp directory, keeping recent resumable partials unless "full".
    if [ "${1:-}" = full ]; then
        rm -rf "${TEMP_DIR}" 2>/dev/null || true
    else
        _prune_temp_dir
    fi
}

# ---------------------------------------------------------------------------
# Trusted-directory / ownership gate (privilege-escalation hardening).
#
# The default WORK_DIR (/var/local) is 2775 root:staff on stock Debian, so a
# 'staff' user could pre-plant dirs/symlinks/PID files that root then operates
# on. These helpers refuse to touch a state directory unless it (and every
# ancestor) is root-owned and not group/other-writable.
#
# EXPECTED_OWNER_UID defaults to 0 (never ${VAR:-0}) so it is never overridable
# through the environment. determine_run_mode may set it — but only from the REAL
# effective uid (`id -u`, which an attacker cannot forge without already holding
# that uid): it stays literal 0 in root mode, and becomes the running uid ONLY in
# unprivileged mode. Root mode's owner anchor therefore remains env-immutable.
# ---------------------------------------------------------------------------
EXPECTED_OWNER_UID=0
TRUST_FAIL_REASON=""

# Validate a catalog-derived base name before using it to build an on-disk
# .zim path. Allows only [A-Za-z0-9._-], and rejects empty, '.', '..', a
# leading '-' (option injection) or a leading '.' (hidden file). This is the
# positive control that makes path-traversal handling non-fragile.
is_safe_zim_name() {
    local name="$1"
    case "$name" in
        ''|.|..) return 1 ;;
        -*|.*)   return 1 ;;
    esac
    [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]]
}

# True if an octal mode string (e.g. 2775, 755) is group- OR other-writable.
# The last three octal digits are user, group, other (a leading special digit,
# as in 2775, is ignored by taking the last three).
_mode_group_other_writable() {
    local perm="${1: -3}"
    local g="${perm:1:1}" o="${perm:2:1}"
    [ $(( g & 2 )) -ne 0 ] || [ $(( o & 2 )) -ne 0 ]
}

# Strip C0 control chars + DEL for safe terminal display. UTF-8-safe: keeps the
# C1 range (legitimate UTF-8 continuation bytes). ESC (0x1B) is a C0 byte, so
# ESC[/ESC] terminal-escape sequences are neutralized.
_disp() { printf '%s' "$1" | tr -d '\000-\037\177'; }

# Tighten a state/log/PID file to owner-only (600). NEVER applied to .zim or the
# library XML — kiwix-serve (a non-root account) must read those. Do NOT use a
# blanket `umask 077`, which would make the served files unreadable.
_restrict_state_file() {
    [ -e "$1" ] && chmod 600 "$1" 2>/dev/null || true
}

# True if $1 is owned by EXPECTED_OWNER_UID (root in root mode; the running user
# in unprivileged mode).
is_owned_by_expected() {
    local owner
    owner=$(stat -c%u "$1" 2>/dev/null) || return 1
    [ "$owner" = "$EXPECTED_OWNER_UID" ]
}

# True iff an ANCESTOR owner uid ($1) is acceptable: EXPECTED_OWNER_UID or root.
# The `0` is a hard-coded LITERAL (never a variable) so the root-TCB allowance can
# never be relocated off root — do not parameterize it. Applies to ancestors only;
# the leaf must match EXPECTED_OWNER_UID exactly (root is not accepted for a leaf).
_ancestor_owner_ok() {
    [ "$1" = "$EXPECTED_OWNER_UID" ] || [ "$1" = 0 ]
}

# True if $1 is a real directory owned by EXPECTED_OWNER_UID, not group/other-
# writable, and every ANCESTOR is owned by EXPECTED_OWNER_UID *or root (0)* and
# not group/other-writable. In root mode EXPECTED_OWNER_UID is 0, so the ancestor
# set {0,0} collapses to {0} — identical to the original root-only rule. In
# unprivileged mode a root-owned ancestor (e.g. /home, /) is trusted because root
# is the TCB, which lets a user-owned WORK_DIR under $HOME pass; a peer-owned
# ancestor is still rejected. The literal 0 is hard-coded (never a variable) so
# the root-TCB allowance can't be moved off root.
# Sets TRUST_FAIL_REASON to symlink|missing|owner|writable|ancestor on failure.
# Owner and mode come exclusively from `stat -c` so a stat-shim governs tests.
is_trusted_dir() {
    local path="$1"
    TRUST_FAIL_REASON=""
    if [ -L "$path" ]; then TRUST_FAIL_REASON="symlink"; return 1; fi
    if [ ! -d "$path" ]; then TRUST_FAIL_REASON="missing"; return 1; fi

    local canon
    canon=$(readlink -f "$path" 2>/dev/null) || { TRUST_FAIL_REASON="symlink"; return 1; }

    local owner mode
    owner=$(stat -c%u "$canon" 2>/dev/null) || { TRUST_FAIL_REASON="owner"; return 1; }
    mode=$(stat -c%a "$canon" 2>/dev/null) || { TRUST_FAIL_REASON="owner"; return 1; }
    [ "$owner" = "$EXPECTED_OWNER_UID" ] || { TRUST_FAIL_REASON="owner"; return 1; }
    _mode_group_other_writable "$mode" && { TRUST_FAIL_REASON="writable"; return 1; }

    local cur="$canon"
    while [ "$cur" != "/" ]; do
        cur=$(dirname "$cur")
        owner=$(stat -c%u "$cur" 2>/dev/null) || { TRUST_FAIL_REASON="ancestor"; return 1; }
        mode=$(stat -c%a "$cur" 2>/dev/null) || { TRUST_FAIL_REASON="ancestor"; return 1; }
        # Ancestor owner must be EXPECTED_OWNER_UID or root (the hard-coded TCB).
        if ! _ancestor_owner_ok "$owner" || _mode_group_other_writable "$mode"; then
            TRUST_FAIL_REASON="ancestor"
            return 1
        fi
    done
    return 0
}

# Mode-aware remediation guidance (stderr).
_trust_remediation() {
    if [ "$EXPECTED_OWNER_UID" = 0 ]; then
        printf "Remediation: 'chmod g-w,o-w' and 'chown root' the offending path (e.g. 'chmod g-w /var/local'), or set KIWIX_WORK_DIR to a root-owned path such as /var/lib/kiwix.\n" >&2
    else
        printf "Remediation (unprivileged): set KIWIX_WORK_DIR to a directory you own under a non-world-writable home (e.g. \"\$HOME/zims\"), or run as root (sudo) to use the system directory. WORK_DIR and its ancestors must not be group/other-writable.\n" >&2
    fi
}

# Emit a targeted refusal message. Writes to STDERR directly (NOT log()): the
# gate runs before LOG_FILE is safe to open, and a symlinked WORK_DIR would
# otherwise redirect the log write (see LOGFILE_SAFE).
_trust_refuse() {
    local dir="$1"
    local who="uid ${EXPECTED_OWNER_UID}"
    [ "$EXPECTED_OWNER_UID" = 0 ] && who="uid 0 (root)"
    case "$TRUST_FAIL_REASON" in
        symlink) printf 'ERROR: Refusing %s: it is a symlink (possible pre-plant attack).\n' "$dir" >&2 ;;
        owner)   printf 'ERROR: Refusing %s: not owned by %s.\n' "$dir" "$who" >&2
                 _trust_remediation ;;
        writable|ancestor)
            printf 'ERROR: Refusing %s: it or an ancestor is group/other-writable, or not owned by %s (root ancestors are allowed).\n' "$dir" "$who" >&2
            _trust_remediation
            ;;
        *)       printf 'ERROR: Refusing %s: failed the trusted-directory check (%s).\n' "$dir" "${TRUST_FAIL_REASON:-unknown}" >&2 ;;
    esac
}

# Validate (creating the leaf if absent) each directory under the trust gate.
# Process WORK_DIR before its children so the leaf-race mkdir has a valid parent.
# Returns 1 (with a message) on the first failure.
ensure_trusted_dirs() {
    local dir
    for dir in "$@"; do
        if [ -e "$dir" ] || [ -L "$dir" ]; then
            if ! is_trusted_dir "$dir"; then
                _trust_refuse "$dir"
                return 1
            fi
        else
            # Absent: ensure ancestors exist, then create the leaf NON-racily
            # (plain mkdir fails EEXIST if a symlink/dir was pre-planted).
            # Create intermediates under a scoped umask 022 so a lax caller umask
            # (002/000) can't leave a group/other-writable ancestor that the gate
            # would then reject (or, worse, a peer could pre-occupy).
            ( umask 022; mkdir -p "$(dirname "$dir")" ) 2>/dev/null || true
            if ! mkdir "$dir" 2>/dev/null; then
                # Distinguish a genuine pre-plant (the path is already occupied)
                # from the common unprivileged case: the parent is not writable by
                # us (e.g. a non-root user left at the default root-owned
                # /var/local/zims). The latter gets the mode-aware remediation so
                # the error is actionable, not a misleading "pre-plant race".
                # Writes to stderr, not log(): LOG_FILE lives under this very dir.
                if [ -e "$dir" ] || [ -L "$dir" ]; then
                    printf 'ERROR: Refusing %s: it already exists as a symlink/file (possible pre-plant).\n' "$dir" >&2
                else
                    printf 'ERROR: Cannot create %s (parent directory not writable).\n' "$dir" >&2
                    _trust_remediation
                fi
                return 1
            fi
            chmod 755 "$dir" || return 1
            if ! is_trusted_dir "$dir"; then
                _trust_refuse "$dir"
                return 1
            fi
        fi
    done
    return 0
}

# Echo the PID from PID_FILE only if the file is a regular (non-symlink), file
# owned by the expected uid whose content is a plain PID; else return 1. Prevents
# acting on an attacker-planted PID file and guarantees the value handed to kill
# is strictly numeric.
read_trusted_pid() {
    [ ! -L "${PID_FILE}" ] || return 1          # never follow a symlinked PID file
    is_owned_by_expected "${PID_FILE}" || return 1
    local pid
    pid=$(cat "${PID_FILE}" 2>/dev/null) || return 1
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1        # only a bare PID is acceptable
    printf '%s' "$pid"
}

# Create PID_FILE exclusively (O_EXCL via noclobber). If it already exists,
# reclaim it only when it is stale (dead PID) or not root-owned; refuse when a
# live root-owned process still holds it. Returns 0 on success.
create_pid_file() {
    local pid="$1"
    if ( set -o noclobber; printf '%s\n' "$pid" > "${PID_FILE}" ) 2>/dev/null; then
        _restrict_state_file "${PID_FILE}"
        return 0
    fi
    local existing
    if existing=$(read_trusted_pid) && kill -0 "$existing" 2>/dev/null; then
        log "ERROR" "An update process is already running (PID: ${existing})."
        return 1
    fi
    # Stale or untrusted PID file -> reclaim.
    rm -f "${PID_FILE}"
    if ( set -o noclobber; printf '%s\n' "$pid" > "${PID_FILE}" ) 2>/dev/null; then
        _restrict_state_file "${PID_FILE}"
        return 0
    fi
    return 1
}

# Resolve root vs unprivileged mode from the effective uid. euid 0 -> root mode
# (EXPECTED_OWNER_UID pinned literal 0, today's behavior). Non-root -> unprivileged
# mode: EXPECTED_OWNER_UID becomes the running uid and, unless the operator set
# KIWIX_ZIM_LIBRARY, the library defaults under WORK_DIR (the root-mode default
# /var/local is unwritable to a normal user). RUN_UID comes only from `id -u`,
# never the environment, so root mode's owner anchor stays immutable.
determine_run_mode() {
    local RUN_UID
    RUN_UID=$(id -u 2>/dev/null) || RUN_UID=""
    if ! [[ "$RUN_UID" =~ ^[0-9]+$ ]]; then
        printf 'Error: cannot determine effective uid (id -u returned %s)\n' "'${RUN_UID}'" >&2
        exit 1
    fi
    if [ "$RUN_UID" -eq 0 ]; then
        UNPRIVILEGED=false
        EXPECTED_OWNER_UID=0
    else
        UNPRIVILEGED=true
        EXPECTED_OWNER_UID="$RUN_UID"
        # Empty is treated as unset, matching the header's :- default semantics.
        if [ -z "${KIWIX_ZIM_LIBRARY:-}" ]; then
            ZIM_LIBRARY="${WORK_DIR}/library_zim.xml"
        fi
    fi
}

main() {
    # Enable strict mode here (not at file scope) so sourcing for tests does not
    # impose these options on the caller's shell.
    set -euo pipefail

    # Save original arguments for background mode
    ORIGINAL_ARGS=("$@")

    # Help never needs a resolved mode — short-circuit before determine_run_mode
    # (so a broken `id -u` can never abort `help`, and a bare call still prints it).
    case "${1:-help}" in
        help|-h|--help)
            show_help
            exit 0
            ;;
    esac

    # Resolve root vs unprivileged mode before ANY WORK_DIR read/write below.
    determine_run_mode

    # Simple commands that touch WORK_DIR (check_status reads/removes PID_FILE;
    # clean_state rm's state + TEMP_DIR): gate them through the trusted-dir check
    # in BOTH modes before any destructive op (an unprivileged clean must not rm
    # through a peer-planted symlinked WORK_DIR either).
    case "${1:-help}" in
        status)
            ensure_trusted_dirs "${WORK_DIR}" || exit 1
            LOGFILE_SAFE=true
            check_status
            exit $?
            ;;
        clean)
            ensure_trusted_dirs "${WORK_DIR}" || exit 1
            LOGFILE_SAFE=true
            acquire_run_lock || exit 1   # never wipe a live run's state
            clean_state full
            # Only a stale-marker warning can have been logged since the wipe.
            _restrict_state_file "${LOG_FILE}"
            echo "All logs, state files and partial downloads cleared"
            exit 0
            ;;
    esac

    # Store command and shift
    COMMAND="${1:-help}"
    shift

    # Extract the long-form integrity opt-out before getopts (getopts handles
    # short options only). Deliberately verbose so it is never set by accident.
    local _kept_args=()
    local _arg
    for _arg in "$@"; do
        case "$_arg" in
            --allow-unverified) ALLOW_UNVERIFIED=true ;;
            --https-only) HTTPS_ONLY=true ;;
            *) _kept_args+=("$_arg") ;;
        esac
    done
    set -- "${_kept_args[@]+"${_kept_args[@]}"}"

    # Parse arguments with basic validation
    while getopts "hycbqp:m:vu:" opt; do
        case $opt in
            h) show_help; exit 0 ;;
            y) YES_TO_ALL=true; EXPLICIT_YES=true ;;
            c) CONTINUE_ON_ERROR=true ;;
            # -b implies YES_TO_ALL (a background job can't answer prompts) but
            # deliberately NOT EXPLICIT_YES: it must not disarm the unprivileged
            # serving-guard. Pass -b -y to override that too.
            b) BACKGROUND=true; YES_TO_ALL=true; QUIET=true ;;
            q) QUIET=true ;;
            p)
                if [[ "${OPTARG}" == :* ]]; then
                    PARALLEL_CONNECTIONS="${OPTARG#:}"
                    if ! [[ "$PARALLEL_CONNECTIONS" =~ ^[0-9]+$ ]] || [ "$PARALLEL_CONNECTIONS" -lt 1 ] || [ "$PARALLEL_CONNECTIONS" -gt 50 ]; then
                        echo "Invalid parallel connections. Use -p:[1-50]" >&2
                        exit 1
                    fi
                else
                    echo "Invalid format. Use -p:[NUMBER]" >&2
                    exit 1
                fi
                ;;
            m)
                if [[ "${OPTARG}" == :* ]]; then
                    MAX_SPEED="${OPTARG#:}"
                    if ! [[ "$MAX_SPEED" =~ ^[0-9]+[KMG]?$ ]]; then
                        echo "Invalid speed format. Use -m:[NUMBER[K|M|G]]" >&2
                        exit 1
                    fi
                else
                    echo "Invalid format. Use -m:[NUMBER[K|M|G]]" >&2
                    exit 1
                fi
                ;;
            v) DEBUG=true ;;
            u)
                if [[ "${OPTARG}" == :* ]]; then
                    UPDATE_CRITERIA="${OPTARG#:}"
                    case "$UPDATE_CRITERIA" in
                        size|newer|all) ;;
                        *) echo "Invalid criteria. Use -u:size, -u:newer, or -u:all" >&2; exit 1 ;;
                    esac
                else
                    echo "Invalid format. Use -u:[size|newer|all]" >&2
                    exit 1
                fi
                ;;
            :) echo "Option -$OPTARG requires an argument" >&2; exit 1 ;;
            \?) echo "Invalid option: -$OPTARG" >&2; show_help; exit 1 ;;
        esac
    done

    shift $((OPTIND-1))

    # --- Dependency + trust gate: MUST precede ANY WORK_DIR read/write ---------
    # The mode is already resolved (determine_run_mode, above). The dependency
    # check and the trusted-directory gate run BEFORE the clean-start/PID handling,
    # criteria write, and background fork below — otherwise those touch an
    # unvalidated (possibly symlinked) WORK_DIR. There is no longer a hard root
    # check here: a non-root user proceeds in unprivileged mode and is stopped, if
    # at all, by the trust gate below with a precise, mode-aware message.
    if ! check_dependencies; then
        exit 1
    fi
    # Also gate the directory that holds ZIM_LIBRARY: in root mode the default is
    # /var/local (group-writable on Debian, OUTSIDE WORK_DIR), yet root does
    # chmod/chown/mv on the library there — a non-root user could pre-plant a
    # symlink to escalate. The gate validates it against EXPECTED_OWNER_UID.
    ensure_trusted_dirs "${WORK_DIR}" "${TEMP_DIR}" "${BACKUP_DIR}" "$(dirname "${ZIM_LIBRARY}")" || exit 1
    LOGFILE_SAFE=true   # WORK_DIR validated — LOG_FILE is now safe to open

    # Unprivileged mode can't manage kiwix-serve; for the mutating commands,
    # refuse to run (or warn under -y) while it is up. MUST precede clean_state,
    # the criteria write, and the background fork so nothing is touched on refusal.
    case "${COMMAND}" in
        smart-update|update-library)
            require_service_stopped_if_unprivileged
            ;;
    esac

    # `stop` only signals a live background run: no lock, state cleanup,
    # criteria write or cleanup trap, any of which would clobber the run being
    # stopped (or a live foreground run, which has no PID file). Unknown commands
    # are rejected here too, before any state file is written.
    case "${COMMAND}" in
        stop)
            stop_update || exit 1
            exit 0
            ;;
        check-updates|smart-update|update-library) ;;
        *)
            echo "Unknown command: ${COMMAND}" >&2
            echo "Valid commands: check-updates, smart-update, update-library, status, stop, clean, help" >&2
            show_help
            exit 1
            ;;
    esac

    # Interactive runs may offer to stop a live background run first (PID reads
    # go through read_trusted_pid so a planted PID file is never acted upon).
    local pid="" lock_wait=""
    if ! ${YES_TO_ALL}; then
        if pid=$(read_trusted_pid) && kill -0 "$pid" 2>/dev/null && _is_our_run "$pid"; then
            echo "An update process is running (PID: $pid)"
            read -p "Stop it and start fresh? (y/N) " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                stop_update || exit 1
                # Its whole process group was signalled; a short-lived child still
                # finishing (curl --max-time 60) may hold the lock briefly.
                lock_wait=75
            else
                echo "Aborted"
                exit 1
            fi
        fi
    fi

    # Exclusive run lock, BEFORE any state mutation (clean_state, criteria write,
    # background fork, cleanup trap): a refused run exits having touched nothing.
    # The -b parent takes it here and its nohup child inherits fd 9.
    acquire_run_lock "$lock_wait" || exit 1

    # Holding the lock means no other run is live, so stale state is always
    # cleared — except in the -b child: its parent cleaned before forking, and a
    # second clean would race the parent's PID/criteria writes.
    if [ -z "${KIWIX_BACKGROUND:-}" ]; then
        clean_state
    fi

    # Save criteria
    printf '%s\n' "${UPDATE_CRITERIA}" > "${CRITERIA_FILE}"
    _restrict_state_file "${CRITERIA_FILE}"
    _restrict_state_file "${LOG_FILE}"

    # Background mode handling
    if [ "${BACKGROUND}" = "true" ] && [ -z "${KIWIX_BACKGROUND:-}" ]; then
        export KIWIX_BACKGROUND=1
        export UPDATE_CRITERIA

        # Keep the caller's stdout/stderr on fds 3/4 for the launcher's own
        # messages; everything else from here goes to the log.
        exec 3>&1 4>&2
        exec 1>>"${LOG_FILE}" 2>&1

        # setsid: the child leads its own process group, so `stop` can signal it
        # together with its aria2c/sha256sum. Not a group leader here, so setsid
        # execs in place and $! stays the child's PID. `3>&- 4>&-`: the child
        # must not inherit the caller's stdout/stderr, or a caller reading them
        # (ssh, a pipe, cron) would block until the whole update finishes.
        nohup setsid "$0" "${ORIGINAL_ARGS[@]}" </dev/null >>"${LOG_FILE}" 2>&1 3>&- 4>&- &
        pid=$!

        # Exclusive create; refuse (and reap the child) if a live process
        # already holds the PID file. The child does NOT re-write it.
        if ! create_pid_file "$pid"; then
            kill "$pid" 2>/dev/null || true
            echo "Error: could not start the background run (see ${LOG_FILE})" >&4
            exit 1
        fi

        echo "Process started in background with PID $pid. Use '$(basename "$0") status' to check progress." >&3

        # Verify process started
        sleep 2
        if ! kill -0 $pid 2>/dev/null; then
            echo "Warning: Background process failed to start" >&4
            rm -f "${PID_FILE}"
            exit 1
        fi
        exec 3>&- 4>&-

        exit 0
    fi

    # Background CHILD setup
    if [ -n "${KIWIX_BACKGROUND:-}" ]; then
        # Load criteria written by the parent and RE-VALIDATE before trusting it (B5).
        if [ -f "${CRITERIA_FILE}" ]; then
            UPDATE_CRITERIA=$(cat "${CRITERIA_FILE}")
            case "$UPDATE_CRITERIA" in
                size|newer|all) ;;
                *) log "ERROR" "Invalid criteria reloaded from ${CRITERIA_FILE}: '${UPDATE_CRITERIA}'"; exit 1 ;;
            esac
        fi
        # The parent already created PID_FILE with this child's PID via
        # create_pid_file; the child does NOT re-write it (a second write would
        # defeat the exclusive-create guard and race the owner check).
    fi

    # Set up cleanup
    trap 'cleanup' EXIT
    trap 'cleanup 143' SIGTERM
    trap 'cleanup 130' SIGINT
    trap 'cleanup 129' SIGHUP

    # Process commands
    case "$COMMAND" in
        check-updates)
            analyze_updates || exit 1
            ;;
        smart-update)
            analyze_updates && do_smart_update || exit 1
            ;;
        update-library)
            # Dependency + trusted-dir checks already ran in the gate above; the
            # unprivileged pre-flight already ensured kiwix-serve is stopped.

            cmd_update_library || exit 1
            ;;
        *)
            log "ERROR" "internal: no handler for command ${COMMAND}"
            exit 1
            ;;
    esac
}

# Call main with all arguments (guarded so the script can be sourced for testing)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
