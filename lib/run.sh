#!/bin/bash
# ==============================================================================
# lib/run.sh
# Launch an O2Physics DPL workflow on local machine or HPC cluster (OAR).
# Sourced by o2.sh — never executed directly.
#
# Entry point: cmd_run "$@"
#
# Execution flow:
#   LOCAL:
#     cmd_run → _resolve_files → _generate_workflow_script
#             → _run_groups_local → _run_workflow (per group)
#             → cmd_merge (auto after all groups)
#
#   HPC login node (ENV_TYPE=hpc_login):
#     cmd_run → _resolve_files → _generate_workflow_script
#             → _submit_oar_jobs (one job per group + one merge job)
#
#   Inside OAR job (OAR_JOB_ID set, --group given):
#     cmd_run → _run_workflow (single group)
# ==============================================================================

# ==============================================================================
# cmd_run
# ==============================================================================
cmd_run() {
    # Args: <workflow> <production> [options]
    local WORKFLOW=""
    local PRODUCTION=""
    local RUNS="all"
    local DATA_MODE_OVERRIDE=""
    local RESUME=0
    local GROUP_OVERRIDE=""   # internal: set by OAR job script
    local HPC_MODE=0          # --hpc: drive everything from the local machine

    while [[ $# -gt 0 ]]; do
        case $1 in
            --runs)    shift; RUNS="$1" ;;
            --mode)    shift; DATA_MODE_OVERRIDE="$1" ;;
            --group)   shift; GROUP_OVERRIDE="$1" ;;
            --resume)  RESUME=1 ;;
            --hpc)     HPC_MODE=1 ;;
            --help|-h) _run_help; return 0 ;;
            -*)        log_warn "Unknown option: $1" ;;
            *)
                if   [ -z "$WORKFLOW"    ]; then WORKFLOW="$1"
                elif [ -z "$PRODUCTION"  ]; then PRODUCTION="$1"
                fi
                ;;
        esac
        shift
    done

    [ -z "$WORKFLOW"   ] && { log_error "workflow name required"; _run_help; exit 1; }

    _resolve_workflow_paths "$WORKFLOW" "$PRODUCTION"

    # Source config_input.sh — analysis-specific defaults (production, runs,
    # data mode, group size). CLI arguments always take precedence over these.
    if [ -f "$WORKFLOW_DIR/config_input.sh" ]; then
        source "$WORKFLOW_DIR/config_input.sh"
        [ -z "$PRODUCTION" ] && [ -n "$INPUT_PRODUCTION" ] && PRODUCTION="$INPUT_PRODUCTION"
        [ "$RUNS" = "all" ] && [ -n "$INPUT_RUNS" ] && RUNS="$INPUT_RUNS"
    fi

    [ -z "$PRODUCTION" ] && { log_error "production name required (set on CLI or in config_input.sh)"; _run_help; exit 1; }

    # CLI --mode always wins; otherwise config_input.sh's O2_DATA_MODE; otherwise global default
    [ -n "$DATA_MODE_OVERRIDE" ] && O2_DATA_MODE="$DATA_MODE_OVERRIDE"
    _validate_data_mode

    # ---- Inside OAR job: run the assigned group only ----
    # WORKFLOW_OUTPUT is already fully self-contained (baked + synced from
    # the local machine) — no need to touch config_tasks.sh / WORKFLOW_DIR
    # here at all.
    if [ -n "$GROUP_OVERRIDE" ]; then
        load_apptainer
        _run_workflow "$WORKFLOW" "$PRODUCTION" "$GROUP_OVERRIDE"
        return
    fi

    load_apptainer
    log_sep
    log_info "O2Physics workflow launcher"
    log_info "Workflow    : $WORKFLOW"
    log_info "Production  : $PRODUCTION"
    log_info "Runs        : $RUNS"
    log_info "Mode        : $O2_DATA_MODE"
    log_info "Environment : $ENV_TYPE"
    log_sep

    _resolve_files   "$WORKFLOW" "$PRODUCTION" "$RUNS" "$RESUME"
    _generate_workflow_script "$WORKFLOW" "$PRODUCTION"
    _init_bookkeeping "$WORKFLOW" "$PRODUCTION" "$RUNS" "$RESUME"

    if [ "$HPC_MODE" -eq 1 ]; then
        [ "$ENV_TYPE" = "local" ] || {
            log_error "--hpc must be run from your local machine, not the cluster"
            exit 1
        }
        _run_hpc "$WORKFLOW" "$PRODUCTION" "$RESUME"
        return
    fi

    if [ "$ENV_TYPE" = "hpc_login" ]; then
        _submit_oar_jobs "$WORKFLOW" "$PRODUCTION" "$RESUME"
    else
        _run_groups_local "$WORKFLOW" "$PRODUCTION" "$RESUME"
        # Auto-merge after local run
        log_info "Launching merge..."
        cmd_merge "$WORKFLOW" "$PRODUCTION"
    fi
}

