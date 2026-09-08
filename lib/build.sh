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
    local COMMIT_MSG=""
    local GIT_STATUS_ONLY=0
    local GIT_RESCUE=0

    while [[ $# -gt 0 ]]; do
        case $1 in
            --sandbox-only)   SANDBOX_ONLY=1 ;;
            --build-only)     BUILD_ONLY=1 ;;
            --rebuild-tasks)  REBUILD_TASKS=1 ;;
            --update)         UPDATE_ONLY=1 ;;
            --commit)         shift; COMMIT_MSG="$1" ;;
            --git-status)     GIT_STATUS_ONLY=1 ;;
            --git-rescue)     GIT_RESCUE=1 ;;
            --help|-h)        _build_help; return 0 ;;
            *) log_warn "Unknown option: $1" ;;
        esac
        shift
    done

    # Git-only operations (no apptainer needed)
    if [ "$GIT_STATUS_ONLY" -eq 1 ]; then _git_status;  return; fi
    if [ "$GIT_RESCUE"      -eq 1 ]; then _git_rescue;  return; fi
    if [ -n "$COMMIT_MSG"         ]; then
        _build_assert_local "commit"
        _git_commit "$COMMIT_MSG"
        _rebuild_tasks
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
  --rebuild-tasks    fast ninja rebuild of your PWGJE/Tasks only
  --update           sync fork with upstream + rebuild tasks
  --commit "msg"     commit + push your task changes, then rebuild
  --git-status       show git status of your O2Physics fork
  --git-rescue       recover from a broken git state (saves your files first)
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
# Stage, commit and push user task changes.
# ==============================================================================
_git_commit() {
    local MSG="$1"

    if [ ! -d "$O2PHYSICS_SRC/.git" ]; then
        log_error "O2Physics not found at $O2PHYSICS_SRC"
        exit 1
    fi

    cd "$O2PHYSICS_SRC"

    local CURRENT_BRANCH
    CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
    if [ "$CURRENT_BRANCH" != "$O2_DEV_BRANCH" ]; then
        log_warn "Not on '$O2_DEV_BRANCH' (on '$CURRENT_BRANCH') — switching"
        git checkout "$O2_DEV_BRANCH"
    fi

    if git diff --quiet && git diff --cached --quiet; then
        log_info "No changes to commit"
        cd - > /dev/null
        return
    fi

    log_info "Changes to commit:"
    git status --short

    git add "$O2_PHYSICS_COMPONENTS/"
    git add "CMakeLists.txt" 2>/dev/null || true
    git commit -m "$MSG"
    git push origin "$O2_DEV_BRANCH"

    log_info "Pushed to origin/$O2_DEV_BRANCH"
    cd - > /dev/null
}

# ==============================================================================
# _git_status
# ==============================================================================
_git_status() {
    if [ ! -d "$O2PHYSICS_SRC/.git" ]; then
        log_info "O2Physics fork not set up yet — run: o2 build"
        return
    fi
    cd "$O2PHYSICS_SRC"
    log_sep
    log_info "O2Physics fork git status"
    log_sep
    echo "  Branch   : $(git rev-parse --abbrev-ref HEAD)"
    echo "  Remote   : $(git remote get-url origin 2>/dev/null || echo n/a)"
    echo "  Upstream : $(git remote get-url upstream 2>/dev/null || echo n/a)"
    echo ""
    echo "  Recent commits on $O2_DEV_BRANCH:"
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
_rebuild_tasks() {
    log_step "Syncing user tasks from analysis/ to O2Physics..."

    local ANALYSIS_DIR="$O2_LOCAL_DIR/analysis"
    local O2PHYSICS_TASKS="$SW_DIR/O2Physics/$O2_PHYSICS_COMPONENTS"
    local CMAKEFILE="$SW_DIR/O2Physics/$O2_PHYSICS_COMPONENTS/CMakeLists.txt"
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

    if [ ! -f "$CMAKEFILE" ]; then
        log_error "CMakeLists.txt not found at $CMAKEFILE"
        return 1
    fi

    # Source analysis.sh for helper functions
    source "$SCRIPTS_DIR/lib/analysis.sh"

    # Get enabled tasks from registry
    local ENABLED_TASKS
    ENABLED_TASKS=$(_analysis_get_enabled_tasks "$REGISTRY")

    if [ -z "$ENABLED_TASKS" ]; then
        log_warn "No tasks enabled in analysis.json"
        log_warn "Use 'o2 analysis --enable <analysis>' to activate tasks"
        return 0
    fi

    # Process each enabled task
    while IFS= read -r LINE; do
        [ -z "$LINE" ] && continue
        local ANALYSIS TASK_FILE DPL_NAME TASK_NAME
        ANALYSIS=$(  echo "$LINE" | awk '{print $1}')
        TASK_FILE=$( echo "$LINE" | awk '{print $2}')
        DPL_NAME=$(  echo "$LINE" | awk '{print $3}')
        TASK_NAME="${TASK_FILE%.cxx}"

        local SRC="$ANALYSIS_DIR/$ANALYSIS/code/Tasks/$TASK_FILE"
        local DST="$O2PHYSICS_TASKS/$TASK_FILE"

        if [ ! -f "$SRC" ]; then
            log_warn "[$ANALYSIS] $TASK_FILE not found in code/Tasks/ — skipping"
            TASKS_SKIPPED=$((TASKS_SKIPPED + 1))
            continue
        fi

        # Copy source file
        cp "$SRC" "$DST"
        log_info "[$ANALYSIS] Copied $TASK_FILE → O2Physics/$O2_PHYSICS_COMPONENTS/"

        # Track the new file in git so aliBuild detects changes incrementally
        # Without git add, aliBuild sees untracked files and rebuilds unconditionally
        git -C "$SW_DIR/O2Physics" add "$O2_PHYSICS_COMPONENTS/$TASK_FILE" 2>/dev/null || true
        git -C "$SW_DIR/O2Physics" add "$O2_PHYSICS_COMPONENTS/CMakeLists.txt" 2>/dev/null || true

        # Add CMakeLists.txt entry if not already present
        if ! grep -q "SOURCES ${TASK_FILE}" "$CMAKEFILE"; then
            cat >> "$CMAKEFILE" << CMAKEOF

o2physics_add_dpl_workflow(${DPL_NAME}
                    SOURCES ${TASK_FILE}
                    PUBLIC_LINK_LIBRARIES O2Physics::AnalysisCore O2Physics::PWGJECore
                    COMPONENT_NAME Analysis)
CMAKEOF
            log_info "[$ANALYSIS] Added $DPL_NAME to CMakeLists.txt"
        else
            log_info "[$ANALYSIS] $DPL_NAME already in CMakeLists.txt"
        fi

        TASKS_COPIED=$((TASKS_COPIED + 1))

    done <<< "$ENABLED_TASKS" 

    log_info "Tasks synced: $TASKS_COPIED copied, $TASKS_SKIPPED skipped"

    if [ "$TASKS_COPIED" -eq 0 ] && [ "$TASKS_SKIPPED" -eq 0 ]; then
        log_warn "No tasks activated — check enabled_tasks.txt in your analysis/"
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
