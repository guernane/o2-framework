#!/bin/bash
# ==============================================================================
# lib/clean.sh
# Removes old AO2D data, run outputs, or O2Physics dev-build versions,
# locally and/or on the HPC cluster (over SSH).
#
# Executes by default. Pass --dry-run to preview without deleting.
# ==============================================================================

_clean_help() {
    cat << 'EOF'
o2 clean data    [<production>]            (--all|--keep N) (--local|--remote|--both) [--dry-run]
o2 clean outputs [<workflow>/<production>] (--all|--keep N) (--local|--remote|--both) [--dry-run]
o2 clean builds  (--local|--remote|--both) [--dry-run] [--aggressive]

Three independent categories:
  data      Downloaded AO2D files (data/<production>/) — only relevant when
            using O2_DATA_MODE=local; irrelevant in alien mode.
  outputs   Run output directories (analysis/<wf>/output/<production>/).
  builds    Delegates to aliBuild's own native 'aliBuild clean' command
            (run inside the container), which safely removes everything
            NOT referenced by a "latest-*" symlink — this covers old
            dev-local* package versions as well as sw/BUILD/, sw/TARS/,
            sw/INSTALLROOT/ leftovers that a hand-rolled cleanup would
            miss or could corrupt. Pass --aggressive for aliBuild's
            --aggressive-cleanup (frees more space, but can break cached
            builds that reference removed tarballs — see aliBuild issue
            alisw/alibuild#412). No --all/--keep/<name> for this category:
            aliBuild's clean is holistic, not selective by version.

Use 'o2 list' first to see what exists (exact names, sizes, dates) for the
data and outputs categories before choosing what to remove.

Selecting what to remove (data / outputs only):
  <name>      Remove exactly that one item. Cannot be combined with --both.
  --all       Remove everything in the category.
  --keep N    Remove everything except the N most recently modified items.

data/outputs execute immediately by default; pass --dry-run to preview.
builds always runs aliBuild's own --dry-run first unless you omit it — see
above (aliBuild's dry-run is native, not a wrapper approximation).

--local/--remote/--both is mandatory — there is no default, to avoid
accidentally acting on the wrong machine.

Examples:
  o2 list --both
  o2 clean outputs test/LHC22o --local
  o2 clean outputs --keep 3 --local
  o2 clean outputs --all --remote --dry-run
  o2 clean data LHC22o --local
  o2 clean builds --local --dry-run
  o2 clean builds --local
  o2 clean builds --remote --aggressive
EOF
}

# ------------------------------------------------------------------------------
# Listing helpers — print: date \t size \t name \t path [\t marker]
# ------------------------------------------------------------------------------
_clean_list_data_local() {
    find "$O2_LOCAL_DIR/data" -mindepth 1 -maxdepth 1 -type d 2>/dev/null \
        | while read -r d; do
            printf "%s\t%s\t%s\t%s\n" "$(date -r "$d" '+%Y-%m-%d %H:%M')" "$(du -sh "$d" 2>/dev/null | cut -f1)" "$(basename "$d")" "$d"
        done | sort -r
}

_clean_list_outputs_local() {
    find "$O2_LOCAL_DIR/analysis" -mindepth 3 -maxdepth 3 -type d -path "*/output/*" 2>/dev/null \
        | while read -r d; do
            local PROD WF NAME
            PROD="$(basename "$d")"
            WF="$(basename "$(dirname "$(dirname "$d")")")"
            NAME="$WF/$PROD"
            printf "%s\t%s\t%s\t%s\n" "$(date -r "$d" '+%Y-%m-%d %H:%M')" "$(du -sh "$d" 2>/dev/null | cut -f1)" "$NAME" "$d"
        done | sort -r
}

_clean_list_builds_local() {
    local O2DIR="$O2_LOCAL_DIR/sw/slc9_x86-64/O2Physics"
    [ -d "$O2DIR" ] || return

    _clean_print_active_versions

    local ACTIVE
    ACTIVE="$(readlink -f "$O2DIR/latest" 2>/dev/null || readlink -f "$O2DIR/latest-dev-o2" 2>/dev/null)"
    find "$O2DIR" -mindepth 1 -maxdepth 1 -type d -name "dev-local*" 2>/dev/null \
        | while read -r d; do
            local MARK=""
            [ "$(readlink -f "$d")" = "$ACTIVE" ] && MARK="ACTIVE"
            printf "%s\t%s\t%s\t%s\t%s\n" "$(date -r "$d" '+%Y-%m-%d %H:%M')" "$(du -sh "$d" 2>/dev/null | cut -f1)" "$(basename "$d")" "$d" "$MARK"
        done | sort -r
}

# ------------------------------------------------------------------------------
# _clean_print_active_versions
# Prints a short summary of the currently active O2 and O2Physics versions,
# using alienv q (the same modulefile system aliBuild itself relies on) as
# the authoritative source, plus the O2Physics fork's current git branch
# and commit (since it's a dev package, tracked in git, not just a tag).
# ------------------------------------------------------------------------------
_clean_print_active_versions() {
    log_info "Active versions:"

    load_apptainer
    local O2_VERSIONS O2PHYSICS_VERSIONS
    O2_VERSIONS="$(_o2_container_raw -- alienv q "^O2/" 2>/dev/null)"
    O2PHYSICS_VERSIONS="$(_o2_container_raw -- alienv q "^O2Physics/" 2>/dev/null)"

    local O2PHYSICS_ACTIVE
    O2PHYSICS_ACTIVE="$(echo "$O2PHYSICS_VERSIONS" | grep -iE "::latest(-dev-o2)?$" | tail -1)"

    log_info "  O2 (latest* tags):"
    echo "$O2_VERSIONS" | grep -iE "::latest" | sed 's/^/    /'
    log_info "  O2Physics  : ${O2PHYSICS_ACTIVE:-unknown}"

    if [ -d "$O2_LOCAL_DIR/sw/O2Physics/.git" ]; then
        local BRANCH COMMIT
        BRANCH="$(git -C "$O2_LOCAL_DIR/sw/O2Physics" rev-parse --abbrev-ref HEAD 2>/dev/null)"
        COMMIT="$(git -C "$O2_LOCAL_DIR/sw/O2Physics" log -1 --format='%h %s' 2>/dev/null)"
        log_info "  fork branch: $BRANCH ($COMMIT)"
    fi
    echo ""
}

# ------------------------------------------------------------------------------
# _clean_path_for_name — resolve a category + short name to its absolute path
# ------------------------------------------------------------------------------
_clean_path_for_name() {
    local CATEGORY="$1"
    local NAME="$2"

    case "$CATEGORY" in
        data)
            echo "$O2_LOCAL_DIR/data/$NAME"
            ;;
        outputs)
            local WF="${NAME%%/*}"
            local PROD="${NAME#*/}"
            echo "$O2_LOCAL_DIR/analysis/$WF/output/$PROD"
            ;;
        builds)
            echo "$O2_LOCAL_DIR/sw/slc9_x86-64/O2Physics/$NAME"
            ;;
    esac
}

