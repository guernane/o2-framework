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

cmd_tools_lint() {
    local SCOPE_ALL=0 PWG="" TARGET=""
    local -a FILES_ARG=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --all)        SCOPE_ALL=1 ;;
            --pwg)        shift; PWG="$1" ;;
            --pr|--use)   shift; TARGET="$1" ;;
            --help|-h)    _tools_lint_help; return 0 ;;
            -*)           log_warn "Unknown option: $1" ;;
            *)            FILES_ARG+=("$1") ;;
        esac
        shift
    done

    local WT
    WT=$(_tools_target "$TARGET") || return 1

    local -a FILE_LIST=()
    mapfile -t FILE_LIST < <(_tools_resolve_files "$WT" "$SCOPE_ALL" "$PWG" "${FILES_ARG[@]}")

    if [ "${#FILE_LIST[@]}" -eq 0 ]; then
        log_info "No changed .cxx/.h files vs upstream/master in '${TARGET:-dev}' — nothing to lint"
        log_info "(use --all, --pwg <NAME>, or pass file paths explicitly)"
        return 0
    fi

    local CONTAINER_WT="/alice/sw/${WT#$SW_DIR/}"
    log_step "O2 linter [${TARGET:-dev}] — ${#FILE_LIST[@]} file(s)"
    printf '    %s\n' "${FILE_LIST[@]}"

    load_apptainer
    _o2_container -- bash -c "cd '$CONTAINER_WT' && python3 Scripts/o2_linter.py \"\$@\"" bash "${FILE_LIST[@]}"
    local RC=$?

    if [ "$RC" -eq 0 ]; then
        log_info "O2 linter: no errors"
    else
        log_error "O2 linter found issues (exit $RC) — see above"
        log_info "This is the same check O2Physics CI runs on your PR — fix locally before pushing."
    fi
    return "$RC"
}

cmd_tools_format() {
    local SCOPE_ALL=0 PWG="" CHECK_ONLY=0 TARGET=""
    local -a FILES_ARG=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --check)      CHECK_ONLY=1 ;;
            --all)        SCOPE_ALL=1 ;;
            --pwg)        shift; PWG="$1" ;;
            --pr|--use)   shift; TARGET="$1" ;;
            --help|-h)    _tools_format_help; return 0 ;;
            -*)           log_warn "Unknown option: $1" ;;
            *)            FILES_ARG+=("$1") ;;
        esac
        shift
    done

    local WT
    WT=$(_tools_target "$TARGET") || return 1

    local -a FILE_LIST=()
    mapfile -t FILE_LIST < <(_tools_resolve_files "$WT" "$SCOPE_ALL" "$PWG" "${FILES_ARG[@]}")

    if [ "${#FILE_LIST[@]}" -eq 0 ]; then
        log_info "No changed .cxx/.h files vs upstream/master in '${TARGET:-dev}' — nothing to format"
        log_info "(use --all, --pwg <NAME>, or pass file paths explicitly)"
        return 0
    fi

    local CONTAINER_WT="/alice/sw/${WT#$SW_DIR/}"
    local MODE_LABEL="in-place"
    [ "$CHECK_ONLY" -eq 1 ] && MODE_LABEL="check-only"
    log_step "clang-format ($MODE_LABEL) [${TARGET:-dev}] — ${#FILE_LIST[@]} file(s)"
    printf '    %s\n' "${FILE_LIST[@]}"

    load_apptainer
    if [ "$CHECK_ONLY" -eq 1 ]; then
        _o2_container -- bash -c "cd '$CONTAINER_WT' && clang-format --dry-run --Werror \"\$@\"" bash "${FILE_LIST[@]}"
    else
        _o2_container -- bash -c "cd '$CONTAINER_WT' && clang-format -i \"\$@\"" bash "${FILE_LIST[@]}"
    fi
    local RC=$?

    if [ "$CHECK_ONLY" -eq 1 ]; then
        if [ "$RC" -eq 0 ]; then
            log_info "clang-format: all files already formatted"
        else
            log_error "clang-format: formatting issues found (exit $RC)"
            log_info "Re-run 'o2 tools format' (without --check) to fix in place"
        fi
    else
        if [ "$RC" -eq 0 ]; then
            log_info "Files formatted in place — review with: o2 build --git-status"
        else
            log_error "clang-format failed (exit $RC)"
        fi
    fi
    return "$RC"
}

