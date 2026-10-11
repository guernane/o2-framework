#!/bin/bash
# lib/list.sh - List existing data, outputs, and builds
#
# The listing helpers (_clean_list_*_local, _clean_print_active_versions) are
# shared with 'o2 clean' and live in clean.sh. Source it here so this module
# is self-contained instead of relying on whoever sourced it first.
source "${SCRIPTS_DIR:?SCRIPTS_DIR is not set}/lib/clean.sh"

cmd_list() {
    local CATEGORY="${1:-}"
    [[ "$CATEGORY" == --* ]] && CATEGORY=""
    [ -n "$CATEGORY" ] && shift
    local WHERE=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --local)  WHERE="local" ;;
            --remote) WHERE="remote" ;;
            --both)   WHERE="both" ;;
            --help|-h) _list_help; return 0 ;;
        esac
        shift
    done
    [ -z "$WHERE" ] && { log_error "specify --local, --remote, or --both"; _list_help; exit 1; }

    local REMOTE_HOST="${O2_HPC_USER}@${O2_HPC_HOST}"
    local CATS=(data outputs builds)
    [ -n "$CATEGORY" ] && CATS=("$CATEGORY")

    if [ "$WHERE" = "local" ] || [ "$WHERE" = "both" ]; then
        for c in "${CATS[@]}"; do
            log_step "Local — $c"
            case "$c" in
                data)    _clean_list_data_local ;;
                outputs) _clean_list_outputs_local ;;
                builds)  _clean_list_builds_local ;;
            esac
        done
    fi
    if [ "$WHERE" = "remote" ] || [ "$WHERE" = "both" ]; then
	ssh "$REMOTE_HOST" "$O2_HPC_HOME_DIR/o2.sh" list "$CATEGORY" --local 2>&1 | sed 's/^──── Local —/──── Remote —/; /^$/d'
    fi
}

_list_help() {
    cat << 'EOF'
o2 list [data|outputs|builds] (--local|--remote|--both)

Shows what exists in each category (size, last modified), without
deleting anything. See 'o2 clean' to remove items.

For builds, the last column marks the build 'latest' points to (ACTIVE)
and the worktree(s) each build belongs to, e.g. "[dev]" or "[master]".
The build name is what 'o2 shell --tag' expects.

Examples:
  o2 list --both
  o2 list outputs --local
  o2 list builds --remote
EOF
}