_run_help() {
    cat << 'EOF'
o2 run <workflow> <production> [options]

Arguments:
  workflow     name of the analysis workflow (e.g. proxies, jet-spectra)
  production   production name               (e.g. LHC24aj, LHC25b4b6)

Options:
  --runs LIST  comma-separated run numbers, or "all" (default: all)
  --mode MODE  data mode: "local" or "alien" (overrides o2_config.sh)
  --resume     skip completed groups, rerun only failed ones

Examples:
  o2 run proxies LHC24aj
  o2 run proxies LHC24aj --runs 544116,544122
  o2 run proxies LHC24aj --mode alien
  o2 run proxies LHC24aj --resume
EOF
}

_validate_data_mode() {
    if [ "$O2_DATA_MODE" != "local" ] && [ "$O2_DATA_MODE" != "alien" ]; then
        log_error "Invalid data mode: '$O2_DATA_MODE' (must be 'local' or 'alien')"
        exit 1
    fi
}

# ==============================================================================
# _resolve_files
# Run get_aod.sh inside the container to find/download AOD files and create
# group filelists under WORKFLOW_OUTPUT.
# ==============================================================================
_resolve_files() {
    local WF_NAME="$1"
    local PROD="$2"
    local RUNS="$3"
    local RESUME="${4:-0}"

    local N_GROUPS_FILE="$WORKFLOW_OUTPUT/.n_groups"

    if [ "$RESUME" -eq 1 ] && [ -f "$N_GROUPS_FILE" ]; then
        N_GROUPS=$(cat "$N_GROUPS_FILE")
        log_info "Resume mode: $N_GROUPS existing group(s)"
        return
    fi

    log_info "Resolving files for $PROD (mode: $O2_DATA_MODE)..."

    local GET_AOD_SCRIPT="$SCRIPTS_DIR/get_aod.sh"
    [ -f "$GET_AOD_SCRIPT" ] || { log_error "get_aod.sh not found in $SCRIPTS_DIR"; exit 1; }

    mkdir -p "$DATA_BASE/$PROD"

    _o2_container \
        -B "$(dirname "$GET_AOD_SCRIPT"):/workdir_scripts" \
        -B "$DATA_BASE:/data" \
        -B "$WORKFLOW_OUTPUT:/output" \
        -- bash -c "
            export O2_PRODUCTION='$PROD'
            export O2_RUNS='$RUNS'
            export O2_MAX_FILES='${O2_MAX_FILES:-0}'
            export O2_DATA_MODE='$O2_DATA_MODE'
            export O2_GROUP_SIZE='$O2_GROUP_SIZE'
            export ALICE_CERN_USER='$ALICE_CERN_USER'
            bash /workdir_scripts/get_aod.sh
        " 2>&1 | tee "$LOG_DIR/get_aod_${WF_NAME}_${PROD}.log"

    [ -f "$N_GROUPS_FILE" ] || { log_error "File resolution failed"; exit 1; }
    N_GROUPS=$(cat "$N_GROUPS_FILE")
    log_info "File resolution complete: $N_GROUPS group(s)"
}

