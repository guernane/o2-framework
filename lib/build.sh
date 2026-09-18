#!/bin/bash
# ==============================================================================
# lib/build.sh
# O2Physics build management: GitHub fork, git automation, Apptainer sandbox,
# aliBuild, and ninja incremental rebuilds.
# Sourced by o2.sh — never executed directly.
#
# Entry point: cmd_build "$@"
# ==============================================================================

# ==============================================================================
# cmd_build — parse args and dispatch
# ==============================================================================
cmd_build() {
    local SANDBOX_ONLY=0
    local BUILD_ONLY=0
    local REBUILD_TASKS=0
    local UPDATE_ONLY=0
    local DO_COMMIT=0
    local COMMIT_MSG=""
    local DO_STATUS=0
    local DO_DISCARD=0
    local GIT_RESCUE=0
    local TARGET=""
    local -a PATH_ARGS=()
    local DO_CUT_PR=0
    local CUT_PR_ANALYSIS=""
    local CUT_PR_BRANCH=""
    local DO_PR_CLEANUP=0
    local PR_CLEANUP_ANALYSIS=""
    local DO_USE=0
    local USE_NAME=""
    local DO_LIST=0
    local DO_BUILD_WT=0
    local BUILD_WT_NAME=""
    local -a CMD_ARGS=()
    local SEEN_DASHDASH=0

    while [[ $# -gt 0 ]]; do
        case $1 in
            --sandbox-only)         SANDBOX_ONLY=1 ;;
            --build-only)           BUILD_ONLY=1 ;;
            --rebuild-tasks)        REBUILD_TASKS=1 ;;
            --update)               UPDATE_ONLY=1 ;;
            --commit)                DO_COMMIT=1; shift; COMMIT_MSG="$1" ;;
            --status|--git-status)  DO_STATUS=1 ;;
            --discard)              DO_DISCARD=1 ;;
            --git-rescue)           GIT_RESCUE=1 ;;
            --pr)                   shift; TARGET="$1" ;;
            --cut-pr)               DO_CUT_PR=1; shift; CUT_PR_ANALYSIS="$1" ;;
            --branch)               shift; CUT_PR_BRANCH="$1" ;;
            --pr-cleanup)           DO_PR_CLEANUP=1; shift; PR_CLEANUP_ANALYSIS="$1" ;;
            --use)                  DO_USE=1; shift; USE_NAME="$1" ;;
            --list)                 DO_LIST=1 ;;
            --build-worktree)       DO_BUILD_WT=1; shift; BUILD_WT_NAME="$1" ;;
            --)                     SEEN_DASHDASH=1 ;;
            --help|-h)              _build_help; return 0 ;;
            -*)                     log_warn "Unknown option: $1" ;;
            *)
                if [ "$DO_USE" -eq 1 ] && [ "$SEEN_DASHDASH" -eq 1 ]; then
                    CMD_ARGS+=("$1")
                else
                    PATH_ARGS+=("$1")
                fi
                ;;
        esac
        shift
    done

    # Git-only operations (no apptainer needed)
    if [ "$DO_STATUS"  -eq 1 ]; then _git_status  "$TARGET"; return; fi
    if [ "$GIT_RESCUE" -eq 1 ]; then _git_rescue;  return; fi
    if [ "$DO_DISCARD" -eq 1 ]; then _git_discard "$TARGET" "${PATH_ARGS[@]}"; return; fi
    if [ "$DO_COMMIT"  -eq 1 ]; then
        _build_assert_local "commit"
        _git_commit "$COMMIT_MSG" "$TARGET" "${PATH_ARGS[@]}"
        return
    fi
    if [ "$DO_CUT_PR" -eq 1 ]; then
        _build_assert_local "cut-pr"
        _build_cut_pr "$CUT_PR_ANALYSIS" "$CUT_PR_BRANCH"
        return
    fi
    if [ "$DO_PR_CLEANUP" -eq 1 ]; then
        _build_assert_local "pr-cleanup"
        _build_pr_cleanup "$PR_CLEANUP_ANALYSIS"
        return
    fi
    if [ "$DO_LIST" -eq 1 ]; then _build_list; return; fi
    if [ "$DO_BUILD_WT" -eq 1 ]; then
        _build_assert_local "build-worktree"
        _build_worktree "$BUILD_WT_NAME"
        return
    fi
    if [ "$DO_USE" -eq 1 ]; then
        _build_assert_local "use"
        _build_use "$USE_NAME" "${CMD_ARGS[@]}"
        return
    fi
    if [ "$UPDATE_ONLY"     -eq 1 ]; then
        _build_assert_local "update"
        _git_update
        return
    fi
    if [ "$REBUILD_TASKS"   -eq 1 ]; then _rebuild_tasks; return; fi

    # Full build or partial
    load_apptainer
    detect_resources

    log_sep
    log_info "O2Physics build"
    log_info "Environment : $ENV_TYPE"
    log_info "Sandbox     : $SANDBOX"
    log_info "SW dir      : $SW_DIR"
    log_info "Dev branch  : $O2_DEV_BRANCH"
    log_info "Components  : $O2_PHYSICS_COMPONENTS"
    log_info "Build jobs  : $JOBS  (RAM: ${O2_MEM_PER_JOB}GB/job)"
    log_info "TMPDIR      : $TMP_INFO"
    log_sep

    # HPC login node: submit OAR job
    if [ "$ENV_TYPE" = "hpc_login" ]; then
        _build_submit_oar "$SANDBOX_ONLY" "$BUILD_ONLY"
        return
    fi

    # Local or inside scheduler job: full build
    _build_lock_acquire
    trap '_build_lock_release' EXIT SIGTERM SIGINT

    if [ "$BUILD_ONLY" -eq 0 ]; then
        [ "$ENV_TYPE" = "local" ] && _git_setup_fork
        _generate_def_file
        _build_sandbox
    fi
    if [ "$SANDBOX_ONLY" -eq 0 ]; then
        _build_o2physics
        _build_summary
    fi
}

# ==============================================================================
# _build_lock_acquire / _build_lock_release
# Lockfile written to $SW_DIR/.build.lock while a build is in progress.
# Prevents o2 deploy from wiping SOURCES/O2Physics mid-build.
#
# Lock format (one line per field):
#   pid=<PID>
#   oar_job=<OAR_JOB_ID or local>
#   host=<hostname>
#   started=<ISO timestamp>
#
# The lock is also released automatically via trap EXIT so a killed job
# (OAR walltime, Ctrl-C) does not leave a stale lock forever.
# _deploy_sync_sources reads this file via SSH before touching SOURCES/.
# ==============================================================================
_build_lock_acquire() {
    local LOCK="$SW_DIR/.build.lock"
    if [ -f "$LOCK" ]; then
        log_warn "Build lock exists: $LOCK"
        log_warn "Contents:"
        cat "$LOCK" | sed 's/^/    /' >&2
        log_error "Another build may be running. Remove $LOCK manually if it is stale."
        exit 1
    fi
    mkdir -p "$SW_DIR"
    cat > "$LOCK" << LOCKEOF
pid=$$
oar_job=${OAR_JOB_ID:-local}
host=$(hostname -s)
started=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
LOCKEOF
    log_info "Build lock acquired: $LOCK"
}

_build_lock_release() {
    local LOCK="$SW_DIR/.build.lock"
    if [ -f "$LOCK" ]; then
        rm -f "$LOCK"
        log_info "Build lock released"
    fi
}

