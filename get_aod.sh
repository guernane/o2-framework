#!/bin/bash
# ==============================================================================
# get_aod.sh
# Resolve and download AO2D.root files from the ALICE Grid.
# Runs INSIDE the O2Physics Apptainer container via _o2_container().
# Never executed directly by the user.
#
# Environment variables (set by lib/run.sh before container call):
#   O2_PRODUCTION    production name          (e.g. LHC24aj)
#   O2_RUNS          comma-separated runs or "all"
#   O2_MAX_FILES     max files per run (0 = unlimited)
#   O2_DATA_MODE     "local" | "alien"
#   O2_GROUP_SIZE    files per group
#   ALICE_CERN_USER  CERN username for alien-token-init
#
# Bind mounts (set by lib/run.sh):
#   /data    ← host DATA_BASE     (downloaded AOD files, local mode)
#   /output  ← host WORKFLOW_OUTPUT/<production>  (filelists written here)
#
# Outputs (written to /output/):
#   group_NNN/filelist.txt   one file per group
#                            local mode: absolute host paths via /data/...
#                            alien mode: alien:///alice/... paths
#   .n_groups                total number of groups created
#
# Exit codes:
#   0  success
#   1  no files found or fatal download failure
# ==============================================================================

set -e

PRODUCTION="${O2_PRODUCTION:?O2_PRODUCTION not set}"
RUNS="${O2_RUNS:-all}"
MAX_FILES="${O2_MAX_FILES:-0}"
DATA_MODE="${O2_DATA_MODE:-local}"
GROUP_SIZE="${O2_GROUP_SIZE:-10}"
OUTPUT_BASE="/output"
LOCAL_DATA_BASE="/data"
PARALLEL_STREAMS=4

# Detect data type from production name
# MC:   digit after LHCYYx  (e.g. LHC25b4b6)
# Data: only letters after  (e.g. LHC24aj)
if echo "$PRODUCTION" | grep -qP 'LHC\d{2}[a-z]\d'; then
    DATA_TYPE="sim"
    GRID_BASE="/alice/sim"
else
    DATA_TYPE="data"
    GRID_BASE="/alice/data"
fi

YEAR="20$(echo "$PRODUCTION" | grep -oP '(?<=LHC)\d{2}')"
GRID_PRODUCTION_PATH="$GRID_BASE/$YEAR/$PRODUCTION"

echo "========================================"
echo "   ALICE Grid AOD resolver"
echo "   Production : $PRODUCTION  ($DATA_TYPE)"
echo "   Mode       : $DATA_MODE"
echo "   Runs       : $RUNS"
echo "   Max files  : ${MAX_FILES:-unlimited}"
echo "   Group size : $GROUP_SIZE"
echo "   Grid path  : $GRID_PRODUCTION_PATH"
echo "========================================"
echo ""

# ------------------------------------------------------------------------------
# Initialize ALICE Grid token (non-interactive)
# ------------------------------------------------------------------------------
echo "[INFO] Initializing ALICE Grid token..."
alien-token-init "$ALICE_CERN_USER" 2>/dev/null || \
    echo "[WARNING] alien-token-init failed — trying with existing token"

if ! alien.py pwd &>/dev/null; then
    echo "[ERROR] Cannot connect to ALICE Grid"
    exit 1
fi
echo "[INFO] Grid connection OK"
echo ""

# ------------------------------------------------------------------------------
# Build list of runs
# ------------------------------------------------------------------------------
if [ "$RUNS" = "all" ]; then
    echo "[INFO] Scanning runs under $GRID_PRODUCTION_PATH ..."
    RUN_LIST=$(alien.py ls "$GRID_PRODUCTION_PATH/" 2>/dev/null \
        | grep -oP '\d{6,9}' | sort -u || true)
    [ -z "$RUN_LIST" ] && { echo "[ERROR] No runs found"; exit 1; }
    echo "[INFO] Found $(echo "$RUN_LIST" | wc -l) run(s)"
else
    RUN_LIST=$(echo "$RUNS" | tr ',' '\n' | tr -d ' ' | sort -u)
    echo "[INFO] Requested $(echo "$RUN_LIST" | wc -l) run(s)"
fi

# ------------------------------------------------------------------------------
# Find all AO2D.root files
# ------------------------------------------------------------------------------
ALL_FILES_TMP=$(mktemp)

while IFS= read -r RUN; do
    [ -z "$RUN" ] && continue

    if [ "$DATA_TYPE" = "data" ]; then
        RUN_PATH="$GRID_PRODUCTION_PATH/$(printf '%09d' "$RUN")"
    else
        RUN_PATH="$GRID_PRODUCTION_PATH/0/$RUN"
    fi

    echo "[INFO] Scanning run $RUN ..."
    RUN_FILES=$(alien.py find "$RUN_PATH" -select AO2D.root 2>/dev/null || true)

    if [ -z "$RUN_FILES" ]; then
        echo "[WARNING] No AO2D.root found for run $RUN — skipping"
        continue
    fi

    N_RUN=$(echo "$RUN_FILES" | wc -l)
    echo "[INFO]   Found $N_RUN file(s)"

    if [ "$MAX_FILES" -gt 0 ] && [ "$N_RUN" -gt "$MAX_FILES" ]; then
        RUN_FILES=$(echo "$RUN_FILES" | head -n "$MAX_FILES")
        echo "[INFO]   Limited to $MAX_FILES file(s)"
    fi

    echo "$RUN_FILES" >> "$ALL_FILES_TMP"
