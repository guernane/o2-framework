#!/bin/bash
# ==============================================================================
# lib/merge.sh
# Merge AnalysisResults.root files from all completed groups using hadd.
# Consolidates bookkeeping fragment JSONs into the main JSON file.
# Sourced by o2.sh — never executed directly.
#
# Entry point: cmd_merge "$@"
# ==============================================================================

# ==============================================================================
# cmd_merge
# ==============================================================================
cmd_merge() {
    local WORKFLOW=""
    local PRODUCTION=""
    local FORCE=0

    while [[ $# -gt 0 ]]; do
        case $1 in
            --force)   FORCE=1 ;;
            --help|-h) _merge_help; return 0 ;;
            -*)        log_warn "Unknown option: $1" ;;
            *)
                if   [ -z "$WORKFLOW"   ]; then WORKFLOW="$1"
                elif [ -z "$PRODUCTION" ]; then PRODUCTION="$1"
                fi
                ;;
        esac
        shift
    done

    [ -z "$WORKFLOW"   ] && { log_error "workflow name required";   _merge_help; exit 1; }
    [ -z "$PRODUCTION" ] && { log_error "production name required"; _merge_help; exit 1; }

    _resolve_workflow_paths "$WORKFLOW" "$PRODUCTION"
    load_apptainer

    local MERGE_DIR="$WORKFLOW_OUTPUT/merge"
    local MERGE_OUTPUT="$MERGE_DIR/AnalysisResults.root"
    local MERGE_LOG="$LOG_DIR/merge_${WORKFLOW}_${PRODUCTION}.log"
    mkdir -p "$MERGE_DIR"

    log_sep
    log_info "Merging results"
    log_info "Workflow   : $WORKFLOW"
    log_info "Production : $PRODUCTION"
    log_sep

    _consolidate_bookkeeping
    _collect_outputs "$FORCE"
    _run_hadd "$MERGE_DIR" "$MERGE_OUTPUT" "$MERGE_LOG"
    _finalize_bookkeeping "$MERGE_OUTPUT"
    _merge_summary "$MERGE_OUTPUT"
}

_merge_help() {
    cat << 'EOF'
o2 merge <workflow> <production> [options]

Arguments:
  workflow     analysis workflow name  (e.g. proxies)
  production   production name         (e.g. LHC24aj)

Options:
  --force    merge available groups even if some failed
EOF
}

# ==============================================================================
# _consolidate_bookkeeping
# Merge all fragment JSONs into the main bookkeeping file using jq -s.
# jq -s is safe regardless of content (no fragile string concat).
# ==============================================================================
_consolidate_bookkeeping() {
    log_info "Consolidating bookkeeping fragments..."

    [ -f "$BOOKKEEPING_FILE" ] || {
        log_warn "Main bookkeeping file not found: $BOOKKEEPING_FILE"
        return
    }

    # Collect all fragment files
    local FRAGS=()
    for f in "$BOOKKEEPING_FRAGS"/*.json; do
        [ -f "$f" ] && FRAGS+=("$f")
    done

    if [ "${#FRAGS[@]}" -eq 0 ]; then
        log_warn "No fragment files found — bookkeeping not updated"
        return
    fi

    # Build groups object: merge all fragments into one JSON object
    # jq -s reads multiple files as an array, then converts to object keyed by .group
    local GROUPS_JSON
    GROUPS_JSON=$(jq -s 'map({key: .group, value: .}) | from_entries' \
        "${FRAGS[@]}")

    # Inject groups object into main bookkeeping file
    local TMP
    TMP=$(mktemp)
    jq --argjson groups "$GROUPS_JSON" '.groups = $groups' \
        "$BOOKKEEPING_FILE" > "$TMP" && mv "$TMP" "$BOOKKEEPING_FILE"

    log_info "Consolidated ${#FRAGS[@]} fragment(s) into $BOOKKEEPING_FILE"
}

# ==============================================================================
# _collect_outputs
# Build MERGE_INPUTS array from completed groups.
# Sets: MERGE_INPUTS, N_DONE, N_FAILED, N_MISSING
# ==============================================================================
_collect_outputs() {
    local FORCE="${1:-0}"
    MERGE_INPUTS=()
    N_DONE=0
    N_FAILED=0
    N_MISSING=0

    local N_GROUPS=0
    [ -f "$BOOKKEEPING_FILE" ] && \
        N_GROUPS=$(jq -r '.n_groups // 0' "$BOOKKEEPING_FILE")

    if [ "$N_GROUPS" -eq 0 ]; then
        log_warn "No bookkeeping found — scanning output directories"
        for d in "$WORKFLOW_OUTPUT"/group_*/; do
            local f="$d/AnalysisResults.root"
            if [ -f "$f" ]; then
                MERGE_INPUTS+=("$f")
                N_DONE=$(( N_DONE + 1 ))
            fi
        done
        return
    fi

    for i in $(seq 0 $(( N_GROUPS - 1 ))); do
        local GROUP_TAG
        GROUP_TAG=$(printf "group_%03d" "$i")
        local FRAG="$BOOKKEEPING_FRAGS/${GROUP_TAG}.json"
        local OUTPUT="$WORKFLOW_OUTPUT/$GROUP_TAG/AnalysisResults.root"

        if [ -f "$FRAG" ]; then
            local STATUS
            STATUS=$(jq -r '.status // "unknown"' "$FRAG")
            if [ "$STATUS" = "done" ] && [ -f "$OUTPUT" ]; then
                MERGE_INPUTS+=("$OUTPUT")
                N_DONE=$(( N_DONE + 1 ))
            else
                log_warn "$GROUP_TAG status=$STATUS — skipping"
                N_FAILED=$(( N_FAILED + 1 ))
            fi
        else
            log_warn "$GROUP_TAG has no bookkeeping fragment"
            N_MISSING=$(( N_MISSING + 1 ))
        fi
    done

    if [ "${#MERGE_INPUTS[@]}" -eq 0 ]; then
        log_error "No completed groups to merge"
        exit 1
    fi

    if [ "$(( N_FAILED + N_MISSING ))" -gt 0 ] && [ "$FORCE" -eq 0 ]; then
        log_error "$N_FAILED failed + $N_MISSING missing group(s)"
        echo ""
        echo "  Options:"
        echo "    o2 run $WORKFLOW $PRODUCTION --resume   retry failed groups first"
        echo "    o2 merge $WORKFLOW $PRODUCTION --force  merge available groups anyway"
        exit 1
    fi

    [ "$N_FAILED"  -gt 0 ] && log_warn "Partial merge: $N_FAILED failed group(s) skipped"
    [ "$N_MISSING" -gt 0 ] && log_warn "Partial merge: $N_MISSING missing group(s) skipped"
}

