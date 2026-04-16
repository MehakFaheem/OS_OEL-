#!/bin/bash
# =============================================================================
# backup_cleanup.sh — Automated Backup & Cleanup System
# =============================================================================
# Behaviour:
#   1. Creates /backup/backup_YYYY-MM-DD  (handles name conflicts with a suffix)
#   2. Moves files older than 30 days from /project → backup dir (preserves tree)
#   3. Deletes .tmp files older than 7 days directly (no backup)
#   4. Writes report.txt  (moved / deleted / space freed / permission errors)
#   5. Appends timestamped entries to cleanup.log
#   6. Handles:
#        - Name conflicts      → append _N counter to destination filename
#        - Permission errors   → log, record in report, continue
#        - /backup out of space→ abort backup phase, report clearly
# =============================================================================

# ── Configurable paths ──────────────────────────────────────────────────────
PROJECT_DIR="${PROJECT_DIR:-/project}"
BACKUP_BASE="${BACKUP_BASE:-/backup}"
LOG_FILE="${LOG_FILE:-${BACKUP_BASE}/cleanup.log}"
REPORT_FILE="${REPORT_FILE:-${BACKUP_BASE}/report.txt}"

# Age thresholds (in days)
BACKUP_AGE=30          # move files older than this to backup
TMP_DELETE_AGE=7       # delete .tmp files older than this

# ── Derived values ───────────────────────────────────────────────────────────
TODAY=$(date +%F)                          # YYYY-MM-DD
BACKUP_DIR="${BACKUP_BASE}/backup_${TODAY}"
SCRIPT_START=$(date "+%Y-%m-%d %H:%M:%S")

# ── Counters ─────────────────────────────────────────────────────────────────
MOVED_COUNT=0
DELETED_COUNT=0
PERM_ERROR_COUNT=0
SPACE_FREED_BYTES=0

declare -a MOVED_FILES=()
declare -a DELETED_FILES=()
declare -a PERM_ERRORS=()

# =============================================================================
# Helper: log a message with timestamp to cleanup.log
# =============================================================================
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "${LOG_FILE}"
}

# =============================================================================
# Helper: print + log
# =============================================================================
info() {
    echo "$*"
    log "INFO  $*"
}

# =============================================================================
# Helper: human-readable bytes
# =============================================================================
human_bytes() {
    local bytes=$1
    if   [ "${bytes}" -ge 1073741824 ]; then printf "%.2f GB" "$(echo "scale=2; ${bytes}/1073741824" | bc)"
    elif [ "${bytes}" -ge 1048576 ];    then printf "%.2f MB" "$(echo "scale=2; ${bytes}/1048576"    | bc)"
    elif [ "${bytes}" -ge 1024 ];       then printf "%.2f KB" "$(echo "scale=2; ${bytes}/1024"       | bc)"
    else printf "%d B" "${bytes}"
    fi
}

# =============================================================================
# Helper: resolve name conflict — returns a unique destination path
#   Usage: unique_dest <dest_path>
# =============================================================================
unique_dest() {
    local dest="$1"
    if [ ! -e "${dest}" ]; then
        echo "${dest}"
        return
    fi
    local dir  base ext counter=1
    dir=$(dirname  "${dest}")
    base=$(basename "${dest}")
    # split extension (handles dotfiles with no extension)
    if [[ "${base}" == *.* && "${base}" != .* ]]; then
        ext=".${base##*.}"
        base="${base%.*}"
    else
        ext=""
    fi
    while [ -e "${dir}/${base}_${counter}${ext}" ]; do
        (( counter++ ))
    done
    echo "${dir}/${base}_${counter}${ext}"
}

# =============================================================================
# PHASE 0 — Preflight checks
# =============================================================================
preflight() {
    info "=== Preflight checks ==="

    # Ensure /project exists
    if [ ! -d "${PROJECT_DIR}" ]; then
        log "FATAL /project directory '${PROJECT_DIR}' does not exist."
        echo "ERROR: ${PROJECT_DIR} not found. Aborting." >&2
        exit 1
    fi

    # Ensure /backup exists (or create it)
    if [ ! -d "${BACKUP_BASE}" ]; then
        if mkdir -p "${BACKUP_BASE}" 2>/dev/null; then
            info "Created backup base directory: ${BACKUP_BASE}"
        else
            log "FATAL Cannot create ${BACKUP_BASE}"
            echo "ERROR: Cannot create ${BACKUP_BASE}. Aborting." >&2
            exit 1
        fi
    fi

    # Ensure log file is writable (touch it)
    touch "${LOG_FILE}" 2>/dev/null || {
        echo "ERROR: Cannot write to log file ${LOG_FILE}. Aborting." >&2
        exit 1
    }

    log "---- Session start: ${SCRIPT_START} ----"
    info "PROJECT_DIR : ${PROJECT_DIR}"
    info "BACKUP_BASE : ${BACKUP_BASE}"
    info "BACKUP_DIR  : ${BACKUP_DIR}"
}