cmd_tools_hooks() {
    local ACTION="${1:-status}"
    shift || true

    case "$ACTION" in
        --help|-h) _tools_hooks_help; return 0 ;;
    esac

    [ -d "$O2PHYSICS_SRC/.git" ] || {
        log_error "O2Physics not found at $O2PHYSICS_SRC — run 'o2 build' first"
        return 1
    }

    case "$ACTION" in
        install)
            if ! command -v pre-commit &>/dev/null; then
                log_info "pre-commit not found — installing (pip3 install --user pre-commit)..."
                pip3 install --user pre-commit || {
                    log_error "Failed to install pre-commit — install manually: pip install pre-commit"
                    return 1
                }
            fi
            if ( cd "$O2PHYSICS_SRC" && pre-commit install ); then
                log_info "Pre-commit hooks installed in $O2PHYSICS_SRC"
                log_info "clang-format + cpplint will now run automatically on 'git commit'"
            else
                log_error "Failed to install pre-commit hooks"
                return 1
            fi
            ;;
        uninstall)
            if ( cd "$O2PHYSICS_SRC" && pre-commit uninstall ); then
                log_info "Pre-commit hooks removed from $O2PHYSICS_SRC"
            else
                log_error "Failed to remove pre-commit hooks"
                return 1
            fi
            ;;
        status)
            if grep -q "pre-commit.com" "$O2PHYSICS_SRC/.git/hooks/pre-commit" 2>/dev/null; then
                log_info "Pre-commit hooks: installed in $O2PHYSICS_SRC"
            else
                log_info "Pre-commit hooks: not installed"
                log_info "Run 'o2 tools hooks install' to enable clang-format + cpplint on every commit"
            fi
            ;;
        *)
            log_error "Unknown hooks action: $ACTION"
            _tools_hooks_help
            return 1
            ;;
    esac
}

# ==============================================================================
# _tools_target
# Resolve --pr/--use <name> (or "" -> dev) to a worktree path, with a
# tools-specific error message on failure. Every worktree-aware subcommand
# (lint/format/check/cppcheck/deps) goes through this instead of assuming
# $O2PHYSICS_SRC, so they act on whichever worktree the user asked for.
# ==============================================================================
_tools_target() {
    local NAME="$1"
    local WT
    if ! WT=$(_resolve_worktree "$NAME"); then
        log_error "Unknown worktree: '${NAME:-dev}'"
        log_error "Run 'o2 build --list' to see available worktrees (dev, master, or a PR name)"
        return 1
    fi
    echo "$WT"
}

