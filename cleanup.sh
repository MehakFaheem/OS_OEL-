#!/bin/bash

# ============================================================
#  cleanup.sh — Automated Backup & Cleanup System
#  Author : student
#  Purpose: Backs up old files, removes temp files, generates
#           a report and keeps an ongoing timestamped log.
# ============================================================

PROJECT_DIR="/home/mehak/project"
BACKUP_BASE="/home/mehak/backup"
LOG_FILE="/home/mehak/cleanup.log"
REPORT_FILE="/home/mehak/report.txt"

BACKUP_MIN_FREE_MB=100          # minimum free space required (MB)
DATE_TAG=$(date +%Y-%m-%d)
BACKUP_DIR="${BACKUP_BASE}/backup_${DATE_TAG}"

FILES_MOVED=0
FILES_DELETED=0
SPACE_CLEARED_KB=0
PERM_ERRORS=0

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# ── 0. Sanity checks ─────────────────────────────────────────
log "====== Cleanup session started ======"

if [ ! -d "$PROJECT_DIR" ]; then
    log "ERROR: Project directory $PROJECT_DIR not found. Exiting."
    exit 1
fi

mkdir -p "$BACKUP_BASE" 2>/dev/null

# ── 1. Disk space guard ──────────────────────────────────────
FREE_MB=$(df -m "$BACKUP_BASE" | awk 'NR==2 {print $4}')
log "Free space on backup volume: ${FREE_MB} MB"

if [ "$FREE_MB" -lt "$BACKUP_MIN_FREE_MB" ]; then
    log "ERROR: Not enough space on backup volume (need ${BACKUP_MIN_FREE_MB} MB, have ${FREE_MB} MB). Aborting backup."
    echo "CRITICAL: Backup aborted — insufficient disk space." >> "$REPORT_FILE"
    exit 2
fi

# ── 2. Create dated backup directory ────────────────────────
if [ -d "$BACKUP_DIR" ]; then
    # Name conflict resolution: append timestamp suffix
    BACKUP_DIR="${BACKUP_DIR}_$(date +%H%M%S)"
    log "Backup folder already existed for today. Using: $BACKUP_DIR"
fi
mkdir -p "$BACKUP_DIR"
log "Backup destination: $BACKUP_DIR"

# ── 3. Delete .tmp files older than 7 days (no backup) ──────
log "--- Phase 1: Deleting .tmp files older than 7 days ---"

while IFS= read -r -d '' tmpfile; do
    SIZE_KB=$(du -k "$tmpfile" 2>/dev/null | cut -f1)
    if rm "$tmpfile" 2>/dev/null; then
        log "DELETED (tmp): $tmpfile  [${SIZE_KB}K]"
        SPACE_CLEARED_KB=$((SPACE_CLEARED_KB + SIZE_KB))
        FILES_DELETED=$((FILES_DELETED + 1))
    else
        log "PERM ERROR: Cannot delete $tmpfile"
        PERM_ERRORS=$((PERM_ERRORS + 1))
    fi
done < <(find "$PROJECT_DIR" -type f -name "*.tmp" -mtime +7 -print0)

# ── 4. Move files older than 30 days into backup ────────────
log "--- Phase 2: Moving files older than 30 days to backup ---"

while IFS= read -r -d '' oldfile; do
    # Build mirror path inside backup dir
    RELATIVE="${oldfile#$PROJECT_DIR/}"
    DEST_DIR="${BACKUP_DIR}/$(dirname "$RELATIVE")"
    DEST_PATH="${BACKUP_DIR}/${RELATIVE}"

    mkdir -p "$DEST_DIR" 2>/dev/null

    # Conflict resolution: if dest already exists, rename with timestamp
    if [ -e "$DEST_PATH" ]; then
        DEST_PATH="${DEST_PATH}.$(date +%s)"
        log "CONFLICT resolved: renaming to $(basename "$DEST_PATH")"
    fi

    SIZE_KB=$(du -k "$oldfile" 2>/dev/null | cut -f1)

    if mv "$oldfile" "$DEST_PATH" 2>/dev/null; then
        log "MOVED: $oldfile  ->  $DEST_PATH  [${SIZE_KB}K]"
        SPACE_CLEARED_KB=$((SPACE_CLEARED_KB + SIZE_KB))
        FILES_MOVED=$((FILES_MOVED + 1))
    else
        log "PERM ERROR: Cannot move $oldfile"
        PERM_ERRORS=$((PERM_ERRORS + 1))
    fi
done < <(find "$PROJECT_DIR" -type f ! -name "*.tmp" -mtime +30 -print0)

# ── 5. Generate report.txt ───────────────────────────────────
log "--- Phase 3: Generating report ---"

{
    echo "========================================"
    echo "  Backup & Cleanup Report"
    echo "  Generated : $(date '+%Y-%m-%d %H:%M:%S')"
    echo "  Backup dir: $BACKUP_DIR"
    echo "========================================"
    echo ""
    echo "SUMMARY"
    echo "-------"
    echo "  Files moved to backup : $FILES_MOVED"
    echo "  Temp files deleted    : $FILES_DELETED"
    printf "  Total space cleared   : %s MB\n" "$(echo "scale=2; $SPACE_CLEARED_KB/1024" | bc)"
    echo "  Permission errors     : $PERM_ERRORS"
    echo ""
    echo "FILES MOVED"
    echo "-----------"
    find "$BACKUP_DIR" -type f 2>/dev/null | while read -r f; do
        echo "  $f"
    done
    echo ""
    echo "REMAINING IN PROJECT (recent files kept)"
    echo "----------------------------------------"
    find "$PROJECT_DIR" -type f 2>/dev/null | while read -r f; do
        echo "  $f"
    done
    echo ""
    if [ "$PERM_ERRORS" -gt 0 ]; then
        echo "NOTE: $PERM_ERRORS permission error(s) encountered. Check cleanup.log for details."
    fi
    echo "========================================"
} > "$REPORT_FILE"

log "Report written to $REPORT_FILE"
log "====== Cleanup session complete ======"
log "  Moved=$FILES_MOVED | Deleted=$FILES_DELETED | Space=${SPACE_CLEARED_KB}K | Errors=$PERM_ERRORS"
