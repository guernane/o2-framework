#!/bin/bash
# ==============================================================================
# lib/deploy.sh
# Synchronize scripts and analysis from local machine to HPC cluster.
# Generates a sanitized o2_config.sh for HPC (no GitHub token).
# Sourced by o2.sh — never executed directly.
#
# Entry point: cmd_deploy "$@"
# ==============================================================================

# ==============================================================================
# cmd_deploy
# ==============================================================================
cmd_deploy() {
    local SYNC_ONLY=0
    local SANDBOX_ONLY=0
    local BUILD_ONLY=0
    local STATUS_ONLY=0
    local LOG_ONLY=0
    local DRY_RUN=0
    local EXTEND=0
    local EXTEND_BY=""

    while [[ $# -gt 0 ]]; do
        case $1 in
            --sync-only)    SYNC_ONLY=1 ;;
            --sandbox-only) SANDBOX_ONLY=1 ;;
            --build-only)   BUILD_ONLY=1 ;;
            --status)       STATUS_ONLY=1 ;;
            --log)          LOG_ONLY=1 ;;
            --dry-run)      DRY_RUN=1 ;;
            --extend)       EXTEND=1
                            # optional amount: +H, +H:MM or +H:MM:SS
                            if [[ $# -gt 1 && "$2" =~ ^\+[0-9]+(:[0-9]{1,2}){0,2}$ ]]; then
                                EXTEND_BY="$2"; shift
                            fi ;;
            --help|-h)      _deploy_help; return 0 ;;
            *)              log_warn "Unknown option: $1" ;;
        esac
        shift
    done

    local HPC_LOGIN="${O2_HPC_USER}@${O2_HPC_HOST}"

    if [ "$STATUS_ONLY" -eq 1 ]; then
        _deploy_status "$HPC_LOGIN"; return
    fi
    if [ "$LOG_ONLY" -eq 1 ]; then
        _deploy_log "$HPC_LOGIN"; return
    fi
    if [ "$EXTEND" -eq 1 ]; then
        _deploy_extend "$HPC_LOGIN" "$EXTEND_BY"; return
    fi

    log_sep
    log_info "O2Physics remote deploy"
    log_info "Target : $HPC_LOGIN"
    log_sep

    _deploy_check_ssh        "$HPC_LOGIN"
    _deploy_gen_config       "$HPC_LOGIN"

    if [ "$DRY_RUN" -eq 1 ]; then
        # Read-only: same rsync commands as a real deploy, run with -n.
        log_info "Mode   : --dry-run (read-only, nothing is changed on the cluster)"
        O2_DEPLOY_DRYRUN=1
        _DEPLOY_DRY_PENDING=0
        _DEPLOY_DRY_SYNC=0
        _deploy_sync         "$HPC_LOGIN"
        _deploy_sync_sources "$HPC_LOGIN"
        _deploy_tasks_check  "$HPC_LOGIN"
        _deploy_dry_verdict  "$HPC_LOGIN"
        return
    fi

    _deploy_sync             "$HPC_LOGIN"
    _deploy_sync_sources     "$HPC_LOGIN"

    if [ "$SYNC_ONLY" -eq 1 ]; then
        echo ""
        log_info "--sync-only: skipping remote build launch"
        echo ""
        echo "  To launch manually:"
        echo "    ssh $HPC_LOGIN"
        echo "    $O2_HPC_HOME_DIR/o2.sh build"
        return
    fi

    local REMOTE_ARGS=""
    [ "$SANDBOX_ONLY" -eq 1 ] && REMOTE_ARGS="--sandbox-only"
    [ "$BUILD_ONLY"   -eq 1 ] && REMOTE_ARGS="--build-only"

    _deploy_launch "$HPC_LOGIN" "$REMOTE_ARGS"
}