# ==============================================================================
# _tools_resolve_files
# Resolve which .cxx/.h files 'lint', 'format' and 'cppcheck' (file mode)
# should act on, within a given worktree. Shared so all three scope
# identically.
#
# Priority:
#   1. Explicit file paths passed on the command line
#   2. --pwg <NAME>  -> every tracked .cxx/.h file under <NAME>/
#   3. --all         -> every tracked .cxx/.h file in the worktree
#   4. (default)     -> only files you actually changed: the diff between
#                       upstream/master and the worktree's checked-out
#                       branch, plus any uncommitted local edits. This
#                       mirrors what O2Physics-code-check does for a PR
#                       (base-commit..head-commit) and keeps --all-file
#                       runs (slow, container-bound) the exception rather
#                       than the default.
#
# Args: $1=worktree_path  $2=scope_all(0|1)  $3=pwg_name(or "")  $4..=explicit file args
# Echoes one path per line, relative to the worktree root. Paths that no
# longer exist (e.g. deleted in the diff) are dropped — clang-format/
# o2_linter would just error on them.
# ==============================================================================
_tools_resolve_files() {
    local WT="$1";        shift
    local SCOPE_ALL="$1"; shift
    local PWG="$1";       shift
    local -a EXPLICIT=("$@")

    cd "$WT" || return 1

    local FILES=""
    if [ "${#EXPLICIT[@]}" -gt 0 ]; then
        FILES=$(printf '%s\n' "${EXPLICIT[@]}")
    elif [ -n "$PWG" ]; then
        FILES=$(git ls-files -- "$PWG" | grep -E '\.(cxx|h)$')
    elif [ "$SCOPE_ALL" -eq 1 ]; then
        FILES=$(git ls-files -- '*.cxx' '*.h')
    else
        git fetch upstream --quiet 2>/dev/null || true
        local BASE
        BASE=$(git merge-base upstream/master HEAD 2>/dev/null || echo upstream/master)
        FILES=$({
            git diff --name-only --diff-filter=ACMR "$BASE"...HEAD -- '*.cxx' '*.h' 2>/dev/null
            git diff --name-only --diff-filter=ACMR HEAD             -- '*.cxx' '*.h' 2>/dev/null
        } | sort -u)
    fi

    cd - > /dev/null

    while IFS= read -r f; do
        [ -n "$f" ] && [ -f "$WT/$f" ] && echo "$f"
    done <<< "$FILES"
}

_tools_lint_help() {
    cat << 'EOF'
o2 tools lint [options] [file...]

Run the O2 linter (Scripts/o2_linter.py) — the same check O2Physics CI
runs on every PR ("O2 linter" status check).

Options:
  (none)          lint files changed vs upstream/master on your dev branch
  --all           lint every tracked .cxx/.h file in O2Physics (slow)
  --pwg <NAME>    lint every tracked .cxx/.h file under <NAME>/ (e.g. PWGJE)
  --pr <NAME>     lint a specific worktree instead of dev (also: master)
  file...         lint specific files (paths relative to O2Physics/)

Examples:
  o2 tools lint
  o2 tools lint --pwg PWGJE
  o2 tools lint --pr proxies
  o2 tools lint PWGJE/Tasks/taskProxyBuilder.cxx
EOF
}

_tools_format_help() {
    cat << 'EOF'
o2 tools format [options] [file...]

Format code with clang-format, using O2Physics' own .clang-format style.

Options:
  (none)          format in place: files changed vs upstream/master
  --check         dry-run — report files that need formatting, change nothing
  --all           format every tracked .cxx/.h file in O2Physics (slow)
  --pwg <NAME>    format every tracked .cxx/.h file under <NAME>/
  --pr <NAME>     format a specific worktree instead of dev (also: master)
  file...         format specific files (paths relative to O2Physics/)

Examples:
  o2 tools format --check
  o2 tools format
  o2 tools format --pwg PWGJE
  o2 tools format --pr proxies --check
EOF
}

_tools_hooks_help() {
    cat << 'EOF'
o2 tools hooks <action>

Manage O2Physics' official Git pre-commit hooks (clang-format + cpplint),
so formatting/lint issues are caught at commit time instead of in CI.

Actions:
  install     install pre-commit (if missing) and enable the hooks
  uninstall   remove the hooks from your O2Physics fork
  status      show whether the hooks are currently installed (default)
EOF
}