# ------------------------------------------------------------------------------
# _clean_active_build_path — resolve target of the "latest" symlink, if any
# ------------------------------------------------------------------------------
_clean_active_build_path() {
    local O2DIR="$O2_LOCAL_DIR/sw/slc9_x86-64/O2Physics"
    readlink -f "$O2DIR/latest" 2>/dev/null || readlink -f "$O2DIR/latest-dev-o2" 2>/dev/null
}

# ------------------------------------------------------------------------------
# _clean_remove_one — $1 path, $2 category, $3 DRY_RUN(0|1)
# ------------------------------------------------------------------------------
_clean_remove_one() {
    local TARGET="$1"
    local CATEGORY="$2"
    local DRY_RUN="$3"

    if [ ! -e "$TARGET" ]; then
        log_warn "Not found, skipping: $TARGET"
        return
    fi

    if [ "$CATEGORY" = "builds" ]; then
        local ACTIVE
        ACTIVE="$(_clean_active_build_path)"
        if [ -n "$ACTIVE" ] && [ "$(readlink -f "$TARGET")" = "$ACTIVE" ]; then
            log_warn "Skipping ACTIVE build (never removed): $TARGET"
            return
        fi
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        log_info "[dry-run] would remove: $TARGET ($(du -sh "$TARGET" 2>/dev/null | cut -f1))"
    else
        rm -rf "$TARGET" && log_info "Removed: $TARGET"
    fi
}

