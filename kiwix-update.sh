#!/bin/bash

# Set shell options for safer execution
set -e          # Exit on error
set -u          # Exit on undefined variable
set -o pipefail # Exit on pipe failure

# File & URL locations
WORK_DIR="/var/local/zims" # this is where your .zim files live
ZIM_LIBRARY="/var/local/library_zim.xml" # this points to your library_zim.xml
TEMP_DIR="${WORK_DIR}/temp"
BACKUP_DIR="${WORK_DIR}/backups"
LOG_FILE="${WORK_DIR}/kiwix_update.log"
STATUS_FILE="${WORK_DIR}/.kiwix_update_status"
PID_FILE="${WORK_DIR}/.kiwix_update.pid" 
CRITERIA_FILE="${WORK_DIR}/.kiwix_update_criteria"
LIBRARY_CACHE="${WORK_DIR}/.kiwix_library_cache"
KIWIX_LIBRARY_API="https://library.kiwix.org/catalog/root.xml"
KIWIX_DOWNLOAD_BASE="https://download.kiwix.org"

# Default values
YES_TO_ALL=false
CONTINUE_ON_ERROR=false
QUIET=false
PARALLEL_CONNECTIONS=5
MAX_SPEED=""
START_LETTER=""
DAYS_OLD=0
RESUME=false
BACKGROUND=false
TIMEOUT=30
MAX_RETRIES=3
UPDATE_CRITERIA="all"
DEBUG=false

declare -g CLEANUP_IN_PROGRESS=false
declare -g FILES_TO_UPDATE=()

# Required commands
REQUIRED_COMMANDS=(
    "aria2c"
    "kiwix-manage"
    "curl"
    "find"
    "stat"
    "numfmt"
)

log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    # Basic log injection prevention - remove control characters
    message=$(echo "$message" | tr -d '\000-\037\177')
    
    # Write to log file
    echo "[${timestamp}] [${level}] ${message}" >> "${LOG_FILE}" 2>/dev/null || true

    # Echo to stdout if not quiet/background
    if ! ${QUIET} && [ -z "${KIWIX_BACKGROUND:-}" ]; then
        if [ "${level}" = "DEBUG" ]; then
            ${DEBUG} && echo "${message}"
        elif [ "${level}" = "ERROR" ]; then
            echo "ERROR: ${message}" >&2
        else
            echo "${message}"
        fi
    fi
}