# ==============================================================================
# _run_hadd
# Run hadd inside the container.
#
# Key fix (Bug 1): paths passed to hadd must be valid INSIDE the container.
# MERGE_INPUTS contains host paths under WORKFLOW_OUTPUT.
# WORKFLOW_OUTPUT is bind-mounted as /output inside the container.
# We convert each path from host to container by replacing the prefix.
# ==============================================================================
_run_hadd() {
    local MERGE_DIR="$1"
    local MERGE_OUTPUT="$2"
    local MERGE_LOG="$3"

    log_info "Merging ${#MERGE_INPUTS[@]} AnalysisResults.root file(s)..."
    log_info "Output : $MERGE_OUTPUT"
    log_info "Log    : $MERGE_LOG"

    # Build container-side input paths
    # Host:      WORKFLOW_OUTPUT/group_NNN/AnalysisResults.root
    # Container: /output/group_NNN/AnalysisResults.root
    local CONTAINER_INPUTS=()
    for HOST_PATH in "${MERGE_INPUTS[@]}"; do
        local CONTAINER_PATH="/output/${HOST_PATH#$WORKFLOW_OUTPUT/}"
        CONTAINER_INPUTS+=("$CONTAINER_PATH")
    done

    # Container-side merge output path
    local MERGE_OUTPUT_CONTAINER="/output/merge/AnalysisResults.root"

    local EXIT_CODE=0
    _o2_container \
        -B "$WORKFLOW_OUTPUT:/output" \
        -- bash -c "
            hadd -f ${MERGE_OUTPUT_CONTAINER} ${CONTAINER_INPUTS[*]}
        " 2>&1 | tee "$MERGE_LOG" || EXIT_CODE=$?

    if [ "$EXIT_CODE" -ne 0 ] || [ ! -f "$MERGE_OUTPUT" ]; then
        log_error "hadd failed — check $MERGE_LOG"
        _write_merge_bookkeeping "failed" "" ""
        exit 1
    fi
}

# ==============================================================================
# _finalize_bookkeeping
# ==============================================================================
_finalize_bookkeeping() {
    local MERGE_OUTPUT="$1"
    local NOW
    NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local SIZE MD5
    SIZE=$(du -sh "$MERGE_OUTPUT" | cut -f1)
    MD5=$(md5sum "$MERGE_OUTPUT" | cut -d' ' -f1)

    _write_merge_bookkeeping "done" "$MERGE_OUTPUT" "$MD5"
    log_info "Bookkeeping updated: $BOOKKEEPING_FILE"
}

_write_merge_bookkeeping() {
    local STATUS="$1"
    local PATH_VAL="$2"
    local MD5="$3"
    local NOW
    NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    [ -f "$BOOKKEEPING_FILE" ] || return

    local TMP
    TMP=$(mktemp)
    jq --arg status "$STATUS" \
       --arg path   "$PATH_VAL" \
       --arg md5    "$MD5" \
       --arg date   "$NOW" \
       --argjson ndone    "$N_DONE" \
       --argjson nfailed  "$(( N_FAILED + N_MISSING ))" \
       '.merge = {
           "status":           $status,
           "path":             $path,
           "md5":              $md5,
           "date":             $date,
           "n_groups_merged":  $ndone,
           "n_groups_skipped": $nfailed
       }' "$BOOKKEEPING_FILE" > "$TMP" && mv "$TMP" "$BOOKKEEPING_FILE"
}

# ==============================================================================
# _merge_summary
# ==============================================================================
_merge_summary() {
    local MERGE_OUTPUT="$1"
    local SIZE
    SIZE=$(du -sh "$MERGE_OUTPUT" 2>/dev/null | cut -f1)
    echo ""
    log_sep
    log_info "Merge complete"
    log_info "Merged  : $N_DONE group(s)"
    [ "$(( N_FAILED + N_MISSING ))" -gt 0 ] && \
        log_warn "Skipped : $(( N_FAILED + N_MISSING )) group(s)"
    log_info "Output  : $MERGE_OUTPUT ($SIZE)"
    log_sep
}