_deploy_help() {
    cat << 'EOF'
o2 deploy [options]

Options:
  (none)           sync scripts + O2Physics source + launch full build on HPC
  --sync-only      sync scripts + O2Physics source only, no build launch
  --sandbox-only   sync + launch sandbox build only
  --build-only     sync + launch O2Physics build only (no sandbox rebuild)
  --status         show running OAR jobs on HPC
  --log            tail the remote O2Physics build log
  --extend [+H:MM] manual override: ask OAR for more time for the RUNNING build job (runs
                   oarwalltime on the login node: the OAR commands do not exist on compute
                   nodes). Without an amount, only shows the job's walltime-change status.
                   OAR decides: the request may be pending or refused, e.g. +4:00:00
                   Normally not needed: the build job is checkpointed before its walltime
                   and resubmitted by OAR (O2_OAR_CHECKPOINT / O2_OAR_AUTORESUBMIT in
                   o2_config.sh), and aliBuild resumes where it stopped.
  --dry-run        read-only check: list what a deploy would change on the cluster
                   (scripts, analysis, O2Physics source) and verify that every
                   enabled task is in the synced source, in CMakeLists.txt and built
EOF
}

# ==============================================================================
# _deploy_check_ssh
# ==============================================================================
_deploy_check_ssh() {
    local HPC_LOGIN="$1"
    log_info "Checking SSH connectivity to $HPC_LOGIN ..."

    if ! ssh -o ConnectTimeout=10 -o BatchMode=yes \
             "$HPC_LOGIN" "echo ok" &>/dev/null; then
        log_error "Cannot connect to $HPC_LOGIN"
        echo ""
        echo "  Set up SSH key authentication:"
        echo "    ssh-keygen -t ed25519"
        echo "    ssh-copy-id $HPC_LOGIN"
        exit 1
    fi
    log_info "SSH connection OK"
}

# ==============================================================================
# _deploy_gen_config
# Generate sanitized o2_config.sh for HPC:
#   - GitHub token removed
#   - O2_APPTAINER_SUDO set to "" (rootless)
#   - O2_FORCE_HPC set to 1
# ==============================================================================
_deploy_gen_config() {
    local HPC_LOGIN="$1"
    log_info "Generating sanitized HPC config (no GitHub token)..."

    SANITIZED_CONFIG=$(mktemp /tmp/o2_config_hpc_XXXXXX.sh)

    sed \
        -e 's|^O2_GITHUB_TOKEN=.*|O2_GITHUB_TOKEN=""  # removed — not needed on HPC|' \
        -e 's|^O2_APPTAINER_SUDO=.*|O2_APPTAINER_SUDO=""  # rootless on HPC|' \
        -e 's|^O2_FORCE_HPC=0|O2_FORCE_HPC=1|' \
        "$O2_LOCAL_DIR/o2_config.sh" > "$SANITIZED_CONFIG"

    log_info "Sanitized config ready (token removed, HPC mode enabled)"
}