# ==============================================================================
# _generate_workflow_script
# Sources config_tasks.sh, calls MakeScriptO2(), writes run_generated.sh.
# This script is called inside the container by _run_workflow().
#
# Key design:
#   - run_generated.sh receives two arguments:
#       $1 = filelist path  (container-side: /workdir/filelist.txt)
#       $2 = output dir     (container-side: /workdir)
#   - DPL is run from /workdir (output dir), so AnalysisResults.root lands there
#   - JSON config is at /analysis/dpl-config.json (/analysis = WORKFLOW_DIR)
# ==============================================================================
_generate_workflow_script() {
    local WF_NAME="$1"
    local PROD="$2"
    local GENERATED="$WORKFLOW_OUTPUT/run_generated.sh"

    log_info "Generating workflow script from $WORKFLOW_DIR/config_tasks.sh ..."

    # Source config_tasks.sh on HOST — defines MakeScriptO2(), AdjustJson(), Clean()
    # shellcheck source=/dev/null
    source "$WORKFLOW_DIR/config_tasks.sh"

    # run_generated.sh contains ONLY the DPL pipeline.
    # AdjustJson() and Clean() are HOST-side functions called by _run_workflow()
    # before and after the container — they cannot run inside the container.
    cat > "$GENERATED" << 'HEADER'
#!/bin/bash
# Auto-generated by o2 run — do not edit manually
set -e

# $1 = filelist path inside container (e.g. /workdir/filelist.txt)
# $2 = output directory inside container (e.g. /workdir)
FILELIST="${1:?filelist path required}"
OUTPUT_DIR="${2:?output directory required}"

cd "$OUTPUT_DIR"

HEADER

    # Append DPL pipeline from MakeScriptO2() — pure O2 commands, no host functions
    echo "# DPL pipeline" >> "$GENERATED"
    MakeScriptO2 >> "$GENERATED"

    chmod +x "$GENERATED"
    log_info "Workflow script: $GENERATED"

    _bake_run_bundle "$WF_NAME" "$PROD"
}

# ==============================================================================
# _bake_run_bundle
# Makes WORKFLOW_OUTPUT fully self-contained, so that running a group never
# again needs to read anything from WORKFLOW_DIR (analyses/<wf>/) — only
# from WORKFLOW_OUTPUT, which is the only thing that gets synced to HPC.
#
#   - copies dpl-config.json into WORKFLOW_OUTPUT
#   - applies AdjustJson() now, locally, on that copy (if defined)
#   - dumps AdjustJson()/Clean() function bodies into WORKFLOW_OUTPUT/.hooks.sh
#     so _run_workflow() can source them without touching config_tasks.sh
# ==============================================================================
_bake_run_bundle() {
    local WF_NAME="$1"
    local PROD="$2"
    local HOOKS_FILE="$WORKFLOW_OUTPUT/.hooks.sh"

    cp "$WORKFLOW_DIR/dpl-config.json" "$WORKFLOW_OUTPUT/dpl-config.json"

    {
        type AdjustJson &>/dev/null && declare -f AdjustJson
        type Clean      &>/dev/null && declare -f Clean
    } > "$HOOKS_FILE"

    # Apply AdjustJson now, locally, against the baked copy — /analysis
    # inside AdjustJson() traditionally refers to the bind-mounted dir,
    # which will now BE WORKFLOW_OUTPUT at run time, so operating directly
    # on WORKFLOW_OUTPUT here produces an identical result.
    if type AdjustJson &>/dev/null; then
        ( cd "$WORKFLOW_OUTPUT" && AdjustJson ) || \
            log_warn "AdjustJson() failed while baking bundle — dpl-config.json left as-is"
    fi

    log_info "Bundle baked: $WORKFLOW_OUTPUT (self-contained, ready to sync)"
}

