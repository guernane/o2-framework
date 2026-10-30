#!/bin/bash
# ==============================================================================
# lib/docs.sh
# Builds ONE markdown file from the ALICE O2 analysis-framework documentation
# (https://aliceo2group.github.io/analysis-framework/docs/).
# Local machine only. Needs git and network access (except with --offline).
#
# Usage:
#   o2 docs [options]
# ==============================================================================

# Default sections (docs/ subdirectories), in reading order. Overridden by
# O2_DOCS_SECTIONS in o2_config.sh or by --sections.
_DOCS_DEFAULT_SECTIONS="gettingstarted basics-tasks basics-usage analysis-tools hyperloop advanced-specifics tutorials faq tools troubleshooting datamodel glossary"
_DOCS_DEFAULT_REPO="https://github.com/AliceO2Group/analysis-framework.git"

_docs_help() {
    cat << 'EOF'
o2 docs [options]

Builds ONE markdown file from the ALICE O2 analysis-framework documentation.
A light clone (markdown files only, no images) is cached in $O2_DOCS_DIR/src
and updated on each run. The Jekyll front matter of every page is stripped and
the pages are concatenated section by section; each page is preceded by a
separator line and an HTML comment holding its path in the repository.

Options:
  --output FILE       Output file.
                      Default: $O2_DOCS_DIR/alice_o2_docs.md
  --sections "a b"    Sections (docs/ subdirectories) to include, in this order.
                      Default: O2_DOCS_SECTIONS from o2_config.sh
  --exclude "a b"     Sections to leave out of the list, e.g. --exclude datamodel
  --order site|path   Order of the pages inside a section:
                        site (default)  the 'sort' key of each page's front
                                        matter, i.e. the order of the website
                        path            alphabetical by file path
  --offline           Do not contact GitHub; use the cached clone as is
  -h, --help          This help

Sections may be separated by spaces or commas.

The datamodel section is generated reference tables: about 4.5 MB of the ~5 MB
total. Use --exclude datamodel for a document small enough to read in full or
to hand to an assistant.

Examples:
  o2 docs
  o2 docs --exclude datamodel
  o2 docs --sections "basics-tasks,tutorials" --output ~/o2_tasks.md
  o2 docs --offline --order path
EOF
}

# Value of a front matter key (first '---' block of the file); empty if absent.
_docs_fm_get() {
    awk -v k="$2" '
        NR==1 && /^---[[:space:]]*$/ {fm=1; next}
        fm && /^---[[:space:]]*$/ {exit}
        fm && index($0, k ":")==1 {sub("^" k ":[[:space:]]*", ""); print; exit}
    ' "$1"
}

# Page content without its Jekyll front matter (leading '---' ... '---' block).
_docs_strip() {
    awk 'NR==1 && /^---[[:space:]]*$/ {fm=1; next} fm && /^---[[:space:]]*$/ {fm=0; next} !fm' "$1"
}

# Pages of one section, as paths relative to the docs root, in the wanted order.
#   $1 docs root   $2 section   $3 order (site|path)
_docs_list_pages() {
    local ROOT="$1" SECTION="$2" ORDER="$3" f
    (
        cd "$ROOT" || exit 1
        if [ "$ORDER" = "path" ]; then
            find "$SECTION" -name '*.md' 2>/dev/null | LC_ALL=C sort
        else
            # key 1: 'sort' front matter (pages without one go last)
            # key 2: a section's README.md before other pages with the same key
            # key 3: path, to be deterministic
            find "$SECTION" -name '*.md' 2>/dev/null | while IFS= read -r f; do
                local K R=1
                K="$(_docs_fm_get "$f" sort)"
                case "$K" in ''|*[!0-9]*) K=9999 ;; esac
                [ "$(basename "$f")" = "README.md" ] && R=0
                printf '%s\t%s\t%s\n' "$K" "$R" "$f"
            done | LC_ALL=C sort -t "$(printf '\t')" -k1,1n -k2,2n -k3,3 | cut -f3-
        fi
    )
}