_build_help() {
    cat << 'EOF'
o2 build [options]

Options:
  (none)             full build: fork setup + sandbox + O2Physics
  --sandbox-only     build Apptainer sandbox only
  --build-only       rebuild O2Physics only (no sandbox rebuild)
  --rebuild-tasks    sync enabled tasks (CMakeLists + incremental build)
  --update           sync fork with upstream + rebuild tasks
  --status           show git status of a worktree (default: dev)
  --commit "msg" [path...]
                     stage (given paths, or everything changed) + commit
                     + push a worktree. Does NOT run --rebuild-tasks —
                     run that yourself first if you need it.
  --discard [path...]
                     discard uncommitted changes (given paths, or
                     everything, with confirmation) in a worktree
  --pr <name>        target a specific worktree instead of dev for
                     --status/--commit/--discard (also: --use, master)
  --cut-pr <analysis> [--branch <name>]
                     cut a clean PR branch + worktree for a promoted
                     analysis (must be 'ready-for-pr'), straight from
                     upstream/master — never from dev
  --pr-cleanup <analysis>
                     remove a PR's worktree + local branch after merge
  --use <name> [-- command...]
                     enter (or run a command in) a worktree's built
                     environment (dev/master/a PR name). Must have been
                     built first: --rebuild-tasks for dev,
                     --build-worktree <name> for master or a PR
  --build-worktree <name>
                     build master or a PR worktree (shares $SW_DIR's
                     installed dependencies — only O2Physics itself is
                     rebuilt); records its version tag for --use/--list
  --list             show all known worktrees, their branch, and
                     whether their last recorded build is up to date
  --git-rescue       recover from a broken git state (saves your files first)

Examples:
  o2 build --status
  o2 build --status --pr proxies
  o2 build --commit "add jet finder cuts"
  o2 build --commit "fix review comment" --pr proxies
  o2 build --discard PWGJE/Tasks/taskX.cxx
  o2 build --discard --pr proxies
  o2 build --cut-pr proxies
  o2 build --pr-cleanup proxies
  o2 build --build-worktree master
  o2 build --list
  o2 build --use dev
  o2 build --use master -- alienv q O2Physics
EOF
}

_build_assert_local() {
    if [ "$ENV_TYPE" != "local" ]; then
        log_error "o2 build --$1 must be run on your local machine"
        exit 1
    fi
}

# ==============================================================================
# GitHub API helpers
# ==============================================================================
_github_api() {
    local METHOD="$1"
    local ENDPOINT="$2"
    local DATA="${3:-}"
    local ARGS=(
        -s
        -H "Authorization: token $O2_GITHUB_TOKEN"
        -H "Accept: application/vnd.github+json"
        -X "$METHOD"
        "https://api.github.com${ENDPOINT}"
    )
    [ -n "$DATA" ] && ARGS+=(-d "$DATA")
    curl "${ARGS[@]}"
}

_fork_exists() {
    _github_api GET "/repos/${O2_GITHUB_USER}/O2Physics" \
        | grep -q '"full_name"'
}

# ==============================================================================
# _git_setup_fork
# Creates GitHub fork if needed, clones locally, sets up remotes and branch.
# Runs on local machine only.
# ==============================================================================
_git_setup_fork() {
    log_step "Setting up O2Physics fork..."

    if [ -d "$O2PHYSICS_SRC/.git" ]; then
        log_info "O2Physics already cloned at $O2PHYSICS_SRC"
        return
    fi

    # Create fork on GitHub if needed
    if _fork_exists; then
        log_info "Fork exists: github.com/$O2_GITHUB_USER/O2Physics"
    else
        log_info "Creating fork on GitHub..."
        _github_api POST "/repos/AliceO2Group/O2Physics/forks" \
            '{"default_branch_only": false}' > /dev/null

        log_info "Waiting for fork to be ready..."
        local ATTEMPTS=0
        until _fork_exists; do
            (( ATTEMPTS++ )) || true
            if [ "$ATTEMPTS" -gt 12 ]; then
                log_error "Fork not ready after 60s — check github.com/$O2_GITHUB_USER"
                exit 1
            fi
            log_info "  ... ${ATTEMPTS}/12"
            sleep 5
        done
        log_info "Fork ready: github.com/$O2_GITHUB_USER/O2Physics"
    fi

    # Clone fork
    log_info "Cloning into $O2PHYSICS_SRC ..."
    mkdir -p "$(dirname "$O2PHYSICS_SRC")"
    git clone "git@github.com:${O2_GITHUB_USER}/O2Physics.git" "$O2PHYSICS_SRC"

    cd "$O2PHYSICS_SRC"
    git remote add upstream https://github.com/AliceO2Group/O2Physics.git
    log_info "Upstream remote configured"

    # Create dev branch
    if git show-ref --verify --quiet "refs/heads/$O2_DEV_BRANCH"; then
        log_info "Branch '$O2_DEV_BRANCH' already exists"
        git checkout "$O2_DEV_BRANCH"
    else
        log_info "Creating branch '$O2_DEV_BRANCH'..."
        git checkout -b "$O2_DEV_BRANCH"
        git push -u origin "$O2_DEV_BRANCH"
    fi
    cd - > /dev/null

    log_info "O2Physics fork ready on branch '$O2_DEV_BRANCH'"
}

# ==============================================================================
# _git_update
# Full synchronization of O2Physics + alidist with upstream, then build
# locally and deploy to HPC.
#
# Sync strategy:
#   1. alidist   : checkout latest daily-YYYYMMDD-0000 tag from upstream
#   2. O2Physics SOURCES : checkout same daily tag (exact, not HEAD)
#   3. O2Physics working tree : fetch upstream, rebase dev on daily tag
#      (your tasks stay on top of the tag)
#   4. aliBuild build O2Physics locally
#   5. o2 deploy --build-only (same build on HPC)
# ==============================================================================
_git_update() {
    log_step "Updating O2Physics + alidist..."
    _build_assert_local "update"

    if [ ! -d "$O2PHYSICS_SRC/.git" ]; then
        log_info "Fork not found — running setup first"
        _git_setup_fork
        return
    fi

    load_apptainer
    detect_resources
    _setup_git_safe

    # ------------------------------------------------------------------
    # Step 1: Find latest daily tag in alidist
    # ------------------------------------------------------------------
    local ALIDIST_DIR="$SW_DIR/alidist"
    if [ ! -d "$ALIDIST_DIR/.git" ]; then
        log_error "alidist not found at $ALIDIST_DIR"
        exit 1
    fi

    log_info "Fetching latest alidist tags..."
    _o2_container_raw -- bash -c "
            git config --global --add safe.directory '*' 2>/dev/null || true
            cd /alice/sw/alidist
            git fetch upstream --tags --quiet 2>/dev/null || true
        "

    # Find latest daily tag (format: O2PDPSuite-daily-YYYYMMDD-0000)
    git config --global --add safe.directory "$ALIDIST_DIR" 2>/dev/null || true
    local LATEST_TAG
    LATEST_TAG=$(git -C "$ALIDIST_DIR" tag | grep -E '^O2PDPSuite-daily-[0-9]{8}-0000$' | sort -t- -k3 -V | tail -1)

    if [ -z "$LATEST_TAG" ]; then
        log_error "No daily tag found in alidist"
        exit 1
    fi

    # Extract date part: O2PDPSuite-daily-20260530-0000 → daily-20260530-0000
    local DAILY_TAG="${LATEST_TAG#O2PDPSuite-}"
    log_info "Latest daily tag : $LATEST_TAG"
    log_info "O2Physics tag    : $DAILY_TAG"

    # Checkout alidist at this tag
    # Fix ownership if alidist was created by root (via sudo aliBuild)
    if [ -n "$SUDO_USER" ] || [ "$(stat -c '%U' "$ALIDIST_DIR")" = "root" ]; then
        log_info "Fixing alidist ownership..."
        sudo chown -R "$(whoami)" "$ALIDIST_DIR" 2>/dev/null || true
    fi
    log_info "Checking out alidist at $LATEST_TAG..."
    git -C "$ALIDIST_DIR" checkout "$LATEST_TAG" --quiet
    local O2_TAG
    O2_TAG=$(grep "^tag:" "$ALIDIST_DIR/o2.sh" | awk '{print $2}' | tr -d '"')
    local O2PHYSICS_TAG
    O2PHYSICS_TAG=$(grep "^tag:" "$ALIDIST_DIR/o2physics.sh" | awk '{print $2}' | tr -d '"')
    log_info "alidist O2 tag       : $O2_TAG"
    log_info "alidist O2Physics tag: $O2PHYSICS_TAG"

    # ------------------------------------------------------------------
    # Step 2: Sync O2Physics SOURCES to the exact daily tag
    # ------------------------------------------------------------------
    local SOURCES_DIR="$SW_DIR/SOURCES/O2Physics/dev/0"
    # Fix ownership if created by root
    sudo chown -R "$(whoami)" "$SW_DIR/SOURCES" 2>/dev/null || true
    sudo chown -R "$(whoami)" "$SW_DIR/MIRROR"  2>/dev/null || true
    sudo chown -R "$(whoami)" "$O2PHYSICS_SRC"  2>/dev/null || true
    if [ -d "$SOURCES_DIR/.git" ]; then
        log_info "Syncing SOURCES/O2Physics to $O2PHYSICS_TAG..."
        _o2_container_raw -- bash -c "
            git config --global --add safe.directory '*' 2>/dev/null || true
            cd /alice/sw/SOURCES/O2Physics/dev/0
            git fetch upstream --tags --quiet 2>/dev/null || true
            git checkout $O2PHYSICS_TAG --quiet
        "
        log_info "SOURCES/O2Physics at: $(git -C "$SOURCES_DIR" describe --tags HEAD 2>/dev/null)"
    fi

    # ------------------------------------------------------------------
    # Step 3: Update O2Physics working tree — rebase dev on daily tag
    # ------------------------------------------------------------------
    cd "$O2PHYSICS_SRC"

    # Stash uncommitted changes
    local STASHED=0
    if ! git diff --quiet || ! git diff --cached --quiet; then
        log_info "Stashing uncommitted changes..."
        git stash push -m "auto-stash before update $(date -u +%Y%m%d-%H%M%S)"
        STASHED=1
    fi

    log_info "Fetching upstream O2Physics tags..."
    git fetch upstream --tags --quiet 2>/dev/null || true

    # Update master to daily tag
    log_info "Updating master to $O2PHYSICS_TAG..."
    git checkout master --quiet
    git reset --hard "$O2PHYSICS_TAG"
    git push origin master --force-with-lease --quiet 2>/dev/null || true

    # Rebase dev on the daily tag
    log_info "Rebasing '$O2_DEV_BRANCH' on $O2PHYSICS_TAG..."
    git checkout "$O2_DEV_BRANCH" --quiet

    if git rebase master; then
        git push --force-with-lease origin "$O2_DEV_BRANCH" --quiet 2>/dev/null || true
        log_info "Rebase successful — dev is on top of $O2PHYSICS_TAG"
    else
        log_error "Rebase conflict!"
        mkdir -p "$RESCUE_DIR"
        git diff --name-only --diff-filter=U | while read -r f; do
            cp "$f" "$RESCUE_DIR/$(basename "$f").conflict" 2>/dev/null || true
        done
        cat << EOF

  Your task files saved to: $RESCUE_DIR

  To resolve:
    1. Edit conflicted files (look for <<<<<<<, =======, >>>>>>>)
    2. cd $O2PHYSICS_SRC && git add . && git rebase --continue
    3. o2 build --rebuild-tasks

  To abort:
    cd $O2PHYSICS_SRC && git rebase --abort
    o2 build --git-rescue
EOF
        cd - > /dev/null
        exit 1
    fi

    # Restore stash
    if [ "$STASHED" -eq 1 ]; then
        log_info "Restoring stashed changes..."
        git stash pop || log_warn "Could not restore: cd $O2PHYSICS_SRC && git stash pop"
    fi

    cd - > /dev/null

    log_info "Git sync complete"
    log_info "  alidist    : $LATEST_TAG"
    log_info "  O2Physics  : $O2PHYSICS_TAG (dev branch on top)"

    # ------------------------------------------------------------------
    # Step 4: Build locally
    # ------------------------------------------------------------------
    log_info "Building O2Physics locally..."
    _build_lock_acquire
    trap '_build_lock_release' EXIT SIGTERM SIGINT
    _build_o2physics

    # ------------------------------------------------------------------
    # Step 5: Deploy sources to HPC and launch build
    # ------------------------------------------------------------------
    # No git operations on the cluster — _deploy_sync_sources handles
    # rsync of O2Physics + alidist (without .git/), which is sufficient
    # for aliBuild to rebuild from the synced working tree.
    log_info "Deploying sources and launching build on HPC..."
    cmd_deploy --build-only
}