# ==============================================================================
# _run_workflow
# Execute the DPL pipeline for a single group inside the container.
#
# Bind mounts inside container:
#   /alice/sw → SW_DIR
#   /tmp      → TMP_DIR
#   /root     → FAKEHOME
#   /workdir  → GROUP_DIR  (filelist.txt + AnalysisResults.root land here)
#   /analysis → WORKFLOW_OUTPUT (dpl-config.json, run_generated.sh, .hooks.sh —
#               fully self-contained; analyses/<wf>/ itself is never needed
#               here, which is what makes syncing to HPC lightweight)
#   /data     → DATA_BASE  (local AOD files)
#   /output   → WORKFLOW_OUTPUT (same dir as /analysis; kept as a separate
#               bind point for backward-compatible path references)
# ==============================================================================
_run_workflow() {
    local WF_NAME="$1"
    local PROD="$2"
    local GROUP_TAG="$3"
    local GROUP_DIR="$WORKFLOW_OUTPUT/$GROUP_TAG"
    local FILELIST="$GROUP_DIR/filelist.txt"
    local ANALYSIS_LOG="$LOG_DIR/run_${WF_NAME}_${PROD}_${GROUP_TAG}.log"

    [ -f "$FILELIST" ] || {
        log_error "Filelist not found: $FILELIST"
        _update_group_bookkeeping "$WF_NAME" "$PROD" "$GROUP_TAG" "failed" "" "1"
        return 1
    }

    mkdir -p "$GROUP_DIR"
    log_info "Running $GROUP_TAG ($(wc -l < "$FILELIST") files)..."
    log_info "Output : $GROUP_DIR/AnalysisResults.root"
    log_info "Log    : $ANALYSIS_LOG"

    _update_group_bookkeeping "$WF_NAME" "$PROD" "$GROUP_TAG" "running" "${OAR_JOB_ID:-}"

    # Source pre-baked hooks from WORKFLOW_OUTPUT (self-contained — never
    # reads config_tasks.sh / WORKFLOW_DIR here). AdjustJson() was already
    # applied once, at generation time, in _bake_run_bundle(); only Clean()
    # needs to run per-execution.
    # shellcheck source=/dev/null
    source "$WORKFLOW_OUTPUT/.hooks.sh" 2>/dev/null || true

    # Pre-run cleanup (HOST side)
    type Clean &>/dev/null && Clean 1 || true

    local EXIT_CODE=0
    _o2_container \
        -B "$GROUP_DIR:/workdir" \
        -B "$WORKFLOW_OUTPUT:/analysis" \
        -B "$DATA_BASE:/data" \
        -B "$WORKFLOW_OUTPUT:/output" \
        -- bash /output/run_generated.sh /workdir/filelist.txt /workdir \
        2>&1 | tee "$ANALYSIS_LOG" || EXIT_CODE=$?

    # Post-run cleanup (HOST side)
    type Clean &>/dev/null && Clean 2 || true

    if [ "$EXIT_CODE" -eq 0 ] && [ -f "$GROUP_DIR/AnalysisResults.root" ]; then
        log_info "Group $GROUP_TAG: done"
        _update_group_bookkeeping "$WF_NAME" "$PROD" "$GROUP_TAG" "done" \
            "${OAR_JOB_ID:-}" "0"
    else
        log_error "Group $GROUP_TAG: failed (exit code $EXIT_CODE)"
        _update_group_bookkeeping "$WF_NAME" "$PROD" "$GROUP_TAG" "failed" \
            "${OAR_JOB_ID:-}" "$EXIT_CODE"
        return 1
    fi
}

# ==============================================================================
# _run_groups_local
# Run all groups sequentially on local machine.
# ==============================================================================
_run_groups_local() {
    local WF_NAME="$1"
    local PROD="$2"
    local RESUME="${3:-0}"
    local FAILED=0

    log_info "Running $N_GROUPS group(s) locally..."

    for i in $(seq 0 $(( N_GROUPS - 1 ))); do
        local GROUP_TAG
        GROUP_TAG=$(printf "group_%03d" "$i")

        if [ "$RESUME" -eq 1 ]; then
            local FRAG="$BOOKKEEPING_FRAGS/${GROUP_TAG}.json"
            if [ -f "$FRAG" ] && grep -q '"status": "done"' "$FRAG"; then
                log_info "Skipping $GROUP_TAG (already done)"
                continue
            fi
        fi

        _run_workflow "$WF_NAME" "$PROD" "$GROUP_TAG" || FAILED=$(( FAILED + 1 ))
    done

    echo ""
    log_info "Local run complete: $((N_GROUPS - FAILED))/$N_GROUPS succeeded"
    [ "$FAILED" -gt 0 ] && \
        log_warn "$FAILED group(s) failed — retry with: o2 run $WF_NAME $PROD --resume"
}