# ==============================================================================
# _deploy_sync
# rsync scripts and analysis to HPC.
# The sanitized config replaces o2_config.sh on the cluster.
# ==============================================================================
_deploy_sync() {
    local HPC_LOGIN="$1"
    log_info "Syncing to $HPC_LOGIN:$O2_HPC_HOME_DIR ..."

    # Create remote directories
    if [ "${O2_DEPLOY_DRYRUN:-0}" -ne 1 ]; then
        ssh "$HPC_LOGIN" "mkdir -p $O2_HPC_HOME_DIR/logs $O2_HPC_HOME_DIR/lib"
    fi

    # Sync declared files/dirs
    local SOURCES=()
    for item in "${O2_DEPLOY_FILES[@]}"; do
        local LOCAL_PATH="$O2_LOCAL_DIR/$item"
        if [ -e "$LOCAL_PATH" ]; then
            SOURCES+=("$LOCAL_PATH")
        else
            log_warn "Not found locally, skipping: $LOCAL_PATH"
        fi
    done

    # analysis/<wf>/output and analysis/<wf>/bookkeeping are per-run artefacts
    # (see .gitignore), never part of the analysis source. They must NOT be
    # pushed to the cluster:
    #   - output/ : on the cluster, $HOME/alice/analysis/<wf>/output is a
    #     symlink to the scratch (created by _resolve_workflow_paths). Without
    #     this exclusion rsync would fill the small HOME quota with local run
    #     output and could replace that symlink by a real directory.
    #   - bookkeeping/ : the cluster writes the job fragments (<prod>.d/); a
    #     stale local copy would overwrite more recent ones.
    # The patterns are anchored at the transfer root (leading "/"), so only
    # analysis/<wf>/output and analysis/<wf>/bookkeeping are matched. There is
    # no --delete here, and excluded paths are never deleted on the receiver.
    if [ "${#SOURCES[@]}" -gt 0 ]; then
        _deploy_rsync "scripts + analysis" -avz --checksum \
            --exclude='*~' \
            --exclude='*.swp' \
            --exclude='*.bak' \
            --exclude='.git' \
            --exclude='/analysis/*/output' \
            --exclude='/analysis/*/bookkeeping' \
            "${SOURCES[@]}" \
            "${HPC_LOGIN}:${O2_HPC_HOME_DIR}/"
    fi

    # Sync sanitized config (replaces o2_config.sh on cluster)
    # Use a fixed remote name so rsync output shows o2_config.sh not the tmp name
    log_info "Syncing sanitized o2_config.sh to cluster..."
    _deploy_rsync "o2_config.sh (sanitized)" -az --checksum \
        "$SANITIZED_CONFIG" \
        "${HPC_LOGIN}:${O2_HPC_HOME_DIR}/o2_config.sh"
    rm -f "$SANITIZED_CONFIG"

    if [ "${O2_DEPLOY_DRYRUN:-0}" -eq 1 ]; then
        return 0
    fi

    # Make scripts executable on cluster
    ssh "$HPC_LOGIN" \
        "chmod +x $O2_HPC_HOME_DIR/o2.sh \
                  $O2_HPC_HOME_DIR/get_aod.sh \
                  $O2_HPC_HOME_DIR/lib/*.sh \
                  2>/dev/null || true"

    log_info "Sync complete"
    log_info "Note: o2_config.sh on HPC has no GitHub token"
}