cmd_tools_deps() {
    local TARGET=""
    local -a REST=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --pr|--use) shift; TARGET="$1" ;;
            --help|-h)  _tools_deps_help; return 0 ;;
            *)          REST+=("$1") ;;
        esac
        shift
    done

    local WT
    WT=$(_tools_target "$TARGET") || return 1

    # Thin pass-through to the installed find_dependencies.py — this is the
    # exact tool referenced by O2Physics' own troubleshooting docs
    # ($O2PHYSICS_ROOT/share/scripts/find_dependencies.py), so we forward
    # all args/flags (-t/-T/-w/-W/-c/-g/-x/-l) verbatim instead of
    # reimplementing its CLI. NOTE: find_dependencies.py reads the *built*
    # O2Physics install, which alienv resolves independently of which
    # worktree we cd into — --pr/--use here only decides which worktree's
    # sources 'o2 tools deps --project'-style commands would see; the
    # dependency graph itself always reflects whatever is currently built
    # for that worktree (run 'o2 build --use <name>' first if stale).
    load_apptainer
    _o2_container -- bash -c '
        cd "$1"; shift
        SCRIPT="$O2PHYSICS_ROOT/share/scripts/find_dependencies.py"
        if [ ! -f "$SCRIPT" ]; then
            echo "[ERROR]   find_dependencies.py not found at $SCRIPT — is O2Physics built?" >&2
            exit 1
        fi
        "$SCRIPT" "$@"
    ' bash "/alice/sw/${WT#$SW_DIR/}" "${REST[@]}"
}

cmd_tools_clang_tidy() {
    local BASE="master"
    local HEAD="HEAD"
    local FIX=0
    local TARGET=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --base)     shift; BASE="$1" ;;
            --head)     shift; HEAD="$1" ;;
            --fix)      FIX=1 ;;
            --pr|--use) shift; TARGET="$1" ;;
            --help|-h)  _tools_check_help; return 0 ;;
            -*)         log_warn "Unknown option: $1" ;;
        esac
        shift
    done

    local WT
    WT=$(_tools_target "$TARGET") || return 1

    # aliBuild's O2Physics-code-check relies on its own dev-package
    # auto-detection (a directory literally named "O2Physics" under the
    # work-dir), which today only resolves to the dev worktree. Pointing
    # it at another worktree needs the build-multiplexing work from
    # 'o2 build --use' — not done yet, so refuse rather than silently
    # checking the wrong source.
    if [ -n "$TARGET" ] && [ "$TARGET" != "dev" ]; then
        log_error "'o2 tools check --pr $TARGET' isn't supported yet"
        log_error "(needs 'o2 build --use' to build non-dev worktrees — not implemented yet)"
        return 1
    fi

    log_step "O2Physics-code-check (clang-tidy) — base=$BASE head=$HEAD"
    load_apptainer
    detect_resources
    _setup_git_safe

    local FIX_ENV=""
    [ "$FIX" -eq 1 ] && FIX_ENV="-e O2PHYSICS_CHECKER_FIX=1"

    local ALIBUILD_DEFAULTS="$O2_ALIBUILD_DEFAULTS"
    local CHECK_LOG="$LOG_DIR/code_check.log"

    _o2_container_raw -- bash -c "
        set -e
        export ALIBUILD_WORK_DIR=/alice/sw
        export ALIBUILD_ANALYTICS=0
        eval \"\$(alienv shell-helper)\"
        cd /alice/sw
        aliBuild build O2Physics-code-check --work-dir /alice/sw \
            --defaults '$ALIBUILD_DEFAULTS' \
            -e ALIBUILD_BASE_HASH=$BASE -e ALIBUILD_HEAD_HASH=$HEAD $FIX_ENV
    " 2>&1 | tee "$CHECK_LOG"

    local RC=${PIPESTATUS[0]}
    if [ "$RC" -eq 0 ]; then
        log_info "clang-tidy (O2Physics-code-check): no issues — log: $CHECK_LOG"
    else
        log_error "clang-tidy found issues (exit $RC) — see $CHECK_LOG"
        log_info "Re-run with --fix to let clang-tidy apply automatic fixes"
    fi
    return "$RC"
}