# ==============================================================================
# _run_hpc
# Drives an HPC run entirely from the local machine:
#   1. WORKFLOW_OUTPUT is already resolved + generated + baked (self-contained)
#      by the time this is called — see cmd_run.
#   2. rsync ONLY that directory to the cluster (never all of analyses/).
#   3. ssh into the cluster and trigger OAR submission remotely, via a
#      lightweight command that doesn't need analyses/config_*.sh at all.
# ==============================================================================
_run_hpc() {
    local WF_NAME="$1"
    local PROD="$2"
    local RESUME="${3:-0}"

    [ -n "${O2_HPC_SCRATCH_DIR:-}" ] || {
        log_error "O2_HPC_SCRATCH_DIR must be set in o2_config.sh for --hpc"
        log_error "(WORKFLOW_OUTPUT resolves under \$SCRATCH on the cluster," \
                   "which falls back to O2_HPC_HOME_DIR only if unset — a" \
                   "case this remote path computation does not handle)"
        exit 1
    }

    # WORKFLOW_OUTPUT resolves under $SCRATCH on the cluster (see
    # _resolve_workflow_paths in common.sh: SCRATCH_ANALYSES uses $SCRATCH,
    # not $O2_HPC_HOME_DIR — only WORKFLOW_DIR/config files live under HOME,
    # with a symlink pointing to the scratch output). $SCRATCH resolves to
    # $O2_HPC_SCRATCH_DIR whenever that variable is set in o2_config.sh.
    local REMOTE_OUTPUT="${WORKFLOW_OUTPUT/#$O2_LOCAL_DIR/$O2_HPC_SCRATCH_DIR}"
    local REMOTE_HOST="${O2_HPC_USER}@${O2_HPC_HOST}"

    log_sep
    log_info "Syncing workflow bundle to HPC..."
    log_info "Local  : $WORKFLOW_OUTPUT"
    log_info "Remote : ${REMOTE_HOST}:${REMOTE_OUTPUT}"

    ssh "$REMOTE_HOST" "mkdir -p '$(dirname "$REMOTE_OUTPUT")'" || {
        log_error "Failed to prepare remote directory over SSH"
        exit 1
    }

    rsync -a --delete "$WORKFLOW_OUTPUT/" "${REMOTE_HOST}:${REMOTE_OUTPUT}/" || {
        log_error "rsync of workflow bundle failed"
        exit 1
    }
    log_info "Bundle synced"

    log_info "Triggering remote OAR submission..."
    local RESUME_FLAG=""
    [ "$RESUME" -eq 1 ] && RESUME_FLAG="--resume"

    ssh "$REMOTE_HOST" \
        "${O2_HPC_HOME_DIR}/o2.sh submit-remote ${WF_NAME} ${PROD} --mode ${O2_DATA_MODE} ${RESUME_FLAG}"

    log_sep
    log_info "o2 run --hpc complete — jobs submitted from the cluster login node"
    log_info "Monitor with: ssh ${REMOTE_HOST} '${O2_HPC_HOME_DIR}/o2.sh status ${WF_NAME} ${PROD}'"
    log_sep
}