update_kiwix_library() {
    log "INFO" "Updating Kiwix library..."
    
    # Backup current library first
    backup_library_xml
    
    # Check if library file exists
    if [ ! -f "${ZIM_LIBRARY}" ]; then
        log "WARN" "Library file does not exist, creating new one"
        touch "${ZIM_LIBRARY}"
    fi
    
    # Get list of ZIM files currently in library
    local library_files=()
    local library_ids=()
    
    # Parse the XML to get current library entries
    while IFS= read -r line; do
        if [[ "$line" =~ \<book.*id=\"([^\"]+)\".*path=\"([^\"]+)\" ]] || 
           [[ "$line" =~ \<book.*path=\"([^\"]+)\".*id=\"([^\"]+)\" ]]; then
            local book_id="${BASH_REMATCH[1]}"
            local book_path="${BASH_REMATCH[2]}"
            if [[ "$line" =~ id=\"([^\"]+)\" ]]; then
                book_id="${BASH_REMATCH[1]}"
            fi
            library_files+=("$(basename "$book_path")")
            library_ids+=("$book_id")
        fi
    done < "${ZIM_LIBRARY}"
    
    log "INFO" "Found ${#library_files[@]} files in library"
    
    # Find all ZIM files in directory
    local found_files=()
    while IFS= read -r -d '' file; do
        found_files+=("$file")
    done < <(find "${WORK_DIR}" -maxdepth 1 -type f -name "*.zim" -print0 | sort -z)
    
    log "INFO" "Found ${#found_files[@]} ZIM files in directory"
    
    # Add new files to library
    local added_count=0
    for file_path in "${found_files[@]}"; do
        local filename=$(basename "$file_path")
        local in_library=false
        
        for lib_file in "${library_files[@]}"; do
            if [ "$filename" = "$lib_file" ]; then
                in_library=true
                break
            fi
        done
        
        if ! $in_library; then
            log "INFO" "Adding $filename to library"
            if kiwix-manage "${ZIM_LIBRARY}" add "$file_path"; then
                added_count=$((added_count + 1))
            else
                log "ERROR" "Failed to add $filename to library"
            fi
        fi
    done
    
    # Remove files from library that no longer exist
    local removed_count=0
    local temp_library="${WORK_DIR}/.library_zim_temp.xml"
    cp "${ZIM_LIBRARY}" "$temp_library"
    
    # Check each library entry
    for i in "${!library_files[@]}"; do
        local lib_file="${library_files[$i]}"
        local book_id="${library_ids[$i]}"
        
        if [ ! -f "${WORK_DIR}/${lib_file}" ]; then
            log "INFO" "Removing $lib_file (ID: $book_id) from library - file no longer exists"
            if kiwix-manage "$temp_library" remove "$book_id"; then
                removed_count=$((removed_count + 1))
            else
                log "WARN" "Failed to remove $lib_file from library"
            fi
        fi
    done
    
    # Replace the library with the updated one if removals were successful
    if [ $removed_count -gt 0 ] && [ -s "$temp_library" ]; then
        mv "$temp_library" "${ZIM_LIBRARY}"
    else
        rm -f "$temp_library"
    fi
    
    # Report results
    log "INFO" "Library update complete: $added_count added, $removed_count removed"
    
    # Set proper permissions
    chmod 644 "${ZIM_LIBRARY}"
    chown root:root "${ZIM_LIBRARY}"
    
    return 0
}

fetch_library_data() {
    local cache_age=3600  # Cache for 1 hour
    
    # Check if cache exists and is recent
    if [ -f "$LIBRARY_CACHE" ]; then
        local cache_time=$(stat -c%Y "$LIBRARY_CACHE")
        local current_time=$(date +%s)
        if [ $((current_time - cache_time)) -lt $cache_age ]; then
            log "DEBUG" "Using cached library data"
            return 0
        fi
    fi
    
    log "INFO" "Fetching latest library data from Kiwix..."
    
    # Get the root catalog with basic error handling
    if curl -sL --connect-timeout "$TIMEOUT" --max-time 60 --fail "$KIWIX_LIBRARY_API" -o "${LIBRARY_CACHE}.tmp"; then
        # Parse the ATOM feed
        awk '
            /<entry>/ { in_entry=1; publisher=""; link=""; size=""; }
            /<\/entry>/ { 
                if (link != "") {
                    path = link
                    gsub(/^https:\/\/download\.kiwix\.org\//, "", path);
                    gsub(/\.meta4$/, "", path);
                    filename = path
                    gsub(/.*\//, "", filename);
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
            in_entry && /rel="http:\/\/opds-spec.org\/acquisition\/open-access"/ {
                match($0, /href="[^"]+"/);
                link=substr($0, RSTART+6, RLENGTH-7);
                match($0, /length="[^"]+"/);
                if (RSTART > 0) {
                    size=substr($0, RSTART+8, RLENGTH-9);
                }
            }
        ' "${LIBRARY_CACHE}.tmp" > "$LIBRARY_CACHE"
        
        rm -f "${LIBRARY_CACHE}.tmp"
        log "INFO" "Library data updated - found $(wc -l < "$LIBRARY_CACHE") entries"
        return 0
    else
        log "ERROR" "Failed to fetch library data"
        return 1
    fi
}

find_latest_zim() {
    local local_filename="$1"
    local base_name="${local_filename%.zim}"
    local alt_name=""
    
    if [ ! -f "$LIBRARY_CACHE" ]; then
        log "ERROR" "Library cache not found"
        return 1
    fi
    
    ${DEBUG} && log "DEBUG" "Looking for matches for: $base_name"
    
    # Handle special cases for renamed files
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
    esac
    
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
        if [ -n "${alt_name}" ] && [[ "$file_base" =~ ^${alt_name}(_[0-9]{4}-[0-9]{2})?$ ]]; then
            if [[ "$file_base" =~ _[0-9]{4}-[0-9]{2}$ ]]; then
                local date_part="${file_base##*_}"
                if [ -z "$best_date" ] || [ "$date_part" > "$best_date" ]; then
                    best_date="$date_part"
                    best_match="${publisher}|${filename}|${path}|${size}"
                fi
            else
                result="${publisher}|${filename}|${path}|${size}"
                break
            fi
        fi
        
        # Dated version match
        if [[ "$file_base" =~ ^${base_name}_[0-9]{4}-[0-9]{2}$ ]]; then
            local date_part="${file_base##*_}"
            if [ -z "$best_date" ] || [ "$date_part" > "$best_date" ]; then
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
            while IFS='|' read -r publisher filename path size; do
                local file_base="${filename%.zim}"
                if [[ "$file_base" =~ ^${nopic_name}(_[0-9]{4}-[0-9]{2})?$ ]]; then
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

cleanup() {
    if ${CLEANUP_IN_PROGRESS}; then
        return
    fi
    CLEANUP_IN_PROGRESS=true

    local exit_code=$?
    
    # Skip cleanup if parent process launching background job
    if [ "${BACKGROUND}" = "true" ] && [ -z "${KIWIX_BACKGROUND:-}" ]; then
        exit "$exit_code"
    fi
    
    if [ -z "${KIWIX_BACKGROUND:-}" ] && ! ${QUIET}; then
        log "INFO" "Cleaning up..."
    fi
    
    # Clean up files if not in background mode
    if [ -z "${KIWIX_BACKGROUND:-}" ]; then
        [ -f "${PID_FILE}" ] && rm -f "${PID_FILE}"
        [ -d "${TEMP_DIR}" ] && rm -rf "${TEMP_DIR}"
        [ -f "${STATUS_FILE}" ] && rm -f "${STATUS_FILE}"
    fi
    
    CLEANUP_IN_PROGRESS=false
    exit "$exit_code"
}

show_help() {
   cat << EOF
Usage: $(basename "$0") [OPTIONS] COMMAND

Commands:
   check-updates        Check which ZIM files need updating
   smart-update         Only download and update ZIM files that need updating
   update-library       Update Kiwix library to match ZIM files in directory
   status               Show current update status
   stop                 Stop a running update process
   clean                Remove all logs and state files
   help                 Show this help message

Options:
   -h                   Show this help message
   -y                   Automatic yes to all prompts
   -c                   Continue processing even if errors occur
   -s:[LETTER]          Start processing files beginning with letter
   -d:[DAYS]            Process files older than specified days
   -r                   Resume from last known position
   -b                   Run in background
   -q                   Quiet mode
   -v                   Verbose/debug mode
   -p:[NUM]             Parallel connections (1-50)
   -m:[NUM[M|K]]        Max download speed
   -u:[size|newer|all]  Update criteria

Examples:
   $(basename "$0") check-updates
   $(basename "$0") smart-update -u:size -m:5M
   $(basename "$0") smart-update -y -b
   
Note: This script must be run as root.
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

check_network() {
    if curl -s --connect-timeout 5 --max-time 10 --fail "${KIWIX_DOWNLOAD_BASE}" >/dev/null 2>&1; then
        return 0
    else
        log "ERROR" "Network connectivity check failed"
        return 1
    fi
}

update_progress() {
    local current="$1"
    local total="$2"
    local filename="$3"
    
    local percentage=0
    if [ "$total" -gt 0 ]; then
        percentage=$((current * 100 / total))
    fi
    
    echo "${percentage}:${filename}" > "${WORK_DIR}/.progress"
    
    if ! $QUIET; then
        printf "\rProgress: [%-50s] %d%% (%d/%d) - %-30s\033[K" \
            "$(printf '#%.0s' $(seq 1 $((percentage / 2))))" \
            "$percentage" "$current" "$total" "$filename"
    fi
}

manage_kiwix_service() {
    local action="$1"
    
    case "$action" in
        stop)
            log "INFO" "Stopping Kiwix service"
            if service kiwix stop; then
                sleep 2
                if ! pgrep -f kiwix-serve >/dev/null; then
                    log "INFO" "Kiwix service stopped"
                    touch "${WORK_DIR}/.kiwix_was_running"
                    return 0
                fi
            fi
            log "ERROR" "Failed to stop Kiwix service"
            return 1
            ;;
        start)
            log "INFO" "Starting Kiwix service"
            if service kiwix start; then
                sleep 2
                if pgrep -f kiwix-serve >/dev/null; then
                    log "INFO" "Kiwix service started"
                    return 0
                fi
            fi
            log "ERROR" "Failed to start Kiwix service"
            return 1
            ;;
        status)
            pgrep -f kiwix-serve >/dev/null
            return $?
            ;;
    esac
}

get_remote_size() {
    local url="$1"
    local size
    
    if [ -z "$url" ]; then
        return 1
    fi
    
    if size=$(curl -sI --connect-timeout "$TIMEOUT" --max-time "$TIMEOUT" --fail "$url" | grep -i content-length | tail -n1 | awk '{print $2}' | tr -d '\r'); then
        if [[ "$size" =~ ^[0-9]+$ ]]; then
            echo "$size"
            return 0
        fi
    fi
    
    return 1
}

get_remote_details() {
    local url="$1"
    
    if [ -z "$url" ]; then
        return 1
    fi
    
    local output
    if ! output=$(curl -sI --connect-timeout "$TIMEOUT" --max-time "$TIMEOUT" --fail "$url"); then
        return 1
    fi
    
    local size=$(echo "$output" | grep -i content-length | tail -n1 | awk '{print $2}' | tr -d '\r')
    local modified=$(echo "$output" | grep -i last-modified | tail -n1 | sed 's/Last-Modified: //')
    
    if [ -z "$size" ] || ! [[ "$size" =~ ^[0-9]+$ ]]; then
        return 1
    fi
    
    local timestamp
    if [ -z "$modified" ]; then
        timestamp=$(date +%s)
    else
        timestamp=$(date -d "$modified" +%s 2>/dev/null) || timestamp=$(date +%s)
    fi
    
    echo "$size $timestamp"
}

check_update_needed() {
    local local_file="$1"
    local remote_url="$2"
    local force="${3:-false}"
    
    log "INFO" "Checking if update needed for $(basename "$local_file") using criteria: $UPDATE_CRITERIA"
    
    if $force; then
        log "INFO" "Force update requested"
        return 0
    fi
    
    if [ ! -f "$local_file" ]; then
        log "INFO" "Local file doesn't exist - update needed"
        return 0
    fi
    
    local local_size=$(stat -c%s "$local_file" 2>/dev/null) || return 1
    local remote_details
    
    if ! remote_details=$(get_remote_details "$remote_url"); then
        log "ERROR" "Failed to get remote details"
        return 1
    fi
    
    local remote_size=$(echo "$remote_details" | cut -d' ' -f1)
    local remote_time=$(echo "$remote_details" | cut -d' ' -f2)
    
    case "$UPDATE_CRITERIA" in
        size)
            if [ "$local_size" != "$remote_size" ]; then
                log "INFO" "Size differs - update needed"
                return 0
            fi
            log "INFO" "Size matches - no update needed"
            return 2
            ;;
        newer)
            local local_time=$(stat -c%Y "$local_file")
            if [ "$local_time" -lt "$remote_time" ]; then
                log "INFO" "Remote file is newer - update needed"
                return 0
            fi
            log "INFO" "Local file is up to date - no update needed"
            return 2
            ;;
        all)
            if [ "$local_size" != "$remote_size" ]; then
                log "INFO" "Size differs - update needed"
                return 0
            fi
            local local_time=$(stat -c%Y "$local_file")
            if [ "$local_time" -lt "$remote_time" ]; then
                log "INFO" "Remote file is newer - update needed"
                return 0
            fi
            log "INFO" "File is up to date - no update needed"
            return 2
            ;;
    esac
}

verify_downloaded_file() {
    local file="$1"
    local temp_file="$2"
    local remote_url="$3"

    log "INFO" "Verifying downloaded file: $file"
    
    if [ ! -r "$temp_file" ] || [ ! -s "$temp_file" ]; then
        log "ERROR" "Downloaded file is empty or unreadable"
        return 1
    fi
    
    local expected_size actual_size
    
    if ! expected_size=$(get_remote_size "$remote_url"); then
        log "ERROR" "Failed to get remote size for verification"
        return 1
    fi
    
    actual_size=$(stat -c%s "$temp_file" 2>/dev/null) || return 1
    
    if [ "$actual_size" != "$expected_size" ]; then
        log "ERROR" "Size mismatch - expected: $expected_size, got: $actual_size"
        return 1
    fi
    
    log "INFO" "File size verification passed"
    return 0
}

backup_library_xml() {
    local timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_file="${BACKUP_DIR}/library_zim_${timestamp}.xml"
    
    mkdir -p "${BACKUP_DIR}" || return 1
    
    if [ ! -f "${ZIM_LIBRARY}" ]; then
        log "WARN" "No library file to backup"
        return 0
    fi
    
    if ! cp "${ZIM_LIBRARY}" "$backup_file"; then
        log "ERROR" "Failed to create backup"
        return 1
    fi
    
    log "INFO" "Library backed up to: $backup_file"
    
    # Keep only last 5 backups
    ls -t "${BACKUP_DIR}"/library_zim_*.xml 2>/dev/null | tail -n +6 | xargs -r rm
    
    return 0
}

download_file() {
    local url="$1"
    local output="$2"
    local filename=$(basename "$output")
    local temp_file="${TEMP_DIR}/$(basename "$output").part"
    
    # Basic URL validation
    if [[ ! "$url" =~ ^https?:// ]]; then
        log "ERROR" "Invalid URL: $url"
        return 1
    fi
    
    mkdir -p "${TEMP_DIR}" || return 1
    
    # Remove existing temp file
    rm -f "$temp_file"
    
    # Confirm download if not auto-yes
    if ! ${YES_TO_ALL}; then
        local size=$(get_remote_size "$url")
        read -p "Download $filename ($(numfmt --to=iec-i --suffix=B "$size"))? [y/N] " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log "INFO" "Skipping $filename"
            return 0
        fi
    fi
    
    # Get final URL after redirects
    local final_url
    final_url=$(curl -sLI -o /dev/null -w '%{url_effective}' "$url") || final_url="$url"
    
    # Aria2c options
    local aria_opts=(
        --max-connection-per-server="${PARALLEL_CONNECTIONS}"
        --min-split-size=1M
        --file-allocation=none
        --continue=true
        --dir="$(dirname "$temp_file")"
        --out="$(basename "$temp_file")"
        --check-certificate=true
        --allow-overwrite=true
        --max-tries=3
        --retry-wait=3
        --connect-timeout=60
        --remote-time=true
        --console-log-level=error
    )
    
    [ -n "${MAX_SPEED}" ] && aria_opts+=(--max-download-limit="${MAX_SPEED}")
    
    local retry_count=0
    local success=false
    
    while [ $retry_count -lt $MAX_RETRIES ] && [ "$success" = false ]; do
        retry_count=$((retry_count + 1))
        
        if [ $retry_count -gt 1 ]; then
            log "INFO" "Retry attempt $retry_count for $filename"
            sleep 5
        fi
        
        if ! ${QUIET}; then
            aria_opts+=(--show-console-readout=true)
            aria2c "${aria_opts[@]}" "$final_url" 2>&1 | \
                awk -v filename="$filename" '
                /\[#.*\]/ {
                    match($0, /([0-9]+)%/)
                    pct = substr($0, RSTART, RLENGTH-1)
                    match($0, /DL:([0-9.]+[KMGT]?i?B\/s)/)
                    speed = substr($0, RSTART+3, RLENGTH-3)
                    bar = ""
                    for(i=0; i<pct/2; i++) bar = bar "#"
                    for(i=pct/2; i<50; i++) bar = bar "-"
                    printf "\rDownloading %s: [%s] %3d%% %s", filename, bar, pct, speed
                    fflush()
                }'
            echo
        else
            aria_opts+=(--quiet=true --show-console-readout=false)
            aria2c "${aria_opts[@]}" "$final_url" > /dev/null 2>&1
        fi
        
        if [ $? -eq 0 ] && [ -f "$temp_file" ] && [ -s "$temp_file" ]; then
            if verify_downloaded_file "$output" "$temp_file" "$final_url"; then
                success=true
                if mv "$temp_file" "$output"; then
                    log "INFO" "Successfully downloaded $filename"
                else
                    log "ERROR" "Failed to move $temp_file to $output"
                    success=false
                fi
            else
                log "ERROR" "File verification failed for $filename"
                rm -f "$temp_file"
            fi
        else
            log "ERROR" "Download failed for $filename"
            rm -f "$temp_file"
        fi
    done
    
    return $([ "$success" = true ] && echo 0 || echo 1)
}

check_status() {
    if [ ! -f "${PID_FILE}" ]; then
        echo "No active update process found"
        return 1
    fi

    local pid=$(cat "${PID_FILE}" 2>/dev/null)
    
    if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
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
    echo "$status" > "${STATUS_FILE}"
    echo "$(date +%s)" > "${WORK_DIR}/.heartbeat"
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
    local skipped_files=0
    
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
                "$filename" \
                "$(numfmt --to=iec-i --suffix=B "$local_size")" \
                "-" \
                "SKIPPED" \
                "No match in library"
            skipped_files=$((skipped_files + 1))
            continue
        fi
        
        # Parse the result
        local latest_publisher latest_filename latest_path remote_size
        latest_publisher=$(echo "$latest_info" | cut -d'|' -f1)
        latest_filename=$(echo "$latest_info" | cut -d'|' -f2)
        latest_path=$(echo "$latest_info" | cut -d'|' -f3)
        remote_size=$(echo "$latest_info" | cut -d'|' -f4)
        
        latest_path="${latest_path#/}"
        local latest_url="${KIWIX_DOWNLOAD_BASE}/${latest_path}"
        local latest_name="${latest_filename%.zim}"
        
        local status="Up to date"
        local details=""
        local update_needed=false
        
        # Check based on criteria
        case "$UPDATE_CRITERIA" in
            size)
                if [ "$remote_size" -gt "$local_size" ]; then
                    status="Update needed"
                    local size_diff=$((remote_size - local_size))
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
                
                # Extract date from remote filename
                if [[ "$latest_name" =~ _([0-9]{4}-[0-9]{2})$ ]]; then
                    remote_date="${BASH_REMATCH[1]}"
                    remote_timestamp=$(date -d "${remote_date}-01" +%s 2>/dev/null || echo "0")
                fi
                
                # Extract date from local filename
                if [[ "${filename%.zim}" =~ _([0-9]{4}-[0-9]{2})$ ]]; then
                    local_date="${BASH_REMATCH[1]}"
                    local_timestamp=$(date -d "${local_date}-01" +%s 2>/dev/null || echo "0")
                else
                    local_timestamp=$(stat -c%Y "$f")
                fi
                
                local is_newer=false
                if [ -n "$local_date" ] && [ -n "$remote_date" ]; then
                    [ "$remote_date" > "$local_date" ] && is_newer=true
                elif [ -n "$remote_timestamp" ] && [ "$remote_timestamp" -gt "$local_timestamp" ]; then
                    is_newer=true
                fi
                
                if $is_newer; then
                    # Check if suspiciously smaller
                    local size_ratio=100
                    if [ "$local_size" -gt 0 ]; then
                        size_ratio=$(( (remote_size * 100) / local_size ))
                    fi
                    
                    if [ "$size_ratio" -lt 50 ]; then
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
                
                # Check size
                if [ "$remote_size" -gt "$local_size" ]; then
                    local size_diff=$((remote_size - local_size))
                    reasons+=("size +$(numfmt --to=iec-i --suffix=B $size_diff)")
                    should_update=true
                fi
                
                # Check if newer
                local remote_date="" local_date="" local_timestamp="" remote_timestamp=""
                
                if [[ "$latest_name" =~ _([0-9]{4}-[0-9]{2})$ ]]; then
                    remote_date="${BASH_REMATCH[1]}"
                    remote_timestamp=$(date -d "${remote_date}-01" +%s 2>/dev/null || echo "0")
                fi
                
                if [[ "${filename%.zim}" =~ _([0-9]{4}-[0-9]{2})$ ]]; then
                    local_date="${BASH_REMATCH[1]}"
                    local_timestamp=$(date -d "${local_date}-01" +%s 2>/dev/null || echo "0")
                else
                    local_timestamp=$(stat -c%Y "$f")
                fi
                
                if [ -n "$remote_timestamp" ] && [ "$remote_timestamp" -gt "$local_timestamp" ]; then
                    reasons+=("newer: $latest_name")
                    if [ ${#reasons[@]} -eq 1 ]; then  # Only newer, not bigger
                        local size_ratio=100
                        if [ "$local_size" -gt 0 ]; then
                            size_ratio=$(( (remote_size * 100) / local_size ))
                        fi
                        if [ "$size_ratio" -ge 90 ]; then
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
                    if [ "$remote_size" -lt "$local_size" ]; then
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
            FILES_TO_UPDATE+=("$f|$latest_url|$latest_name")
        fi
        
        # Print status line
        if [ -z "${KIWIX_BACKGROUND:-}" ] && [ "${QUIET}" != "true" ]; then
            printf "%-40s %-15s %-15s %-15s %s\n" \
                "$filename" \
                "$(numfmt --to=iec-i --suffix=B "$local_size")" \
                "$(numfmt --to=iec-i --suffix=B "$remote_size")" \
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
    log "INFO" "Total download size needed: $(numfmt --to=iec-i --suffix=B "${total_download_size}")"
    
    # Check available space
    if [ $total_updates -gt 0 ]; then
        local free_space=$(get_free_space)
        if [ "${total_download_size}" -gt "${free_space}" ]; then
            log "ERROR" "Not enough free space for updates"
            log "ERROR" "Required: $(numfmt --to=iec-i --suffix=B "${total_download_size}")"
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
    
    log "INFO" "Starting smart update process"
    update_status "Starting update process"
    
    if [ ${#FILES_TO_UPDATE[@]} -eq 0 ]; then
        log "INFO" "No files need updating"
        return 0
    fi
    
    # Stop Kiwix service if running
    if [ -z "${KIWIX_BACKGROUND:-}" ] && manage_kiwix_service status; then
        touch "${WORK_DIR}/.kiwix_was_running"
        if ! manage_kiwix_service stop; then
            log "ERROR" "Cannot proceed without stopping Kiwix service"
            return 1
        fi
    fi
    
    # Backup library
    backup_library_xml
    
    # Process updates
    for entry in "${FILES_TO_UPDATE[@]}"; do
        local f remote_url new_name
        f=$(echo "$entry" | cut -d'|' -f1)
        remote_url=$(echo "$entry" | cut -d'|' -f2)
        new_name=$(echo "$entry" | cut -d'|' -f3)
        
        local filename=$(basename "$f")
        local new_filepath="${WORK_DIR}/${new_name}.zim"
        
        log "INFO" "Updating ${filename} to ${new_name}.zim"
        
        # Check space if different files
        if [ "$f" != "$new_filepath" ]; then
            local remote_size
            if remote_size=$(get_remote_size "$remote_url"); then
                if ! check_disk_space "$remote_size"; then
                    log "ERROR" "Not enough space for ${new_name}.zim"
                    total_failed=$((total_failed + 1))
                    if ! $CONTINUE_ON_ERROR; then
                        update_success=false
                        break
                    fi
                    continue
                fi
            fi
        fi
        
        # Download
        if ! download_file "$remote_url" "$new_filepath"; then
            log "ERROR" "Failed to update ${filename}"
            total_failed=$((total_failed + 1))
            if ! $CONTINUE_ON_ERROR; then
                update_success=false
                break
            fi
        else
            total_updated=$((total_updated + 1))
            log "INFO" "Successfully downloaded ${new_name}.zim"
            
            # Handle library and old file
            if [ "$f" != "$new_filepath" ] && [ -f "$f" ]; then
                log "INFO" "Transitioning from $filename to ${new_name}.zim"
                
                # Remove old from library
                local old_book_id=""
                if [ -f "${ZIM_LIBRARY}" ]; then
                    while IFS= read -r line; do
                        if [[ "$line" =~ path=\"[^\"]*/${filename}\" ]] || [[ "$line" =~ path=\"${filename}\" ]]; then
                            if [[ "$line" =~ id=\"([^\"]+)\" ]]; then
                                old_book_id="${BASH_REMATCH[1]}"
                                break
                            fi
                        fi
                    done < "${ZIM_LIBRARY}"
                fi
                
                if [ -n "$old_book_id" ]; then
                    log "INFO" "Removing old entry from library"
                    kiwix-manage "${ZIM_LIBRARY}" remove "$old_book_id" 2>/dev/null || true
                fi
                
                # Add new to library
                log "INFO" "Adding new file to library"
                kiwix-manage "${ZIM_LIBRARY}" add "$new_filepath" 2>/dev/null || true
                
                # Remove old file
                log "INFO" "Removing old file: $filename"
                rm -f "$f"
            else
                # Same filename, check if in library
                if [ -f "${ZIM_LIBRARY}" ]; then
                    if ! grep -q "path=\".*${filename}\"" "${ZIM_LIBRARY}"; then
                        log "INFO" "Adding ${filename} to library"
                        kiwix-manage "${ZIM_LIBRARY}" add "$new_filepath" 2>/dev/null || true
                    fi
                fi
            fi
        fi
        
        # Update progress
        local current=$((total_updated + total_failed))
        local total=${#FILES_TO_UPDATE[@]}
        update_progress "$current" "$total" "$filename"
    done
    
    # Final library cleanup
    if [ $total_updated -gt 0 ]; then
        log "INFO" "Running final library cleanup..."
        update_kiwix_library
    fi
    
    # Restore Kiwix service
    if [ -f "${WORK_DIR}/.kiwix_was_running" ]; then
        log "INFO" "Restarting Kiwix service..."
        manage_kiwix_service start || log "ERROR" "Failed to restore Kiwix service"
        rm -f "${WORK_DIR}/.kiwix_was_running"
    fi
    
    # Final status
    if $update_success; then
        log "INFO" "Smart update completed successfully"
        log "INFO" "Files updated: ${total_updated}"
        [ $total_failed -gt 0 ] && log "WARN" "Files failed: ${total_failed}"
        return 0
    else
        log "ERROR" "Smart update completed with errors"
        log "ERROR" "Files updated: ${total_updated}, failed: ${total_failed}"
        return 1
    fi
}

stop_update() {
    if [ -f "${PID_FILE}" ]; then
        local pid=$(cat "${PID_FILE}")
        if kill -0 "${pid}" 2>/dev/null; then
            log "INFO" "Stopping update process (PID: ${pid})"
            kill "${pid}"
            
            # Wait up to 30 seconds for graceful shutdown
            local count=0
            while kill -0 "${pid}" 2>/dev/null && [ $count -lt 30 ]; do
                sleep 1
                count=$((count + 1))
            done
            
            # Force kill if still running
            if kill -0 "${pid}" 2>/dev/null; then
                log "WARN" "Forcing process termination"
                kill -9 "${pid}"
            fi
            
            log "INFO" "Update process stopped"
            return 0
        else
            log "WARN" "No running update process found"
            rm -f "${PID_FILE}"
            return 1
        fi
    else
        log "ERROR" "No PID file found"
        return 1
    fi
}

clean_state() {
    # Create work directory if it doesn't exist
    mkdir -p "${WORK_DIR}" 2>/dev/null || true
    
    # Clean up state files (use || true to prevent failures)
    rm -f "${WORK_DIR}"/.kiwix_update* \
          "${WORK_DIR}"/kiwix_update.log* \
          "${WORK_DIR}"/.heartbeat \
          "${STATUS_FILE}" \
          "${LIBRARY_CACHE}" 2>/dev/null || true
    
    # Remove temp directory if it exists
    if [ -d "${TEMP_DIR}" ]; then
        rm -rf "${TEMP_DIR}" 2>/dev/null || true
    fi
}

main() {
    # Save original arguments for background mode
    ORIGINAL_ARGS=("$@")

    # Handle simple commands first
    case "${1:-help}" in
        status)
            check_status
            exit $?
            ;;
        help|-h|--help)
            show_help
            exit 0
            ;;
        clean)
            clean_state
            echo "All logs and state files cleared"
            exit 0
            ;;
    esac

    # Store command and shift
    COMMAND="${1:-help}"
    shift

    # Parse arguments with basic validation
    while getopts "hycs:d:rbqp:m:vu:" opt; do
        case $opt in
            h) show_help; exit 0 ;;
            y) YES_TO_ALL=true ;;
            c) CONTINUE_ON_ERROR=true ;;
            s)
                if [[ "${OPTARG}" == :* ]]; then
                    START_LETTER="${OPTARG#:}"
                    if [[ ! "$START_LETTER" =~ ^[A-Za-z]$ ]]; then
                        echo "Invalid start letter. Use -s:[LETTER]" >&2
                        exit 1
                    fi
                    START_LETTER="${START_LETTER^^}"
                else
                    echo "Invalid format. Use -s:[LETTER]" >&2
                    exit 1
                fi
                ;;
            d)
                if [[ "${OPTARG}" == :* ]]; then
                    DAYS_OLD="${OPTARG#:}"
                    if ! [[ "$DAYS_OLD" =~ ^[0-9]+$ ]] || [ "$DAYS_OLD" -gt 3650 ]; then
                        echo "Invalid days. Use -d:[NUMBER]" >&2
                        exit 1
                    fi
                else
                    echo "Invalid format. Use -d:[NUMBER]" >&2
                    exit 1
                fi
                ;;
            r) RESUME=true ;;
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

    # Clean start handling
    if ! ${YES_TO_ALL}; then
        if [ -f "${PID_FILE}" ]; then
            local pid=$(cat "${PID_FILE}")
            if kill -0 "$pid" 2>/dev/null; then
                echo "An update process is running (PID: $pid)"
                read -p "Stop it and start fresh? (y/N) " -n 1 -r
                echo
                if [[ $REPLY =~ ^[Yy]$ ]]; then
                    stop_update || exit 1
                else
                    echo "Aborted"
                    exit 1
                fi
            fi
        fi
        clean_state
    else
        # Non-interactive mode
        if [ ! -f "${PID_FILE}" ] || ! kill -0 "$(cat "${PID_FILE}" 2>/dev/null)" 2>/dev/null; then
            clean_state
        fi
    fi

    # Save criteria
    echo "${UPDATE_CRITERIA}" > "${CRITERIA_FILE}"

    # Background mode handling
    if [ "${BACKGROUND}" = "true" ] && [ -z "${KIWIX_BACKGROUND:-}" ]; then
        export KIWIX_BACKGROUND=1
        export UPDATE_CRITERIA
        
        # Redirect output and launch background process
        exec 3>&1
        exec 1>>"${LOG_FILE}" 2>&1
        
        nohup "$0" "${ORIGINAL_ARGS[@]}" </dev/null >>"${LOG_FILE}" 2>&1 &
        pid=$!
        
        echo $pid > "${PID_FILE}"
        
        echo "Process started in background with PID $pid. Use '$(basename "$0") status' to check progress." >&3
        exec 3>&-
        
        # Verify process started
        sleep 2
        if ! kill -0 $pid 2>/dev/null; then
            echo "Warning: Background process failed to start" >&2
            rm -f "${PID_FILE}"
            exit 1
        fi
        
        exit 0
    fi

    # Environment setup for main process
    if [ "$(id -u)" -ne 0 ]; then
        echo "Error: This script must be run as root" >&2
        exit 1
    fi
    
    if ! check_dependencies; then
        exit 1
    fi
    
    # Create directories
    for dir in "${WORK_DIR}" "${TEMP_DIR}" "${BACKUP_DIR}"; do
        mkdir -p "$dir" || exit 1
        chmod 755 "$dir" || exit 1
    done

    # Background process setup
    if [ -n "${KIWIX_BACKGROUND:-}" ]; then
        # Load criteria from file
        if [ -f "${CRITERIA_FILE}" ]; then
            UPDATE_CRITERIA=$(cat "${CRITERIA_FILE}")
        fi
        
        echo $ > "${PID_FILE}"
    fi

    # Set up cleanup
    trap 'cleanup' EXIT
    trap 'cleanup' SIGTERM SIGINT SIGHUP

    # Process commands
    case "$COMMAND" in
        check-updates)
            analyze_updates || exit 1
            ;;
        smart-update)
            analyze_updates && do_smart_update || exit 1
            ;;
        update-library)
            if [ "$(id -u)" -ne 0 ]; then
                echo "Error: This script must be run as root" >&2
                exit 1
            fi
            if ! check_dependencies; then
                exit 1
            fi
            
            # Stop Kiwix if running
            if manage_kiwix_service status; then
                manage_kiwix_service stop || exit 1
            fi
            
            update_kiwix_library
            
            # Restart if it was running
            if [ -f "${WORK_DIR}/.kiwix_was_running" ]; then
                manage_kiwix_service start || log "ERROR" "Failed to start Kiwix service"
                rm -f "${WORK_DIR}/.kiwix_was_running"
            fi
            ;;
        stop)
            stop_update || exit 1
            ;;
        *)
            echo "Unknown command: ${COMMAND}" >&2
            echo "Valid commands: check-updates, smart-update, update-library, status, stop, clean, help" >&2
            show_help
            exit 1
            ;;
    esac
}

# Call main with all arguments
main "$@"