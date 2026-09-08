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
            eval "$(alienv shell-helper)"
            "$@"
        ' -- "${CMD[@]}"
}

# ==============================================================================
# Logging helpers
# ==============================================================================
log_info()  { echo "[INFO]    $*"; }
log_warn()  { echo "[WARNING] $*"; }
log_error() { echo "[ERROR]   $*" >&2; }
log_step()  { echo ""; echo "──── $* ────"; echo ""; }
log_sep()   { echo "========================================"; }