# ==============================================================================
# cmd_submit_remote
# Runs ON the HPC login node (invoked over SSH by _run_hpc, never by hand).
# Submits OAR jobs for a workflow bundle that has already been synced —
# never reads analyses/config_input.sh or config_tasks.sh.
#
# Usage: o2 submit-remote <workflow> <production> --mode <mode> [--resume]
# ==============================================================================
cmd_submit_remote() {
    local WF_NAME="$1"; shift
    local PROD="$1"; shift
    local RESUME=0

    while [[ $# -gt 0 ]]; do
        case $1 in
            --mode)   shift; O2_DATA_MODE="$1" ;;
            --resume) RESUME=1 ;;
        esac
        shift
    done

    [ -z "$WF_NAME" ] && { log_error "workflow name required"; exit 1; }
    [ -z "$PROD"    ] && { log_error "production name required"; exit 1; }
    [ -z "${O2_DATA_MODE:-}" ] && { log_error "--mode required (submit-remote never reads config_input.sh)"; exit 1; }
    _validate_data_mode

    _resolve_workflow_paths "$WF_NAME" "$PROD"

    local N_GROUPS_FILE="$WORKFLOW_OUTPUT/.n_groups"
    [ -f "$N_GROUPS_FILE" ] || {
        log_error "No synced bundle found at $WORKFLOW_OUTPUT (.n_groups missing) — was the bundle rsynced?"
        exit 1
    }
    N_GROUPS=$(cat "$N_GROUPS_FILE")

    log_info "Remote submission: $WF_NAME / $PROD ($N_GROUPS group(s), mode=$O2_DATA_MODE)"
    _submit_oar_jobs "$WF_NAME" "$PROD" "$RESUME"
}


_submit_oar_jobs() {
    local WF_NAME="$1"
    local PROD="$2"
    local RESUME="${3:-0}"

    command -v oarsub &>/dev/null || {
        log_error "oarsub not found — are you on the HPC login node?"
        exit 1
    }

    local OAR_CORES="${O2_OAR_CORES:-$(nproc)}"
    local OAR_FLAGS="--project ${O2_OAR_PROJECT}"
    [ -n "${O2_OAR_TYPE:-}"       ] && OAR_FLAGS="$OAR_FLAGS -t ${O2_OAR_TYPE}"
    [ "${O2_OAR_DEVEL:-0}" -eq 1 ] && OAR_FLAGS="$OAR_FLAGS -t devel"

    local JOB_IDS=()
    log_info "Submitting $N_GROUPS OAR job(s)..."

    for i in $(seq 0 $(( N_GROUPS - 1 ))); do
        local GROUP_TAG
        GROUP_TAG=$(printf "group_%03d" "$i")

        if [ "$RESUME" -eq 1 ]; then
            local FRAG="$BOOKKEEPING_FRAGS/${GROUP_TAG}.json"
            if [ -f "$FRAG" ] && grep -q '"status": "done"' "$FRAG"; then
                log_info "Skipping $GROUP_TAG (already done)"
                continue
            fi
        fi

        local OAR_SCRIPT="$LOG_DIR/oar_${WF_NAME}_${PROD}_${GROUP_TAG}.sh"
        cat > "$OAR_SCRIPT" << OAREOF
#!/bin/bash
#OAR -n O2_${WF_NAME}_${PROD}_${GROUP_TAG}
#OAR -l /nodes=1/core=${OAR_CORES},walltime=${O2_OAR_WALLTIME}
#OAR --stdout $LOG_DIR/oar_${WF_NAME}_${PROD}_${GROUP_TAG}.log
#OAR --stderr $LOG_DIR/oar_${WF_NAME}_${PROD}_${GROUP_TAG}.err
#OAR --notify mail:${O2_EMAIL}

command -v apptainer &>/dev/null || module load apptainer 2>/dev/null || \
    module load singularity 2>/dev/null

${SCRIPTS_DIR}/o2.sh run ${WF_NAME} ${PROD} --group ${GROUP_TAG} --mode ${O2_DATA_MODE}
OAREOF
        chmod +x "$OAR_SCRIPT"

        local JOB_ID
        JOB_ID=$(oarsub $OAR_FLAGS -S "$OAR_SCRIPT" \
            | grep -oP 'OAR_JOB_ID=\K[0-9]+')

        log_info "Submitted $GROUP_TAG → OAR job $JOB_ID"
        JOB_IDS+=("$JOB_ID")
        _update_group_bookkeeping "$WF_NAME" "$PROD" "$GROUP_TAG" "pending" "$JOB_ID"
    done

    # Submit merge job — depends on ALL analysis jobs
    # OAR dependency syntax: one -a flag per dependency job
    if [ "${#JOB_IDS[@]}" -gt 0 ]; then
        local DEP_FLAGS=""
        for JID in "${JOB_IDS[@]}"; do
            DEP_FLAGS="$DEP_FLAGS -a $JID"
        done

        local MERGE_SCRIPT="$LOG_DIR/oar_${WF_NAME}_${PROD}_merge.sh"
        cat > "$MERGE_SCRIPT" << OAREOF
#!/bin/bash
#OAR -n O2_${WF_NAME}_${PROD}_merge
#OAR -l /nodes=1/core=4,walltime=01:00:00
#OAR --stdout $LOG_DIR/oar_${WF_NAME}_${PROD}_merge.log
#OAR --stderr $LOG_DIR/oar_${WF_NAME}_${PROD}_merge.err
#OAR --notify mail:${O2_EMAIL}

command -v apptainer &>/dev/null || module load apptainer 2>/dev/null || \
    module load singularity 2>/dev/null

${SCRIPTS_DIR}/o2.sh merge ${WF_NAME} ${PROD}
OAREOF
        chmod +x "$MERGE_SCRIPT"

        local MERGE_JOB_ID
        MERGE_JOB_ID=$(oarsub $OAR_FLAGS $DEP_FLAGS -S "$MERGE_SCRIPT" \
            | grep -oP 'OAR_JOB_ID=\K[0-9]+')

        log_info "Submitted merge → OAR job $MERGE_JOB_ID"
    fi

    echo ""
    log_sep
    log_info "OAR jobs submitted"
    log_info "Workflow   : $WF_NAME / $PROD"
    log_info "Groups     : ${#JOB_IDS[@]}"
    log_info "Monitor    : o2 status $WF_NAME $PROD"
    log_info "Logs       : $LOG_DIR/"
    log_sep
}