cmd_tools_cppcheck() {
    local SCOPE_ALL=0 PWG="" PROJECT_MODE=0 TARGET=""
    local -a FILES_ARG=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --all)      SCOPE_ALL=1 ;;
            --pwg)      shift; PWG="$1" ;;
            --project)  PROJECT_MODE=1 ;;
            --pr|--use) shift; TARGET="$1" ;;
            --help|-h)  _tools_cppcheck_help; return 0 ;;
            -*)         log_warn "Unknown option: $1" ;;
            *)          FILES_ARG+=("$1") ;;
        esac
        shift
    done

    local WT
    WT=$(_tools_target "$TARGET") || return 1
    local CONTAINER_WT="/alice/sw/${WT#$SW_DIR/}"

    load_apptainer
    local LOGFILE="$LOG_DIR/cppcheck.err.log"
    local SUPPR=""
    [ -f "$WT/cppcheck_suppressions" ] && SUPPR="--suppressions-list=cppcheck_suppressions"

    if [ "$PROJECT_MODE" -eq 1 ]; then
        [ -e "$WT/compile_commands.json" ] || {
            log_error "compile_commands.json not found in $WT"
            log_error "Symlink it to the alice/sw/BUILD/.../O2Physics/compile_commands.json" \
                       "produced by your build, then re-run with --project"
            return 1
        }
        log_step "cppcheck (project mode) [${TARGET:-dev}]"
        _o2_container -- bash -c "
            cd '$CONTAINER_WT' &&
            cppcheck --language=c++ --std=c++20 --enable=style --check-level=exhaustive \
                $SUPPR --inline-suppr --force --project=compile_commands.json -j \$(nproc) \
                2> '$LOGFILE'
        "
    else
        local -a FILE_LIST=()
        mapfile -t FILE_LIST < <(_tools_resolve_files "$WT" "$SCOPE_ALL" "$PWG" "${FILES_ARG[@]}")

        if [ "${#FILE_LIST[@]}" -eq 0 ]; then
            log_info "No changed .cxx/.h files vs upstream/master in '${TARGET:-dev}' — nothing to check"
            log_info "(use --all, --pwg <NAME>, --project, or pass file paths explicitly)"
            return 0
        fi

        log_step "cppcheck (file mode) [${TARGET:-dev}] — ${#FILE_LIST[@]} file(s)"
        printf '    %s\n' "${FILE_LIST[@]}"
        _o2_container -- bash -c "
            cd '$CONTAINER_WT' &&
            cppcheck --language=c++ --std=c++20 --enable=style --check-level=exhaustive \
                $SUPPR --inline-suppr --force \"\$@\" 2> '$LOGFILE'
        " bash "${FILE_LIST[@]}"
    fi

    if [ -s "$LOGFILE" ]; then
        log_warn "cppcheck reported issues — see $LOGFILE"
    else
        log_info "cppcheck: no issues"
    fi
}

cmd_tools_shell() {
    local ACTION="${1:-show}"
    shift || true

    case "$ACTION" in
        --help|-h) _tools_shell_help; return 0 ;;
    esac

    local SCRIPT_URL="https://aliceo2group.github.io/analysis-framework/docs/tools/bashrc-alice.sh"
    local SCRIPT="$SCRIPTS_DIR/bashrc-alice.sh"

    if [ ! -f "$SCRIPT" ]; then
        log_info "Downloading bashrc-alice.sh..."
        wget -q -O "$SCRIPT" "$SCRIPT_URL" || {
            log_error "Failed to download bashrc-alice.sh"
            return 1
        }
    fi

    case "$ACTION" in
        show)
            cat "$SCRIPT"
            ;;
        install|source)
            local LINE="source \"$SCRIPT\""
            if grep -qF "$LINE" "$HOME/.bashrc" 2>/dev/null; then
                log_info "Already sourced in ~/.bashrc"
            else
                echo "$LINE" >> "$HOME/.bashrc"
                log_info "Added to ~/.bashrc: $LINE"
                log_info "Run 'source ~/.bashrc' (or open a new shell) to activate"
            fi
            ;;
        *)
            log_error "Unknown shell action: $ACTION"
            _tools_shell_help
            return 1
            ;;
    esac
}

