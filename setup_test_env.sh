#!/bin/bash
# =============================================================================
# setup_test_env.sh — Creates a realistic sample /project tree for testing
# =============================================================================
# Run this BEFORE backup_cleanup.sh to populate test data.
# Uses touch -d to fake old modification times.
# =============================================================================

PROJECT_DIR="${PROJECT_DIR:-/project}"
BACKUP_DIR="${BACKUP_BASE:-/backup}"

echo "Setting up test environment in ${PROJECT_DIR} ..."

# ── Create directory structure ───────────────────────────────────────────────
mkdir -p "${PROJECT_DIR}/alice/src"
mkdir -p "${PROJECT_DIR}/alice/logs"
mkdir -p "${PROJECT_DIR}/bob/data"
mkdir -p "${PROJECT_DIR}/bob/temp"
mkdir -p "${PROJECT_DIR}/shared/archives"
mkdir -p "${PROJECT_DIR}/shared/reports"
mkdir -p "${BACKUP_DIR}"

# ── Helper: create file, set age, optional content ───────────────────────────
mkfile() {
    local path="$1"   # full path
    local age="$2"    # age in days (positive integer)
    local size="$3"   # rough content size in KB (uses dd)
    local type="$4"   # 'normal' | 'noperm'

    # Write a bit of dummy content proportional to size
    local kb="${size:-1}"
    dd if=/dev/urandom bs=1024 count="${kb}" 2>/dev/null | \
        base64 > "${path}" 2>/dev/null
    touch -d "${age} days ago" "${path}"
    [ "${type}" = "noperm" ] && chmod 000 "${path}"
}

echo "  Creating alice's files ..."
mkfile "${PROJECT_DIR}/alice/src/main.py"          5   2   normal
mkfile "${PROJECT_DIR}/alice/src/utils.py"        35   3   normal    # old → move
mkfile "${PROJECT_DIR}/alice/src/old_utils.py"    60   4   normal    # old → move
mkfile "${PROJECT_DIR}/alice/logs/app.log"        40   1   normal    # old → move
mkfile "${PROJECT_DIR}/alice/logs/debug.log"       3   1   normal
mkfile "${PROJECT_DIR}/alice/logs/session.tmp"    10   1   normal    # old .tmp → delete
mkfile "${PROJECT_DIR}/alice/logs/crash.tmp"       4   1   normal    # recent .tmp → keep

echo "  Creating bob's files ..."
mkfile "${PROJECT_DIR}/bob/data/dataset.csv"      45  10   normal    # old → move
mkfile "${PROJECT_DIR}/bob/data/results.csv"       2   5   normal
mkfile "${PROJECT_DIR}/bob/data/archive.zip"      90  50   normal    # old large zip → move
mkfile "${PROJECT_DIR}/bob/temp/scratch.tmp"      15   2   normal    # old .tmp → delete
mkfile "${PROJECT_DIR}/bob/temp/new_scratch.tmp"   1   1   normal    # recent .tmp → keep
mkfile "${PROJECT_DIR}/bob/temp/work_notes.txt"   32   1   normal    # old → move

echo "  Creating shared files ..."
mkfile "${PROJECT_DIR}/shared/archives/release_v1.zip"   50  30   normal   # old → move
mkfile "${PROJECT_DIR}/shared/archives/release_v2.zip"   10  30   normal   # recent → keep
mkfile "${PROJECT_DIR}/shared/reports/q1_report.txt"     45   5   normal   # old → move
mkfile "${PROJECT_DIR}/shared/reports/q2_report.txt"      5   5   normal

# ── Name conflict test: two old files with the same name in different dirs
#    that map to the same relative path after restructuring (edge case)
mkfile "${PROJECT_DIR}/alice/logs/app.log"        31   1   normal    # will conflict with above

# ── Permission-denied test ───────────────────────────────────────────────────
echo "  Creating permission-restricted file ..."
mkfile "${PROJECT_DIR}/shared/reports/secret.log" 40   1   noperm   # perm error expected

echo ""
echo "Test environment ready."
echo ""
echo "Directory tree:"
find "${PROJECT_DIR}" | sort | sed 's|[^/]*/|  |g'
echo ""
echo "Run:  sudo ./backup_cleanup.sh"
echo "  or  PROJECT_DIR=${PROJECT_DIR} BACKUP_BASE=${BACKUP_DIR} ./backup_cleanup.sh"
