#!/bin/bash
# ==============================================================================
# config_tasks.sh
# Task configuration for the "proxies" analysis workflow.
# Sourced by o2.sh to generate the DPL pipeline command.
#
# Required function:
#   MakeScriptO2()
#     Echoes the complete DPL pipeline command.
#     Inside the container at runtime:
#       $FILELIST    = /workdir/filelist.txt
#       $OUTPUT_DIR  = /workdir  (AnalysisResults.root lands here)
#       JSON config  = /analysis/dpl-config.json
#
# Optional functions (called by run_generated.sh if defined):
#   AdjustJson()   modify dpl-config.json before the run
#   Clean(1|2)     pre-run (1) and post-run (2) cleanup
#
# Workflow naming convention:
#   o2-analysis-<pwg>-<task-name>
#   Examples:
#     o2-analysis-je-jet-finder-charged
#     o2-analysis-event-selection
#     o2-analysis-track-propagation
# ==============================================================================

# ------------------------------------------------------------------------------
# Workflow activation switches — set to 1 to include in pipeline
# ------------------------------------------------------------------------------

# Helper tasks (required for Run 3 data)
DOO2_TIMESTAMP=1            # o2-analysis-timestamp
DOO2_TRACK_PROPAGATION=1    # o2-analysis-track-propagation
DOO2_EVENT_SELECTION=1      # o2-analysis-event-selection
DOO2_MULTIPLICITY_TABLE=1   # o2-analysis-multiplicity-table
DOO2_TRACK_SELECTION=1      # o2-analysis-trackselection

# Jet framework
DOO2_JET_FINDER=1           # o2-analysis-je-jet-finder-charged
DOO2_JET_TRACK_QA=0         # o2-analysis-je-jet-track-qa
DOO2_JET_VALIDATION=0       # o2-analysis-je-jet-validation-qa-charged

# User tasks (from your O2Physics fork, PWGJE/Tasks/)
DOO2_USER_PROXY_BUILDER=0   # o2-analysis-je-proxy-builder

# ------------------------------------------------------------------------------
# MakeScriptO2
# Generates the DPL pipeline command echoed into run_generated.sh.
#
# Design notes:
#   - /workdir is bind-mounted from GROUP_DIR (per group, contains filelist.txt)
#   - /analysis is bind-mounted from WORKFLOW_DIR (contains dpl-config.json)
#   - DPL is run from /workdir so AnalysisResults.root lands there
#   - @filelist.txt paths are container-side (/workdir/filelist.txt entries
#     use /data/... paths for local mode, alien:// for alien mode)
# ------------------------------------------------------------------------------
MakeScriptO2() {
    local WORKFLOWS=""

    [ "${DOO2_TIMESTAMP:-0}"          -eq 1 ] && WORKFLOWS+=" o2-analysis-timestamp"
    [ "${DOO2_TRACK_PROPAGATION:-0}"  -eq 1 ] && WORKFLOWS+=" o2-analysis-track-propagation"
    [ "${DOO2_EVENT_SELECTION:-0}"    -eq 1 ] && WORKFLOWS+=" o2-analysis-event-selection"
    [ "${DOO2_MULTIPLICITY_TABLE:-0}" -eq 1 ] && WORKFLOWS+=" o2-analysis-multiplicity-table"
    [ "${DOO2_TRACK_SELECTION:-0}"    -eq 1 ] && WORKFLOWS+=" o2-analysis-trackselection"
    [ "${DOO2_JET_FINDER:-0}"         -eq 1 ] && WORKFLOWS+=" o2-analysis-je-jet-finder-charged"
    [ "${DOO2_JET_TRACK_QA:-0}"       -eq 1 ] && WORKFLOWS+=" o2-analysis-je-jet-track-qa"
    [ "${DOO2_JET_VALIDATION:-0}"     -eq 1 ] && WORKFLOWS+=" o2-analysis-je-jet-validation-qa-charged"
    [ "${DOO2_USER_PROXY_BUILDER:-0}" -eq 1 ] && WORKFLOWS+=" o2-analysis-je-proxy-builder"

    WORKFLOWS="${WORKFLOWS# }"

    if [ -z "$WORKFLOWS" ]; then
        echo "[ERROR] No workflows activated in config_tasks.sh" >&2
        exit 1
    fi

    # Build pipe-separated DPL command
    local PIPE_CMD=""
    local FIRST=1
    for W in $WORKFLOWS; do
        if [ "$FIRST" -eq 1 ]; then
            PIPE_CMD="$W"; FIRST=0
        else
            PIPE_CMD="$PIPE_CMD | $W"
        fi
    done

    # Emit the complete pipeline command.
    # $FILELIST and $OUTPUT_DIR are set by run_generated.sh at runtime.
    # /analysis/dpl-config.json is the JSON config inside the container.
    cat << CMDEOF
# DPL pipeline — $(echo "$WORKFLOWS" | wc -w) task(s) activated
${PIPE_CMD} \\
    --aod-file @\${FILELIST} \\
    --configuration json:///analysis/dpl-config.json \\
    -b
CMDEOF
}

# ------------------------------------------------------------------------------
# AdjustJson (optional)
# Modify /analysis/dpl-config.json before the run if needed.
# Called inside the container — /analysis = WORKFLOW_DIR bind-mount.
# ------------------------------------------------------------------------------
AdjustJson() {
    # Example: override event selection system for PbPb
    # jq '.["event-selection-task"]["syst"] = "PbPb"' \
    #     /analysis/dpl-config.json > /tmp/dpl-config-adjusted.json
    # cp /tmp/dpl-config-adjusted.json /analysis/dpl-config.json
    :
}

# ------------------------------------------------------------------------------
# Clean (optional)
# $1 = 1 : pre-run  (called before the DPL pipeline)
# $1 = 2 : post-run (called after the DPL pipeline)
# ------------------------------------------------------------------------------
Clean() {
    case "${1:-}" in
        1)
            # Pre-run: uncomment to force-remove previous output
            # rm -f "$OUTPUT_DIR/AnalysisResults.root"
            # rm -f "$OUTPUT_DIR/QAResults.root"
            :
            ;;
        2)
            # Post-run: remove DPL driver temp files
            rm -f "$OUTPUT_DIR"/dpl-config-*.json 2>/dev/null || true
            ;;
    esac
}