cmd_tools_validate() {
    local ACTION="${1:-status}"
    shift || true

    case "$ACTION" in
        --help|-h) _tools_validate_help; return 0 ;;
    esac

    local REPO_DIR="$O2_LOCAL_DIR/Run3AnalysisValidation"

    case "$ACTION" in
        setup|install)
            if [ -d "$REPO_DIR/.git" ]; then
                log_info "Already cloned: $REPO_DIR — pulling latest..."
                git -C "$REPO_DIR" pull --quiet
            else
                log_info "Cloning AliceO2Group/Run3AnalysisValidation..."
                git clone --quiet https://github.com/AliceO2Group/Run3AnalysisValidation.git "$REPO_DIR"
            fi
            log_info "Validation framework ready: $REPO_DIR"
            log_info "It is a separate, self-contained tool (own exec/*.sh, own workflows.yml)."
            log_info "Configure it and run its own scripts inside the O2Physics environment:"
            log_info "  o2 tools shell install   # once, to get alienv-friendly helpers"
            log_info "  cd $REPO_DIR && follow its README for ENV_O2 / DOO2 configuration"
            log_info "README: https://github.com/AliceO2Group/Run3AnalysisValidation#readme"
            ;;
        status)
            if [ -d "$REPO_DIR/.git" ]; then
                log_info "Run3AnalysisValidation: cloned at $REPO_DIR"
                git -C "$REPO_DIR" log -1 --oneline | sed 's/^/    /'
            else
                log_info "Run3AnalysisValidation: not set up — run 'o2 tools validate setup'"
            fi
            ;;
        *)
            log_error "Unknown validate action: $ACTION"
            _tools_validate_help
            return 1
            ;;
    esac
}

cmd_tools_all() {
    local QUICK=0 FORCE=0 QUIET=0 TARGET=""
    local LOGFILE=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --quick)    QUICK=1 ;;
            --force)    FORCE=1 ;;
            --log-file) shift; LOGFILE="$1" ;;
            --quiet)    QUIET=1 ;;
            --pr|--use) shift; TARGET="$1" ;;
            --help|-h)  _tools_all_help; return 0 ;;
            -*)         log_warn "Unknown option: $1" ;;
        esac
        shift
    done

    if [ -n "$LOGFILE" ]; then
        exec > >(tee -a "$LOGFILE") 2>&1
        log_info "Logging to $LOGFILE"
    fi

    # NOTE: each step runs on its own default scope (files changed vs
    # upstream/master) — same as calling the subcommand alone. There is no
    # pass-through for --all/--pwg here; run the individual subcommand
    # directly if you need a wider scope. 'check' (clang-tidy) only
    # supports the dev worktree today (see cmd_tools_clang_tidy) — it's
    # skipped automatically when --pr/--use targets anything else.
    local -a STEPS=(lint format)
    if [ "$QUICK" -eq 0 ]; then
        STEPS+=(cppcheck)
        [ -z "$TARGET" ] || [ "$TARGET" = "dev" ] && STEPS+=(check)
    fi

    local -a FORMAT_ARGS=()
    [ "$FORCE" -eq 0 ] && FORMAT_ARGS=(--check)
    local -a TARGET_ARGS=()
    [ -n "$TARGET" ] && TARGET_ARGS=(--pr "$TARGET")

    local FAILED=0
    for STEP in "${STEPS[@]}"; do
        [ "$QUIET" -eq 0 ] && log_step "o2 tools $STEP"
        case "$STEP" in
            lint)     cmd_tools_lint "${TARGET_ARGS[@]}"                       || FAILED=1 ;;
            format)   cmd_tools_format "${FORMAT_ARGS[@]}" "${TARGET_ARGS[@]}" || FAILED=1 ;;
            cppcheck) cmd_tools_cppcheck "${TARGET_ARGS[@]}"                    || FAILED=1 ;;
            check)    cmd_tools_clang_tidy                                     || FAILED=1 ;;
        esac
    done

    log_sep
    if [ "$FAILED" -eq 0 ]; then
        log_info "o2 tools all: all checks passed"
    else
        log_error "o2 tools all: one or more checks failed — see above"
    fi
    return "$FAILED"
}