# ==============================================================================
# Bookkeeping helpers
# Fragment JSON files are written per group (safe for concurrent OAR jobs).
# The main JSON is consolidated at merge time.
# ==============================================================================
_init_bookkeeping() {
    local WF_NAME="$1"
    local PROD="$2"
    local RUNS="$3"
    local RESUME="${4:-0}"
    local NOW
    NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    if [ "$RESUME" -eq 0 ] || [ ! -f "$BOOKKEEPING_FILE" ]; then
        cat > "$BOOKKEEPING_FILE" << JSONEOF
{
  "workflow": "$WF_NAME",
  "production": "$PROD",
  "data_mode": "$O2_DATA_MODE",
  "group_size": $O2_GROUP_SIZE,
  "runs": "$RUNS",
  "scan_date": "$NOW",
  "n_groups": $N_GROUPS,
  "groups": {},
  "merge": null
}
JSONEOF
        log_info "Bookkeeping initialized: $BOOKKEEPING_FILE"
    else
        log_info "Resuming bookkeeping: $BOOKKEEPING_FILE"
    fi
}

_update_group_bookkeeping() {
    local WF_NAME="$1"
    local PROD="$2"
    local GROUP_TAG="$3"
    local STATUS="$4"
    local OAR_ID="${5:-}"
    local EXIT_CODE="${6:-}"
    local NOW
    NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    local FRAG="$BOOKKEEPING_FRAGS/${GROUP_TAG}.json"
    local FILELIST="$WORKFLOW_OUTPUT/$GROUP_TAG/filelist.txt"
    local N_FILES=0
    [ -f "$FILELIST" ] && N_FILES=$(wc -l < "$FILELIST")

    cat > "$FRAG" << JSONEOF
{
  "group": "$GROUP_TAG",
  "status": "$STATUS",
  "oar_id": ${OAR_ID:-null},
  "n_files": $N_FILES,
  "filelist": "$FILELIST",
  "output": "$WORKFLOW_OUTPUT/$GROUP_TAG/AnalysisResults.root",
  "updated": "$NOW",
  "exit_code": ${EXIT_CODE:-null}
}
JSONEOF
}