# ==============================================================================
# _git_commit
# Stage, commit and push changes on a worktree (dev by default, or
# whichever --pr/--use targets — this is what lets the same command push
# a fix onto an already-open PR: 'o2 build --commit "msg" --pr <name>').
#
# Generalizes the old version, which only ever staged a single hardcoded
# O2_PHYSICS_COMPONENTS directory: now stages exactly the given
# pathspecs, or everything changed if none are given, anywhere in the
# worktree. No longer force-switches branches — a worktree is always
# pinned to its own branch by construction, so there's nothing to check.
#
# Deliberately does NOT call _rebuild_tasks — that coupling belonged to
# the old model where "commit" implicitly meant "sync task files first".
# Now that files are edited directly in the worktree, run
# 'o2 build --rebuild-tasks' yourself first if you need the CMakeLists/
# incremental-build side effects before committing.
# ==============================================================================
_git_commit() {
    local MSG="$1";    shift
    local TARGET="$1"; shift
    local -a PATHS=("$@")

    local WT
    WT=$(_resolve_worktree "$TARGET") || {
        log_error "Unknown worktree: '${TARGET:-dev}'"
        log_error "Run 'o2 build --list' to see available worktrees"
        return 1
    }

    cd "$WT" || return 1

    local -a PATHSPEC=(".")
    [ "${#PATHS[@]}" -gt 0 ] && PATHSPEC=("${PATHS[@]}")

    # git diff ignores untracked files entirely — status --porcelain is the
    # only check that also catches a brand-new file that was never staged.
    if [ -z "$(git status --porcelain -- "${PATHSPEC[@]}")" ]; then
        log_info "No changes to commit in [${TARGET:-dev}]"
        cd - > /dev/null
        return
    fi

    if [ "${#PATHS[@]}" -gt 0 ]; then
        git add -- "${PATHS[@]}"
    else
        git add -A
    fi

    log_info "Staging in [${TARGET:-dev}]:"
    git diff --cached --name-status | sed 's/^/    /'

    git commit -m "$MSG"

    local CURRENT_BRANCH
    CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
    git push origin "$CURRENT_BRANCH"

    log_info "Pushed to origin/$CURRENT_BRANCH"
    cd - > /dev/null
}

# ==============================================================================
# _git_status
# Friendly 'git status' for a worktree — dev by default, or --pr/--use.
# ==============================================================================
_git_status() {
    local TARGET="$1"

    local WT
    if ! WT=$(_resolve_worktree "$TARGET"); then
        if [ -z "$TARGET" ] || [ "$TARGET" = "dev" ]; then
            log_info "O2Physics fork not set up yet — run: o2 build"
        else
            log_error "Unknown worktree: '$TARGET'"
            log_error "Run 'o2 build --list' to see available worktrees"
        fi
        return 1
    fi

    cd "$WT"
    log_sep
    log_info "O2Physics worktree status [${TARGET:-dev}]"
    log_sep
    echo "  Path     : $WT"
    echo "  Branch   : $(git rev-parse --abbrev-ref HEAD)"
    echo "  Remote   : $(git remote get-url origin 2>/dev/null || echo n/a)"
    echo "  Upstream : $(git remote get-url upstream 2>/dev/null || echo n/a)"
    echo ""
    echo "  Recent commits:"
    git log --oneline -5 | sed 's/^/    /'
    echo ""
    echo "  Uncommitted changes:"
    if git diff --quiet && git diff --cached --quiet; then
        echo "    (none)"
    else
        git status --short | sed 's/^/    /'
    fi
    echo ""
    cd - > /dev/null
}

# ==============================================================================
# _git_discard
# Discard uncommitted changes on a worktree. With explicit paths, reverts
# tracked modifications and removes untracked new files at those paths
# only. With no paths, discards EVERYTHING uncommitted in the worktree
# (tracked and untracked) — asks for confirmation first, since that's
# unscoped and destructive.
# ==============================================================================
_git_discard() {
    local TARGET="$1"; shift
    local -a PATHS=("$@")

    local WT
    WT=$(_resolve_worktree "$TARGET") || {
        log_error "Unknown worktree: '${TARGET:-dev}'"
        log_error "Run 'o2 build --list' to see available worktrees"
        return 1
    }

    cd "$WT" || return 1

    if [ "${#PATHS[@]}" -eq 0 ]; then
        if git diff --quiet && git diff --cached --quiet; then
            log_info "Nothing to discard in [${TARGET:-dev}]"
            cd - > /dev/null
            return 0
        fi
        log_warn "This discards ALL uncommitted changes in [${TARGET:-dev}]"
        log_warn "— including untracked new files (e.g. from 'o2 analysis --add-file'):"
        git status --short | sed 's/^/    /'
        read -r -p "Discard everything above? [y/N] " REPLY
        case "$REPLY" in
            y|Y) ;;
            *) log_info "Cancelled"; cd - > /dev/null; return 1 ;;
        esac
        git checkout -- .
        git clean -fd
    else
        local P
        for P in "${PATHS[@]}"; do
            if git ls-files --error-unmatch "$P" &>/dev/null; then
                git checkout -- "$P"
            else
                rm -f "$P"
            fi
        done
    fi

    log_info "Discarded in [${TARGET:-dev}]"
    cd - > /dev/null
}