# ==============================================================================
# _deploy_sync_sources
# Rsync O2Physics source tree and alidist to HPC scratch.
# Only the working tree is synced — aliBuild artifacts (BUILD/, INSTALLROOT/,
# slc9_x86-64/, SOURCES/, MIRROR/, TARS/) are excluded because they will be
# rebuilt on the cluster from scratch.
#
# This replaces any git-based sync on the cluster: the cluster never needs
# git — it receives ready-to-build sources and runs aliBuild only.
# ==============================================================================
_deploy_sync_sources() {
    local HPC_LOGIN="$1"
    local HPC_SW="${O2_HPC_SCRATCH_DIR}/sw"
    local LOCAL_O2PHYSICS="$SW_DIR/O2Physics"
    local LOCAL_ALIDIST="$SW_DIR/alidist"

    # O2Physics source — required
    if [ ! -d "$LOCAL_O2PHYSICS/.git" ]; then
        log_warn "O2Physics source not found at $LOCAL_O2PHYSICS — skipping source sync"
        log_warn "Run 'o2 build' locally first to set up the source tree"
        return
    fi

    log_info "Syncing O2Physics source to $HPC_LOGIN:$HPC_SW/O2Physics ..."
    log_info "  Branch : $(git -C "$LOCAL_O2PHYSICS" rev-parse --abbrev-ref HEAD 2>/dev/null)"
    log_info "  Commit : $(git -C "$LOCAL_O2PHYSICS" log --oneline -1 2>/dev/null)"

    [ "${O2_DEPLOY_DRYRUN:-0}" -eq 1 ] || ssh "$HPC_LOGIN" "mkdir -p $HPC_SW/O2Physics $HPC_SW/alidist"

    # .sync_info is written on the cluster right after this rsync, so it must
    # not be deleted by --delete (it would show up as a permanent difference).
    _deploy_rsync "O2Physics source" -az --checksum --delete \
        --exclude='/.sync_info' \
        --exclude='.git/' \
        --exclude='cmake_install.cmake' \
        --exclude='CMakeCache.txt' \
        --exclude='CMakeFiles/' \
        "$LOCAL_O2PHYSICS/" \
        "${HPC_LOGIN}:${HPC_SW}/O2Physics/"

    if [ "${O2_DEPLOY_DRYRUN:-0}" -ne 1 ]; then
        log_info "O2Physics source synced ($(du -sh --exclude=".git" "$LOCAL_O2PHYSICS" | cut -f1) → cluster)"

        # Write sync info file on cluster for 'o2 sync --check'
        local COMMIT
        local BRANCH
        COMMIT=$(git -C "$LOCAL_O2PHYSICS" rev-parse HEAD 2>/dev/null)
        BRANCH=$(git -C "$LOCAL_O2PHYSICS" rev-parse --abbrev-ref HEAD 2>/dev/null)
        ssh "$HPC_LOGIN" "cat > ${HPC_SW}/O2Physics/.sync_info << SYNCEOF
commit=${COMMIT}
branch=${BRANCH}
synced_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
synced_from=$(hostname -s)
SYNCEOF"
        log_info "Sync info written to cluster (.sync_info)"
    fi

    # alidist — sync if present (needed for correct build recipes)
    if [ -d "$LOCAL_ALIDIST/.git" ]; then
        log_info "Syncing alidist to $HPC_LOGIN:$HPC_SW/alidist ..."
        _deploy_rsync "alidist" -az --checksum --delete \
            --exclude='.git/' \
            "$LOCAL_ALIDIST/" \
            "${HPC_LOGIN}:${HPC_SW}/alidist/"
        [ "${O2_DEPLOY_DRYRUN:-0}" -eq 1 ] || \
            log_info "alidist synced (tag: $(git -C "$LOCAL_ALIDIST" describe --tags HEAD 2>/dev/null || echo unknown))"
    else
        log_warn "alidist not found at $LOCAL_ALIDIST — cluster will use its own copy"
    fi

    # Tell aliBuild on the cluster to use the synced source, not clone from git.
    # This is done by removing any SOURCES/O2Physics entry that would take
    # precedence over the working tree (aliBuild prefers sw/O2Physics/ if present).
    #
    # Safety check: read the build lockfile on the cluster before touching SOURCES/.
    # The lock is written by _build_lock_acquire() at the start of every build
    # and removed by _build_lock_release() on EXIT — including OAR walltime kills.
    # (--dry-run stops here: no .sync_info, no SOURCES/ cleanup.)
    [ "${O2_DEPLOY_DRYRUN:-0}" -eq 1 ] && return 0

    local LOCK_FILE="${O2_HPC_HOME_DIR}/.build.lock"
    local LOCK_CONTENT
    LOCK_CONTENT=$(ssh "$HPC_LOGIN" "cat $LOCK_FILE 2>/dev/null || true")
    if [ -n "$LOCK_CONTENT" ]; then
        log_warn "Build lock detected on cluster:"
        echo "$LOCK_CONTENT" | sed 's/^/    /' >&2
        # State of the job that owns the lock. A build killed at its walltime
        # leaves its lock behind (OAR does not run the owner's trap), and the OAR
        # commands do not exist on the compute nodes: the login node, where
        # oarstat works, is the right place to recognize a stale lock.
        local LOCK_JOB LOCK_JOB_STATE LOCK_JOB_ROW
        LOCK_JOB="$(printf '%s\n' "$LOCK_CONTENT" | sed -n 's/^oar_job=//p')"
        if [[ "$LOCK_JOB" =~ ^[0-9]+$ ]]; then
            LOCK_JOB_STATE="$(ssh "$HPC_LOGIN" "oarstat -j $LOCK_JOB 2>&1 | grep -E 'Job id|^ *$LOCK_JOB '" || true)"
            [ -n "$LOCK_JOB_STATE" ] && { log_warn "Owner job $LOCK_JOB:"; echo "$LOCK_JOB_STATE" | sed 's/^/    /'; }
            # Only the job's own row decides, and only a clearly terminal state
            # counts as evidence (an oarstat failure must never free a live lock).
            LOCK_JOB_ROW="$(printf '%s\n' "$LOCK_JOB_STATE" | grep -E "^ *$LOCK_JOB " || true)"
            if printf '%s\n' "$LOCK_JOB_ROW" | grep -qiE 'running|launching|waiting|hold|resuming|suspended|finishing'; then
                :   # alive: keep the lock
            elif printf '%s\n' "$LOCK_JOB_ROW" | grep -qiE 'terminated|error|killed'; then
                log_warn "Owner job $LOCK_JOB is no longer alive: removing the stale lock."
                ssh "$HPC_LOGIN" "rm -f $LOCK_FILE"
                LOCK_CONTENT=""
            fi
        fi
    fi
    if [ -n "$LOCK_CONTENT" ]; then
        log_warn "Skipping SOURCES/O2Physics cleanup to avoid corrupting a running build."
        log_warn "If you are sure the lock is stale: ssh $HPC_LOGIN rm -f $LOCK_FILE"
        return
    fi

    ssh "$HPC_LOGIN" \
        "rm -rf ${HPC_SW}/SOURCES/O2Physics 2>/dev/null || true" && \
        log_info "Cleared SOURCES/O2Physics on cluster (aliBuild will use synced tree)"
}

