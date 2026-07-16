#!/bin/bash
# ==============================================================================
# o2.sh
# Single entry point for all O2Physics operations.
# Place in ~/alice/ and add ~/alice/ to PATH via o2rc.
#
# Usage:
#   o2 <command> [args...]
#
# Commands:
#   build      manage O2Physics build (fork, sandbox, aliBuild, ninja)
#   run        launch a DPL workflow on local machine or HPC
#   merge      merge AnalysisResults.root files from completed groups
#   status     monitor analyses and HPC jobs
#   deploy     sync scripts to HPC and launch remote build
#   help       show this message or help for a specific command
#
# Examples:
#   o2 build
#   o2 build --update
#   o2 build --commit "add jet task"
#   o2 build --git-status
#
#   o2 run proxies LHC24aj
#   o2 run proxies LHC24aj --runs 544116,544122 --mode alien
#   o2 run proxies LHC24aj --resume
#
#   o2 merge proxies LHC24aj
#   o2 merge proxies LHC24aj --force
#
#   o2 status proxies LHC24aj
#   o2 status proxies LHC24aj --failed
#   o2 status proxies LHC24aj --jobs
#   o2 status all
#   o2 status sync
#   o2 status proxy
#
#   o2 deploy
#   o2 deploy --sync-only
#   o2 deploy --status
#   o2 deploy --log
#
#   o2 help build
# ==============================================================================

set -e

# ==============================================================================
# Bootstrap: locate scripts directory and config file
# ==============================================================================
SCRIPTS_DIR="$(dirname "$(realpath "$0")")"
export SCRIPTS_DIR

CONFIG_FILE="$SCRIPTS_DIR/o2_config.sh"
if [ ! -f "$CONFIG_FILE" ]; then
    echo "[ERROR] Configuration file not found: $CONFIG_FILE"
    echo "        Place o2_config.sh next to o2.sh in $SCRIPTS_DIR"
    exit 1
fi
source "$CONFIG_FILE"

# ==============================================================================
# Source all lib modules
# Order matters: common first (defines helpers used by all others)
# ==============================================================================
LIB_DIR="$SCRIPTS_DIR/lib"
for mod in common build run merge status deploy; do
    MOD_FILE="$LIB_DIR/${mod}.sh"
    if [ ! -f "$MOD_FILE" ]; then
        echo "[ERROR] Module not found: $MOD_FILE"
        exit 1
    fi
    # shellcheck source=/dev/null
    source "$MOD_FILE"
done

# ==============================================================================
# Shared setup: environment + paths (available to all modules)
# ==============================================================================
detect_environment
resolve_paths

# ==============================================================================
# Command dispatcher
# ==============================================================================

# ==============================================================================
# _o2_help
# ==============================================================================
_o2_help() {
    local TOPIC="${1:-}"

    case "$TOPIC" in
        build)  _build_help;  return ;;
        run)    _run_help;    return ;;
        merge)  _merge_help;  return ;;
        status) _status_help; return ;;
        deploy) _deploy_help; return ;;
        backup) source "$SCRIPTS_DIR/lib/backup.sh"; _backup_help; return ;;
        export) source "$SCRIPTS_DIR/lib/export.sh"; _export_help; return ;;
    esac

    cat << 'EOF'
o2 <command> [args...]

Commands:
  build    Manage O2Physics build (GitHub fork, Apptainer sandbox, aliBuild, ninja)
  run      Launch a DPL analysis workflow on local machine or HPC cluster
  merge    Merge AnalysisResults.root files from all completed job groups
  status   Monitor analyses, HPC jobs, and ALICE Grid token
  deploy   Sync scripts to HPC and launch a remote build
  backup   Commit and push all 3 repos to GitHub (local machine only)
  export   Bundle fresh clones of all 3 repos into a shareable archive (local machine only)

Use 'o2 help <command>' for detailed options.

Quick start:
  1. Configure:   edit ~/alice/o2_config.sh
  2. Build:       o2 build
  3. Activate:    source ~/alice/o2rc
  4. Run:         o2 run proxies LHC24aj
  5. Monitor:     o2 status proxies LHC24aj
  6. Merge:       o2 merge proxies LHC24aj

Workflow development:
  Edit task:    ~/alice/sw/O2Physics/PWGJE/Tasks/taskProxyBuilder.cxx
  Rebuild:      o2 build --rebuild-tasks
  Commit:       o2 build --commit "description of changes"
  Sync fork:    o2 build --update
EOF
}

COMMAND="${1:-help}"
shift || true

case "$COMMAND" in
    build)
        cmd_build "$@"
        ;;
    run)
        detect_resources
        cmd_run "$@"
        ;;
    merge)
        cmd_merge "$@"
        ;;
    status)
        cmd_status "$@"
        ;;
    deploy)
        # deploy must run on local machine only
        if [ "$ENV_TYPE" != "local" ]; then
            log_error "o2 deploy must be run from your local machine"
            exit 1
        fi
        cmd_deploy "$@"
        ;;
    sync)
        # sync check must run on local machine only
        if [ "$ENV_TYPE" != "local" ]; then
            log_error "o2 sync must be run from your local machine"
            exit 1
        fi
        source "$SCRIPTS_DIR/lib/sync.sh"
        cmd_sync "$@"
        ;;
    analyses)
        # analyses management must run on local machine only
        if [ "$ENV_TYPE" != "local" ]; then
            log_error "o2 analyses must be run from your local machine"
            exit 1
        fi
        source "$SCRIPTS_DIR/lib/analyses.sh"
        cmd_analyses "$@"
        ;;
    backup)
        # backup must run on local machine only
        if [ "$ENV_TYPE" != "local" ]; then
            log_error "o2 backup must be run from your local machine"
            exit 1
        fi
        source "$SCRIPTS_DIR/lib/backup.sh"
        cmd_backup "$@"
        ;;
    export)
        # export must run on local machine only
        if [ "$ENV_TYPE" != "local" ]; then
            log_error "o2 export must be run from your local machine"
            exit 1
        fi
        source "$SCRIPTS_DIR/lib/export.sh"
        cmd_export "$@"
        ;;
    submit-remote)
        # internal: invoked over SSH by 'o2 run --hpc', never by hand
        source "$SCRIPTS_DIR/lib/run.sh"
        cmd_submit_remote "$@"
        ;;
    help|-h|--help)
        _o2_help "$@"
        ;;
    *)
        log_error "Unknown command: $COMMAND"
        echo ""
        _o2_help
        exit 1
        ;;
esac