# =============================================================================
# PHASE 1 — Create today's backup directory (handle conflict with _N suffix)
# =============================================================================
create_backup_dir() {
    info "=== Phase 1: Creating backup directory ==="
    local dir="${BACKUP_DIR}"
    local counter=1
    while [ -e "${dir}" ]; do
        dir="${BACKUP_BASE}/backup_${TODAY}_${counter}"
        (( counter++ ))
    done
    BACKUP_DIR="${dir}"   # update global

    if mkdir -p "${BACKUP_DIR}"; then
        info "Backup directory created: ${BACKUP_DIR}"
    else
        log "FATAL Cannot create backup directory ${BACKUP_DIR}"
        echo "ERROR: Cannot create ${BACKUP_DIR}. Aborting." >&2
        exit 1
    fi
}

# =============================================================================
# PHASE 2 — Check available space in /backup before moving files
#            Compares total size of files-to-move against available space.
# =============================================================================
check_space() {
    info "=== Phase 2: Space check ==="

    # Total size of candidates (files older than BACKUP_AGE, excluding .tmp)
    local required_kb
    required_kb=$(find "${PROJECT_DIR}" -type f ! -name "*.tmp" \
        -mtime +${BACKUP_AGE} 2>/dev/null \
        -exec du -k {} + 2>/dev/null | awk '{sum+=$1} END{print sum+0}')

    # Available space in /backup (KB)
    local available_kb
    available_kb=$(df -k "${BACKUP_BASE}" 2>/dev/null | awk 'NR==2{print $4}')

    info "Space required  : ${required_kb} KB"
    info "Space available : ${available_kb} KB"

    if [ "${required_kb}" -gt "${available_kb}" ]; then
        log "ERROR /backup is out of space. Required: ${required_kb} KB, Available: ${available_kb} KB"
        echo ""
        echo "⚠  WARNING: Not enough space in ${BACKUP_BASE}."
        echo "   Required : ${required_kb} KB"
        echo "   Available: ${available_kb} KB"
        echo "   Backup phase will be SKIPPED. Cleanup of .tmp files will still proceed."
        echo ""
        log "WARN  Backup phase skipped due to insufficient space."
        SKIP_BACKUP=true
    else
        SKIP_BACKUP=false
        info "Space check passed."
    fi
}

# =============================================================================
# PHASE 3 — Move files older than 30 days (not .tmp) into backup
# =============================================================================
move_old_files() {
    info "=== Phase 3: Moving files older than ${BACKUP_AGE} days ==="

    if [ "${SKIP_BACKUP}" = true ]; then
        info "Skipping backup phase (insufficient space)."
        return
    fi

    # Collect candidates
    while IFS= read -r -d '' src_file; do

        # Skip .tmp files — they are handled in Phase 4
        [[ "${src_file}" == *.tmp ]] && continue

        # Compute relative path inside /project
        local rel_path="${src_file#${PROJECT_DIR}/}"
        local rel_dir
        rel_dir=$(dirname "${rel_path}")

        # Recreate subdirectory structure under backup dir
        local dest_dir="${BACKUP_DIR}/${rel_dir}"
        mkdir -p "${dest_dir}" 2>/dev/null

        local dest_file="${dest_dir}/$(basename "${src_file}")"

        # ── Resolve name conflict ────────────────────────────────────────
        dest_file=$(unique_dest "${dest_file}")

        # ── Get file size before moving ──────────────────────────────────
        local fsize
        fsize=$(du -b "${src_file}" 2>/dev/null | awk '{print $1}')
        fsize=${fsize:-0}

        # ── Attempt move ─────────────────────────────────────────────────
        if mv "${src_file}" "${dest_file}" 2>/dev/null; then
            (( MOVED_COUNT++ ))
            (( SPACE_FREED_BYTES += fsize ))   # space freed from /project
            MOVED_FILES+=("${src_file} → ${dest_file}")
            log "MOVED ${src_file} → ${dest_file} (${fsize} bytes)"
        else
            # Could be a permission error
            (( PERM_ERROR_COUNT++ ))
            PERM_ERRORS+=("MOVE FAILED (permission?): ${src_file}")
            log "ERROR Cannot move ${src_file} — permission denied or locked"
        fi

    done < <(find "${PROJECT_DIR}" -type f ! -name "*.tmp" \
        -mtime +${BACKUP_AGE} -print0 2>/dev/null)

    info "Moved ${MOVED_COUNT} file(s)."
}

