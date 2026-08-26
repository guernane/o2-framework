#!/bin/bash
# lib/tools.sh - Encapsulates ALL ALICE O2 tools with explicit subcommands
#
# This module provides a unified interface for ALICE O2 tooling:
#   - o2 tools diag      : Run setup diagnostic
#   - o2 tools lint      : Run O2 linter
#   - o2 tools format    : Code formatting with clang-format
#   - o2 tools check     : Static analysis with clang-tidy
#   - o2 tools cppcheck  : Cppcheck static analysis
#   - o2 tools deps      : Dependency analysis
#   - o2 tools all       : Run all tools in sequence
#   - o2 tools hooks     : Git pre-commit hooks management
#   - o2 tools shell     : ALICE shell utilities
#   - o2 tools validate  : Run 3 validation framework
#
# All tools run inside the Apptainer container to ensure proper environment.

cmd_tools() {
    local SUBCOMMAND="${1:-help}"
    shift || true
    case "$SUBCOMMAND" in
        all)        cmd_tools_all "$@" ;;
        lint)       cmd_tools_lint "$@" ;;
        format)     cmd_tools_format "$@" ;;
        deps)       cmd_tools_deps "$@" ;;
        check)      cmd_tools_clang_tidy "$@" ;;
        cppcheck)    cmd_tools_cppcheck "$@" ;;
        diag)       cmd_tools_diag "$@" ;;
        hooks)      cmd_tools_hooks "$@" ;;
        shell)      cmd_tools_shell "$@" ;;
        validate)   cmd_tools_validate "$@" ;;
        help|-h|--help) _tools_help ;;
        *) log_error "[ERROR] Unknown tool: $SUBCOMMAND"; _tools_help; return 1 ;;
    esac
}

cmd_tools_diag() {
    # Script URL from official ALICE O2 documentation
    local SCRIPT_URL="https://aliceo2group.github.io/analysis-framework/docs/tools/summarise_o2p_setup.sh"
    # Cache location for the downloaded script
    local SCRIPT="/tmp/summarise_o2p_setup.sh"

    # Download script only if not already present
    if [ ! -f "$SCRIPT" ]; then
        log_info "[LOG] Downloading diagnostic script..."
        if ! wget -q -O "$SCRIPT" "$SCRIPT_URL"; then
            log_error "[ERROR] Failed to download script"
            return 1
        fi
        chmod +x "$SCRIPT"
    fi

    # Ensure Apptainer is available and execute in container
    load_apptainer
    _o2_container -- bash "$SCRIPT"
}

# ==============================================================================
# Help functions for 'o2 help tools'
# ==============================================================================
_tools_help() {
    cat << 'EOF'
o2 tools <subcommand> [options] - ALICE O2 toolkit

Subcommands:
  all         Run ALL tools in sequence (with --quick/--force/--log-file/--quiet)
  lint        Run O2 linter (O2-specific + C++ issues)
  format      Format code with clang-format (--check/--all/--pwg)
  deps        Explore workflow/table dependencies
  check       Run O2Physics-code-check (clang-tidy)
  cppcheck    Run cppcheck (static analysis)
  diag        Run setup diagnostic tool
  hooks       Manage Git pre-commit hooks (install/uninstall)
  shell       Manage ALICE shell utilities (show/source)
  validate    Run 3 validation framework

Use 'o2 tools <subcommand> --help' for details.
EOF
}

