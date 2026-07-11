# lib/sync.sh
# Check synchronization state between local O2Physics and HPC cluster.
#
# Sourced by o2.sh — never executed directly.

# ==============================================================================
# cmd_sync
# Entry point for: o2 sync [--check]
# ==============================================================================
cmd_sync() {
    local CHECK=0

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --check) CHECK=1 ; shift ;;
            --help|-h) _sync_help ; return ;;
            *) log_error "Unknown option: $1" ; _sync_help ; return 1 ;;
        esac
    done

    _sync_check
}

# ==============================================================================
# _sync_check
# Compare local O2Physics commit with the .sync_info written on the cluster
# by _deploy_sync_sources during the last 'o2 deploy'.
# ==============================================================================
_sync_check() {
    local HPC_LOGIN="${O2_HPC_USER}@${O2_HPC_HOST}"
    local HPC_SYNC_INFO="${O2_HPC_SCRATCH_DIR}/sw/O2Physics/.sync_info"
    local LOCAL_O2PHYSICS="$SW_DIR/O2Physics"

    log_sep
    log_info "O2Physics synchronization check"
    log_sep

    # --- Local state ---
    if [ ! -d "$LOCAL_O2PHYSICS/.git" ]; then
        log_error "O2Physics not found locally at $LOCAL_O2PHYSICS"
        return 1
    fi

    local LOCAL_COMMIT LOCAL_BRANCH LOCAL_DIRTY
    LOCAL_COMMIT=$(git -C "$LOCAL_O2PHYSICS" rev-parse HEAD 2>/dev/null)
    LOCAL_BRANCH=$(git -C "$LOCAL_O2PHYSICS" rev-parse --abbrev-ref HEAD 2>/dev/null)
    LOCAL_DIRTY=$(git -C "$LOCAL_O2PHYSICS" status --porcelain 2>/dev/null | wc -l)

    log_info "Local O2Physics :"
    log_info "  Branch : $LOCAL_BRANCH"
    log_info "  Commit : $(git -C "$LOCAL_O2PHYSICS" log --oneline -1 2>/dev/null)"
    if [ "$LOCAL_DIRTY" -gt 0 ]; then
        log_warn "  Status : $LOCAL_DIRTY uncommitted change(s)"
    else
        log_info "  Status : clean"
    fi

    echo ""

    # --- Cluster state ---
    local SYNC_INFO
    SYNC_INFO=$(ssh "$HPC_LOGIN" "cat $HPC_SYNC_INFO 2>/dev/null || echo NOT_FOUND")

    if [ "$SYNC_INFO" = "NOT_FOUND" ]; then
        log_warn "Cluster : no sync info found — run 'o2 deploy --sync-only' first"
        log_sep
        return 1
    fi

    local CLUSTER_COMMIT CLUSTER_BRANCH CLUSTER_DATE CLUSTER_FROM
    CLUSTER_COMMIT=$(echo "$SYNC_INFO" | grep '^commit='  | cut -d= -f2)
    CLUSTER_BRANCH=$(echo "$SYNC_INFO" | grep '^branch='  | cut -d= -f2)
    CLUSTER_DATE=$(  echo "$SYNC_INFO" | grep '^synced_at=' | cut -d= -f2)
    CLUSTER_FROM=$(  echo "$SYNC_INFO" | grep '^synced_from=' | cut -d= -f2)

    log_info "Cluster O2Physics ($HPC_LOGIN) :"
    log_info "  Branch    : $CLUSTER_BRANCH"
    log_info "  Commit    : ${CLUSTER_COMMIT:0:9} ($(ssh "$HPC_LOGIN" \
        "git -C ${O2_HPC_SCRATCH_DIR}/sw/O2Physics log --oneline -1 $CLUSTER_COMMIT 2>/dev/null \
         || echo $CLUSTER_COMMIT" 2>/dev/null || echo "$CLUSTER_COMMIT"))"
    log_info "  Synced at : $CLUSTER_DATE (from $CLUSTER_FROM)"

    echo ""

    # --- Comparison ---
    if [ "$LOCAL_COMMIT" = "$CLUSTER_COMMIT" ]; then
        log_info "✓ IN SYNC — local and cluster are on the same commit"
    else
        log_warn "✗ OUT OF SYNC"
        log_warn "  Local   : ${LOCAL_COMMIT:0:9}"
        log_warn "  Cluster : ${CLUSTER_COMMIT:0:9}"
        log_warn "  Run 'o2 deploy --sync-only' to sync, then 'o2 deploy --build-only' to rebuild"
    fi

    # --- Last build status ---
    local STATUS_FILE="${O2_HPC_HOME_DIR}/logs/build_status"
    local STATUS_CONTENT
    STATUS_CONTENT=$(ssh "$HPC_LOGIN" "cat $STATUS_FILE 2>/dev/null || echo NOT_FOUND")

    echo ""
    if [ "$STATUS_CONTENT" = "NOT_FOUND" ]; then
        log_warn "No build status found on cluster — run 'o2 deploy --build-only' first"
    else
        local BUILD_STATUS BUILD_DATE BUILD_BRANCH BUILD_RC
        BUILD_STATUS=$(echo "$STATUS_CONTENT" | grep '^status='     | cut -d= -f2)
        BUILD_DATE=$(  echo "$STATUS_CONTENT" | grep '^finished_at=' | cut -d= -f2)
        BUILD_BRANCH=$(echo "$STATUS_CONTENT" | grep '^branch='     | cut -d= -f2)
        BUILD_RC=$(    echo "$STATUS_CONTENT" | grep '^exit_code='  | cut -d= -f2)

        log_info "Last build on cluster :"
        log_info "  Status    : $BUILD_STATUS"
        log_info "  Finished  : $BUILD_DATE"
        log_info "  Branch    : $BUILD_BRANCH"
        [ -n "$BUILD_RC" ] && log_warn "  Exit code : $BUILD_RC"

        if [ "$BUILD_STATUS" != "success" ]; then
            log_warn "Last build FAILED — run 'o2 deploy --build-only' to rebuild"
        fi
    fi

    # --- Build lock state ---
    local LOCK_FILE="${O2_HPC_SCRATCH_DIR}/sw/.build.lock"
    local LOCK_CONTENT
    LOCK_CONTENT=$(ssh "$HPC_LOGIN" "cat $LOCK_FILE 2>/dev/null || true")
    if [ -n "$LOCK_CONTENT" ]; then
        echo ""
        log_warn "Build lock active on cluster:"
        echo "$LOCK_CONTENT" | sed 's/^/    /' >&2
    fi

    log_sep
}

_sync_help() {
    cat << 'EOF'
o2 sync [options]

Check synchronization between local O2Physics and the HPC cluster.

Options:
  --check    Compare local commit with last deployed commit on cluster
  --help     Show this help

Examples:
  o2 sync            # check sync status
  o2 sync --check    # same

EOF
}