# ------------------------------------------------------------------------------
# _clean_builds_local
# Delegates entirely to aliBuild's own native 'aliBuild clean' command,
# run inside the container. Verified against alibuild_helpers/clean.py:
# aliBuild's decideClean() removes $workDir/TMP, $workDir/INSTALLROOT,
# any $workDir/BUILD/* not referenced by a BUILD/*-latest* symlink, and
# any $workDir/<arch>/<package>/<version> not referenced by that package's
# own latest* symlink (covers our dev-local* dirs) — plus, with
# --aggressive-cleanup, $workDir/TARS/<arch>/store and $workDir/SOURCES.
# This is more complete and more trustworthy than a hand-rolled rm -rf on
# just dev-local* (which would miss BUILD/, INSTALLROOT/, etc.).
# ------------------------------------------------------------------------------
_clean_builds_local() {
    local DRY_RUN="$1"
    local AGGRESSIVE="$2"

    local ARGS=(clean --work-dir /alice/sw)
    [ "$DRY_RUN" -eq 1 ]    && ARGS+=(--dry-run)
    [ "$AGGRESSIVE" -eq 1 ] && ARGS+=(--aggressive-cleanup)

    load_apptainer
    _o2_container_raw -- aliBuild "${ARGS[@]}"
}

# ------------------------------------------------------------------------------
# _clean_category_local — handles the data/outputs categories, local machine
# args: $1 CATEGORY  $2 NAME(may be empty)  $3 ALL(0|1)  $4 KEEP(may be empty)
#       $5 DRY_RUN(0|1)
# ------------------------------------------------------------------------------
_clean_category_local() {
    local CATEGORY="$1"
    local NAME="$2"
    local ALL="$3"
    local KEEP="$4"
    local DRY_RUN="$5"

    if [ -n "$NAME" ]; then
        local TARGET
        TARGET="$(_clean_path_for_name "$CATEGORY" "$NAME")"
        _clean_remove_one "$TARGET" "$CATEGORY" "$DRY_RUN"
        return
    fi

    local LIST
    case "$CATEGORY" in
        data)    LIST="$(_clean_list_data_local)" ;;
        outputs) LIST="$(_clean_list_outputs_local)" ;;
        builds)  LIST="$(_clean_list_builds_local)" ;;
    esac

    [ -z "$LIST" ] && { log_info "Nothing found for category '$CATEGORY'"; return; }

    local KEPT
    if [ "$ALL" -eq 1 ]; then
        KEPT=""
    else
        KEPT="$(echo "$LIST" | head -n "$KEEP")"
    fi

    echo "$LIST" | while IFS=$'\t' read -r _date _size name path _mark; do
        if [ -n "$KEPT" ] && echo "$KEPT" | grep -qF "$path"; then
            continue
        fi
        _clean_remove_one "$path" "$CATEGORY" "$DRY_RUN"
    done
}



