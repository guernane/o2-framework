#!/bin/bash
# ==============================================================================
# lib/deploy.sh
# Synchronize scripts and analyses from local machine to HPC cluster.
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

    while [[ $# -gt 0 ]]; do
        case $1 in
            --sync-only)    SYNC_ONLY=1 ;;
            --sandbox-only) SANDBOX_ONLY=1 ;;
            --build-only)   BUILD_ONLY=1 ;;
            --status)       STATUS_ONLY=1 ;;
            --log)          LOG_ONLY=1 ;;
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

    log_sep
    log_info "O2Physics remote deploy"
    log_info "Target : $HPC_LOGIN"
    log_sep

    _deploy_check_ssh        "$HPC_LOGIN"
    _deploy_gen_config       "$HPC_LOGIN"
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
# rsync scripts and analyses to HPC.
# The sanitized config replaces o2_config.sh on the cluster.
# ==============================================================================
_deploy_sync() {
    local HPC_LOGIN="$1"
    log_info "Syncing to $HPC_LOGIN:$O2_HPC_HOME_DIR ..."

    # Create remote directories
    ssh "$HPC_LOGIN" "mkdir -p $O2_HPC_HOME_DIR/logs $O2_HPC_HOME_DIR/lib"

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

    if [ "${#SOURCES[@]}" -gt 0 ]; then
        rsync -avz --checksum \
            --exclude='*~' \
            --exclude='*.swp' \
            --exclude='*.bak' \
            --exclude='.git' \
            "${SOURCES[@]}" \
            "${HPC_LOGIN}:${O2_HPC_HOME_DIR}/"
    fi

    # Sync sanitized config (replaces o2_config.sh on cluster)
    # Use a fixed remote name so rsync output shows o2_config.sh not the tmp name
    log_info "Syncing sanitized o2_config.sh to cluster..."
    rsync -az --checksum \
        "$SANITIZED_CONFIG" \
        "${HPC_LOGIN}:${O2_HPC_HOME_DIR}/o2_config.sh"
    rm -f "$SANITIZED_CONFIG"

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

    ssh "$HPC_LOGIN" "mkdir -p $HPC_SW/O2Physics $HPC_SW/alidist"

    rsync -az --checksum --delete \
        --exclude='.git/' \
        --exclude='cmake_install.cmake' \
        --exclude='CMakeCache.txt' \
        --exclude='CMakeFiles/' \
        "$LOCAL_O2PHYSICS/" \
        "${HPC_LOGIN}:${HPC_SW}/O2Physics/"

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

    # alidist — sync if present (needed for correct build recipes)
    if [ -d "$LOCAL_ALIDIST/.git" ]; then
        log_info "Syncing alidist to $HPC_LOGIN:$HPC_SW/alidist ..."
        rsync -az --checksum --delete \
            --exclude='.git/' \
            "$LOCAL_ALIDIST/" \
            "${HPC_LOGIN}:${HPC_SW}/alidist/"
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
    local LOCK_FILE="${HPC_SW}/.build.lock"
    local LOCK_CONTENT
    LOCK_CONTENT=$(ssh "$HPC_LOGIN" "cat $LOCK_FILE 2>/dev/null || true")
    if [ -n "$LOCK_CONTENT" ]; then
        log_warn "Build lock detected on cluster — a build is in progress:"
        echo "$LOCK_CONTENT" | sed 's/^/    /' >&2
        log_warn "Skipping SOURCES/O2Physics cleanup to avoid corrupting the build."
        log_warn "If the lock is stale, remove it with:"
        log_warn "  ssh $HPC_LOGIN rm -f $LOCK_FILE"
        log_warn "Then re-run: o2 deploy --build-only"
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

    local JOB_OUTPUT
    JOB_OUTPUT=$(ssh "$HPC_LOGIN" \
        "cd $O2_HPC_HOME_DIR && $O2_HPC_HOME_DIR/o2.sh build $REMOTE_ARGS")
    echo "$JOB_OUTPUT"

    local JOB_ID
    JOB_ID=$(echo "$JOB_OUTPUT" \
        | grep -oP '(?:OAR_JOB_ID=|OAR job submitted:\s*)\K[0-9]+' | tail -1)

    echo ""
    log_sep
    log_info "OAR job submitted on $HPC_LOGIN"
    log_info "Job ID  : ${JOB_ID:-unknown}"
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
    # Use oarstat -J (JSON) and jq to filter only O2Physics jobs by name
    # Note: jq filter passed via env var to avoid quoting issues over SSH
    ssh "$HPC_LOGIN" \
        'JQ_FILTER='"'"'to_entries[] | select(.value.name != null and (.value.name | test("^O2"))) | [.key, .value.state, .value.name, (.value.message | split(",")[1] | ltrimstr("W=") // "?")] | @tsv'"'"'; oarstat -u '"${O2_HPC_USER}"' -J 2>/dev/null | jq -r "$JQ_FILTER" 2>/dev/null || echo "No O2Physics OAR jobs found"'
}

# ==============================================================================
# _deploy_log
# ==============================================================================
_deploy_log() {
    local HPC_LOGIN="$1"
    log_info "Tailing remote build log..."
    ssh "$HPC_LOGIN" \
        "tail -f ${O2_HPC_HOME_DIR}/logs/o2physics.log 2>/dev/null \
         || echo '[ERROR] Log not found: ${O2_HPC_HOME_DIR}/logs/o2physics.log'"
}
