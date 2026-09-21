#!/bin/bash
# ==============================================================================
# lib/common.sh
# Shared functions sourced by all lib/*.sh modules and o2.sh.
# Never executed directly.
# ==============================================================================

# ==============================================================================
# detect_environment
# Sets: ENV_TYPE = local | hpc_login | oar | slurm
# ==============================================================================
detect_environment() {
    if [ -n "${OAR_JOB_ID:-}" ]; then
        ENV_TYPE="oar"
    elif [ -n "${SLURM_JOB_ID:-}" ]; then
        ENV_TYPE="slurm"
    elif [ "${O2_FORCE_HPC:-0}" -eq 1 ]; then
        ENV_TYPE="hpc_login"
    else
        ENV_TYPE="local"
    fi
}

# ==============================================================================
# resolve_paths
# Sets all shared path variables based on ENV_TYPE + o2_config.sh.
# ==============================================================================
resolve_paths() {
    if [ "$ENV_TYPE" = "local" ]; then
        SUDO="${O2_APPTAINER_SUDO:-sudo}"
        BASE="$O2_LOCAL_DIR"
        LOG_DIR="$BASE/logs"
        SANDBOX="$BASE/$O2_SANDBOX_NAME"
        DEF_FILE="$BASE/$O2_DEF_FILE_NAME"
        SW_DIR="$BASE/sw"
        TMP_BASE="$BASE/tmp"
        FAKEHOME="$BASE/fakehome"
        DATA_BASE="$BASE/data"
        O2PHYSICS_SRC="$BASE/sw/O2Physics"
        O2PHYSICS_MASTER_SRC="$BASE/sw/O2Physics/.worktrees/master"
        RESCUE_DIR="$BASE/rescue"
    else
        SUDO=""
        if [ -n "${O2_HPC_SCRATCH_DIR:-}" ]; then
            SCRATCH="${O2_HPC_SCRATCH_DIR}"
        elif [ -n "${SCRATCH:-}" ]; then
            local _SCHED_SCRATCH="${SCRATCH}"
            SCRATCH="${_SCHED_SCRATCH}/alice"
        elif [ -n "${WORKDIR:-}" ]; then
            SCRATCH="${WORKDIR}/alice"
        else
            SCRATCH="${O2_HPC_HOME_DIR}"
        fi
        LOG_DIR="$O2_HPC_HOME_DIR/logs"
        SANDBOX="$SCRATCH/$O2_SANDBOX_NAME"
        DEF_FILE="$O2_HPC_HOME_DIR/$O2_DEF_FILE_NAME"
        SW_DIR="$SCRATCH/sw"
        TMP_BASE="$SCRATCH/tmp"
        FAKEHOME="$SCRATCH/fakehome"
        DATA_BASE="$SCRATCH/data"
        O2PHYSICS_SRC="$SCRATCH/sw/O2Physics"
        O2PHYSICS_MASTER_SRC="$SCRATCH/sw/O2Physics/.worktrees/master"
        RESCUE_DIR="$SCRATCH/rescue"
    fi

    mkdir -p "$LOG_DIR" "$FAKEHOME" "$SW_DIR" "$TMP_BASE" \
              "$DATA_BASE" "$RESCUE_DIR"
    mkdir -p "$FAKEHOME/.config/alibuild"
    touch "$FAKEHOME/.config/alibuild/disable-analytics"

    # Sync ALICE grid certificate into fakehome
    if [ -d "$HOME/.globus" ] && [ "$HOME/.globus" != "$FAKEHOME/.globus" ]; then
        mkdir -p "$FAKEHOME/.globus"
        cp -u "$HOME/.globus/usercert.pem" "$FAKEHOME/.globus/" 2>/dev/null || true
        cp -u "$HOME/.globus/userkey.pem"  "$FAKEHOME/.globus/" 2>/dev/null || true
        chmod 400 "$FAKEHOME/.globus/userkey.pem" 2>/dev/null || true
    fi
}