# Make sure the cached light clone exists (and is current unless --offline).
#   $1 clone dir   $2 repo url   $3 offline (0|1)
_docs_fetch() {
    local SRC="$1" REPO="$2" OFFLINE="$3"

    if [ -d "$SRC/.git" ]; then
        if [ "$OFFLINE" -eq 1 ]; then
            log_info "Offline: using the cached clone as is"
            return 0
        fi
        log_info "Updating cached clone..."
        if git -C "$SRC" fetch --quiet --depth 1 origin HEAD 2>/dev/null \
           && git -C "$SRC" reset --quiet --hard FETCH_HEAD 2>/dev/null; then
            return 0
        fi
        log_warn "Update failed (network?) — using the cached clone as is"
        return 0
    fi

    if [ "$OFFLINE" -eq 1 ]; then
        log_error "--offline: no cached clone in $SRC (run 'o2 docs' once online)"
        return 1
    fi

    mkdir -p "$(dirname "$SRC")"
    log_info "Cloning $REPO (markdown files only)..."
    # Light clone: shallow, blobs fetched on demand, only docs/**/*.md checked
    # out (the full repository is ~140 MB, mostly images).
    if git clone --quiet --depth 1 --filter=blob:none --sparse "$REPO" "$SRC" 2>/dev/null \
       && git -C "$SRC" sparse-checkout set --no-cone '/docs/**/*.md' 2>/dev/null; then
        return 0
    fi

    log_warn "Light clone failed (old git or network?) — retrying with a plain shallow clone (large)"
    rm -rf "$SRC"
    git clone --quiet --depth 1 "$REPO" "$SRC" || {
        log_error "git clone failed: $REPO"
        return 1
    }
}

