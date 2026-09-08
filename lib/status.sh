#!/bin/bash
# ==============================================================================
# lib/status.sh
# Monitor and manage O2Physics analyses locally and on the HPC cluster.
# Can be run from your local machine to monitor jobs running on Dahu.
# Sourced by o2.sh — never executed directly.
#
# Entry point: cmd_status "$@"
#
# Commands:
#   o2 status <workflow> <production>          overview
#   o2 status <workflow> <production> --failed list failed groups
#   o2 status <workflow> <production> --jobs   OAR job states
#   o2 status all                              all workflows + productions
#   o2 status sync                             rsync bookkeeping from HPC
#   o2 status proxy                            ALICE Grid token status
#   o2 status proxy --renew                    renew token on HPC
# ==============================================================================

# ==============================================================================
# cmd_status
# ==============================================================================
cmd_status() {
    local SUBCOMMAND=""
    local WORKFLOW=""
    local PRODUCTION=""
    local SHOW_FAILED=0
    local SHOW_JOBS=0
    local USE_LOCAL=0
    local RENEW_PROXY=0

    while [[ $# -gt 0 ]]; do
        case $1 in
            all|sync|proxy)
                SUBCOMMAND="$1" ;;
            --failed)   SHOW_FAILED=1 ;;
            --jobs)     SHOW_JOBS=1 ;;
            --local)    USE_LOCAL=1 ;;
            --renew)    RENEW_PROXY=1 ;;
            --help|-h)  _status_help; return 0 ;;
            -*)         log_warn "Unknown option: $1" ;;
            *)
                if   [ -z "$WORKFLOW"   ]; then WORKFLOW="$1"
                elif [ -z "$PRODUCTION" ]; then PRODUCTION="$1"
                fi
                ;;
        esac
        shift
    done

    # Dispatch
    case "${SUBCOMMAND:-}" in
        all)   _status_all "$USE_LOCAL"; return ;;
        sync)  _status_sync; return ;;
        proxy) _status_proxy "$RENEW_PROXY"; return ;;
    esac

    [ -z "$WORKFLOW"   ] && { log_error "workflow name required"; _status_help; exit 1; }
    [ -z "$PRODUCTION" ] && { log_error "production name required"; _status_help; exit 1; }

    if   [ "$SHOW_FAILED" -eq 1 ]; then _status_failed "$WORKFLOW" "$PRODUCTION" "$USE_LOCAL"
    elif [ "$SHOW_JOBS"   -eq 1 ]; then _status_jobs   "$WORKFLOW" "$PRODUCTION"
    else                                _status_overview "$WORKFLOW" "$PRODUCTION" "$USE_LOCAL"
    fi
}

_status_help() {
    cat << 'EOF'
o2 status <workflow> <production> [options]
o2 status all
o2 status sync
o2 status proxy [--renew]

Options:
  --failed    list failed groups only
  --jobs      show OAR job IDs and states
  --local     read local bookkeeping copy (after sync)

Examples:
  o2 status proxies LHC24aj
  o2 status proxies LHC24aj --failed
  o2 status proxies LHC24aj --jobs
  o2 status all
  o2 status sync && o2 status all --local
  o2 status proxy
  o2 status proxy --renew
EOF
}

# ==============================================================================
# SSH / local helpers
# ==============================================================================
_is_local_machine() {
    [ "${O2_FORCE_HPC:-0}" -eq 0 ] && \
    [ -z "${OAR_JOB_ID:-}" ] && \
    [ -z "${SLURM_JOB_ID:-}" ]
}

# Read a bookkeeping JSON — local file or via SSH
_read_bookkeeping() {
    local WF="$1"
    local PROD="$2"
    local USE_LOCAL="${3:-0}"

    if _is_local_machine && [ "$USE_LOCAL" -eq 0 ]; then
        ssh "${O2_HPC_USER}@${O2_HPC_HOST}" \
            "cat ${O2_HPC_HOME_DIR}/analysis/${WF}/bookkeeping/${PROD}.json 2>/dev/null" \
            2>/dev/null
    else
        cat "$O2_LOCAL_DIR/analysis/$WF/bookkeeping/${PROD}.json" 2>/dev/null
    fi
}