# ==============================================================================
# _resolve_workflow_paths
# Sets workflow-specific paths.
# Args: $1=workflow_name  $2=production
#
# Sets: WORKFLOW_DIR, WORKFLOW_OUTPUT, BOOKKEEPING_DIR,
#       BOOKKEEPING_FILE, BOOKKEEPING_FRAGS
# ==============================================================================
_resolve_workflow_paths() {
    local WF_NAME="$1"
    local PROD="$2"

    if [ "$ENV_TYPE" = "local" ]; then
        WORKFLOW_DIR="$O2_LOCAL_DIR/analysis/$WF_NAME"
        local SCRATCH_ANALYSIS="$O2_LOCAL_DIR/analysis"
    else
        WORKFLOW_DIR="$O2_HPC_HOME_DIR/analysis/$WF_NAME"
        local SCRATCH_ANALYSIS="$SCRATCH/analysis"
    fi

    WORKFLOW_OUTPUT="$SCRATCH_ANALYSIS/$WF_NAME/output/$PROD"
    BOOKKEEPING_DIR="$WORKFLOW_DIR/bookkeeping"
    BOOKKEEPING_FILE="$BOOKKEEPING_DIR/${PROD}.json"
    BOOKKEEPING_FRAGS="$BOOKKEEPING_DIR/${PROD}.d"

    mkdir -p "$WORKFLOW_OUTPUT" "$BOOKKEEPING_DIR" "$BOOKKEEPING_FRAGS"

    # On HPC: symlink ~/alice/analysis/<wf>/output → scratch
    if [ "$ENV_TYPE" != "local" ]; then
        local LINK="$WORKFLOW_DIR/output"
        if [ ! -L "$LINK" ]; then
            mkdir -p "$WORKFLOW_DIR"
            ln -s "$SCRATCH_ANALYSIS/$WF_NAME/output" "$LINK"
            log_info "Created symlink: $LINK → $SCRATCH_ANALYSIS/$WF_NAME/output"
        fi
    fi
}

# ==============================================================================
# load_apptainer
# ==============================================================================
load_apptainer() {
    command -v apptainer &>/dev/null && return 0
    if command -v module &>/dev/null; then
        module load apptainer   2>/dev/null || \
        module load singularity 2>/dev/null || true
    fi
    command -v apptainer &>/dev/null || {
        log_error "apptainer not found — install with: sudo apt install apptainer"
        exit 1
    }
}

# ==============================================================================
# detect_resources
# Sets: CPU_CORES, JOBS, TMP_DIR, TMP_INFO
# ==============================================================================
detect_resources() {
    CPU_CORES=$(nproc)
    local TOTAL_MEM_GB TOTAL_SWAP_GB EFFECTIVE_MEM_GB MAX_JOBS_MEM
    TOTAL_MEM_GB=$(awk  '/MemTotal/  {printf "%d", $2/1024/1024}' /proc/meminfo)
    TOTAL_SWAP_GB=$(awk '/SwapTotal/ {printf "%d", $2/1024/1024}' /proc/meminfo)
    EFFECTIVE_MEM_GB=$(( TOTAL_MEM_GB + TOTAL_SWAP_GB / 2 ))
    MAX_JOBS_MEM=$(( EFFECTIVE_MEM_GB / ${O2_MEM_PER_JOB:-4} ))
    JOBS=$(( MAX_JOBS_MEM < CPU_CORES ? MAX_JOBS_MEM : CPU_CORES ))
    JOBS=$(( JOBS > 1 ? JOBS : 1 ))

    local SHM_SIZE_GB
    SHM_SIZE_GB=$(df -BG /dev/shm 2>/dev/null \
        | awk 'NR==2 {gsub("G","",$2); print $2}' || echo 0)
    if [ "${SHM_SIZE_GB:-0}" -gt "${O2_SHM_MIN_GB:-16}" ]; then
        TMP_DIR=/dev/shm/o2tmp
        TMP_INFO="tmpfs (/dev/shm, ${SHM_SIZE_GB}G)"
    else
        TMP_DIR="$TMP_BASE"
        TMP_INFO="disk ($TMP_DIR)"
    fi
    mkdir -p "$TMP_DIR"
}

# ==============================================================================
# _o2_container
# Run a command inside the O2Physics Apptainer container.
#
# Usage:
#   _o2_container [-B host:container ...] -- command [args...]
#
# Standard mounts always included: SW_DIR→/alice/sw, TMP_DIR→/tmp,
#                                  FAKEHOME→/root
# Extra mounts go before "--", command after "--".
# ==============================================================================
_o2_container() {
    local BINDS=()
    local CMD=()
    local FOUND_SEP=0

    for arg in "$@"; do
        if [ "$arg" = "--" ]; then
            FOUND_SEP=1; continue
        fi
        if [ "$FOUND_SEP" -eq 0 ]; then
            BINDS+=("$arg")
        else
            CMD+=("$arg")
        fi
    done

    [ "${#CMD[@]}" -eq 0 ] && {
        log_error "_o2_container: no command after '--'"
        return 1
    }

    $SUDO apptainer exec --cleanenv \
        --env O2_DEBUG="$O2_DEBUG" \
        -B "$SW_DIR:/alice/sw" \
        -B "$TMP_DIR:/tmp" \
        -B "$FAKEHOME:/root" \
        "${BINDS[@]}" \
        "$SANDBOX" \
        bash -c '
            export ALIBUILD_WORK_DIR=/alice/sw
            export HOME=/root
            export TMPDIR=/tmp
            export LANG=en_US.UTF-8
            export LC_ALL=en_US.UTF-8
            [ -n "$O2_DEBUG" ] && set -x
            eval "$(alienv shell-helper)"
            alienv setenv O2Physics/latest -c "$@"
        ' -- "${CMD[@]}"
}