cmd_clean() {
    # Handle help option first
    if [[ "$1" == "--help" || "$1" == "-h" ]]; then
        _clean_help
        return 0
    fi
    local ARGS=("$@")

    local CATEGORY="${ARGS[0]:-}"
    case "$CATEGORY" in
        data|outputs|builds) ;;
        *)
            log_error "First argument must be: list, data, outputs, or builds"
            _clean_help
            exit 1
            ;;
    esac
    shift

    local NAME=""
    local ALL=0
    local KEEP=""
    local WHERE=""
    local DRY_RUN=0
    local AGGRESSIVE=0

    while [ $# -gt 0 ]; do
        case "$1" in
            --all)        ALL=1 ;;
            --keep)       shift; KEEP="$1" ;;
            --local)      WHERE="local" ;;
            --remote)     WHERE="remote" ;;
            --both)       WHERE="both" ;;
            --dry-run)    DRY_RUN=1 ;;
            --aggressive) AGGRESSIVE=1 ;;
            --help|-h)    _clean_help; return 0 ;;
            --*)          log_warn "Unknown option: $1" ;;
            *)            NAME="$1" ;;
        esac
        shift
    done

    [ -z "$WHERE" ] && { log_error "specify --local, --remote, or --both (no default, by design)"; exit 1; }

    if [ "$CATEGORY" = "builds" ]; then
        [ -n "$NAME" ] && { log_error "'builds' does not take a <name> — it delegates to aliBuild's own clean"; exit 1; }
        if [ "$ALL" -eq 1 ] || [ -n "$KEEP" ]; then
            log_error "'builds' does not support --all/--keep — it delegates to aliBuild's own clean"
            exit 1
        fi

        local REMOTE_HOST="${O2_HPC_USER}@${O2_HPC_HOST}"
        if [ "$WHERE" = "local" ] || [ "$WHERE" = "both" ]; then
            log_step "Local — builds (aliBuild clean)"
            _clean_builds_local "$DRY_RUN" "$AGGRESSIVE"
        fi
        if [ "$WHERE" = "remote" ] || [ "$WHERE" = "both" ]; then
            log_step "Remote — builds (aliBuild clean)"
            local REMOTE_ARGS=(builds --local)
            [ "$DRY_RUN" -eq 1 ]    && REMOTE_ARGS+=(--dry-run)
            [ "$AGGRESSIVE" -eq 1 ] && REMOTE_ARGS+=(--aggressive)
            ssh "$REMOTE_HOST" "$O2_HPC_HOME_DIR/o2.sh" clean "${REMOTE_ARGS[@]}"
        fi
        return
    fi

    if [ -n "$NAME" ]; then
        [ "$WHERE" = "both" ] && { log_error "a specific <name> does not support --both — pick --local or --remote"; exit 1; }
    else
        if [ "$ALL" -eq 0 ] && [ -z "$KEEP" ]; then
            log_error "specify a <name>, or --all, or --keep N"
            exit 1
        fi
        [ "$ALL" -eq 1 ] && [ -n "$KEEP" ] && { log_error "--all and --keep are mutually exclusive"; exit 1; }
    fi

    local REMOTE_HOST="${O2_HPC_USER}@${O2_HPC_HOST}"

    if [ "$WHERE" = "local" ] || [ "$WHERE" = "both" ]; then
        log_step "Local — $CATEGORY"
        _clean_category_local "$CATEGORY" "$NAME" "$ALL" "$KEEP" "$DRY_RUN"
    fi

    if [ "$WHERE" = "remote" ] || [ "$WHERE" = "both" ]; then
        log_step "Remote — $CATEGORY"
        local REMOTE_ARGS=("$CATEGORY")
        [ -n "$NAME" ] && REMOTE_ARGS+=("$NAME")
        [ "$ALL" -eq 1 ] && REMOTE_ARGS+=(--all)
        [ -n "$KEEP" ] && REMOTE_ARGS+=(--keep "$KEEP")
        REMOTE_ARGS+=(--local)
        [ "$DRY_RUN" -eq 1 ] && REMOTE_ARGS+=(--dry-run)
        ssh "$REMOTE_HOST" "$O2_HPC_HOME_DIR/o2.sh" clean "${REMOTE_ARGS[@]}"
    fi
}