# ==============================================================================
# _git_rescue
# Reset dev branch to clean state, saving user files first.
# ==============================================================================
_git_rescue() {
    log_warn "Git rescue mode — resetting to safe state"
    [ ! -d "$O2PHYSICS_SRC/.git" ] && { log_info "Nothing to rescue"; return; }

    cd "$O2PHYSICS_SRC"
    mkdir -p "$RESCUE_DIR"

    if [ -d "$O2_PHYSICS_COMPONENTS" ]; then
        cp -r "$O2_PHYSICS_COMPONENTS/." "$RESCUE_DIR/"
        log_info "Task files saved to: $RESCUE_DIR"
    fi

    git rebase --abort 2>/dev/null || true
    git merge  --abort 2>/dev/null || true
    git fetch upstream
    git checkout master
    git reset --hard upstream/master
    git push --force-with-lease origin master 2>/dev/null || true
    git branch -D "$O2_DEV_BRANCH" 2>/dev/null || true
    git checkout -b "$O2_DEV_BRANCH"
    git push --force-with-lease origin "$O2_DEV_BRANCH" 2>/dev/null || true

    cat << EOF

  Branch '$O2_DEV_BRANCH' reset to upstream/master.
  Your task files are in: $RESCUE_DIR

  To restore your work:
    cp $RESCUE_DIR/*.cxx $O2PHYSICS_SRC/$O2_PHYSICS_COMPONENTS/
    o2 build --commit "restore user tasks"
EOF
    cd - > /dev/null
}

# ==============================================================================
# _build_cut_pr
# Cut a clean PR branch + worktree for one analysis, straight from
# upstream/master — never from dev, so it never carries anything from
# other analyses sharing the same dev sandbox.
#
# For each of the analysis's enabled files: pulls the file's CURRENT
# content from dev via 'git show dev:<path>' (a direct blob read — no
# risk of dragging along unrelated working-tree state), and for DPL
# tasks, replays the CMakeLists.txt block on the clean copy with
# _cmakelists_ensure_task_block rather than copying dev's CMakeLists.txt
# wholesale (which could contain other analyses' blocks too).
#
# The worktree is always named after the ANALYSIS (so 'o2 build --pr
# <analysis>' finds it later) — --branch only renames the underlying git
# branch, not the worktree.
# ==============================================================================
_build_cut_pr() {
    local ANALYSIS="$1"
    local BRANCH_NAME="$2"
    [ -z "$BRANCH_NAME" ] && BRANCH_NAME="pr/$ANALYSIS"

    if [ -z "$ANALYSIS" ]; then
        log_error "Usage: o2 build --cut-pr <analysis> [--branch <name>]"
        return 1
    fi

    local REGISTRY="$O2_LOCAL_DIR/analysis/analysis.json"
    if [ ! -f "$REGISTRY" ]; then
        log_error "analysis.json not found at $REGISTRY"
        return 1
    fi
    source "$SCRIPTS_DIR/lib/analysis.sh"

    local STATUS
    STATUS=$(_analysis_show_status "$REGISTRY" "$ANALYSIS") || return 1
    if [ "$STATUS" != "ready-for-pr" ]; then
        log_error "$ANALYSIS: status is '$STATUS', not 'ready-for-pr'"
        log_error "Promote it first: o2 analysis --promote $ANALYSIS"
        return 1
    fi

    local FILES
    FILES=$(_analysis_get_files "$REGISTRY" "$ANALYSIS")
    if [ -z "$FILES" ]; then
        log_error "$ANALYSIS has no enabled files/tasks to include in a PR"
        return 1
    fi

    local WT_PATH="$SW_DIR/O2Physics-pr-$ANALYSIS"
    if [ -e "$WT_PATH" ]; then
        log_error "Worktree already exists: $WT_PATH"
        log_error "Run 'o2 build --pr-cleanup $ANALYSIS' first if you want to re-cut it"
        return 1
    fi

    log_step "Cutting PR branch '$BRANCH_NAME' for $ANALYSIS"

    cd "$O2PHYSICS_SRC" || return 1
    git fetch upstream --quiet
    if ! git branch "$BRANCH_NAME" upstream/master 2>/dev/null; then
        log_error "Branch '$BRANCH_NAME' already exists — pick another with --branch, or clean it up first"
        cd - > /dev/null
        return 1
    fi
    git worktree add "$WT_PATH" "$BRANCH_NAME"
    cd - > /dev/null

    local DESCRIPTION
    DESCRIPTION=$(python3 - "$REGISTRY" "$ANALYSIS" << 'PYEOF'
import sys, json
registry_path, name = sys.argv[1:]
with open(registry_path) as f:
    data = json.load(f)
for a in data.get("analysis", []):
    if a.get("name") == name:
        print(a.get("description", ""))
        break
PYEOF
)

    local COUNT=0
    while IFS= read -r LINE; do
        [ -z "$LINE" ] && continue
        local FPATH FDPL
        FPATH=$(echo "$LINE" | awk '{print $1}')
        FDPL=$(echo "$LINE"  | awk '{print $2}')

        mkdir -p "$(dirname "$WT_PATH/$FPATH")"
        if ! git -C "$O2PHYSICS_SRC" show "$O2_DEV_BRANCH:$FPATH" > "$WT_PATH/$FPATH" 2>/dev/null; then
            log_warn "$FPATH: not found on $O2_DEV_BRANCH — skipping"
            rm -f "$WT_PATH/$FPATH"
            continue
        fi

        git -C "$WT_PATH" add "$FPATH"
        COUNT=$((COUNT + 1))
        log_info "[$ANALYSIS] Pulled $FPATH from $O2_DEV_BRANCH"

        if [ "$FDPL" != "-" ]; then
            local TASK_FILE PWG CMAKEFILE
            TASK_FILE=$(basename "$FPATH")
            PWG="${FPATH%%/*}"
            CMAKEFILE="$(dirname "$WT_PATH/$FPATH")/CMakeLists.txt"
            _cmakelists_ensure_task_block "$CMAKEFILE" "$TASK_FILE" "$FDPL" "$PWG"
            git -C "$WT_PATH" add "$CMAKEFILE"
        fi
    done <<< "$FILES"

    if [ "$COUNT" -eq 0 ]; then
        log_error "No files could be extracted — aborting"
        git -C "$O2PHYSICS_SRC" worktree remove --force "$WT_PATH"
        git -C "$O2PHYSICS_SRC" branch -D "$BRANCH_NAME"
        return 1
    fi

    local MSG="[$ANALYSIS] ${DESCRIPTION:-$ANALYSIS}"
    git -C "$WT_PATH" commit -q -m "$MSG"
    git -C "$WT_PATH" push -u origin "$BRANCH_NAME"

    _analysis_set_status "$REGISTRY" "$ANALYSIS" "pr-open"
    python3 - "$REGISTRY" "$ANALYSIS" "$BRANCH_NAME" "$WT_PATH" << 'PYEOF'
import sys, json
registry_path, name, branch, worktree = sys.argv[1:]
with open(registry_path) as f:
    data = json.load(f)
for a in data.get("analysis", []):
    if a.get("name") == name:
        a["pr_branch"] = branch
        a["pr_worktree"] = worktree
        break
with open(registry_path, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PYEOF

    log_sep
    log_info "PR branch ready: $BRANCH_NAME ($COUNT file(s))"
    log_info "Worktree       : $WT_PATH"
    log_info "Pushed to origin/$BRANCH_NAME — open the PR on GitHub against AliceO2Group/O2Physics master"
    log_info "To address review comments later: edit files in $WT_PATH, then"
    log_info "  o2 build --commit \"...\" --pr $ANALYSIS"
    log_sep
}

# ==============================================================================
# _build_pr_cleanup
# Remove a PR's worktree and local branch after it has been merged (or
# abandoned) on GitHub. Refuses if there are uncommitted changes. Always
# asks for confirmation — this is destructive and not undoable locally.
# ==============================================================================
_build_pr_cleanup() {
    local ANALYSIS="$1"

    if [ -z "$ANALYSIS" ]; then
        log_error "Usage: o2 build --pr-cleanup <analysis>"
        return 1
    fi

    local WT
    if ! WT=$(_resolve_worktree "$ANALYSIS"); then
        log_info "No worktree found for '$ANALYSIS' — nothing to clean up"
        return 0
    fi

    local BRANCH
    BRANCH=$(git -C "$WT" rev-parse --abbrev-ref HEAD)

    if ! git -C "$WT" diff --quiet || ! git -C "$WT" diff --cached --quiet; then
        log_error "$ANALYSIS's worktree has uncommitted changes — commit or discard them first"
        log_error "(o2 build --status --pr $ANALYSIS)"
        return 1
    fi

    log_warn "This removes the worktree at $WT and deletes local branch '$BRANCH'"
    log_warn "(only do this after the PR has been merged or abandoned on GitHub)"
    read -r -p "Continue? [y/N] " REPLY
    case "$REPLY" in
        y|Y) ;;
        *) log_info "Cancelled"; return 1 ;;
    esac

    git -C "$O2PHYSICS_SRC" worktree remove "$WT" --force
    git -C "$O2PHYSICS_SRC" branch -D "$BRANCH" 2>/dev/null || true

    local REGISTRY="$O2_LOCAL_DIR/analysis/analysis.json"
    if [ -f "$REGISTRY" ]; then
        source "$SCRIPTS_DIR/lib/analysis.sh"
        _analysis_set_status "$REGISTRY" "$ANALYSIS" "pr-merged"
    fi

    log_info "Cleaned up: $WT removed, branch '$BRANCH' deleted locally"
    log_info "(origin branch left untouched — delete it on GitHub if you want)"
}

# ==============================================================================
# _ensure_master_worktree
# Create the read-only master worktree if it doesn't exist yet — never
# edited by hand, only ever fast-forwarded to upstream/master.
# ==============================================================================
_ensure_master_worktree() {
    [ -d "$O2PHYSICS_MASTER_SRC/.git" ] && return 0
    [ -d "$O2PHYSICS_SRC/.git" ] || {
        log_error "Dev worktree not set up yet — run 'o2 build' first"
        return 1
    }

    log_step "Creating master worktree at $O2PHYSICS_MASTER_SRC"
    cd "$O2PHYSICS_SRC" || return 1
    git fetch upstream --quiet
    git worktree add "$O2PHYSICS_MASTER_SRC" upstream/master
    cd - > /dev/null
}

# ==============================================================================
# _build_record_tag
# Discover the alienv version tag a just-finished build produced (never
# "latest") and record it + the worktree's current commit in
# analysis.json, for 'o2 build --use'/'--list'. Shared by _build_worktree
# and _rebuild_tasks's incremental dev build.
# ==============================================================================
_build_record_tag() {
    local NAME="$1"
    local WT="$2"

    # Ask alienv itself for the exact, usable tag — do NOT infer it from
    # directory listings: real-world output showed a dev-package build
    # tagged "latest-dev-o2" (defaults-profile-dependent), not a plain
    # "latest" or a directory-derived name. 'alienv q' is the same lookup
    # alienv uses internally to validate a module name, so its output is
    # authoritative. We take the "latest*" line since that is what a
    # dev-package build produces (see WARNING below).
    local TAG
    TAG=$(_o2_container_raw -- bash -c '
        eval "$(alienv shell-helper)" 2>/dev/null
        alienv q O2Physics 2>/dev/null
    ' 2>/dev/null | grep -oE '::[^ ]*latest[^ ]*' | sed 's/^:://' | head -1)

    if [ -z "$TAG" ]; then
        log_warn "Couldn't determine the build's version tag for [$NAME] — 'o2 build --use $NAME' won't work until this is fixed"
        log_warn "Check manually: o2 build --use dev -- alienv q O2Physics"
        return 1
    fi

    local COMMIT
    COMMIT=$(git -C "$WT" rev-parse HEAD)

    local REGISTRY="$O2_LOCAL_DIR/analysis/analysis.json"
    if [ -f "$REGISTRY" ]; then
        python3 - "$REGISTRY" "$NAME" "$TAG" "$COMMIT" << 'PYEOF'
import sys, json
registry_path, name, tag, commit = sys.argv[1:]
with open(registry_path) as f:
    data = json.load(f)
wt = data.setdefault("worktrees", {})
wt[name] = {"tag": tag, "commit": commit}
with open(registry_path, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PYEOF
    fi
    log_info "Recorded build [$NAME] -> O2Physics/$TAG"
}

# ==============================================================================
# _build_worktree
# Build a specific worktree as the O2Physics dev package, sharing the
# same $SW_DIR (and therefore the same installed dependencies — ROOT,
# FairRoot, etc.) as every other worktree — only O2Physics itself gets
# rebuilt per worktree.
#
# Works by staging a directory containing a symlink literally named
# "O2Physics" pointing at the target worktree, and running aliBuild from
# THERE instead of from $SW_DIR directly — aliBuild's dev-package
# auto-detection only cares about a directory named after the package
# existing in its cwd.
#
# After building, discovers and records the resulting alienv version tag
# in analysis.json (never "latest", which is a moving pointer to
# whichever worktree was built most recently) so 'o2 build --use <name>'
# can address this exact build later regardless of what gets built
# afterward.
#
# NOTE: this relies on aliBuild giving a distinct, discoverable version
# tag to each dev-package build of different source content — verify on
# first real run: after building two different worktrees, 'alienv q
# O2Physics' inside the container should list two separate entries, not
# one. If it only ever shows one, this whole approach needs rethinking.
# ==============================================================================
_build_worktree() {
    local NAME="$1"

    local WT
    if ! WT=$(_resolve_worktree "$NAME"); then
        if [ "$NAME" = "master" ]; then
            _ensure_master_worktree || return 1
            WT=$(_resolve_worktree "$NAME") || return 1
        else
            log_error "Unknown worktree: '$NAME'"
            log_error "Run 'o2 build --list' to see available worktrees"
            return 1
        fi
    fi

    log_step "Building worktree [$NAME] ($WT)"
    load_apptainer
    detect_resources
    _setup_git_safe

    local STAGE_REL=".multibuild/$NAME"
    mkdir -p "$SW_DIR/$STAGE_REL"
    ln -sfn "$WT" "$SW_DIR/$STAGE_REL/O2Physics"

    local ALIBUILD_DEFAULTS="$O2_ALIBUILD_DEFAULTS"
    local BUILD_JOBS="$JOBS"
    local BUILD_LOG="$LOG_DIR/build_${NAME}.log"

    _o2_container_raw -- bash -s "$ALIBUILD_DEFAULTS" "$BUILD_JOBS" "$STAGE_REL" << 'CONTAINER_EOF' 2>&1 | tee "$BUILD_LOG"
set -e
ALIBUILD_DEFAULTS="$1"
BUILD_JOBS="$2"
STAGE_REL="$3"
export ALIBUILD_WORK_DIR=/alice/sw
export ALIBUILD_ANALYTICS=0
eval "$(alienv shell-helper)"
cd "/alice/sw/$STAGE_REL"
aliBuild build O2Physics --work-dir /alice/sw --defaults "$ALIBUILD_DEFAULTS" --jobs "$BUILD_JOBS"
CONTAINER_EOF

    local BUILD_RC=${PIPESTATUS[0]}
    if [ "$BUILD_RC" -ne 0 ]; then
        log_error "Build failed for [$NAME] (exit $BUILD_RC) — check $BUILD_LOG"
        return 1
    fi

    _build_record_tag "$NAME" "$WT"
}

# ==============================================================================
# _build_use
# Enter (no command) or run a command inside a worktree's built
# environment, addressed by the exact version tag recorded by
# _build_worktree — never "latest".
# ==============================================================================
_build_use() {
    local NAME="$1"; shift
    local -a CMD=("$@")

    if [ -z "$NAME" ]; then
        log_error "Usage: o2 build --use <name> [-- command...]"
        return 1
    fi

    local WT
    WT=$(_resolve_worktree "$NAME") || {
        log_error "Unknown worktree: '$NAME'"
        log_error "Run 'o2 build --list' to see available worktrees"
        return 1
    }

    local REGISTRY="$O2_LOCAL_DIR/analysis/analysis.json"
    local TAG=""
    if [ -f "$REGISTRY" ]; then
        TAG=$(python3 -c "
import json
with open('$REGISTRY') as f:
    data = json.load(f)
print(data.get('worktrees', {}).get('$NAME', {}).get('tag', ''))
" 2>/dev/null)
    fi

    if [ -z "$TAG" ]; then
        log_error "No build recorded for [$NAME] yet"
        log_error "Build it first: o2 build --rebuild-tasks (for dev), or the equivalent for [$NAME]"
        return 1
    fi

    load_apptainer
    if [ "${#CMD[@]}" -eq 0 ]; then
        log_info "Entering O2Physics/$TAG [$NAME] — 'exit' to leave"
        _o2_container_raw -- bash -c "eval \"\$(alienv shell-helper)\"; alienv enter O2Physics/$TAG"
    else
        _o2_container_raw -- bash -c 'eval "$(alienv shell-helper)"; alienv setenv O2Physics/'"$TAG"' -c "$@"' bash "${CMD[@]}"
    fi
}

# ==============================================================================
# _build_list
# Show every known worktree (dev, master, and any PR worktrees tracked
# in analysis.json) with its branch and last recorded build, and whether
# that build is stale relative to the worktree's current HEAD.
# ==============================================================================
_build_list() {
    log_sep
    log_info "O2Physics worktrees"
    log_sep

    local REGISTRY="$O2_LOCAL_DIR/analysis/analysis.json"
    local -a NAMES=(dev master)
    if [ -f "$REGISTRY" ]; then
        while IFS= read -r N; do
            [ -n "$N" ] && NAMES+=("$N")
        done < <(python3 -c "
import json
with open('$REGISTRY') as f:
    data = json.load(f)
for a in data.get('analysis', []):
    if a.get('pr_worktree'):
        print(a.get('name'))
" 2>/dev/null)
    fi

    printf "%-10s %-14s %-8s %s\n" "NAME" "BRANCH" "BUILD" "SOURCE"
    local NAME
    for NAME in "${NAMES[@]}"; do
        local WT
        WT=$(_resolve_worktree "$NAME" 2>/dev/null) || continue
        local BRANCH
        BRANCH=$(git -C "$WT" rev-parse --abbrev-ref HEAD 2>/dev/null)
        local CURRENT_COMMIT
        CURRENT_COMMIT=$(git -C "$WT" rev-parse HEAD 2>/dev/null)

        local TAG="" BUILT_COMMIT=""
        if [ -f "$REGISTRY" ]; then
            read -r TAG BUILT_COMMIT <<< "$(python3 -c "
import json
with open('$REGISTRY') as f:
    data = json.load(f)
e = data.get('worktrees', {}).get('$NAME', {})
print(e.get('tag',''), e.get('commit',''))
" 2>/dev/null)"
        fi

        local BUILD_LABEL="not built"
        local SOURCE_LABEL="—"
        if [ -n "$TAG" ]; then
            BUILD_LABEL="O2Physics/$TAG"
            if [ "$BUILT_COMMIT" = "$CURRENT_COMMIT" ]; then
                SOURCE_LABEL="up to date"
            else
                SOURCE_LABEL="stale — rebuild"
            fi
        fi
        printf "%-10s %-14s %-8s %s\n" "$NAME" "$BRANCH" "$BUILD_LABEL" "$SOURCE_LABEL"
    done
    log_sep
}

# ==============================================================================
# _rebuild_tasks
# Scan all analysis directories, copy enabled tasks to O2Physics, update
# CMakeLists.txt, then run an incremental aliBuild.
#
# Each analysis directory under $O2_LOCAL_DIR/analysis/ (except template/)
# may contain:
#   code/Tasks/*.cxx        — task source files
#   enabled_tasks.txt       — list of tasks to activate (name  dpl-name)
#
# enabled_tasks.txt format:
#   taskProxyBuilder  je-proxy-builder   # active
#   # myOtherTask    je-other-task       # commented = inactive
# ==============================================================================
# ==============================================================================
# _cmakelists_ensure_task_block
# Idempotently append an o2physics_add_dpl_workflow(...) entry for a task
# to a CMakeLists.txt, deriving PUBLIC_LINK_LIBRARIES from the PWG the
# task lives under (PWGJE/... -> O2Physics::PWGJECore, PWGLF/... ->
# O2Physics::PWGLFCore, etc.) instead of a single hardcoded PWG. Does
# nothing if an entry for that source file is already present — safe to
# call on every _rebuild_tasks run.
#
# Args: $1=cmakelists_path  $2=task_filename (basename only)
#       $3=dpl_name  $4=pwg (top-level dir name, e.g. "PWGJE")
# ==============================================================================
_cmakelists_ensure_task_block() {
    local CMAKEFILE="$1"
    local TASK_FILE="$2"
    local DPL_NAME="$3"
    local PWG="$4"
    local CORE_LIB="${PWG}Core"

    if [ ! -f "$CMAKEFILE" ]; then
        log_error "CMakeLists.txt not found at $CMAKEFILE"
        return 1
    fi

    if grep -q "SOURCES ${TASK_FILE}" "$CMAKEFILE"; then
        return 0
    fi

    cat >> "$CMAKEFILE" << CMAKEOF

o2physics_add_dpl_workflow(${DPL_NAME}
                    SOURCES ${TASK_FILE}
                    PUBLIC_LINK_LIBRARIES O2Physics::AnalysisCore O2Physics::${CORE_LIB}
                    COMPONENT_NAME Analysis)
CMAKEOF
    return 2   # signals "actually added" vs "already present" (0)
}

# ==============================================================================
# _rebuild_tasks
# Sync every enabled task from analysis.json into the O2Physics dev
# worktree, patch each task's own CMakeLists.txt, then run an incremental
# aliBuild.
#
# Two source layouts are supported, transparently:
#   - new  ("files[]"/--add-file): analysis/<name>/code/<full-path> is a
#     SYMLINK straight into $O2PHYSICS_SRC/<full-path> — the content is
#     already there, nothing to copy.
#   - legacy ("tasks[]"): a real file under analysis/<name>/code/Tasks/,
#     copied into $O2PHYSICS_SRC/$O2_PHYSICS_COMPONENTS/ as before.
#
# Works for any PWG (or shared location) a task's full path points at —
# no longer limited to the single O2_PHYSICS_COMPONENTS directory.
# ==============================================================================
_rebuild_tasks() {
    log_step "Syncing user tasks from analysis/ to O2Physics..."

    local ANALYSIS_DIR="$O2_LOCAL_DIR/analysis"
    local TASKS_LINKED=0
    local TASKS_COPIED=0
    local TASKS_SKIPPED=0

    local REGISTRY="$ANALYSIS_DIR/analysis.json"

    if [ ! -d "$ANALYSIS_DIR" ]; then
        log_error "analysis/ directory not found at $ANALYSIS_DIR"
        return 1
    fi

    if [ ! -f "$REGISTRY" ]; then
        log_error "analysis.json not found at $REGISTRY"
        return 1
    fi

    # Source analysis.sh for helper functions
    source "$SCRIPTS_DIR/lib/analysis.sh"

    # Get enabled tasks from registry: "analysis full_path dpl_name" lines
    local ENABLED_TASKS
    ENABLED_TASKS=$(_analysis_get_enabled_tasks "$REGISTRY")

    if [ -z "$ENABLED_TASKS" ]; then
        log_warn "No tasks enabled in analysis.json"
        log_warn "Use 'o2 analysis --enable <analysis>' to activate tasks"
        return 0
    fi

    while IFS= read -r LINE; do
        [ -z "$LINE" ] && continue
        local ANALYSIS FULL_PATH DPL_NAME TASK_FILE
        ANALYSIS=$(  echo "$LINE" | awk '{print $1}')
        FULL_PATH=$( echo "$LINE" | awk '{print $2}')
        DPL_NAME=$(  echo "$LINE" | awk '{print $3}')
        TASK_FILE=$(basename "$FULL_PATH")

        local DST="$O2PHYSICS_SRC/$FULL_PATH"
        local LOCAL_LINK="$ANALYSIS_DIR/$ANALYSIS/code/$FULL_PATH"
        local LEGACY_SRC="$ANALYSIS_DIR/$ANALYSIS/code/Tasks/$TASK_FILE"

        if [ -L "$LOCAL_LINK" ]; then
            if [ ! -e "$DST" ]; then
                log_warn "[$ANALYSIS] $FULL_PATH: symlink target missing — was it deleted from O2Physics?"
                TASKS_SKIPPED=$((TASKS_SKIPPED + 1))
                continue
            fi
            TASKS_LINKED=$((TASKS_LINKED + 1))
        elif [ -f "$LEGACY_SRC" ]; then
            mkdir -p "$(dirname "$DST")"
            cp "$LEGACY_SRC" "$DST"
            log_info "[$ANALYSIS] Copied $TASK_FILE → O2Physics/$FULL_PATH"
            TASKS_COPIED=$((TASKS_COPIED + 1))
        else
            log_warn "[$ANALYSIS] $FULL_PATH not found (checked O2Physics symlink and legacy code/Tasks/$TASK_FILE) — skipping"
            log_warn "[$ANALYSIS] Run 'o2 analysis --add-file $ANALYSIS $FULL_PATH' first"
            TASKS_SKIPPED=$((TASKS_SKIPPED + 1))
            continue
        fi

        # Track in git so aliBuild detects changes incrementally — without
        # git add, aliBuild sees untracked files and rebuilds unconditionally
        git -C "$O2PHYSICS_SRC" add "$FULL_PATH" 2>/dev/null || true

        local PWG="${FULL_PATH%%/*}"
        local CMAKEFILE
        CMAKEFILE="$(dirname "$DST")/CMakeLists.txt"

        _cmakelists_ensure_task_block "$CMAKEFILE" "$TASK_FILE" "$DPL_NAME" "$PWG"
        local CMAKE_RC=$?
        git -C "$O2PHYSICS_SRC" add "$CMAKEFILE" 2>/dev/null || true
        if [ "$CMAKE_RC" -eq 2 ]; then
            log_info "[$ANALYSIS] Added $DPL_NAME to $(basename "$(dirname "$CMAKEFILE")")/CMakeLists.txt"
        elif [ "$CMAKE_RC" -eq 0 ]; then
            log_info "[$ANALYSIS] $DPL_NAME already in $(basename "$(dirname "$CMAKEFILE")")/CMakeLists.txt"
        fi

    done <<< "$ENABLED_TASKS"

    log_info "Tasks synced: $TASKS_LINKED linked, $TASKS_COPIED copied (legacy), $TASKS_SKIPPED skipped"

    if [ "$TASKS_LINKED" -eq 0 ] && [ "$TASKS_COPIED" -eq 0 ]; then
        log_warn "No tasks activated"
        return 0
    fi

    # Incremental aliBuild
    log_step "Rebuilding O2Physics (incremental)..."
    load_apptainer
    detect_resources
    _setup_git_safe

    local ALIBUILD_DEFAULTS="$O2_ALIBUILD_DEFAULTS"
    local BUILD_JOBS="$JOBS"
    local BUILD_LOG="$LOG_DIR/ninja_rebuild.log"

    _o2_container_raw -- bash -s "$ALIBUILD_DEFAULTS" "$BUILD_JOBS" << 'CONTAINER_EOF' 2>&1 | tee "$BUILD_LOG"
set -e
ALIBUILD_DEFAULTS="$1"
BUILD_JOBS="$2"
export ALIBUILD_WORK_DIR=/alice/sw
export ALIBUILD_ANALYTICS=0
eval "$(alienv shell-helper)"
cd /alice/sw
aliBuild build O2Physics     --work-dir /alice/sw     --defaults "$ALIBUILD_DEFAULTS"     --jobs "$BUILD_JOBS"
CONTAINER_EOF

    local BUILD_RC=${PIPESTATUS[0]}
    if [ "$BUILD_RC" -eq 0 ]; then
        log_info "Incremental rebuild complete"
        _build_record_tag "dev" "$O2PHYSICS_SRC"
    else
        log_error "Incremental rebuild failed (exit $BUILD_RC) — check $BUILD_LOG"
        return 1
    fi
}

# ==============================================================================
# _generate_def_file
# ==============================================================================
_generate_def_file() {
    log_step "1/3 Generating Apptainer definition file..."

    cat > "$DEF_FILE" << DEFEOF
Bootstrap: docker
From: almalinux:9

%labels
    Author      $O2_AUTHOR
    Description AlmaLinux 9 environment for O2Physics (ALICE Run 3)

%post
    set -e
    dnf -y install epel-release dnf-plugins-core
    dnf -y update
    dnf config-manager --set-enabled crb
    dnf groupinstall -y "Development Tools"
    dnf -y remove low-memory-monitor || true

    tee /etc/yum.repos.d/alice-system-deps.repo > /dev/null << 'REPOEOF'
[alice-system-deps]
name=alice-system-deps
baseurl=https://s3.cern.ch/swift/v1/alibuild-repo/RPMS/o2-full-deps_el9.x86-64/
enabled=1
gpgcheck=0
REPOEOF

    dnf -y update
    dnf -y install alice-o2-full-deps alibuild git
    dnf clean all
    rm -rf /var/cache/dnf

    dnf -y install glibc-langpack-en 2>/dev/null || true
    localedef -i en_US -f UTF-8 en_US.UTF-8 2>/dev/null || true

    mkdir -p /root/.config/alibuild
    touch /root/.config/alibuild/disable-analytics
    cp /etc/skel/.bashrc /root/.bashrc

%environment
    export ALIBUILD_WORK_DIR=\${ALIBUILD_WORK_DIR:-/alice/sw}
    export TMPDIR=/tmp
    export LANG=en_US.UTF-8
    export LC_ALL=en_US.UTF-8

%runscript
    export ALIBUILD_WORK_DIR=/alice/sw
    export TMPDIR=/tmp
    export LANG=en_US.UTF-8
    export LC_ALL=en_US.UTF-8
    eval "\$(alienv shell-helper)"
    if [ \$# -eq 0 ]; then
        alienv setenv O2Physics/latest -c /bin/bash || exec /bin/bash
    else
        alienv setenv O2Physics/latest -c "\$@"
    fi
DEFEOF
    log_info "Def file: $DEF_FILE"
}

# ==============================================================================
# _build_sandbox
# ==============================================================================
_build_sandbox() {
    log_step "2/3 Building Apptainer sandbox..."
    apptainer cache clean -f --type all 2>/dev/null || true

    if [ -d "$SANDBOX" ]; then
        log_info "Removing existing sandbox: $SANDBOX"
        $SUDO chmod -R u+rwX "$SANDBOX"
        $SUDO rm -rf "$SANDBOX"
    fi

    $SUDO apptainer build --sandbox "$SANDBOX" "$DEF_FILE" \
        2>&1 | tee "$LOG_DIR/apptainer.log"

    if [ -d "$SANDBOX" ]; then
        log_info "Sandbox ready: $SANDBOX ($(du -sh "$SANDBOX" | cut -f1))"
    else
        log_error "Sandbox build failed — check $LOG_DIR/apptainer.log"
        exit 1
    fi
}

# ==============================================================================
# _setup_git_safe
# Add safe.directory entries for O2Physics repo inside the container.
# Needed because the repo may be owned by a different UID inside Apptainer.
# ==============================================================================
_setup_git_safe() {
    # These are set inside the container via _o2_container_raw
    # We write them to the fakehome .gitconfig so they persist across calls
    local GITCONFIG="$FAKEHOME/.gitconfig"
    git config --file "$GITCONFIG" --add safe.directory '/alice/sw' 2>/dev/null || true
    git config --file "$GITCONFIG" --add safe.directory '*' 2>/dev/null || true
    # Ensure upstream remote uses HTTPS (read-only, no auth needed in container)
    # Keep origin as SSH (your fork — only needed outside container for push)
    local REPO="$SW_DIR/O2Physics"
    if [ -d "$REPO/.git" ]; then
        local UPSTREAM_URL
        UPSTREAM_URL=$(git -C "$REPO" remote get-url upstream 2>/dev/null || true)
        if [ -z "$UPSTREAM_URL" ]; then
            git -C "$REPO" remote add upstream https://github.com/AliceO2Group/O2Physics.git
            log_info "O2Physics upstream remote configured (HTTPS)"
        elif echo "$UPSTREAM_URL" | grep -q "^git@"; then
            git -C "$REPO" remote set-url upstream https://github.com/AliceO2Group/O2Physics.git
            log_info "O2Physics upstream remote switched to HTTPS"
        fi
    fi
}

# ==============================================================================
# _check_mirrors
# Before building, clean up two types of stale state that cause build failures:
#
# 1. index.lock files in SOURCES/ — left behind when a previous build job was
#    killed brutally (OAR walltime exceeded). These cause:
#      fatal: Unable to create '.git/index.lock': File exists
#
# 2. Corrupted git mirrors in MIRROR/ — caused by incomplete clones due to
#    network interruption during a previous build. These cause:
#      pack has N unresolved deltas
# ==============================================================================
_check_mirrors() {
    local SOURCES_DIR="$SW_DIR/SOURCES"
    local MIRROR_DIR="$SW_DIR/MIRROR"
    local LOCKS_REMOVED=0
    local CORRUPTED=0

    # --- Clean orphan index.lock files ---
    if [ -d "$SOURCES_DIR" ]; then
        log_info "Checking for orphan git locks in SOURCES/..."
        while IFS= read -r lockfile; do
            log_warn "Removing orphan lock: $lockfile"
            rm -f "$lockfile"
            LOCKS_REMOVED=$(( LOCKS_REMOVED + 1 ))
        done < <(find "$SOURCES_DIR" -name "index.lock" 2>/dev/null)

        if [ "$LOCKS_REMOVED" -gt 0 ]; then
            log_warn "Removed $LOCKS_REMOVED orphan lock(s)"
        else
            log_info "No orphan locks found"
        fi
    fi

    # --- Check git mirrors integrity ---
    if [ -d "$MIRROR_DIR" ]; then
        log_info "Checking git mirrors integrity..."
        local TOTAL=0
        for mirror in "$MIRROR_DIR"/*/; do
            [ -d "$mirror" ] || continue
            TOTAL=$(( TOTAL + 1 ))
            if ! git -C "$mirror" fsck 2>/dev/null 1>/dev/null; then
                log_warn "Corrupted mirror: $(basename "$mirror") — removing"
                rm -rf "$mirror"
                CORRUPTED=$(( CORRUPTED + 1 ))
            fi
        done
        if [ "$CORRUPTED" -gt 0 ]; then
            log_warn "Removed $CORRUPTED corrupted mirror(s) — aliBuild will re-clone"
        else
            log_info "All $TOTAL mirrors OK"
        fi
    fi
}