# ==============================================================================
# _o2_container_raw
# Run a command inside the container WITHOUT loading O2Physics.
# Use for commands that run before O2Physics is built (aliBuild, ninja).
# Same signature as _o2_container: [-B ...] -- command [args...]
# ==============================================================================
_o2_container_raw() {
    local BINDS=()
    local CMD=()
    local FOUND_SEP=0

    for arg in "$@"; do
        if [ "$arg" = "--" ]; then
            FOUND_SEP=1; continue
        fi
        if [ "$FOUND_SEP" -eq 0 ]; then
            BINDS+=("$arg")
        else
            CMD+=("$arg")
        fi
    done

    [ "${#CMD[@]}" -eq 0 ] && {
        log_error "_o2_container_raw: no command after '--'"
        return 1
    }

    $SUDO apptainer exec --cleanenv \
        --env O2_DEBUG="$O2_DEBUG" \
        -B "$SW_DIR:/alice/sw" \
        -B "$TMP_DIR:/tmp" \
        -B "$FAKEHOME:/root" \
        "${BINDS[@]}" \
        "$SANDBOX" \
        bash -c '
            export ALIBUILD_WORK_DIR=/alice/sw
            export HOME=/root
            export TMPDIR=/tmp
            export LANG=en_US.UTF-8
            export LC_ALL=en_US.UTF-8
            [ -n "$O2_DEBUG" ] && set -x
            eval "$(alienv shell-helper)"
            "$@"
        ' -- "${CMD[@]}"
}

# ==============================================================================
# _resolve_worktree
# Resolve a friendly name to the corresponding O2Physics worktree path on
# disk. This is the single place every command that needs to act on a
# specific worktree (build/run/tools) goes through, so 'dev', 'master'
# and a PR name always mean the same directory everywhere in the codebase.
#
# Naming convention:
#   ""|dev   -> $O2PHYSICS_SRC          (the main clone — always exists
#                                         once 'o2 build' has run once)
#   master   -> $O2PHYSICS_MASTER_SRC   (read-only mirror of upstream/master)
#   <name>   -> $O2PHYSICS_SRC/.worktrees/pr-<name>
#
# For anything other than dev, the path is also checked against the real
# 'git worktree list' of the dev clone — this catches a name that was
# never created, or one whose worktree was already removed (e.g. after
# --pr-cleanup), instead of silently resolving to a stale/missing path.
#
# Args: $1 = name (optional, defaults to "dev")
# Echoes the resolved path on success. Returns 1 and echoes nothing on
# failure — callers are expected to log_error with their own context
# (this function doesn't know whether "not found" is fatal for the caller).
# ==============================================================================
_resolve_worktree() {
    local NAME="${1:-dev}"
    local WT_PATH=""

    case "$NAME" in
        ""|dev) WT_PATH="$O2PHYSICS_SRC" ;;
        master) WT_PATH="$O2PHYSICS_MASTER_SRC" ;;
        *)      WT_PATH="$O2PHYSICS_SRC/.worktrees/pr-$NAME" ;;
    esac

    # A linked worktree's ".git" is a FILE (pointer to the main repo's
    # worktrees metadata), not a directory — only the main clone (dev) has
    # a real .git directory. -e covers both.
    [ -e "$WT_PATH/.git" ] || return 1

    if [ "$NAME" != "" ] && [ "$NAME" != "dev" ]; then
        git -C "$O2PHYSICS_SRC" worktree list 2>/dev/null \
            | awk '{print $1}' | grep -qxF "$WT_PATH" || return 1
    fi

    echo "$WT_PATH"
}

# ==============================================================================
# _ensure_git_excludes
# Make sure dev's own .git/info/exclude ignores the nested directories
# we create inside $O2PHYSICS_SRC for other worktrees and build staging
# (.worktrees/, .multibuild/) — otherwise 'git add -A'/'git status' in
# dev would see another worktree's files as plain untracked content.
# Local-only (not committed), safe to call repeatedly.
# ==============================================================================
_ensure_git_excludes() {
    local EXCLUDE_FILE="$O2PHYSICS_SRC/.git/info/exclude"
    [ -d "$O2PHYSICS_SRC/.git" ] || return 0
    mkdir -p "$(dirname "$EXCLUDE_FILE")"
    touch "$EXCLUDE_FILE"
    local LINE
    for LINE in ".worktrees/" ".multibuild/"; do
        grep -qxF "$LINE" "$EXCLUDE_FILE" 2>/dev/null || echo "$LINE" >> "$EXCLUDE_FILE"
    done
}

# ==============================================================================
# Logging helpers
# ==============================================================================
log_info()  { echo "[INFO]    $*"; }
log_warn()  { echo "[WARNING] $*"; }
log_error() { echo "[ERROR]   $*" >&2; }
log_step()  { echo ""; echo "──── $* ────"; echo ""; }
log_sep()   { echo "========================================"; }
