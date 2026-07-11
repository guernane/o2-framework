#!/bin/bash
# ==============================================================================
# lib/export.sh
# Clones fresh copies of the 3 repos from GitHub (not local working copies)
# and bundles them into a single archive, ready to share (e.g. with Claude).
# Local machine only. Requires the GitHub CLI ('gh').
#
# Usage:
#   o2 export [output_path]
# ==============================================================================

_export_help() {
    cat << 'EOF'
o2 export [output_path]

Clones fresh copies of all three repos directly from GitHub (guaranteeing
the exported content matches what's actually backed up, not just your
local working copy) and bundles them into a single .tar.gz archive.

O2Physics is trimmed to PWGJE/ and Common/ only (full source is too large
for casual sharing) — edit lib/export.sh to change this.

Default output: ~/alice_export_<timestamp>.tar.gz

Examples:
  o2 export
  o2 export ~/Desktop/alice_snapshot.tar.gz
EOF
}

cmd_export() {
    local OUT="${1:-$O2_LOCAL_DIR/../alice_export_$(date +%Y%m%d_%H%M%S).tar.gz}"

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

    log_info "Cloning guernane/o2-framework..."
    gh repo clone guernane/o2-framework "$TMP_DIR/o2-framework" -- --depth 1 -q

    log_info "Cloning guernane/analyses..."
    gh repo clone guernane/analyses "$TMP_DIR/analyses" -- --depth 1 -q

    log_info "Cloning guernane/O2Physics (dev branch, shallow)..."
    gh repo clone guernane/O2Physics "$TMP_DIR/O2Physics" -- --depth 1 --branch dev -q

    # Strip .git dirs — this is a content snapshot, not a working clone
    rm -rf "$TMP_DIR/o2-framework/.git" "$TMP_DIR/analyses/.git" "$TMP_DIR/O2Physics/.git"

    # Trim O2Physics to the relevant subset (full source is huge)
    if [ -d "$TMP_DIR/O2Physics" ]; then
        find "$TMP_DIR/O2Physics" -mindepth 1 -maxdepth 1 \
            ! -name "PWGJE" ! -name "Common" ! -name "CMakeLists.txt" \
            -exec rm -rf {} +
    fi

    tar -czf "$OUT" -C "$TMP_DIR" o2-framework analyses O2Physics

    echo "========================================"
    log_info "Export complete: $OUT"
    log_info "Size: $(du -h "$OUT" | cut -f1)"
    echo "========================================"
}