# ==============================================================================
# _deploy_launch
# Submit the build OAR job on HPC via SSH.
# ==============================================================================
_deploy_launch() {
    local HPC_LOGIN="$1"
    local REMOTE_ARGS="${2:-}"

    log_info "Submitting OAR build job on $HPC_LOGIN ..."

    # Capture stdout AND stderr, and always show them: under 'set -e' a failing
    # command substitution would otherwise abort here, silently, hiding the
    # very message that explains the failure.
    local JOB_OUTPUT RC=0
    JOB_OUTPUT=$(ssh "$HPC_LOGIN" \
        "cd $O2_HPC_HOME_DIR && $O2_HPC_HOME_DIR/o2.sh build $REMOTE_ARGS" 2>&1) || RC=$?
    echo "$JOB_OUTPUT"

    if [ "$RC" -ne 0 ]; then
        log_error "Remote build submission FAILED (exit status $RC) — no build job was submitted."
        log_error "Read the output above, or run it by hand:"
        log_error "  ssh $HPC_LOGIN 'cd $O2_HPC_HOME_DIR && ./o2.sh build $REMOTE_ARGS'"
        exit 1
    fi

    local JOB_ID
    JOB_ID=$(echo "$JOB_OUTPUT" \
        | grep -oP '(?:OAR_JOB_ID=|OAR job submitted:\s*)\K[0-9]+' | tail -1 || true)
    if [ -z "$JOB_ID" ]; then
        log_error "The remote command ended without reporting an OAR job id — assume nothing was submitted."
        log_error "Check: ssh $HPC_LOGIN 'oarstat -u $O2_HPC_USER'"
        exit 1
    fi

    echo ""
    log_sep
    log_info "OAR job submitted on $HPC_LOGIN"
    log_info "Job ID  : $JOB_ID"
    log_info "Monitor : o2 deploy --status"
    log_info "Log     : o2 deploy --log"
    log_sep
}

# ==============================================================================
# _deploy_status
# ==============================================================================
_deploy_status() {
    local HPC_LOGIN="$1"
    log_info "O2Physics OAR jobs on $HPC_LOGIN :"
    # Plain-text 'oarstat -u' listing, filtered on the job name. (The former
    # 'oarstat -J | jq' filter swallowed its own errors and answered "no job"
    # while a build was Waiting.)
    local OUT RC=0 BUILD_ACTIVE=0
    OUT="$(ssh "$HPC_LOGIN" "oarstat -u ${O2_HPC_USER} 2>&1")" || RC=$?
    if [ "$RC" -ne 0 ]; then
        log_error "  oarstat failed over ssh (exit status $RC):"
        printf '%s\n' "$OUT" | sed 's/^/    /' >&2
        return 1
    fi
    if printf '%s\n' "$OUT" | grep -q 'O2Physics'; then
        BUILD_ACTIVE=1
        printf '%s\n' "$OUT" | grep -E 'Job id|O2Physics' | sed 's/[[:space:]]*$//'
    else
        echo "  No O2Physics build job queued or running."
    fi

    # Result of the last build that FINISHED (written by the build itself).
    local ST BSTATUS BDATE BCODE
    ST="$(ssh "$HPC_LOGIN" "cat ${O2_HPC_HOME_DIR}/logs/build_status 2>/dev/null || true")"
    echo ""
    log_info "Last finished build:"
    if [ -z "$ST" ]; then
        echo "  no build status recorded yet (${O2_HPC_HOME_DIR}/logs/build_status)"
    else
        BSTATUS="$(printf '%s\n' "$ST" | sed -n 's/^status=//p')"
        BDATE="$(printf '%s\n' "$ST" | sed -n 's/^finished_at=//p')"
        BCODE="$(printf '%s\n' "$ST" | sed -n 's/^exit_code=//p')"
        echo "  status=${BSTATUS:-unknown}  finished_at=${BDATE:-?}${BCODE:+  exit_code=$BCODE}"
        if [ "$BUILD_ACTIVE" -eq 1 ]; then
            echo "  (a build job is queued or running: this is the result of the PREVIOUS build)"
        fi
    fi
}