_tools_deps_help() {
    cat << 'EOF'
o2 tools deps [options]

Pass-through wrapper around O2Physics' own dependency finder
($O2PHYSICS_ROOT/share/scripts/find_dependencies.py). All flags are
forwarded as-is — run 'o2 tools deps -h' for the script's own help.

Common flags (from find_dependencies.py):
  -t TABLE     backward search: workflows that PRODUCE this table
  -T TABLE     forward search:  workflows that CONSUME this table
  -w WORKFLOW  backward search: tables this workflow depends on
  -W WORKFLOW  forward search:  tables produced by this workflow
  -c           case-sensitive table names
  -g {pdf,svg,png}   render a topology graph (needs Graphviz)
  -x PATTERN   exclude tables/workflows matching this regex
  -l LEVELS    max tree depth (default 0 = direct only, <0 = all)

--pr <NAME>    look at a specific worktree's sources instead of dev
               (also: master) — note the dependency graph itself always
               reflects whatever is currently BUILT for that worktree.

Examples:
  o2 tools deps -t TRACKSELECTION
  o2 tools deps -w o2-analysis-je-jet-finder-charged -l 1
EOF
}

_tools_check_help() {
    cat << 'EOF'
o2 tools check [options]

Run O2Physics-code-check (Clang-Tidy), the same check that runs on your
PR under the 'build/O2Physics/code-check' CI status.

Options:
  --base <hash>   base commit to diff from (default: master)
  --head <hash>   head commit to diff to   (default: HEAD)
  --fix           let clang-tidy apply automatic fixes

Only the dev worktree is supported for now — targeting a PR worktree
(--pr <NAME>) needs 'o2 build --use', not implemented yet.

Examples:
  o2 tools check
  o2 tools check --fix
EOF
}

_tools_cppcheck_help() {
    cat << 'EOF'
o2 tools cppcheck [options] [file...]

Run Cppcheck static analysis.

Options:
  (none)          check files changed vs upstream/master (file mode)
  --all           check every tracked .cxx/.h file (file mode, slow)
  --pwg <NAME>    check every tracked .cxx/.h file under <NAME>/
  --pr <NAME>     check a specific worktree instead of dev (also: master)
  --project       project mode: needs compile_commands.json symlinked
                  into that worktree (see 'o2 tools check --help')
  file...         check specific files

Report is written to logs/cppcheck.err.log (see 'o2 status' log dir).
EOF
}

_tools_shell_help() {
    cat << 'EOF'
o2 tools shell <action>

Manage the ALICE bashrc-alice.sh utility script (aliBuild env vars,
ninja rebuild helpers, debugging helpers).

Actions:
  show               print the script content (default)
  install | source   download it and add a 'source' line to ~/.bashrc
EOF
}

_tools_validate_help() {
    cat << 'EOF'
o2 tools validate <action>

Clone/update AliceO2Group/Run3AnalysisValidation next to your analysis/.
This is a separate, self-contained validation framework (own workflows.yml,
own exec scripts) — this command only manages the clone; configuring and
running it is done following its own README.

Actions:
  setup | install   clone (or pull if already cloned)
  status            show whether it is set up
EOF
}

_tools_all_help() {
    cat << 'EOF'
o2 tools all [options]

Run lint, format --check, cppcheck and check (clang-tidy) in sequence,
each on its default scope (files changed vs upstream/master).

Options:
  --quick           skip the slow steps (cppcheck, check)
  --force           apply formatting in place instead of --check
  --log-file <path> tee all output to <path>
  --quiet           suppress per-step banners (tool output still shown)
  --pr <NAME>       run against a specific worktree instead of dev (also:
                    master) — 'check' is skipped automatically for
                    anything other than dev (see 'o2 tools check --help')
EOF
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