# Read all fragment JSONs — local or via SSH
# Each fragment is prefixed with its GROUP_TAG for parsing
_read_fragments() {
    local WF="$1"
    local PROD="$2"
    local USE_LOCAL="${3:-0}"

    if _is_local_machine && [ "$USE_LOCAL" -eq 0 ]; then
        ssh "${O2_HPC_USER}@${O2_HPC_HOST}" \
            "for f in ${O2_HPC_HOME_DIR}/analysis/${WF}/bookkeeping/${PROD}.d/*.json; do
                 [ -f \"\$f\" ] && cat \"\$f\"; echo '---FRAG_SEP---'
             done 2>/dev/null" 2>/dev/null
    else
        local FRAG_DIR="$O2_LOCAL_DIR/analysis/$WF/bookkeeping/${PROD}.d"
        for f in "$FRAG_DIR"/*.json; do
            [ -f "$f" ] || continue
            cat "$f"
            echo '---FRAG_SEP---'
        done
    fi
}

# ==============================================================================
# Color helpers
# ==============================================================================
_clr_green()  { echo -e "\033[0;32m$*\033[0m"; }
_clr_red()    { echo -e "\033[0;31m$*\033[0m"; }
_clr_yellow() { echo -e "\033[1;33m$*\033[0m"; }
_clr_blue()   { echo -e "\033[0;34m$*\033[0m"; }

_status_color() {
    case "$1" in
        done)    _clr_green  "done"    ;;
        failed)  _clr_red    "failed"  ;;
        running) _clr_blue   "running" ;;
        pending) _clr_yellow "pending" ;;
        *)       echo "$1" ;;
    esac
}

# ==============================================================================
# _status_overview
# ==============================================================================
_status_overview() {
    local WF="$1"
    local PROD="$2"
    local USE_LOCAL="${3:-0}"

    log_sep
    echo "  Workflow   : $WF"
    echo "  Production : $PROD"
    log_sep

    local JSON
    JSON=$(_read_bookkeeping "$WF" "$PROD" "$USE_LOCAL")
    if [ -z "$JSON" ]; then
        log_warn "No bookkeeping found for $WF/$PROD"
        echo "  Run: o2 run $WF $PROD"
        return
    fi

    local SCAN_DATE MODE N_GROUPS
    SCAN_DATE=$(echo "$JSON" | jq -r '.scan_date  // "unknown"')
    MODE=$(echo "$JSON"      | jq -r '.data_mode  // "unknown"')
    N_GROUPS=$(echo "$JSON"  | jq -r '.n_groups   // 0')

    echo ""
    echo "  Scan date  : $SCAN_DATE"
    echo "  Data mode  : $MODE"
    echo "  Groups     : $N_GROUPS"
    echo ""
    printf "  %-12s %-12s %-8s %-12s\n" "Group" "Status" "Files" "OAR Job"
    printf "  %-12s %-12s %-8s %-12s\n" "-----" "------" "-----" "-------"

    local N_DONE=0 N_FAILED=0 N_RUNNING=0 N_PENDING=0

    local FRAG_JSON=""
    while IFS= read -r LINE; do
        if [ "$LINE" = "---FRAG_SEP---" ]; then
            [ -z "$FRAG_JSON" ] && continue
            local STATUS FILES OAR_ID GROUP
            STATUS=$(echo "$FRAG_JSON"  | jq -r '.status   // "unknown"' 2>/dev/null) || continue
            FILES=$(echo "$FRAG_JSON"   | jq -r '.n_files  // 0'         2>/dev/null)
            OAR_ID=$(echo "$FRAG_JSON"  | jq -r '.oar_id   // "-"'       2>/dev/null)
            GROUP=$(echo "$FRAG_JSON"   | jq -r '.group    // "?"'        2>/dev/null)

            printf "  %-12s %-22s %-8s %-12s\n" \
                "$GROUP" "$(_status_color "$STATUS")" "$FILES" "$OAR_ID"

            case "$STATUS" in
                done)    N_DONE=$(( N_DONE + 1 ))       ;;
                failed)  N_FAILED=$(( N_FAILED + 1 ))   ;;
                running) N_RUNNING=$(( N_RUNNING + 1 )) ;;
                pending) N_PENDING=$(( N_PENDING + 1 )) ;;
            esac
            FRAG_JSON=""
        else
            FRAG_JSON="${FRAG_JSON}${LINE}"
        fi
    done < <(_read_fragments "$WF" "$PROD" "$USE_LOCAL")

    echo ""
    echo "  Summary: $(_clr_green "done=$N_DONE") $(_clr_red "failed=$N_FAILED") $(_clr_blue "running=$N_RUNNING") $(_clr_yellow "pending=$N_PENDING")"

    # Merge status
    local MERGE_STATUS MERGE_PATH MERGE_DATE
    MERGE_STATUS=$(echo "$JSON" | jq -r '.merge.status // "not started"')
    echo "  Merge  : $(_status_color "$MERGE_STATUS")"
    if [ "$MERGE_STATUS" = "done" ]; then
        MERGE_PATH=$(echo "$JSON" | jq -r '.merge.path // ""')
        MERGE_DATE=$(echo "$JSON" | jq -r '.merge.date // ""')
        echo "  Output : $MERGE_PATH"
        echo "  Date   : $MERGE_DATE"
    fi
    echo ""
}

# ==============================================================================
# _status_failed
# ==============================================================================
_status_failed() {
    local WF="$1"
    local PROD="$2"
    local USE_LOCAL="${3:-0}"

    echo "Failed groups — $WF / $PROD :"
    echo ""

    local FOUND=0
    local FRAG_JSON=""
    while IFS= read -r LINE; do
        if [ "$LINE" = "---FRAG_SEP---" ]; then
            [ -z "$FRAG_JSON" ] && continue
            local STATUS
            STATUS=$(echo "$FRAG_JSON" | jq -r '.status // ""' 2>/dev/null) || { FRAG_JSON=""; continue; }
            if [ "$STATUS" = "failed" ]; then
                local GROUP OAR_ID EXIT_CODE
                GROUP=$(echo "$FRAG_JSON"     | jq -r '.group     // "?"' 2>/dev/null)
                OAR_ID=$(echo "$FRAG_JSON"    | jq -r '.oar_id    // "-"' 2>/dev/null)
                EXIT_CODE=$(echo "$FRAG_JSON" | jq -r '.exit_code // "-"' 2>/dev/null)
                echo "  $GROUP   OAR=$OAR_ID   exit=$EXIT_CODE"
                FOUND=$(( FOUND + 1 ))
            fi
            FRAG_JSON=""
        else
            FRAG_JSON="${FRAG_JSON}${LINE}"
        fi
    done < <(_read_fragments "$WF" "$PROD" "$USE_LOCAL")

    if [ "$FOUND" -eq 0 ]; then
        echo "  No failed groups."
    else
        echo ""
        echo "  Retry: o2 run $WF $PROD --resume"
    fi
}

# ==============================================================================
# _status_jobs
# Show OAR job states for all groups of a production
# ==============================================================================
_status_jobs() {
    local WF="$1"
    local PROD="$2"

    local JOB_IDS=()
    local FRAG_JSON=""
    while IFS= read -r LINE; do
        if [ "$LINE" = "---FRAG_SEP---" ]; then
            [ -z "$FRAG_JSON" ] && continue
            local JOB_ID
            JOB_ID=$(echo "$FRAG_JSON" | jq -r '.oar_id // empty' 2>/dev/null) || true
            [ -n "$JOB_ID" ] && [ "$JOB_ID" != "null" ] && JOB_IDS+=("$JOB_ID")
            FRAG_JSON=""
        else
            FRAG_JSON="${FRAG_JSON}${LINE}"
        fi
    done < <(_read_fragments "$WF" "$PROD" 0)

    if [ "${#JOB_IDS[@]}" -eq 0 ]; then
        echo "No OAR jobs found in bookkeeping for $WF/$PROD"
        return
    fi

    local OARSTAT_CMD="oarstat -u ${O2_HPC_USER} 2>/dev/null | head -40"
    if _is_local_machine; then
        ssh "${O2_HPC_USER}@${O2_HPC_HOST}" "$OARSTAT_CMD"
    else
        eval "$OARSTAT_CMD"
    fi
}

# ==============================================================================
# _status_all
# Show status for all workflows and productions
# ==============================================================================
_status_all() {
    local USE_LOCAL="${1:-0}"

    log_sep
    echo "  All analyses"
    log_sep

    if _is_local_machine && [ "$USE_LOCAL" -eq 0 ]; then
        # List from HPC via SSH
        local ANALYSIS
        ANALYSIS=$(ssh "${O2_HPC_USER}@${O2_HPC_HOST}" \
            "ls ${O2_HPC_HOME_DIR}/analysis/ 2>/dev/null" 2>/dev/null)

        while IFS= read -r wf; do
            [ -z "$wf" ] && continue
            local PRODS
            PRODS=$(ssh "${O2_HPC_USER}@${O2_HPC_HOST}" \
                "ls ${O2_HPC_HOME_DIR}/analysis/${wf}/bookkeeping/*.json \
                 | xargs -n1 basename 2>/dev/null | sed 's/\.json//'" 2>/dev/null)
            while IFS= read -r prod; do
                [ -z "$prod" ] && continue
                _status_overview "$wf" "$prod" "$USE_LOCAL"
            done <<< "$PRODS"
        done <<< "$ANALYSIS"
    else
        local ANALYSIS_DIR="$O2_LOCAL_DIR/analysis"
        for wf_path in "$ANALYSIS_DIR"/*/; do
            local wf
            wf=$(basename "$wf_path")
            for bk in "$wf_path/bookkeeping/"*.json; do
                [ -f "$bk" ] || continue
                local prod
                prod=$(basename "$bk" .json)
                _status_overview "$wf" "$prod" "$USE_LOCAL"
            done
        done
    fi
}

# ==============================================================================
# _status_sync
# rsync bookkeeping directories from HPC to local machine
# ==============================================================================
_status_sync() {
    log_info "Syncing bookkeeping from ${O2_HPC_USER}@${O2_HPC_HOST} ..."

    rsync -avz --checksum \
        "${O2_HPC_USER}@${O2_HPC_HOST}:${O2_HPC_HOME_DIR}/analysis/" \
        "$O2_LOCAL_DIR/analysis/" \
        --include="*/" \
        --include="bookkeeping/" \
        --include="bookkeeping/*.json" \
        --include="bookkeeping/*.d/" \
        --include="bookkeeping/*.d/*.json" \
        --exclude="*"

    log_info "Sync complete — use 'o2 status all --local' to read local copy"
}

# ==============================================================================
# _status_proxy
# Show or renew ALICE Grid token
# ==============================================================================
_status_proxy() {
    local RENEW="${1:-0}"

    if [ "$RENEW" -eq 1 ]; then
        log_info "Renewing ALICE Grid token..."
        if _is_local_machine; then
            ssh "${O2_HPC_USER}@${O2_HPC_HOST}" \
                "alien-token-init ${ALICE_CERN_USER}"
        else
            alien-token-init "$ALICE_CERN_USER"
        fi
        return
    fi

    log_info "ALICE Grid token status:"
    if _is_local_machine; then
        ssh "${O2_HPC_USER}@${O2_HPC_HOST}" \
            "alien.py pwd 2>/dev/null && echo 'Token: valid' \
             || echo 'Token: expired or not initialized'"
    else
        alien.py pwd 2>/dev/null && echo "Token: valid" \
            || echo "Token: expired or not initialized"
    fi
}