# ==============================================================================
# _deploy_log
# ==============================================================================
# _deploy_extend <hpc_login> [<+H:MM:SS>]
# Asks OAR for more time for the RUNNING O2Physics build job with oarwalltime,
# run on the login node (the OAR client commands do not exist on the compute
# nodes of dahu, so a job cannot extend itself). Without an amount, only shows
# the walltime-change status. OAR decides: the request may stay pending or be
# refused (feature disabled, resources reserved by another job).
_deploy_extend() {
    local HPC_LOGIN="$1" BY="$2"
    local OUT RC=0 JOB
    OUT="$(ssh "$HPC_LOGIN" "oarstat -u ${O2_HPC_USER} 2>&1")" || RC=$?
    if [ "$RC" -ne 0 ]; then
        log_error "oarstat failed over ssh (exit status $RC):"
        printf '%s\n' "$OUT" | sed 's/^/    /' >&2
        return 1
    fi
    JOB="$(printf '%s\n' "$OUT" | awk '/O2Physics_full_build/ && /Running/ { print $1; exit }')"
    if [ -z "$JOB" ]; then
        if printf '%s\n' "$OUT" | grep -q 'O2Physics_full_build'; then
            log_warn "The O2Physics build job is queued, not running yet: oarwalltime only applies to a RUNNING job."
        else
            log_info "No O2Physics build job running (nothing to extend)."
        fi
        return 0
    fi

    if [ -z "$BY" ]; then
        log_info "Walltime-change status of job $JOB (to request more time: o2 deploy --extend +4:00:00):"
        ssh "$HPC_LOGIN" "oarwalltime $JOB 2>&1" | sed 's/^/  /' || true
    else
        log_info "Asking OAR for $BY more for job $JOB (OAR decides; the request may be pending or refused):"
        ssh "$HPC_LOGIN" "oarwalltime $JOB $BY 2>&1" | sed 's/^/  /' || true
        log_info "Check later with: o2 deploy --extend"
    fi
}

_deploy_log() {
    local HPC_LOGIN="$1"
    log_info "Tailing remote build log..."
    ssh "$HPC_LOGIN" \
        "tail -f ${O2_HPC_HOME_DIR}/logs/o2physics.log 2>/dev/null \
         || echo '[ERROR] Log not found: ${O2_HPC_HOME_DIR}/logs/o2physics.log'"
}

# ==============================================================================
# --dry-run support (o2 deploy --dry-run)
#
# Read-only check of the cluster state. It runs the SAME rsync commands as a
# real deploy (same flags, same excludes) with -n, so the answer to "is the
# cluster up to date?" is exactly "would deploy change anything?". It then
# checks that each task enabled in analysis.json is in the synced source, has
# its block in CMakeLists.txt and a binary built after its source.
# ==============================================================================

# _deploy_rsync <label> <rsync args...>
# Real deploy: plain rsync. --dry-run: rsync -n --itemize-changes + a report.
_deploy_rsync() {
    local LABEL="$1"; shift
    if [ "${O2_DEPLOY_DRYRUN:-0}" -ne 1 ]; then
        rsync "$@"
        return
    fi
    local OUT
    if ! OUT="$(rsync -n --itemize-changes "$@" 2>&1)"; then
        log_error "  rsync dry-run failed for: $LABEL"
        printf '%s\n' "$OUT" | sed 's/^/      /' >&2
        _DEPLOY_DRY_PENDING=$((_DEPLOY_DRY_PENDING + 1))
        _DEPLOY_DRY_SYNC=$((${_DEPLOY_DRY_SYNC:-0} + 1))
        return 0
    fi
    _deploy_dry_report "$LABEL" "$OUT"
}

