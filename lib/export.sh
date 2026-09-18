#!/bin/bash
# ==============================================================================
# lib/export.sh
# Clones fresh copies of the 2 repos from GitHub (not local working copies)
# and bundles them into a single archive, ready to share (e.g. with Claude).
# Local machine only. Requires the GitHub CLI ('gh').
#
# Usage:
#   o2 export [output_path]
# ==============================================================================

_export_help() {
    cat << 'EOF'
o2 export [output_path] [options]

Clones fresh copies of the selected repos directly from GitHub (guaranteeing
the exported content matches what's actually backed up, not just your
local working copy) and bundles them into a single .tar.gz archive.
analysis/ lives inside the o2-framework repo, so it is exported along with
it automatically — there is no separate filtering for it.

Any file committed and pushed to GitHub is automatically picked up on the
next export — nothing to update in this script when you add new files.
The only filtering below applies to O2Physics (too large to include whole).

Options:
  --repos "a,b"               Which repos to include. Default: both.
                               Choices: o2-framework, O2Physics
  --o2physics-paths "..."     Top-level O2Physics dirs to keep.
                               Default: "PWGJE,Common". Use "ALL" for everything.

Default output: ~/alice_export_<timestamp>.tar.gz

Examples:
  o2 export
  o2 export --repos "o2-framework"
  o2 export --o2physics-paths "PWGJE,PWGCF,Common"
EOF
}

cmd_export() {
    local OUT=""
    local REPOS="o2-framework,O2Physics"
    local O2PHYSICS_PATHS="PWGJE,Common"

    while [ $# -gt 0 ]; do
        case "$1" in
            --repos)             REPOS="$2"; shift 2 ;;
            --o2physics-paths)   O2PHYSICS_PATHS="$2"; shift 2 ;;
            --*)                 log_error "Unknown option: $1"; _export_help; exit 1 ;;
            *)                   OUT="$1"; shift ;;
        esac
    done
    OUT="${OUT:-$O2_LOCAL_DIR/../alice_export_$(date +%Y%m%d_%H%M%S).tar.gz}"

    if ! command -v gh &>/dev/null; then
        log_error "GitHub CLI ('gh') not found — required for 'o2 export'"
        exit 1
    fi

    local TMP_DIR
    TMP_DIR="$(mktemp -d)"
    trap 'rm -rf "$TMP_DIR"' RETURN

    echo "========================================"
    echo "   o2 export — bundling repos from GitHub"
    echo "========================================"

    local BUNDLE_DIRS=()
    IFS=',' read -ra WANTED_REPOS <<< "$REPOS"

    for r in "${WANTED_REPOS[@]}"; do
        case "$r" in
            o2-framework)
                log_info "Cloning guernane/o2-framework..."
                gh repo clone guernane/o2-framework "$TMP_DIR/o2-framework" -- --depth 1 -q
                rm -rf "$TMP_DIR/o2-framework/.git"
                BUNDLE_DIRS+=("o2-framework")
                ;;
            O2Physics)
                log_info "Cloning guernane/O2Physics (dev branch, shallow)..."
                gh repo clone guernane/O2Physics "$TMP_DIR/O2Physics" -- --depth 1 --branch dev -q
                rm -rf "$TMP_DIR/O2Physics/.git"

                if [ "$O2PHYSICS_PATHS" != "ALL" ]; then
                    local KEEP_ARGS=()
                    IFS=',' read -ra KEEP_DIRS <<< "$O2PHYSICS_PATHS"
                    for d in "${KEEP_DIRS[@]}"; do
                        KEEP_ARGS+=(! -name "$d")
                    done
                    KEEP_ARGS+=(! -name "CMakeLists.txt")
                    find "$TMP_DIR/O2Physics" -mindepth 1 -maxdepth 1 "${KEEP_ARGS[@]}" -exec rm -rf {} +
                    log_info "O2Physics trimmed to: $O2PHYSICS_PATHS"
                else
                    log_info "O2Physics: keeping full source (this will be large)"
                fi

                BUNDLE_DIRS+=("O2Physics")
                ;;
            *)
                log_error "Unknown repo in --repos: '$r' (expected: o2-framework, O2Physics)"
                exit 1
                ;;
        esac
    done

    tar -czf "$OUT" -C "$TMP_DIR" "${BUNDLE_DIRS[@]}"

    echo "========================================"
    log_info "Export complete: $OUT"
    log_info "Size: $(du -h "$OUT" | cut -f1)"
    echo "========================================"
}