# ==============================================================================
# _build_o2physics
# ==============================================================================
_build_o2physics() {
    log_step "3/3 Building O2Physics (branch: $O2_DEV_BRANCH)..."

    # Check and clean corrupted mirrors before starting aliBuild
    _check_mirrors
    _setup_git_safe

    # Pass host variables explicitly as env vars so the single-quoted
    # heredoc can reference them without host-side expansion issues.
    local DEV_BRANCH="$O2_DEV_BRANCH"
    local ALIBUILD_DEFAULTS="$O2_ALIBUILD_DEFAULTS"
    local BUILD_JOBS="$JOBS"
    local PHYSICS_VERSION="$O2_PHYSICS_VERSION"
    local BUILD_LOG="$LOG_DIR/o2physics.log"

    _o2_container_raw -- bash -s         "$DEV_BRANCH" "$ALIBUILD_DEFAULTS" "$BUILD_JOBS" "$PHYSICS_VERSION"         << 'CONTAINER_EOF' 2>&1 | tee "$BUILD_LOG"
set -e
DEV_BRANCH="$1"
ALIBUILD_DEFAULTS="$2"
BUILD_JOBS="$3"
PHYSICS_VERSION="$4"

export ALIBUILD_WORK_DIR=/alice/sw
export ALIBUILD_ANALYTICS=0
eval "$(alienv shell-helper)"
cd /alice/sw

# Initialize alidist if missing
if [ ! -d 'alidist' ]; then
    echo '[INFO] Initializing alidist...'
    aliBuild init "$PHYSICS_VERSION"
else
    echo '[INFO] Existing source found — resuming'
fi

# Ensure O2Physics repo is on dev branch before build (local only).
# On HPC after rsync, .git/ is absent — just verify the source tree exists.
if [ -d 'O2Physics/.git' ]; then
    CURRENT=$(git -C O2Physics rev-parse --abbrev-ref HEAD 2>/dev/null)
    if [ "$CURRENT" != "$DEV_BRANCH" ]; then
        echo "[INFO] Switching O2Physics to $DEV_BRANCH..."
        git -C O2Physics checkout "$DEV_BRANCH" --quiet 2>/dev/null || true
    fi
    echo "[INFO] O2Physics branch: $(git -C O2Physics rev-parse --abbrev-ref HEAD 2>/dev/null)"
elif [ -d 'O2Physics' ]; then
    echo '[INFO] O2Physics source present (synced from local — no git)'
else
    echo '[ERROR] O2Physics source not found in /alice/sw/'
    exit 1
fi

aliBuild build O2Physics --work-dir /alice/sw \
    --defaults "$ALIBUILD_DEFAULTS" \
    --jobs "$BUILD_JOBS"
ALIBUILD_RC=$?

if [ $ALIBUILD_RC -eq 0 ]; then
    echo "[INFO] aliBuild completed successfully"
    echo "status=success"
    echo "finished_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    echo "branch=$DEV_BRANCH"
    echo "defaults=$ALIBUILD_DEFAULTS"
else
    echo "[ERROR] aliBuild failed with exit code $ALIBUILD_RC"
    echo "status=failed"
    echo "finished_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    echo "exit_code=$ALIBUILD_RC"
fi
CONTAINER_EOF

# Capture aliBuild exit code through the pipe (tee loses it otherwise)
BUILD_RC=${PIPESTATUS[0]}

# Write build status file readable by 'o2 sync' and 'o2 status'
local STATUS_FILE="$LOG_DIR/build_status"
if [ "$BUILD_RC" -eq 0 ]; then
    cat > "$STATUS_FILE" << STATUSEOF
status=success
finished_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
branch=$O2_DEV_BRANCH
log=$BUILD_LOG
STATUSEOF
    log_info "Build status: SUCCESS — written to $STATUS_FILE"
else
    cat > "$STATUS_FILE" << STATUSEOF
status=failed
finished_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
exit_code=$BUILD_RC
branch=$O2_DEV_BRANCH
log=$BUILD_LOG
STATUSEOF
    log_error "Build status: FAILED (exit $BUILD_RC) — check $BUILD_LOG"
    log_error "Build status written to $STATUS_FILE"
fi
}