# _deploy_dry_report <label> <rsync -n --itemize-changes output>
# Itemize format is YXcstpoguax: Y='>' file would be transferred (new or
# changed content), '*deleting' file would be deleted, 'cL' symlink would be
# created. Lines starting with '.' are attribute-only updates (timestamps) and
# directory creations ('cd') are implied by the files they contain: neither
# is a content difference.
_deploy_dry_report() {
    local LABEL="$1" OUT="$2"
    local CHANGES N_ALL N_NEW N_DEL N_CHG
    CHANGES="$(printf '%s\n' "$OUT" | grep -E '^(>f|<f|c[LDS]|\*deleting)' || true)"
    if [ -z "$CHANGES" ]; then
        log_info "  [OK] $LABEL: up to date"
        return 0
    fi
    N_ALL="$(printf '%s\n' "$CHANGES" | wc -l)"
    N_NEW="$(printf '%s\n' "$CHANGES" | grep -cE '^(>f|<f|c[LDS])[+]{9}' || true)"
    N_DEL="$(printf '%s\n' "$CHANGES" | grep -c '^\*deleting' || true)"
    N_CHG=$((N_ALL - N_NEW - N_DEL))
    log_warn "  [!!] $LABEL: $N_NEW new, $N_CHG changed, $N_DEL to delete"
    printf '%s\n' "$CHANGES" | head -25 | sed 's/^/         /'
    [ "$N_ALL" -gt 25 ] && echo "         ... ($((N_ALL - 25)) more)"
    _DEPLOY_DRY_PENDING=$((_DEPLOY_DRY_PENDING + N_ALL))
    _DEPLOY_DRY_SYNC=$((${_DEPLOY_DRY_SYNC:-0} + N_ALL))
    return 0
}