# =============================================================================
# PHASE 4 — Delete .tmp files older than 7 days (no backup)
# =============================================================================
delete_tmp_files() {
    info "=== Phase 4: Deleting .tmp files older than ${TMP_DELETE_AGE} days ==="

    while IFS= read -r -d '' tmp_file; do

        local fsize
        fsize=$(du -b "${tmp_file}" 2>/dev/null | awk '{print $1}')
        fsize=${fsize:-0}

        if rm "${tmp_file}" 2>/dev/null; then
            (( DELETED_COUNT++ ))
            (( SPACE_FREED_BYTES += fsize ))
            DELETED_FILES+=("${tmp_file}")
            log "DELETED ${tmp_file} (${fsize} bytes)"
        else
            (( PERM_ERROR_COUNT++ ))
            PERM_ERRORS+=("DELETE FAILED (permission?): ${tmp_file}")
            log "ERROR Cannot delete ${tmp_file} — permission denied or locked"
        fi

    done < <(find "${PROJECT_DIR}" -type f -name "*.tmp" \
        -mtime +${TMP_DELETE_AGE} -print0 2>/dev/null)

    info "Deleted ${DELETED_COUNT} .tmp file(s)."
}

# =============================================================================
# PHASE 5 — Remove empty directories left in /project after cleanup
# =============================================================================
prune_empty_dirs() {
    info "=== Phase 5: Pruning empty subdirectories in ${PROJECT_DIR} ==="
    # -depth ensures children are processed before parents
    find "${PROJECT_DIR}" -mindepth 1 -type d -empty -delete 2>/dev/null
    log "INFO  Empty directory pruning complete."
}

# =============================================================================
# PHASE 6 — Generate report.txt
# =============================================================================
generate_report() {
    info "=== Phase 6: Generating report ==="

    local hr
    hr=$(human_bytes "${SPACE_FREED_BYTES}")

    {
        echo "============================================================"
        echo "  BACKUP & CLEANUP REPORT"
        echo "  Generated : $(date '+%Y-%m-%d %H:%M:%S')"
        echo "  Project   : ${PROJECT_DIR}"
        echo "  Backup Dir: ${BACKUP_DIR}"
        echo "============================================================"
        echo ""
        echo "SUMMARY"
        echo "-------"
        echo "  Files moved to backup : ${MOVED_COUNT}"
        echo "  .tmp files deleted    : ${DELETED_COUNT}"
        echo "  Total space cleared   : ${hr} (${SPACE_FREED_BYTES} bytes)"
        echo "  Permission errors     : ${PERM_ERROR_COUNT}"
        echo ""

        # ── Files moved ────────────────────────────────────────────────
        echo "FILES MOVED (older than ${BACKUP_AGE} days)"
        echo "--------------------------------------------"
        if [ ${#MOVED_FILES[@]} -eq 0 ]; then
            echo "  (none)"
        else
            for f in "${MOVED_FILES[@]}"; do
                echo "  • ${f}"
            done
        fi
        echo ""

        # ── Files deleted ──────────────────────────────────────────────
        echo ".TMP FILES DELETED (older than ${TMP_DELETE_AGE} days)"
        echo "--------------------------------------------------------"
        if [ ${#DELETED_FILES[@]} -eq 0 ]; then
            echo "  (none)"
        else
            for f in "${DELETED_FILES[@]}"; do
                echo "  • ${f}"
            done
        fi
        echo ""

        # ── Permission errors ──────────────────────────────────────────
        echo "PERMISSION / ACCESS ERRORS"
        echo "--------------------------"
        if [ ${#PERM_ERRORS[@]} -eq 0 ]; then
            echo "  (none)"
        else
            for e in "${PERM_ERRORS[@]}"; do
                echo "  ✗ ${e}"
            done
        fi
        echo ""
        echo "============================================================"
        echo "  END OF REPORT"
        echo "============================================================"
    } > "${REPORT_FILE}"

    info "Report written to: ${REPORT_FILE}"
    log "INFO  Report generated at ${REPORT_FILE}"
}

# =============================================================================
# MAIN
# =============================================================================
main() {
    preflight
    create_backup_dir
    check_space
    move_old_files
    delete_tmp_files
    prune_empty_dirs
    generate_report

    echo ""
    echo "════════════════════════════════════════"
    echo " Cleanup complete!"
    echo "   Moved   : ${MOVED_COUNT} file(s)"
    echo "   Deleted : ${DELETED_COUNT} .tmp file(s)"
    echo "   Freed   : $(human_bytes ${SPACE_FREED_BYTES})"
    echo "   Errors  : ${PERM_ERROR_COUNT}"
    echo "   Report  : ${REPORT_FILE}"
    echo "   Log     : ${LOG_FILE}"
    echo "════════════════════════════════════════"
    log "---- Session end. Moved=${MOVED_COUNT} Deleted=${DELETED_COUNT} Freed=${SPACE_FREED_BYTES}B Errors=${PERM_ERROR_COUNT} ----"
}

main "$@"