done <<< "$RUN_LIST"

# Remove blank lines
grep -v '^$' "$ALL_FILES_TMP" > "${ALL_FILES_TMP}.clean" \
    && mv "${ALL_FILES_TMP}.clean" "$ALL_FILES_TMP"

TOTAL_FILES=$(wc -l < "$ALL_FILES_TMP")
if [ "$TOTAL_FILES" -eq 0 ]; then
    echo "[ERROR] No AO2D.root files found"
    rm -f "$ALL_FILES_TMP"
    exit 1
fi
echo ""
echo "[INFO] Total files found: $TOTAL_FILES"

# ------------------------------------------------------------------------------
# Split into groups and write filelists
# Bug fix: use temp files instead of subshells for counters
# ------------------------------------------------------------------------------
GROUP_NUM=0
FILE_NUM=0
GROUP_TMP=$(mktemp)

_write_group() {
    local GNUM="$1"
    local GROUP_FILE="$2"   # temp file with list of grid paths for this group
    local N_FILES
    N_FILES=$(wc -l < "$GROUP_FILE")
    [ "$N_FILES" -eq 0 ] && return

    local GROUP_TAG
    GROUP_TAG=$(printf "group_%03d" "$GNUM")
    local GROUP_DIR="$OUTPUT_BASE/$GROUP_TAG"
    mkdir -p "$GROUP_DIR"
    local FILELIST="$GROUP_DIR/filelist.txt"
    > "$FILELIST"  # create empty

    if [ "$DATA_MODE" = "alien" ]; then
        # alien:// paths — DPL reads directly from the Grid
        while IFS= read -r GRID_FILE; do
            [ -z "$GRID_FILE" ] && continue
            echo "alien://${GRID_FILE}" >> "$FILELIST"
        done < "$GROUP_FILE"
        echo "[INFO] $GROUP_TAG: $N_FILES file(s) → $FILELIST (alien mode)"
    else
        # local mode: download if not already present, write /data/... paths
        # /data is bind-mounted from host DATA_BASE
        local DOWNLOADED=0
        local SKIPPED=0
        local FAILED=0

        while IFS= read -r GRID_FILE; do
            [ -z "$GRID_FILE" ] && continue

            local REL_PATH="${GRID_FILE#$GRID_PRODUCTION_PATH/}"
            local LOCAL_FILE_CONTAINER="/data/$PRODUCTION/$REL_PATH"
            local LOCAL_DIR_CONTAINER
            LOCAL_DIR_CONTAINER=$(dirname "$LOCAL_FILE_CONTAINER")
            mkdir -p "$LOCAL_DIR_CONTAINER"

            if [ -f "$LOCAL_FILE_CONTAINER" ]; then
                echo "$LOCAL_FILE_CONTAINER" >> "$FILELIST"
                SKIPPED=$(( SKIPPED + 1 ))
                continue
            fi

            echo "[DOWN] $GRID_FILE"
            if alien.py cp \
                -S "$PARALLEL_STREAMS" \
                -cksum \
                -retry 3 \
                "$GRID_FILE" \
                "file://$LOCAL_FILE_CONTAINER" 2>&1; then
                echo "$LOCAL_FILE_CONTAINER" >> "$FILELIST"
                DOWNLOADED=$(( DOWNLOADED + 1 ))
            else
                echo "[FAIL] $GRID_FILE"
                rm -f "$LOCAL_FILE_CONTAINER"
                FAILED=$(( FAILED + 1 ))
            fi
        done < "$GROUP_FILE"

        echo "[INFO] $GROUP_TAG: $N_FILES file(s) — downloaded=$DOWNLOADED skipped=$SKIPPED failed=$FAILED"
        [ "$FAILED" -gt 0 ] && \
            echo "[WARNING] $FAILED download(s) failed in $GROUP_TAG"
    fi
}

# Split ALL_FILES_TMP into groups using a single loop (no subshell for counters)
> "$GROUP_TMP"
while IFS= read -r GRID_FILE; do
    [ -z "$GRID_FILE" ] && continue
    echo "$GRID_FILE" >> "$GROUP_TMP"
    FILE_NUM=$(( FILE_NUM + 1 ))

    if [ "$FILE_NUM" -ge "$GROUP_SIZE" ]; then
        _write_group "$GROUP_NUM" "$GROUP_TMP"
        GROUP_NUM=$(( GROUP_NUM + 1 ))
        FILE_NUM=0
        > "$GROUP_TMP"
    fi
done < "$ALL_FILES_TMP"

# Write last partial group
if [ -s "$GROUP_TMP" ]; then
    _write_group "$GROUP_NUM" "$GROUP_TMP"
    GROUP_NUM=$(( GROUP_NUM + 1 ))
fi

rm -f "$ALL_FILES_TMP" "$GROUP_TMP"

echo ""
echo "========================================"
echo "   Resolution complete"
echo "   Production : $PRODUCTION"
echo "   Mode       : $DATA_MODE"
echo "   Files      : $TOTAL_FILES"
echo "   Groups     : $GROUP_NUM (size: $GROUP_SIZE)"
echo "   Output     : $OUTPUT_BASE/"
echo "========================================"

# Write group count for lib/run.sh to read
echo "$GROUP_NUM" > "$OUTPUT_BASE/.n_groups"