# _deploy_tasks_check <hpc_login>
# For every task enabled in analysis.json (same enumeration as
# 'o2 build --rebuild-tasks'), checks on the cluster that:
#   - the source file is in the synced O2Physics tree,
#   - its o2physics_add_dpl_workflow(<dpl> block is in the CMakeLists.txt,
#   - the binary o2-analysis-<pwg>-<dpl> exists and is newer than the source.
_deploy_tasks_check() {
    local HPC_LOGIN="$1"
    local REGISTRY="$O2_LOCAL_DIR/analysis/analysis.json"
    local HPC_SW="${O2_HPC_SCRATCH_DIR}/sw"

    log_step "Enabled tasks on the cluster"

    if [ ! -f "$REGISTRY" ]; then
        log_warn "  analysis.json not found locally: $REGISTRY"
        _DEPLOY_DRY_PENDING=$((_DEPLOY_DRY_PENDING + 1))
        return 0
    fi
    source "$SCRIPTS_DIR/lib/analysis.sh"   # _analysis_get_enabled_tasks

    local TASKS
    TASKS="$(_analysis_get_enabled_tasks "$REGISTRY")"
    if [ -z "$TASKS" ]; then
        log_warn "  No task enabled in analysis.json (nothing to check)"
        return 0
    fi

    # The task list travels base64-encoded: ssh would break multi-line arguments.
    local TASKS_B64 RESULT
    TASKS_B64="$(printf '%s\n' "$TASKS" | base64 | tr -d '\n')"
    RESULT="$(ssh "$HPC_LOGIN" bash -s -- "$HPC_SW" "$TASKS_B64" << 'REMOTE'
HPC_SW="$1"
printf '%s' "$2" | base64 -d | while read -r A P D; do
    [ -z "$A" ] && continue
    src="$HPC_SW/O2Physics/$P"
    cml="$HPC_SW/O2Physics/$(dirname "$P")/CMakeLists.txt"
    pwg="$(echo "${P%%/*}" | sed 's/^PWG//' | tr 'A-Z' 'a-z')"
    exe="o2-analysis-$pwg-$D"
    if [ -f "$src" ]; then S=ok; else S=missing; fi
    if grep -Eq "o2physics_add_dpl_workflow\($D([[:space:]]|\$)" "$cml" 2>/dev/null; then C=ok; else C=missing; fi
    bin="$(ls -t "$HPC_SW"/*/O2Physics/*/bin/"$exe" 2>/dev/null | head -1)"
    if [ -z "$bin" ]; then B=missing
    elif [ "$bin" -nt "$src" ]; then B=ok
    else B=stale
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$A" "$P" "$exe" "$S" "$C" "$B" "${bin:--}"
done
REMOTE
)" || true

    if [ -z "$RESULT" ]; then
        log_error "  No answer from the cluster for the task check"
        _DEPLOY_DRY_PENDING=$((_DEPLOY_DRY_PENDING + 1))
        return 0
    fi

    local A P EXE S C B BIN
    while IFS=$'\t' read -r A P EXE S C B BIN; do
        [ -z "$A" ] && continue
        if [ "$S" = ok ] && [ "$C" = ok ] && [ "$B" = ok ]; then
            log_info "  [OK] [$A] $EXE"
            log_info "         binary: $BIN"
            continue
        fi
        log_warn "  [!!] [$A] $EXE"
        [ "$S" = ok ] || log_warn "         source $P: MISSING in the synced O2Physics tree"
        [ "$C" = ok ] || log_warn "         CMakeLists.txt: no o2physics_add_dpl_workflow block for this task"
        case "$B" in
            missing) log_warn "         binary: NOT BUILT on the cluster" ;;
            stale)   log_warn "         binary: OLDER than its source ($BIN) — rebuild needed" ;;
        esac
        _DEPLOY_DRY_PENDING=$((_DEPLOY_DRY_PENDING + 1))
    done <<< "$RESULT"
}

# _deploy_dry_verdict <hpc_login>
# Last build status on the cluster, then the overall answer (exit status 1
# when something is out of date, so it can be used in scripts).
_deploy_dry_verdict() {
    local HPC_LOGIN="$1" ST BSTATUS BDATE
    ST="$(ssh "$HPC_LOGIN" "cat ${O2_HPC_HOME_DIR}/logs/build_status 2>/dev/null || true")"
    log_step "Last build on the cluster"
    if [ -z "$ST" ]; then
        log_warn "  [!!] no build status recorded (${O2_HPC_HOME_DIR}/logs/build_status)"
        _DEPLOY_DRY_PENDING=$((_DEPLOY_DRY_PENDING + 1))
    else
        BSTATUS="$(printf '%s\n' "$ST" | sed -n 's/^status=//p')"
        BDATE="$(printf '%s\n' "$ST" | sed -n 's/^finished_at=//p')"
        if [ "$BSTATUS" = "success" ]; then
            log_info "  [OK] status=success, finished $BDATE"
        else
            log_warn "  [!!] status=${BSTATUS:-unknown}, finished $BDATE"
            _DEPLOY_DRY_PENDING=$((_DEPLOY_DRY_PENDING + 1))
        fi
    fi

    log_sep
    if [ "$_DEPLOY_DRY_PENDING" -eq 0 ]; then
        log_info "Cluster is up to date: nothing to deploy, enabled tasks are built."
        return 0
    fi
    local N_SYNC="${_DEPLOY_DRY_SYNC:-0}" N_BUILD
    N_BUILD=$((_DEPLOY_DRY_PENDING - N_SYNC))
    log_warn "$_DEPLOY_DRY_PENDING item(s) out of date on the cluster ($N_SYNC to synchronize, $N_BUILD about the build)."
    if [ "$N_BUILD" -gt 0 ]; then
        log_warn "To fix: o2 deploy --build-only   (synchronizes first, then rebuilds O2Physics on the cluster)"
    else
        log_warn "To fix: o2 deploy --sync-only    (push scripts, analysis and O2Physics source)"
    fi
    log_warn "Then re-run: o2 deploy --dry-run"
    return 1
}
