#!/bin/bash
# ==============================================================================
# lib/shell.sh
# Interactive shell (or one-off command) inside the O2Physics container,
# with the O2Physics environment already loaded.
#
# Usage:
#   o2 shell [options] [-- command [args...]]
#
# Never executed directly: sourced by o2.sh on demand.
# ==============================================================================

# ------------------------------------------------------------------------------
# _shell_recorded_tag <worktree>
# Echo the alienv version tag recorded for a worktree in analysis.json by
# 'o2 build' (same source as 'o2 build --use'). Echoes nothing if there is no
# registry or no recorded build — the caller then falls back to the default.
# ------------------------------------------------------------------------------
_shell_recorded_tag() {
    local NAME="${1:-dev}"
    local BASE_DIR="$O2_LOCAL_DIR"
    [ "$ENV_TYPE" != "local" ] && BASE_DIR="$O2_HPC_HOME_DIR"
    local REGISTRY="$BASE_DIR/analysis/analysis.json"
    [ -f "$REGISTRY" ] || return 0

    python3 - "$REGISTRY" "$NAME" 2>/dev/null << 'PYEOF'
import sys, json
path, name = sys.argv[1:]
with open(path) as f:
    data = json.load(f)
print(data.get("worktrees", {}).get(name, {}).get("tag", ""))
PYEOF
}

cmd_shell() {
    local TARGET="" RAW=0 TAG=""
    local -a EXTRA_BINDS=() USER_CMD=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --pr|--use) shift; TARGET="$1" ;;
            --raw)      RAW=1 ;;
            --tag)      shift; TAG="$1" ;;
            -B|--bind)  shift; EXTRA_BINDS+=(-B "$1") ;;
            --help|-h)  _shell_help; return 0 ;;
            --)         shift; USER_CMD=("$@"); break ;;
            *)          log_error "Unknown option: $1"; _shell_help; return 1 ;;
        esac
        shift
    done

    # An interactive session must not run on an HPC login node.
    if [ "$ENV_TYPE" = "hpc_login" ]; then
        log_error "o2 shell: do not run an interactive session on the login node"
        log_info  "Start an interactive OAR job first (oarsub -I ...), then run 'o2 shell' inside it"
        return 1
    fi

    [ -d "$SANDBOX" ] || {
        log_error "Sandbox not found: $SANDBOX — run 'o2 build' first"
        return 1
    }

    local WT
    if ! WT=$(_resolve_worktree "$TARGET"); then
        log_error "Unknown worktree: '${TARGET:-dev}'"
        log_error "Run 'o2 build --list' to see available worktrees (dev, master, or a PR name)"
        return 1
    fi
    local CONTAINER_WT="/alice/sw/${WT#$SW_DIR/}"

    # Which O2Physics version to load (not needed with --raw), by priority:
    #   1. --tag <version>                       explicit
    #   2. build recorded for the worktree       analysis.json, as 'o2 build --use'
    #   3. $O2_ENV_TAG, else 'latest'            moving pointer: the most
    #                                            recently built worktree
    local TAG_SRC=""
    if [ "$RAW" -eq 0 ]; then
        if [ -n "$TAG" ]; then
            TAG_SRC="--tag"
        else
            TAG="$(_shell_recorded_tag "${TARGET:-dev}")"
            if [ -n "$TAG" ]; then
                TAG_SRC="build recorded for [${TARGET:-dev}]"
            else
                TAG="${O2_ENV_TAG:-latest}"
                TAG_SRC="default — no build recorded for [${TARGET:-dev}]"
            fi
        fi
        export O2_ENV_TAG="$TAG"
    fi

    load_apptainer
    detect_resources   # sets TMP_DIR, needed by the /tmp bind

    local LABEL="o2:${TARGET:-dev}"
    [ "$RAW" -eq 1 ] && LABEL="o2-raw:${TARGET:-dev}"
    [ "$RAW" -eq 0 ] && LABEL="$LABEL:$TAG"

    # These ride in the bind-args slot of _o2_container (raw apptainer args).
    local -a AP_ARGS=(
        --pwd "$CONTAINER_WT"
        --env "TERM=${TERM:-xterm}"
        --env 'PS1=['"$LABEL"'] \w \$ '
        "${EXTRA_BINDS[@]}"
    )

    local -a CMD
    if [ "${#USER_CMD[@]}" -gt 0 ]; then
        CMD=("${USER_CMD[@]}")
    else
        CMD=(bash --noprofile --norc -i)
        log_info "Entering container [${TARGET:-dev}] in $CONTAINER_WT"
        [ "$RAW" -eq 0 ] && log_info "O2Physics environment: O2Physics/$TAG ($TAG_SRC)"
        log_info "Type 'exit' to leave."
    fi

    local RC=0
    if [ "$RAW" -eq 1 ]; then
        _o2_container_raw "${AP_ARGS[@]}" -- "${CMD[@]}" || RC=$?
    else
        _o2_container "${AP_ARGS[@]}" -- "${CMD[@]}" || RC=$?
    fi
    return "$RC"
}

_shell_help() {
    cat << 'EOF'
o2 shell [options] [-- command [args...]]

Open an interactive shell inside the O2Physics container, with the
O2Physics environment loaded (alienv) and the working directory set to
the O2Physics worktree. With '-- command', run that command in the same
environment instead of a shell.

O2Physics version loaded (first match wins):
  1. --tag <version>                  explicit alienv version
  2. the build recorded for the worktree (analysis.json, same as
     'o2 build --use <name>')
  3. $O2_ENV_TAG, else 'latest' — a moving pointer to the most recently
     built worktree, NOT a fixed version

Options:
  --pr <n>       start in a specific worktree instead of dev (also: master)
                 and load that worktree's own build
  --tag <t>      load this exact O2Physics version (see 'o2 list builds --local')
  --raw          do NOT load O2Physics (aliBuild / ninja debugging)
  -B <h:c>       extra bind mount host:container (repeatable)

Examples:
  o2 shell                              # dev, with its recorded build
  o2 shell --pr master                  # master sources + master's build
  o2 shell --tag 9741fc8cc2-local1      # a specific version
  o2 shell --raw
  o2 shell -B ~/alice/data:/data
  o2 shell -- o2-analysis-je-jet-finder-charged --help

Local workstation, or inside an interactive OAR job on the cluster.
EOF
}