# ==============================================================================
# _build_submit_oar (HPC login node)
# ==============================================================================
_build_submit_oar() {
    local SANDBOX_ONLY="${1:-0}"
    local BUILD_ONLY="${2:-0}"

    command -v oarsub &>/dev/null || {
        log_error "oarsub not found — are you on the HPC login node?"
        exit 1
    }

    local EXTRA_ARGS=""
    [ "$SANDBOX_ONLY" -eq 1 ] && EXTRA_ARGS="--sandbox-only"
    [ "$BUILD_ONLY"   -eq 1 ] && EXTRA_ARGS="--build-only"

    local OAR_SCRIPT="$LOG_DIR/oar_full_build.sh"
    local OAR_CORES="${O2_OAR_CORES:-$(nproc)}"

    cat > "$OAR_SCRIPT" << OAREOF
#!/bin/bash
#OAR -n O2Physics_full_build
#OAR -l /nodes=1/core=${OAR_CORES},walltime=${O2_OAR_WALLTIME}
#OAR --stdout $LOG_DIR/oar_full_build.log
#OAR --stderr $LOG_DIR/oar_full_build.err
#OAR --notify mail:${O2_EMAIL}

command -v apptainer &>/dev/null || module load apptainer 2>/dev/null || \
    module load singularity 2>/dev/null

${SCRIPTS_DIR}/o2.sh build $EXTRA_ARGS
OAREOF
    chmod +x "$OAR_SCRIPT"

    local FLAGS="--project ${O2_OAR_PROJECT}"
    [ -n "${O2_OAR_TYPE:-}"       ] && FLAGS="$FLAGS -t ${O2_OAR_TYPE}"
    [ "${O2_OAR_DEVEL:-0}" -eq 1 ] && FLAGS="$FLAGS -t devel"

    local JOB_ID
    JOB_ID=$(oarsub $FLAGS -S "$OAR_SCRIPT" | grep -oP 'OAR_JOB_ID=\K[0-9]+')

    log_info "OAR job submitted: $JOB_ID"
    log_info "Monitor  : o2 deploy --status"
    log_info "Full log : $LOG_DIR/oar_full_build.log"
}

# ==============================================================================
# _build_summary
# ==============================================================================
_build_summary() {
    echo ""
    log_sep
    log_info "Build complete"
    log_sep
    echo ""
    echo "  Activate O2Physics in your shell:"
    echo "    source ~/alice/o2rc"
    echo ""
    echo "  Run an analysis:"
    echo "    o2 run proxies LHC24aj"
    echo ""
}