cmd_docs() {
    local OUT="" SECTIONS_ARG="" EXCLUDE="" ORDER="site" OFFLINE=0

    while [ $# -gt 0 ]; do
        case "$1" in
            --output|--sections|--exclude|--order)
                [ $# -ge 2 ] || { log_error "Option $1 needs a value"; exit 1; }
                case "$1" in
                    --output)   OUT="$2" ;;
                    --sections) SECTIONS_ARG="$2" ;;
                    --exclude)  EXCLUDE="$2" ;;
                    --order)    ORDER="$2" ;;
                esac
                shift 2 ;;
            --offline)   OFFLINE=1; shift ;;
            -h|--help)   _docs_help; return 0 ;;
            *)           log_error "Unknown option: $1"; _docs_help; exit 1 ;;
        esac
    done

    case "$ORDER" in
        site|path) ;;
        *) log_error "--order must be 'site' or 'path' (got: $ORDER)"; exit 1 ;;
    esac

    if ! command -v git &>/dev/null; then
        log_error "git not found — required for 'o2 docs'"
        exit 1
    fi

    local DOCS_DIR="${O2_DOCS_DIR:-$O2_LOCAL_DIR/docs}"
    local REPO="${O2_DOCS_REPO:-$_DOCS_DEFAULT_REPO}"
    local SRC="$DOCS_DIR/src"
    local DOCS_ROOT="$SRC/docs"
    OUT="${OUT:-$DOCS_DIR/alice_o2_docs.md}"

    # --- sections to build ----------------------------------------------------
    # BASE = configured list (used to detect new upstream sections);
    # SECTIONS = what is actually built after --sections / --exclude.
    local -a BASE SECTIONS KEPT
    local s
    if [ -n "${O2_DOCS_SECTIONS+x}" ] && [ -n "${O2_DOCS_SECTIONS[*]}" ]; then
        read -ra BASE <<< "${O2_DOCS_SECTIONS[*]}"
    else
        read -ra BASE <<< "$_DOCS_DEFAULT_SECTIONS"
    fi
    if [ -n "$SECTIONS_ARG" ]; then
        read -ra SECTIONS <<< "${SECTIONS_ARG//,/ }"
    else
        SECTIONS=("${BASE[@]}")
    fi
    if [ -n "$EXCLUDE" ]; then
        local EX=" ${EXCLUDE//,/ } "
        KEPT=()
        for s in "${SECTIONS[@]}"; do
            case "$EX" in *" $s "*) ;; *) KEPT+=("$s") ;; esac
        done
        SECTIONS=("${KEPT[@]}")
    fi
    if [ "${#SECTIONS[@]}" -eq 0 ]; then
        log_error "No section to build (check --sections / --exclude)"
        exit 1
    fi

    echo "========================================"
    echo "   o2 docs — O2 analysis-framework docs"
    echo "========================================"

    _docs_fetch "$SRC" "$REPO" "$OFFLINE" || exit 1
    if [ ! -d "$DOCS_ROOT" ]; then
        log_error "No docs/ directory in $SRC"
        exit 1
    fi
    local COMMIT
    COMMIT="$(git -C "$SRC" rev-parse --short HEAD 2>/dev/null || echo unknown)"
    log_info "Source : $REPO @ $COMMIT"
    log_info "Order  : $ORDER"

    # New upstream sections the configured list does not know about
    if [ -z "$SECTIONS_ARG" ]; then
        local d NAME
        for d in "$DOCS_ROOT"/*/; do
            NAME="$(basename "$d")"
            [ "$NAME" = "images" ] && continue
            [ -z "$(find "$d" -name '*.md' -print -quit 2>/dev/null)" ] && continue
            case " ${BASE[*]} " in *" $NAME "*) ;; *)
                log_warn "Section '$NAME' exists upstream but is not in O2_DOCS_SECTIONS — not included"
            ;; esac
        done
    fi

    # --- assemble ---------------------------------------------------------------
    mkdir -p "$(dirname "$OUT")"
    local TMP
    TMP="$(mktemp "${OUT}.XXXXXX")" || { log_error "Cannot write in $(dirname "$OUT")"; exit 1; }
    trap 'rm -f "$TMP"' RETURN

    local -a STATS=()
    local f N BEFORE AFTER TOTAL_FILES=0
    for s in "${SECTIONS[@]}"; do
        if [ ! -d "$DOCS_ROOT/$s" ]; then
            log_warn "Section '$s' not found in docs/ — skipped"
            continue
        fi
        BEFORE="$(wc -c < "$TMP")"
        N=0
        while IFS= read -r f; do
            {
                printf '\n\n---\n<!-- %s -->\n\n' "$f"
                _docs_strip "$DOCS_ROOT/$f"
            } >> "$TMP"
            N=$((N + 1))
        done < <(_docs_list_pages "$DOCS_ROOT" "$s" "$ORDER")
        AFTER="$(wc -c < "$TMP")"
        STATS+=("$s|$N|$((AFTER - BEFORE))")
        TOTAL_FILES=$((TOTAL_FILES + N))
    done

    if [ "$TOTAL_FILES" -eq 0 ]; then
        log_error "No page found — nothing written"
        return 1
    fi

    mv "$TMP" "$OUT"
    chmod 644 "$OUT"

    # --- summary ------------------------------------------------------------------
    local TOTAL_BYTES LARGEST="" LARGEST_BYTES=0 st name cnt bytes
    TOTAL_BYTES="$(wc -c < "$OUT")"
    log_step "Sections"
    printf '  %-22s %6s %12s\n' "section" "pages" "size"
    for st in "${STATS[@]}"; do
        IFS='|' read -r name cnt bytes <<< "$st"
        printf '  %-22s %6s %9s KB\n' "$name" "$cnt" "$((bytes / 1024))"
        if [ "$bytes" -gt "$LARGEST_BYTES" ]; then
            LARGEST="$name"; LARGEST_BYTES="$bytes"
        fi
    done
    log_sep
    log_info "Output : $OUT"
    log_info "Total  : $TOTAL_FILES pages, $((TOTAL_BYTES / 1024)) KB, $(wc -l < "$OUT") lines"
    if [ "$TOTAL_BYTES" -gt 1500000 ] && [ "$((LARGEST_BYTES * 2))" -gt "$TOTAL_BYTES" ]; then
        log_info "'$LARGEST' is over half of the file — leave it out with: o2 docs --exclude $LARGEST"
    fi
}
