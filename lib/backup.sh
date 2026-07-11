#!/bin/bash
# ==============================================================================
# lib/backup.sh
# Commits and pushes any local changes in the 3 repos to GitHub.
# Local machine only.
#
# Usage:
#   o2 backup ["commit message"]
# ==============================================================================

_backup_help() {
    cat << 'EOF'
o2 backup ["commit message"]

Commits and pushes any local changes in all three repos to GitHub:
  - o2-framework  (~/alice)
  - analyses      (~/alice/analyses)
  - O2Physics     (~/alice/sw/O2Physics)

If no commit message is given, a timestamp is used.
Repos with nothing to commit are skipped (push is still attempted, in
case there are commits made locally that were not yet pushed).

Examples:
  o2 backup
  o2 backup "add jet finder fix"
EOF
}

_backup_repo() {
    local DIR="$1"
    local NAME="$2"
    local MSG="$3"

    if [ ! -d "$DIR/.git" ]; then
        log_info "[$NAME] skipped — not a git repo ($DIR)"
        return
    fi

    (
        cd "$DIR"
        if [ -z "$(git status --porcelain)" ]; then
            log_info "[$NAME] nothing to commit"
        else
            git add -A
            git commit -m "$MSG" --quiet
            log_info "[$NAME] committed local changes"
        fi
        git push --quiet
        log_info "[$NAME] pushed to origin"
    )
}

cmd_backup() {
    local MSG="${1:-Backup $(date '+%Y-%m-%d %H:%M:%S')}"

    echo "========================================"
    echo "   o2 backup — syncing repos to GitHub"
    echo "========================================"

    _backup_repo "$O2_LOCAL_DIR"              "o2-framework" "$MSG"
    _backup_repo "$O2_LOCAL_DIR/analyses"     "analyses"     "$MSG"
    _backup_repo "$O2_LOCAL_DIR/sw/O2Physics" "O2Physics"    "$MSG"

    echo "========================================"
    echo "   Backup complete"
    echo "========================================"
}
