# lib/analysis.sh
# Manage analysis registry (analysis.json) and sync user tasks to O2Physics.
#
# Sourced by o2.sh — never executed directly.

# ==============================================================================
# cmd_analysis
# Entry point for: o2 analysis [options]
# ==============================================================================
cmd_analysis() {
    local ACTION=""
    local TARGET=""
    local STATUS_VALUE=""
    local ARG2="" ARG3=""
    local FORCE=0

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --list)            ACTION="list"   ; shift ;;
            --enable)          ACTION="enable" ; TARGET="$2" ; shift 2 ;;
            --disable)         ACTION="disable"; TARGET="$2" ; shift 2 ;;
            --status)          ACTION="status" ; TARGET="$2" ; shift 2 ;;
            --set-status)      ACTION="set-status"; TARGET="$2"; STATUS_VALUE="$3"; shift 3 ;;
            --add-file)        ACTION="add-file"; TARGET="$2"; ARG2="$3"; shift 3 ;;
            --register)        ACTION="register"; TARGET="$2"; ARG2="$3"; ARG3="$4"; shift 4 ;;
            --promote)         ACTION="promote"; TARGET="$2"; shift 2 ;;
            --check-deps)      ACTION="check-deps"; TARGET="$2"; shift 2
                               # optional <production>: a positional word, not another option
                               if [[ $# -gt 0 && "$1" != -* ]]; then ARG2="$1"; shift; fi ;;
            --gen-config)      ACTION="gen-config"; TARGET="$2"; shift 2
                               # <production>: a positional word, not another option
                               if [[ $# -gt 0 && "$1" != -* ]]; then ARG2="$1"; shift; fi ;;
            --force)           FORCE=1; shift ;;
            --help|-h)         _analysis_help  ; return ;;
            *) log_error "Unknown option: $1" ; _analysis_help ; return 1 ;;
        esac
    done

    local REGISTRY="$O2_LOCAL_DIR/analysis/analysis.json"
    if [ ! -f "$REGISTRY" ]; then
        log_error "analysis.json not found at $REGISTRY"
        return 1
    fi

    # Idempotent: adds "status": "dev" to any entry that predates it.
    # No-op (and no write) once every entry already has one.
    _analysis_migrate_schema "$REGISTRY"

    case "$ACTION" in
        list)       _analysis_list        "$REGISTRY" ;;
        enable)     _analysis_toggle      "$REGISTRY" "$TARGET" true  ;;
        disable)    _analysis_toggle      "$REGISTRY" "$TARGET" false ;;
        status)     _analysis_show_status "$REGISTRY" "$TARGET" ;;
        set-status) _analysis_set_status  "$REGISTRY" "$TARGET" "$STATUS_VALUE" ;;
        add-file)   _analysis_add_file    "$REGISTRY" "$TARGET" "$ARG2" ;;
        register)   _analysis_register_task "$REGISTRY" "$TARGET" "$ARG2" "$ARG3" ;;
        promote)    _analysis_promote     "$REGISTRY" "$TARGET" "$FORCE" ;;
        check-deps) _analysis_check_deps "$TARGET" "$ARG2" ;;
        gen-config) _analysis_gen_config "$TARGET" "$ARG2" ;;
        *)          _analysis_list        "$REGISTRY" ;;
    esac
}

# ==============================================================================
# _analysis_migrate_schema
# Two migrations, both idempotent and safe to run on every 'o2 analysis'
# call — only writes the file if something was actually missing/legacy,
# so there is no separate migration step to remember:
#   1. add "status" (default "dev") to any entry that predates it.
#   2. fold the legacy "tasks[]" array (bare filename, single implicit
#      PWG from O2_PHYSICS_COMPONENTS) into "files[]" (full path) — the
#      two arrays covered the same concept with two different shapes
#      since Phase 5a; every reader now only looks at "files[]".
#      "tasks" is removed once folded.
# ==============================================================================
_analysis_migrate_schema() {
    local REGISTRY="$1"

    python3 - "$REGISTRY" "$O2_PHYSICS_COMPONENTS" << 'PYEOF'
import sys, json

registry_path, default_components = sys.argv[1:]
with open(registry_path) as f:
    data = json.load(f)

changed = False
for analysis in data.get("analysis", []):
    if "status" not in analysis:
        analysis["status"] = "dev"
        changed = True

    legacy_tasks = analysis.pop("tasks", None)
    if legacy_tasks:
        files = analysis.setdefault("files", [])
        existing_paths = {fe.get("path") for fe in files}
        for task in legacy_tasks:
            full_path = f"{default_components}/{task.get('file', '')}"
            if full_path not in existing_paths:
                files.append({
                    "path": full_path,
                    "dpl": task.get("dpl"),
                    "enabled": task.get("enabled", False),
                })
                existing_paths.add(full_path)
        changed = True
    elif legacy_tasks is not None:
        # was present but empty — still remove the now-unused key
        changed = True

if changed:
    with open(registry_path, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
PYEOF
}

# ==============================================================================
# _analysis_show_status
# Print the current lifecycle status of one analysis (dev|tested-local|
# tested-cluster|ready-for-pr|pr-open|pr-merged).
# ==============================================================================
_analysis_show_status() {
    local REGISTRY="$1"
    local TARGET="$2"

    if [ -z "$TARGET" ]; then
        log_error "Usage: o2 analysis --status <analysis>"
        return 1
    fi

    python3 - "$REGISTRY" "$TARGET" << 'PYEOF'
import sys, json

registry_path, name = sys.argv[1:]
with open(registry_path) as f:
    data = json.load(f)

for analysis in data.get("analysis", []):
    if analysis.get("name") == name:
        print(analysis.get("status", "dev"))
        sys.exit(0)

print(f"[ERROR]   Analysis not found: {name}", file=sys.stderr)
sys.exit(1)
PYEOF
}

# ==============================================================================
# _analysis_set_status
# Move an analysis's lifecycle status forward
# (dev -> tested-local -> tested-cluster -> ready-for-pr -> pr-open -> pr-merged).
#
# Refuses to *downgrade* an already-more-advanced status unless FORCE=1 is
# passed as a 4th argument — this is what lets 'o2 run' safely call
# 'set-status tested-local' after every successful run without ever
# silently undoing a manual '--promote' to ready-for-pr.
# ==============================================================================
_analysis_set_status() {
    local REGISTRY="$1"
    local TARGET="$2"
    local STATUS_VALUE="$3"
    local FORCE="${4:-0}"

    case "$STATUS_VALUE" in
        dev|tested-local|tested-cluster|ready-for-pr|pr-open|pr-merged) ;;
        *)
            log_error "Invalid status: '$STATUS_VALUE'"
            log_error "Valid values: dev, tested-local, tested-cluster, ready-for-pr, pr-open, pr-merged"
            return 1
            ;;
    esac

    python3 - "$REGISTRY" "$TARGET" "$STATUS_VALUE" "$FORCE" << 'PYEOF'
import sys, json

registry_path, name, new_status, force = sys.argv[1:]
force = force == "1"

RANK = {"dev": 0, "tested-local": 1, "tested-cluster": 2,
        "ready-for-pr": 3, "pr-open": 4, "pr-merged": 5}

with open(registry_path) as f:
    data = json.load(f)

for analysis in data.get("analysis", []):
    if analysis.get("name") != name:
        continue
    current = analysis.get("status", "dev")
    if not force and RANK.get(new_status, 0) < RANK.get(current, 0):
        print(f"[INFO]    {name}: status already '{current}' — not downgrading to '{new_status}'")
        sys.exit(0)
    analysis["status"] = new_status
    with open(registry_path, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    print(f"[INFO]    {name}: status -> {new_status}")
    sys.exit(0)

print(f"[ERROR]   Analysis not found: {name}", file=sys.stderr)
sys.exit(1)
PYEOF
}

# ==============================================================================
# _analysis_list
# Display all analyses and their tasks with enabled/disabled state.
# ==============================================================================
_analysis_list() {
    local REGISTRY="$1"

    log_sep
    log_info "Analysis registry: $REGISTRY"
    log_sep

    python3 - "$REGISTRY" << 'PYEOF'
import sys, json

with open(sys.argv[1]) as f:
    data = json.load(f)

for analysis in data.get("analysis", []):
    name        = analysis.get("name", "?")
    enabled     = analysis.get("enabled", False)
    description = analysis.get("description", "")
    life_status = analysis.get("status", "dev")

    on_off = "ON " if enabled else "OFF"
    print(f"  [{on_off}]  {name:<20} [{life_status:<13}] — {description}")

    files = analysis.get("files", [])
    for fentry in files:
        fpath    = fentry.get("path", "?")
        dpl      = fentry.get("dpl")
        fenabled = fentry.get("enabled", False)
        fstatus  = "ON " if fenabled else "OFF"
        label    = f"→ o2-analysis-{dpl}" if dpl else "(plain file, not a DPL task)"
        print(f"           [{fstatus}]  {fpath:<35} {label}")

    if not files:
        print(f"           (no tasks defined)")

PYEOF

    log_sep
}

# ==============================================================================
# _analysis_toggle
# Enable or disable an analysis or a specific task.
#
# TARGET formats:
#   "test"                    → toggle entire analysis
#   "test/testTask.cxx"       → toggle specific task in analysis
# ==============================================================================
_analysis_toggle() {
    local REGISTRY="$1"
    local TARGET="$2"
    local STATE="$3"   # true or false

    python3 - "$REGISTRY" "$TARGET" "$STATE" << 'PYEOF'
import sys, json

registry_path = sys.argv[1]
target        = sys.argv[2]
state         = sys.argv[3].lower() == "true"

with open(registry_path) as f:
    data = json.load(f)

# Parse target: "analysis" or "analysis/task.cxx"
parts = target.split("/", 1)
analysis_name = parts[0]
task_file     = parts[1] if len(parts) > 1 else None

found = False
for analysis in data.get("analysis", []):
    if analysis.get("name") != analysis_name:
        continue
    found = True

    if task_file is None:
        # Toggle entire analysis + all its tracked files
        analysis["enabled"] = state
        for fentry in analysis.get("files", []):
            fentry["enabled"] = state
        action = "Enabled" if state else "Disabled"
        print(f"[INFO]    {action} analysis: {analysis_name}")
    else:
        # Toggle a specific tracked file (full path, from --add-file;
        # a bare legacy filename also still matches if it was never
        # migrated to a full path for some reason).
        task_found = False
        for fentry in analysis.get("files", []):
            if fentry.get("path") == task_file or fentry.get("path", "").endswith(f"/{task_file}"):
                fentry["enabled"] = state
                task_found = True
                action = "Enabled" if state else "Disabled"
                print(f"[INFO]    {action} file: {analysis_name}/{task_file}")
                if state:
                    analysis["enabled"] = True
                break
        if not task_found:
            print(f"[ERROR]   File not found: {task_file} in analysis {analysis_name}")
            sys.exit(1)
    break

if not found:
    print(f"[ERROR]   Analysis not found: {analysis_name}")
    sys.exit(1)

with open(registry_path, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")

PYEOF

    local RC=$?
    if [ $RC -eq 0 ]; then
        log_info "Registry updated: $REGISTRY"
        log_info "Run 'o2 analysis --list' to verify"
        log_info "Run 'o2 build --rebuild-tasks' to recompile"
    fi
    return $RC
}

# ==============================================================================
# _analysis_get_enabled_tasks
# Read analysis.json and print "analysis_name full_path dpl_name" for
# every enabled DPL task in every enabled analysis. Used by
# _rebuild_tasks(). Reads "files[]" only — the legacy "tasks[]" schema
# is folded into it by _analysis_migrate_schema before this ever runs.
# ==============================================================================
_analysis_get_enabled_tasks() {
    local REGISTRY="$1"

    python3 - "$REGISTRY" << 'PYEOF'
import sys, json

registry_path = sys.argv[1]
with open(registry_path) as f:
    data = json.load(f)

for analysis in data.get("analysis", []):
    if not analysis.get("enabled", False):
        continue
    name = analysis.get("name", "")

    for fentry in analysis.get("files", []):
        if not fentry.get("enabled", False):
            continue
        if not fentry.get("dpl"):
            continue  # plain file, not a DPL task — nothing for _rebuild_tasks to do
        print(f"{name} {fentry.get('path', '')} {fentry.get('dpl', '')}")
PYEOF
}

# ==============================================================================
# _analysis_get_files
# Print "full_path dpl_or_dash" for every ENABLED file in "files[]"
# belonging to ONE analysis. Unlike _analysis_get_enabled_tasks (which
# only lists DPL tasks, across ALL enabled analyses, for
# _rebuild_tasks), this lists everything — plain files included — for a
# single named analysis, for 'o2 build --cut-pr' to know exactly which
# files belong in its PR branch. "-" means "plain file, not a DPL task".
# ==============================================================================
_analysis_get_files() {
    local REGISTRY="$1"
    local ANALYSIS="$2"

    python3 - "$REGISTRY" "$ANALYSIS" << 'PYEOF'
import sys, json

registry_path, analysis_name = sys.argv[1:]
with open(registry_path) as f:
    data = json.load(f)

for analysis in data.get("analysis", []):
    if analysis.get("name") != analysis_name:
        continue
    for fentry in analysis.get("files", []):
        if not fentry.get("enabled", False):
            continue
        dpl = fentry.get("dpl") or "-"
        print(f"{fentry.get('path', '')} {dpl}")
    break
PYEOF
}

# ==============================================================================
# _analysis_add_file
# Add (or re-attach) a file to an analysis: symlink
# analysis/<name>/code/<path> to the real file in the dev O2Physics
# worktree, creating the real file there first if it doesn't exist yet.
#
# Deliberately a symlink, not a copy: there is only ever one real file
# (tracked by git in the O2Physics clone) — editing through either path
# edits the same content, so there is nothing to keep "in sync".
# ==============================================================================
_analysis_add_file() {
    local REGISTRY="$1"
    local ANALYSIS="$2"
    local REL_PATH="$3"

    if [ -z "$ANALYSIS" ] || [ -z "$REL_PATH" ]; then
        log_error "Usage: o2 analysis --add-file <analysis> <path-in-O2Physics>"
        return 1
    fi
    if [ -z "$O2PHYSICS_SRC" ] || [ ! -d "$O2PHYSICS_SRC/.git" ]; then
        log_error "O2Physics not found at ${O2PHYSICS_SRC:-<unset>} — run 'o2 build' first"
        return 1
    fi

    local TARGET="$O2PHYSICS_SRC/$REL_PATH"
    local LOCAL_LINK="$O2_LOCAL_DIR/analysis/$ANALYSIS/code/$REL_PATH"

    if [ -e "$TARGET" ]; then
        log_info "File already exists in O2Physics — editing it in place: $REL_PATH"
    else
        mkdir -p "$(dirname "$TARGET")"
        if [[ "$REL_PATH" == *Tasks/*.cxx ]]; then
            _analysis_write_task_skeleton "$TARGET"
        else
            touch "$TARGET"
        fi
        log_info "Created new file in O2Physics: $REL_PATH"
    fi

    mkdir -p "$(dirname "$LOCAL_LINK")"
    if [ -L "$LOCAL_LINK" ] || [ -e "$LOCAL_LINK" ]; then
        rm -f "$LOCAL_LINK"
    fi
    ln -s "$TARGET" "$LOCAL_LINK"
    log_info "Linked: analysis/$ANALYSIS/code/$REL_PATH -> $TARGET"

    _analysis_registry_add_file "$REGISTRY" "$ANALYSIS" "$REL_PATH"
}

# ==============================================================================
# _analysis_write_task_skeleton
# Minimal, generic DPL task skeleton for a brand-new .../Tasks/*.cxx file.
# Deliberately NOT a copy of any existing analysis' task (the shipped
# 'template' analysis made that mistake — see the audit) — this is meant
# to compile as-is and be edited from here, nothing more.
# ==============================================================================
_analysis_write_task_skeleton() {
    local TARGET="$1"
    cat > "$TARGET" << 'CXXEOF'
// SPDX-License-Identifier: GPL-3.0-or-later
// Minimal task skeleton — adjust includes, table types and struct name.

#include "Framework/AnalysisTask.h"
#include "Framework/runDataProcessing.h"

using namespace o2;
using namespace o2::framework;

struct NewTask {
  void process(aod::Collisions const& collisions)
  {
    // TODO: implement
  }
};

WorkflowSpec defineDataProcessing(ConfigContext const& cfgc)
{
  return WorkflowSpec{
    adaptAnalysisTask<NewTask>(cfgc)};
}
CXXEOF
}

# ==============================================================================
# _analysis_registry_add_file
# JSON-side of _analysis_add_file: creates the analysis entry if it
# doesn't exist yet, and tracks the path under its "files" array (dpl:
# null until --register turns it into a DPL task).
# ==============================================================================
_analysis_registry_add_file() {
    local REGISTRY="$1"
    local ANALYSIS="$2"
    local REL_PATH="$3"

    python3 - "$REGISTRY" "$ANALYSIS" "$REL_PATH" << 'PYEOF'
import sys, json

registry_path, analysis_name, rel_path = sys.argv[1:]

with open(registry_path) as f:
    data = json.load(f)

entries = data.setdefault("analysis", [])
analysis = next((a for a in entries if a.get("name") == analysis_name), None)
if analysis is None:
    analysis = {
        "name": analysis_name,
        "enabled": False,
        "status": "dev",
        "description": "",
        "files": [],
    }
    entries.append(analysis)
    print(f"[INFO]    Created new analysis entry: {analysis_name}")

files = analysis.setdefault("files", [])
if any(fe.get("path") == rel_path for fe in files):
    print(f"[INFO]    Already tracked: {analysis_name}/{rel_path}")
else:
    files.append({"path": rel_path, "dpl": None, "enabled": False})
    print(f"[INFO]    Tracked: {analysis_name}/{rel_path}")

with open(registry_path, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PYEOF
}

# ==============================================================================
# _analysis_register_task
# Turn a tracked plain file into a DPL task: sets its "dpl" name in the
# registry. Only the JSON is touched here — actually patching
# CMakeLists.txt and copying it into the build happens on the next
# 'o2 build --rebuild-tasks' (Phase 5).
# ==============================================================================
_analysis_register_task() {
    local REGISTRY="$1"
    local ANALYSIS="$2"
    local REL_PATH="$3"
    local DPL="$4"

    if [ -z "$ANALYSIS" ] || [ -z "$REL_PATH" ] || [ -z "$DPL" ]; then
        log_error "Usage: o2 analysis --register <analysis> <path> <dpl-name>"
        return 1
    fi
    case "$REL_PATH" in
        */Tasks/*.cxx) ;;
        *)
            log_error "Only a .../Tasks/*.cxx file can be registered as a DPL task"
            log_error "'$REL_PATH' doesn't match that pattern"
            return 1
            ;;
    esac

    python3 - "$REGISTRY" "$ANALYSIS" "$REL_PATH" "$DPL" << 'PYEOF'
import sys, json

registry_path, analysis_name, rel_path, dpl = sys.argv[1:]

with open(registry_path) as f:
    data = json.load(f)

for analysis in data.get("analysis", []):
    if analysis.get("name") != analysis_name:
        continue
    files = analysis.setdefault("files", [])
    entry = next((fe for fe in files if fe.get("path") == rel_path), None)
    if entry is None:
        print(f"[ERROR]   {rel_path} isn't tracked in {analysis_name} yet "
              f"— run 'o2 analysis --add-file {analysis_name} {rel_path}' first", file=sys.stderr)
        sys.exit(1)
    entry["dpl"] = dpl
    entry.setdefault("enabled", False)
    with open(registry_path, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    print(f"[INFO]    Registered as DPL task: {analysis_name}/{rel_path} -> o2-analysis-{dpl}")
    print(f"[INFO]    Disabled by default — enable with: o2 analysis --enable {analysis_name}/{rel_path}")
    print(f"[INFO]    CMakeLists.txt will be patched on the next 'o2 build --rebuild-tasks'")
    sys.exit(0)

print(f"[ERROR]   Analysis not found: {analysis_name}", file=sys.stderr)
sys.exit(1)
PYEOF
}

# ==============================================================================
# _analysis_promote
# Move an analysis to "ready-for-pr" — the one status transition that is
# never automatic (see lifecycle in _analysis_set_status). Guards:
#   1. refuses below 'tested-cluster' unless FORCE=1
#   2. if this analysis touches anything outside its own .../Tasks/
#      (shared Core/DataModel/etc.), refuses unless every other ENABLED
#      analysis has itself been at least tested-local — unless FORCE=1
# ==============================================================================
_analysis_promote() {
    local REGISTRY="$1"
    local ANALYSIS="$2"
    local FORCE="${3:-0}"

    if [ -z "$ANALYSIS" ]; then
        log_error "Usage: o2 analysis --promote <analysis> [--force]"
        return 1
    fi

    local CURRENT
    CURRENT=$(_analysis_show_status "$REGISTRY" "$ANALYSIS") || return 1

    local RANK_CURRENT=0
    case "$CURRENT" in
        dev)             RANK_CURRENT=0 ;;
        tested-local)     RANK_CURRENT=1 ;;
        tested-cluster)   RANK_CURRENT=2 ;;
        ready-for-pr|pr-open|pr-merged) RANK_CURRENT=3 ;;
    esac

    if [ "$RANK_CURRENT" -lt 2 ] && [ "$FORCE" -ne 1 ]; then
        log_error "$ANALYSIS: status is '$CURRENT' — not yet tested on the cluster"
        log_error "Promoting untested code to ready-for-pr is exactly what this guards against."
        log_error "Test it first ('o2 run $ANALYSIS --hpc'), or override with --force"
        return 1
    fi

    local TOUCHES_SHARED
    TOUCHES_SHARED=$(python3 - "$REGISTRY" "$ANALYSIS" << 'PYEOF'
import sys, json, re
registry_path, name = sys.argv[1:]
with open(registry_path) as f:
    data = json.load(f)
for a in data.get("analysis", []):
    if a.get("name") != name:
        continue
    for fe in a.get("files", []):
        if not re.match(r".*/Tasks/[^/]+\.cxx$", fe.get("path", "")):
            print("1")
            sys.exit(0)
print("0")
PYEOF
)

    if [ "$TOUCHES_SHARED" = "1" ] && [ "$FORCE" -ne 1 ]; then
        local UNTESTED
        UNTESTED=$(python3 - "$REGISTRY" "$ANALYSIS" << 'PYEOF'
import sys, json
registry_path, name = sys.argv[1:]
RANK = {"dev": 0, "tested-local": 1, "tested-cluster": 2,
        "ready-for-pr": 3, "pr-open": 4, "pr-merged": 5}
with open(registry_path) as f:
    data = json.load(f)
bad = [a.get("name") for a in data.get("analysis", [])
       if a.get("name") != name and a.get("enabled", False)
       and RANK.get(a.get("status", "dev"), 0) < 1]
print(",".join(bad))
PYEOF
)
        if [ -n "$UNTESTED" ]; then
            log_error "$ANALYSIS touches shared O2Physics code outside its own Tasks/ dir"
            log_error "These other active analyses haven't been retested since: $UNTESTED"
            log_error "Retest them, or override with --force if you're confident it's unaffected"
            return 1
        fi
    fi

    _analysis_set_status "$REGISTRY" "$ANALYSIS" "ready-for-pr"
}

_analysis_help() {
    cat << 'EOF'
o2 analysis [options]

Manage the analysis registry (analysis.json).

Options:
  --list                       list all analyses and tasks with their state
  --enable  <target>           enable an analysis or a specific task/file
  --disable <target>           disable an analysis or a specific task/file
  --status  <analysis>         print an analysis's lifecycle status
  --set-status <analysis> <s>  set it directly — mainly for scripting;
                                prefer '--promote' for ready-for-pr
  --add-file <analysis> <path> add/attach a file at <path> in O2Physics
                                (symlinked into analysis/<name>/code/<path>;
                                created there first if it doesn't exist yet)
  --register <analysis> <path> <dpl>
                                turn a tracked .../Tasks/*.cxx file into a
                                DPL task (CMakeLists patched on next
                                'o2 build --rebuild-tasks')
  --promote <analysis> [--force]
                                mark ready-for-pr (see guards below)
  --check-deps <analysis> [<production>]
                               best-effort check that every table consumed
                                by the active task chain has a producer also
                                active in the chain (wraps find_dependencies.py
                                — see 'o2 tools deps'). With a <production>,
                                tables stored in the AO2D itself are checked
                                against a real input file: a cached one, else
                                ONE sample file is downloaded to the data cache.
                                It also checks that EVERY table the chain reads
                                from the file (asked by a task, produced by no
                                other active task) is in that file, with its
                                exact version (e.g. a legacy converter asking
                                for TRACKEXTRA v0 on a file that only has v2).
  --gen-config <analysis> <production>
                                regenerate analysis/<analysis>/dpl-config.json:
                                runs the active task chain on ONE real AO2D of
                                <production> (a cached one, else one sample file
                                is downloaded) and keeps the configuration DPL
                                dumps when it exits. OVERWRITES the file.
  --help                       show this help

Target formats (for --enable/--disable):
  test                         entire analysis (all tasks/files)
  test/testTask.cxx            a legacy task (bare filename)
  proxies/PWGJE/Tasks/foo.cxx  a file added via --add-file (full path)

Lifecycle status:
  dev -> tested-local -> tested-cluster -> ready-for-pr -> pr-open -> pr-merged
  The first two steps are set automatically by 'o2 run'; ready-for-pr is
  always a deliberate '--promote' — never automatic.

--promote guards:
  - refuses below 'tested-cluster' (override: --force)
  - if the analysis touches anything outside its own .../Tasks/ (shared
    Core/DataModel/etc.), refuses unless every other ENABLED analysis has
    itself been retested since (override: --force)

Examples:
  o2 analysis --list
  o2 analysis --add-file proxies PWGJE/Tasks/taskNew.cxx
  o2 analysis --register proxies PWGJE/Tasks/taskNew.cxx je-new-task
  o2 analysis --enable   proxies/PWGJE/Tasks/taskNew.cxx
  o2 analysis --promote  proxies
  o2 analysis --disable  test/testTask.cxx
  o2 analysis --check-deps proxies
  o2 analysis --check-deps proxies LHC24aj
  o2 analysis --gen-config test LHC25f3

After enabling tasks, rebuild with:
  o2 build --rebuild-tasks
  o2 deploy --build-only

EOF
}


# ------------------------------------------------------------------------------
# Input-file inspection helpers for
#   o2 analysis --check-deps <analysis> <production>
#
# Idea: some tables flagged by find_dependencies.py are NOT produced by a task
# at all, they are stored in the AO2D file itself. For those, the input file
# answers the question definitively, which beats guessing from the table name.
# Tables that are computed at runtime (e.g. pidTPCFull*) never exist in the
# file, so the file can neither confirm nor refute them.
# ------------------------------------------------------------------------------

# _analysis_find_local_ao2d <production>
# Prints the host path of one already-downloaded AO2D.root of this production
# (any run), or returns 1 when there is none.
_analysis_find_local_ao2d() {
    local PROD="$1" F
    [ -d "$DATA_BASE/$PROD" ] || return 1
    F=$(find "$DATA_BASE/$PROD" -name AO2D.root -type f -print -quit 2>/dev/null)
    [ -n "$F" ] || return 1
    echo "$F"
}

# _analysis_fetch_sample_ao2d <production>
# Downloads ONE AO2D.root (first file of the first run that has any) into the
# shared data cache, using get_aod.sh in sample mode, and prints its host path.
# Sample mode writes no group files, so it cannot disturb a real 'o2 run' of
# the same production, and that run will reuse the file instead of fetching it
# again. Only the final path goes to stdout (the caller captures it).
_analysis_fetch_sample_ao2d() {
    local PROD="$1"
    local GET_AOD_SCRIPT="$SCRIPTS_DIR/get_aod.sh"
    [ -f "$GET_AOD_SCRIPT" ] || { echo "get_aod.sh not found in $SCRIPTS_DIR" >&2; return 1; }

    _check_grid_token || return 1
    mkdir -p "$DATA_BASE/$PROD"

    local OUT LINE
    OUT=$(_o2_container \
        -B "$(dirname "$GET_AOD_SCRIPT"):/workdir_scripts" \
        -B "$DATA_BASE:/data" \
        -- bash -c "
            export O2_PRODUCTION='$PROD'
            export O2_RUNS='all'
            export O2_DATA_MODE='local'
            export O2_SAMPLE_ONLY=1
            export O2_PARALLEL_STREAMS='${O2_PARALLEL_STREAMS:-4}'
            export ALICE_CERN_USER='$ALICE_CERN_USER'
            bash /workdir_scripts/get_aod.sh
        " 2>&1) || { echo "$OUT" | grep '^\[' | tail -25 >&2; return 1; }

    LINE=$(echo "$OUT" | grep '^SAMPLE_FILE=' | tail -1)
    [ -n "$LINE" ] || { echo "$OUT" | grep '^\[' | tail -25 >&2; return 1; }
    echo "$DATA_BASE/${LINE#SAMPLE_FILE=/data/}"
}

# _analysis_list_trees <host_file>
# Lists the TTree names inside the FIRST DF_* directory of an AO2D.root (all
# DFs of a file normally hold the same set of trees). Emits marker lines:
#   ###DF### <dir> (of N)      ###TREE### <name>      ###ERROR### <message>
# Never fails on its own: any problem (file unreadable, PyROOT missing...)
# comes back as an ###ERROR### line so the caller can fall back cleanly.
_analysis_list_trees() {
    local HOST_FILE="$1"
    local CONT_FILE="/data/${HOST_FILE#$DATA_BASE/}"
    local PY='
import sys
try:
    import ROOT
    ROOT.gErrorIgnoreLevel = ROOT.kError
    f = ROOT.TFile.Open(sys.argv[1])
    if not f or f.IsZombie():
        print("###ERROR### cannot open " + sys.argv[1])
        sys.exit(0)
    dfs = sorted(k.GetName() for k in f.GetListOfKeys() if k.GetName().startswith("DF_"))
    if not dfs:
        print("###ERROR### no DF_ directory in the file")
        sys.exit(0)
    d = f.Get(dfs[0])
    print("###DF### " + dfs[0] + " (of " + str(len(dfs)) + ")")
    for k in d.GetListOfKeys():
        print("###TREE### " + k.GetName())
except Exception as e:
    print("###ERROR### " + str(e))
'
    _o2_container -B "$DATA_BASE:/data" \
        -- bash -c 'python3 -c "$1" "$2"' bash "$PY" "$CONT_FILE" 2>&1
}

# _analysis_file_need <TABLE like AOD/TRACKEXTRA_002> <trees>
# Pure function (no I/O): is a table the chain READS from the input file really
# in it, with this exact version? <trees> as for _analysis_file_verdict.
# Present  -> prints nothing, returns 0.
# Missing  -> prints ONE line "<KIND>|<trees of this table found in the file>"
#             and returns 1. KIND is
#   NEWER  the file only has newer version(s): a task asks for an older one
#   OLDER  the file only has older version(s): a converter must produce it
#   OTHER  the file has other versions, some older and some newer
#   NONE   the file has no version of this table at all
_analysis_file_need() {
    local TABLE="$1" TREES="$2"
    local NAME="${TABLE#*/}"
    NAME="${NAME,,}"
    _analysis_tree_present "$NAME" "$TREES" && return 0

    local BASE="${NAME%_[0-9][0-9][0-9]}"
    local NEED=0
    if [[ "$NAME" =~ _([0-9]{3})$ ]]; then NEED=$((10#${BASH_REMATCH[1]})); fi

    local FOUND
    FOUND=$(grep -E "^${BASE}(_[0-9]{3})?$" <<< "$TREES" | tr '\n' ' ')
    FOUND="${FOUND% }"
    if [ -z "$FOUND" ]; then
        echo "NONE|"
        return 1
    fi

    local T V NEWER=0 OLDER=0
    for T in $FOUND; do
        V=0
        if [[ "$T" =~ _([0-9]{3})$ ]]; then V=$((10#${BASH_REMATCH[1]})); fi
        if [ "$V" -gt "$NEED" ]; then NEWER=1; else OLDER=1; fi
    done
    if   [ "$NEWER" -eq 1 ] && [ "$OLDER" -eq 0 ]; then echo "NEWER|$FOUND"
    elif [ "$OLDER" -eq 1 ] && [ "$NEWER" -eq 0 ]; then echo "OLDER|$FOUND"
    else echo "OTHER|$FOUND"
    fi
    return 1
}

# _analysis_tree_present <lowercase-name> <newline-separated trees>
_analysis_tree_present() {
    grep -qxF -- "$1" <<< "$2"
}

# _analysis_file_verdict <TABLE like AOD/BC_001> <trees>
# Pure function (no I/O): what does the input file say about this table?
# <trees> = newline-separated tree names, lowercased, without the "O2" prefix.
# Prints exactly one verdict:
#   PROVIDED          the table is stored in the file -> no producer needed
#   SPAWNED           extended table (EX<base>) whose stored <base> is present:
#                     the framework builds it in memory, no producer needed
#   CONVERTER_NEEDED  the file only has an OLDER version of a versioned table:
#                     the converter listed as producer really is required
#   MC_ABSENT         an MC table, and the file has no MC trees at all: harmless
#   MC_INPUT_UNSEEN   an MC table, the file HAS MC trees, but not this one
#                     (or its name differs from what we derive): verify by hand
#   UNKNOWN           the file says nothing (e.g. runtime-computed tables)
# Name mapping (table AOD/FOO_001 -> tree O2foo_001) follows the O2 docs'
# Troubleshooting page (missing table DF_<id>/O2v0dataext = table v0dataext).
# The EX-prefix rule and the "any older version" rule are NOT covered by that
# page: they are inferred from the naming seen in real output, so validate
# them on the first real file (the summary prints the trees it found).
_analysis_file_verdict() {
    local TABLE="$1" TREES="$2"
    local NAME="${TABLE#AOD/}"
    NAME="${NAME,,}"

    if _analysis_tree_present "$NAME" "$TREES"; then
        echo PROVIDED; return
    fi

    if [[ "$NAME" == ex* ]]; then
        local BASE="${NAME#ex}"
        if _analysis_tree_present "$BASE" "$TREES"; then
            echo SPAWNED; return
        fi
        NAME="$BASE"     # judge the extended table through its base table
    fi

    if [[ "$NAME" =~ ^(.+)_[0-9]{3}$ ]]; then
        local OLD="${BASH_REMATCH[1]}"
        if _analysis_tree_present "$OLD" "$TREES" || grep -qE "^${OLD}_[0-9]{3}$" <<< "$TREES"; then
            echo CONVERTER_NEEDED; return
        fi
    fi

    if [[ "$NAME" == mc* ]]; then
        if grep -q '^mc' <<< "$TREES"; then
            echo MC_INPUT_UNSEEN
        else
            echo MC_ABSENT
        fi
        return
    fi

    echo UNKNOWN
}

# ==============================================================================
# _analysis_gen_config <analysis> <production>
# 'o2 analysis --gen-config <analysis> <production>'
#
# Overwrites analysis/<analysis>/dpl-config.json with a fresh dump straight
# from the binaries, instead of trusting whatever is currently committed.
#
# Why this exists: comparing a real fresh dump against the committed
# analysis/test/dpl-config.json showed its section names (e.g.
# "trackselection", "track-propagation") don't match any real device name
# in the current build at all (real names: "track-selection",
# "propagation-service") — a silent, total mismatch, not a partial one.
# That means no section in that file was actually being read by DPL; the
# pipeline was running on compiled-in defaults the whole time, coincidentally.
#
# How the dump happens (from reading O2's Framework/Core/src/
# runDataProcessing.cxx, not yet confirmed by a run here): the DPL DRIVER
# writes dpl-config.json to its CURRENT WORKING DIRECTORY when it reaches
# its EXIT state, from the "[CONFIG] key=value" lines the devices reported
# while starting. So the devices must really start and the driver must exit
# cleanly (a SIGTERM from 'timeout' is fine, SIGKILL is not). Starting the
# devices needs a real input: with no --aod-file the AOD reader device stops
# with "No input file defined!", and an empty '@list' makes the metadata
# discovery abort with: Couldn't open file "". Hence the <production>
# argument: this finds (or downloads ONE sample of) an AO2D.root of that
# production, replaces the --aod-file argument by it, strips any
# "--configuration json://..." MakeScriptO2() added, and runs the pipe under
# a timeout in a scratch directory, then moves the dpl-config.json that
# appeared into place.
#
# The AO2D's metadata (data/MC, anchor, reco pass) can change what services
# auto-configure, so the production you pick is the one the defaults are
# dumped for. The dump also records the sample file in the
# internal-dpl-aod-reader section (aod-file-private); that key is removed
# from the result (see the comment before PY_STRIP below), because a device
# with a JSON section reads its options from the JSON, so a leftover value
# would override the --aod-file of every later 'o2 run'.
#
# NOT verified against a real multi-task piped chain: the timeout
# (O2_GENCONFIG_TIMEOUT, default 120 s) and whether the driver dumps when
# the timeout cuts the run short are unconfirmed. Check the output of a
# first real run of this command before trusting it blindly.
#
# Deliberately overwrites, no diff against the old file: the old file has
# already been shown unreliable, so there is nothing trustworthy to merge
# against. If you had hand-tuned values in the old file, they are gone
# after this runs — re-apply them to the new file yourself if still needed.
# ==============================================================================
_analysis_gen_config() {
    local ANALYSIS="$1"
    local PRODUCTION="${2:-}"
    [ -z "$ANALYSIS" ] && { log_error "usage: o2 analysis --gen-config <analysis> <production>"; return 1; }
    if [ -z "$PRODUCTION" ]; then
        log_error "gen-config: a <production> is required (DPL needs a real AO2D to start)"
        log_error "usage: o2 analysis --gen-config $ANALYSIS <production>"
        [ -d "$DATA_BASE" ] && log_info "Productions in $DATA_BASE: $(ls "$DATA_BASE" 2>/dev/null | tr '\n' ' ')"
        return 1
    fi

    local WF_DIR="$O2_LOCAL_DIR/analysis/$ANALYSIS"
    local TASKS_FILE="$WF_DIR/config_tasks.sh"
    [ -f "$TASKS_FILE" ] || { log_error "$TASKS_FILE not found"; return 1; }

    local PIPE_OUTPUT
    PIPE_OUTPUT=$(source "$TASKS_FILE"; MakeScriptO2 2>/dev/null) \
        || { log_error "MakeScriptO2() failed in $TASKS_FILE"; return 1; }

    # One real AO2D of this production: a cached one, else download ONE
    # sample into the shared data cache (same helpers as --check-deps).
    local SAMPLE_HOST=""
    if SAMPLE_HOST=$(_analysis_find_local_ao2d "$PRODUCTION"); then
        log_info "Input file (cached locally): $SAMPLE_HOST"
    else
        log_info "No local AO2D found for $PRODUCTION — downloading one sample file"
        SAMPLE_HOST=$(_analysis_fetch_sample_ao2d "$PRODUCTION") || {
            log_error "gen-config: could not obtain a sample AO2D for $PRODUCTION"
            return 1
        }
    fi
    local CONT_FILE="/data/${SAMPLE_HOST#$DATA_BASE/}"

    # Strip any --configuration json://... flag so DPL falls back to its
    # own compiled-in defaults and dumps them fresh, instead of reading
    # (and perpetuating) whatever is already on disk. Also replace the
    # --aod-file argument (an '@${FILELIST}' that is unset here, hence the
    # old 'Couldn't open file ""') by the real sample file.
    local PIPE_RUN
    PIPE_RUN=$(echo "$PIPE_OUTPUT" | sed -E \
        -e 's#--configuration json://[^[:space:]]*##g' \
        -e "s#--aod-file[[:space:]]+[^[:space:]]+#--aod-file ${CONT_FILE}#")

    load_apptainer
    local WORK_DIR
    WORK_DIR=$(mktemp -d)

    log_step "Generating a fresh dpl-config.json for '$ANALYSIS' (compiled-in defaults, input: $PRODUCTION)"

    # Full output goes to a log file (the screen only shows the tail), so a
    # device that exits with an error can be diagnosed afterwards.
    local GEN_LOG="${LOG_DIR:-$O2_LOCAL_DIR/logs}/gen-config-$ANALYSIS.log"
    mkdir -p "$(dirname "$GEN_LOG")"

    # The pipe is passed as a positional argument ($2), not spliced inside
    # quotes, so a quote in it cannot break the command.
    _o2_container \
        -B "$WORK_DIR:/genconfig" \
        -B "$DATA_BASE:/data" \
        -- bash -c 'cd /genconfig && timeout "$1" bash -c "$2"' \
        bash "${O2_GENCONFIG_TIMEOUT:-120}" "$PIPE_RUN" \
        2>&1 | tee "$GEN_LOG" | tail -30
    log_info "gen-config: full output in $GEN_LOG"

    if [ ! -f "$WORK_DIR/dpl-config.json" ]; then
        log_error "gen-config: no dpl-config.json was produced — see the output above"
        log_error "(the driver only dumps on a clean exit; try a longer O2_GENCONFIG_TIMEOUT)"
        rm -rf "$WORK_DIR"
        return 1
    fi

    # The dump records the sample input in the reader's section
    # (internal-dpl-aod-reader / aod-file-private). When a device has a JSON
    # section, DPL reads its options from that JSON on top of the compiled-in
    # defaults, and the default of aod-file-private is the --aod-file given
    # on the command line. A leftover value here would therefore make every
    # 'o2 run' read this sample file instead of its own filelist. Dropping the
    # key restores the default. Done with the container's python3 (same
    # pattern as --check-deps); the file is rewritten with 4-space indent.
    local PY_STRIP='
import json, sys
p = sys.argv[1]
with open(p) as f:
    d = json.load(f)
r = d.get("internal-dpl-aod-reader")
if isinstance(r, dict):
    r.pop("aod-file-private", None)
with open(p, "w") as f:
    json.dump(d, f, indent=4)
    f.write("\n")
'
    if _o2_container -B "$WORK_DIR:/genconfig" \
        -- bash -c 'python3 -c "$1" /genconfig/dpl-config.json' bash "$PY_STRIP" 2>&1; then
        log_info "gen-config: removed the sample input (aod-file-private) from the reader section"
    else
        log_warn "gen-config: could not strip aod-file-private — delete that line by hand before committing"
    fi

    local DEST="$WF_DIR/dpl-config.json"
    cp "$WORK_DIR/dpl-config.json" "$DEST"
    rm -rf "$WORK_DIR"

    log_info "gen-config: wrote $DEST"
    log_info "Sections now in this file:"
    grep -oE '^    "[^"]+":' "$DEST" | sed 's/^    "/    /; s/":$//'
    grep -q '"aod-file-private"' "$DEST" && \
        log_warn "aod-file-private is still in the file — delete it before committing"
    log_warn "Any hand-tuned values from the previous file are gone — re-apply by hand if still needed"
}

# ==============================================================================
# _analysis_check_deps <analysis> [<production>]
# 'o2 analysis --check-deps <analysis> [<production>]'
#
# Best-effort dependency check for a workflow's config_tasks.sh: sources the
# file and calls MakeScriptO2() for real (reflecting the DOO2_* switches as
# actually set, not every task name merely present in the file text), then
# for each active task uses O2Physics' own find_dependencies.py (the exact
# tool behind 'o2 tools deps') to list the tables it consumes, and checks
# that at least one producer of each table is also active in the chain.
#
# Limitation: when a table has several valid producers (e.g. AOD/TRACKDCA
# can come from either o2-analysis-trackextension or
# o2-analysis-track-propagation), this only checks that ANY of them is
# present — it does not arbitrate which one you actually meant. A clean
# report here does not guarantee the chain is semantically correct, only
# that no producer is obviously missing.
#
# Requires O2Physics to have been built at least once (find_dependencies.py
# reads the installed package, not the sources) — see 'o2 build'.
# ==============================================================================
_analysis_check_deps() {
    local ANALYSIS="$1"
    local PRODUCTION="${2:-}"

    local TASKS_FILE="$O2_LOCAL_DIR/analysis/$ANALYSIS/config_tasks.sh"
    [ -f "$TASKS_FILE" ] || { log_error "$TASKS_FILE not found"; return 1; }

    # Source + call MakeScriptO2() for real, exactly as
    # _generate_workflow_script (lib/run.sh) does — this reflects the
    # DOO2_* switches actually set, not every task name that merely
    # appears somewhere in the file.
    local PIPE_OUTPUT
    PIPE_OUTPUT=$(source "$TASKS_FILE"; MakeScriptO2 2>/dev/null) \
        || { log_error "MakeScriptO2() failed in $TASKS_FILE"; return 1; }

    local -a CHAIN=()
    mapfile -t CHAIN < <(echo "$PIPE_OUTPUT" | grep -oE '\bo2-analysis[a-zA-Z0-9-]*\b' | sort -u)

    if [ "${#CHAIN[@]}" -eq 0 ]; then
        log_warn "No task activated in $TASKS_FILE — nothing to check"
        return 0
    fi

    log_step "Checking dependency chain for '$ANALYSIS' (${#CHAIN[@]} task(s) active)"
    printf '    %s\n' "${CHAIN[@]}"

    load_apptainer

    # Pass 1: what does each active task genuinely need, right now, given
    # its actual configuration — not "what could any of its process
    # functions possibly need" (which is what find_dependencies.py -w
    # answers, and why it used to flag pidTPCFull*/RUN2BCINFO_001/etc. as
    # gaps even though they sit behind a process switch nobody turns on).
    #
    # Reads each task's own dumped workflow spec directly
    # ($O2PHYSICS_ROOT/share/dpl/<task>.json — generated by the binary
    # itself via --dump-workflow, one file per executable). Every input
    # carries "control:default" (always subscribed) or one or more
    # "control:<device>/process<X>" keys (subscribed only if that process
    # is active) — confirmed by inspecting real dumps for trackselection
    # (control:default only, never ambiguous) and propagation-service
    # (processRealData=1 by default, processRealDataWithPID=0 — exactly
    # why its pidTPCFull* inputs are NOT genuinely needed by default).
    #
    # "Active" per process key: the matching key in dpl-config.json's
    # section for that device if one exists (section keys are NOT
    # guaranteed to match the device name — e.g. dpl-config.json's
    # "track-propagation" vs. this device's real name "propagation-service"
    # — so an exact-name section lookup can legitimately miss; when it
    # does, this falls back to the JSON's own defaultValue and says so,
    # rather than silently guessing a match).
    #
    # Known blind spot: a plain numeric/boolean option that changes
    # behaviour without changing any declared "control:" subscription
    # (trackselection's "isRun3" is exactly this) is invisible here by
    # construction — this reads what DPL will SUBSCRIBE to, not what the
    # C++ does once it has the data. Worth a manual look at the task's
    # .cxx if a result here still looks wrong.
    local CFG_DIR
    CFG_DIR="$(dirname "$TASKS_FILE")"
    log_info "Using dpl-config.json: $CFG_DIR/dpl-config.json (run 'o2 analysis --gen-config $ANALYSIS' if unsure it's current)"

    local PY_CONTROL='
import json, sys, os

def format_table(origin, description, subspec):
    name = origin + "/" + description
    try:
        n = int(subspec)
    except Exception:
        n = 0
    if n > 0:
        name += "_%03d" % n
    return name

def load_json(path):
    try:
        with open(path) as f:
            return json.load(f)
    except Exception:
        return {}

def main():
    dpl_root = os.environ.get("O2PHYSICS_ROOT", "")
    config_path = sys.argv[1]
    dpl_config = load_json(config_path)

    for line in sys.stdin:
        task = line.strip()
        if not task:
            continue
        print("###TASK### " + task)
        json_path = os.path.join(dpl_root, "share", "dpl", task + ".json")
        if not os.path.isfile(json_path):
            print("###MISSING-JSON### " + json_path)
            continue
        try:
            with open(json_path) as f:
                spec = json.load(f)
        except Exception as e:
            print("###PARSE-ERROR### " + str(e))
            continue

        wf_list = spec.get("workflow", [])
        if not wf_list:
            continue
        device = wf_list[0]
        device_name = device.get("name", "")
        section = dpl_config.get(device_name)
        if section is None:
            print("###NO-CONFIG-SECTION### " + device_name)

        for inp in device.get("inputs", []):
            origin = inp.get("origin", "")
            description = inp.get("description", "")
            subspec = inp.get("subspec", 0)
            table = format_table(origin, description, subspec)
            meta = inp.get("metadata", [])
            control_keys = []
            for m in meta:
                nm = str(m.get("name", ""))
                if nm.startswith("control:"):
                    control_keys.append(m)

            if not control_keys:
                print("###ACTIVE### " + table)
                continue

            active = False
            for ck in control_keys:
                cname = ck.get("name", "")
                if cname == "control:default":
                    active = True
                    break
                if "/" in cname:
                    proc = cname.split("/", 1)[1]
                else:
                    proc = cname
                if section is not None and proc in section:
                    val = str(section[proc]).strip().lower()
                else:
                    val = str(ck.get("defaultValue", "0")).strip().lower()
                if val == "1" or val == "true":
                    active = True
                    break

            if active:
                print("###ACTIVE### " + table)

main()
'

    # Second pass (only used when a <production> is given): which tables does
    # the chain READ FROM THE INPUT FILE? Same rules as DPL itself, taken from
    # Framework/Core/src/WorkflowHelpers.cxx (injectServiceDevices):
    #   - an AOD-origin input is read from the file unless another active task
    #     produces exactly that table (same origin/description/version);
    #   - an input carrying "projectors" is an EXTENDED table (EXTRACK...): DPL
    #     spawns it, unless a task produces it, from the base table(s) named by
    #     its "input:<name>" metadata, and THOSE are read from the file;
    #   - "index-records" (index tables) and "ccdb:" inputs are not file tables;
    #   - an input with lifetime Optional (7) is not required;
    #   - an input is only requested when its "control:" switch is on (same
    #     rule as the first pass).
    # Every device of every executable is read (an executable can hold several
    # devices, e.g. tracks-extra-converter + tracks-extra-spawner). The table
    # version is the subspec: AOD/TRACKEXTRA subspec 2 = tree O2trackextra_002.
    # Output markers: ###FILE-NEED### <table><TAB><who>  ###NOTE###  ###SKIPPED###
    local PY_FILEREQ='
import json, os, sys

AOD_ORIGINS = ("AOD", "AOD1", "AOD2", "EMB", "AMD")
OPTIONAL = 7

def fmt(origin, description, subspec):
    name = origin + "/" + description
    try:
        n = int(subspec)
    except Exception:
        n = 0
    if n > 0:
        name += "_%03d" % n
    return name

def kind(item):
    names = [str(m.get("name", "")) for m in item.get("metadata", [])]
    if "projectors" in names:
        return "DYN"
    if "index-records" in names:
        return "IDX"
    if any(n.startswith("ccdb:") for n in names):
        return "TIM"
    return "PLAIN"

def is_active(inp, section):
    ctl = [m for m in inp.get("metadata", []) if str(m.get("name", "")).startswith("control:")]
    if not ctl:
        return True
    for ck in ctl:
        cname = str(ck.get("name", ""))
        if cname == "control:default":
            return True
        proc = cname.split("/", 1)[1] if "/" in cname else cname
        if section is not None and proc in section:
            val = str(section[proc]).strip().lower()
        else:
            val = str(ck.get("defaultValue", "0")).strip().lower()
        if val in ("1", "true"):
            return True
    return False

def base_of(value):
    parts = str(value).split("/")
    if len(parts) != 4:
        return None
    return fmt(parts[1], parts[2], parts[3])

def main():
    dpl_root = os.environ.get("O2PHYSICS_ROOT", "")
    try:
        with open(sys.argv[1]) as f:
            config = json.load(f)
    except Exception:
        config = {}
    needs = {}
    req_dyn = []
    prov_aod = set()
    prov_dyn = set()
    idx = set()
    for line in sys.stdin:
        exe = line.strip()
        if not exe:
            continue
        path = os.path.join(dpl_root, "share", "dpl", exe + ".json")
        try:
            with open(path) as f:
                spec = json.load(f)
        except Exception as e:
            print("###SKIPPED### " + exe + ": " + str(e))
            continue
        for dev in spec.get("workflow", []):
            dname = dev.get("name", "")
            who = exe + " [" + dname + "]"
            section = config.get(dname)
            for inp in dev.get("inputs", []):
                origin = inp.get("origin", "")
                table = fmt(origin, inp.get("description", ""), inp.get("subspec", 0))
                try:
                    if int(inp.get("lifetime", 0)) == OPTIONAL:
                        continue
                except Exception:
                    pass
                if not is_active(inp, section):
                    continue
                k = kind(inp)
                if k == "PLAIN":
                    if origin in AOD_ORIGINS:
                        needs.setdefault(table, {}).setdefault(who, [False, set()])[0] = True
                elif k == "DYN":
                    bases = []
                    for m in inp.get("metadata", []):
                        if str(m.get("name", "")).startswith("input:"):
                            b = base_of(m.get("defaultValue", ""))
                            if b:
                                bases.append(b)
                    req_dyn.append((table, who, bases))
                elif k == "IDX":
                    idx.add(table)
            for out in dev.get("outputs", []):
                origin = out.get("origin", "")
                if origin not in AOD_ORIGINS:
                    continue
                table = fmt(origin, out.get("description", ""), out.get("subspec", 0))
                k = kind(out)
                if k == "PLAIN":
                    prov_aod.add(table)
                elif k == "DYN":
                    prov_dyn.add(table)
    for table, who, bases in req_dyn:
        if table in prov_dyn:
            continue
        for b in bases:
            needs.setdefault(b, {}).setdefault(who, [False, set()])[1].add(table)
    for table in sorted(needs):
        if table in prov_aod:
            continue
        parts = []
        for who in sorted(needs[table]):
            direct, vias = needs[table][who]
            vias = sorted(vias)
            if direct and vias:
                parts.append(who + " (also through " + ", ".join(vias) + ")")
            elif vias:
                parts.append(who + " (through " + ", ".join(vias) + ")")
            else:
                parts.append(who)
        print("###FILE-NEED### " + table + "\t" + "; ".join(parts))
    if idx:
        print("###NOTE### " + str(len(idx)) + " index table(s) are built from other tables and were not expanded")

main()
'

    local TASKS_LIST
    TASKS_LIST=$(printf '%s\n' "${CHAIN[@]}")

    local RAW1
    RAW1=$(_o2_container \
        -B "$CFG_DIR:/analysis_cfg" \
        -- bash -c 'python3 -c "$1" /analysis_cfg/dpl-config.json <<< "$2"' \
        bash "$PY_CONTROL" "$TASKS_LIST" 2>&1)

    local -A WF_INPUTS=()      # task -> space-separated tables it genuinely needs
    local -A NEEDED_BY=()      # table -> space-separated task(s) that need it
    local -a NO_CONFIG_NOTES=()
    local ANY_LOOKUP_FAILED=0
    local CUR=""
    while IFS= read -r LINE; do
        case "$LINE" in
            "###TASK### "*)
                CUR="${LINE#"###TASK### "}"
                WF_INPUTS["$CUR"]=""
                ;;
            "###MISSING-JSON### "*)
                log_warn "[$CUR] no dumped workflow spec found: ${LINE#"###MISSING-JSON### "} — is it built?"
                ANY_LOOKUP_FAILED=1
                ;;
            "###PARSE-ERROR### "*)
                log_warn "[$CUR] could not parse its workflow spec: ${LINE#"###PARSE-ERROR### "}"
                ANY_LOOKUP_FAILED=1
                ;;
            "###NO-CONFIG-SECTION### "*)
                NO_CONFIG_NOTES+=("$CUR (device '${LINE#"###NO-CONFIG-SECTION### "}')")
                ;;
            "###ACTIVE### "*)
                local T="${LINE#"###ACTIVE### "}"
                WF_INPUTS["$CUR"]+="$T "
                NEEDED_BY["$T"]+="$CUR "
                ;;
        esac
    done <<< "$RAW1"

    if [ "${#NO_CONFIG_NOTES[@]}" -gt 0 ]; then
        log_info "No matching dpl-config.json section (using the task's own JSON defaults):"
        printf '    %s\n' "${NO_CONFIG_NOTES[@]}"
    fi

    if [ "${#NEEDED_BY[@]}" -eq 0 ]; then
        if [ "$ANY_LOOKUP_FAILED" -eq 1 ]; then
            log_error "check-deps: no table could be resolved — see warning(s) above"
            return 1
        fi
        log_info "check-deps: no input tables resolved — nothing to check"
        return 0
    fi

    local TABLES_LIST
    TABLES_LIST=$(printf '%s\n' "${!NEEDED_BY[@]}")

    local RAW2
    RAW2=$(_o2_container -- bash -c '
        SCRIPT="$O2PHYSICS_ROOT/share/scripts/find_dependencies.py"
        while IFS= read -r TABLE; do
            [ -z "$TABLE" ] && continue
            echo "###TABLE### $TABLE"
            "$SCRIPT" -t "$TABLE" 2>&1
        done <<< "$1"
    ' bash "$TABLES_LIST" 2>&1)

    local -A TABLE_PRODUCERS=()
    CUR=""
    while IFS= read -r LINE; do
        if [[ "$LINE" == "###TABLE### "* ]]; then
            CUR="${LINE#"###TABLE### "}"
            TABLE_PRODUCERS["$CUR"]=""
        elif [ -n "$CUR" ]; then
            TABLE_PRODUCERS["$CUR"]+="$LINE"$'\n'
        fi
    done <<< "$RAW2"

    # Resolve each raw producer-lookup block into a plain list of names now,
    # so the rest of the function works with simple space-separated strings
    # (as WF_INPUTS/NEEDED_BY already do) instead of raw tool output.
    local -A PRODUCERS_OF=()
    local T
    for T in "${!TABLE_PRODUCERS[@]}"; do
        local -a P=()
        mapfile -t P < <(echo "${TABLE_PRODUCERS[$T]}" | grep -oE "'[a-zA-Z0-9-]+'" | tr -d "'")
        PRODUCERS_OF["$T"]="${P[*]}"
    done

    # Optional: check a real input file to settle cases find_dependencies.py
    # cannot — it only knows the static producer graph, not what a specific
    # AO2D file actually contains (an old vs. new table version, or whether
    # MC-only trees exist at all in this file). Local cache first, one
    # sample download as a fallback.
    local TREES=""
    if [ -n "$PRODUCTION" ] && [ "${#NEEDED_BY[@]}" -gt 0 ]; then
        local SAMPLE_HOST=""
        if SAMPLE_HOST=$(_analysis_find_local_ao2d "$PRODUCTION"); then
            log_info "Input file (cached locally): $SAMPLE_HOST"
        else
            log_info "No local AO2D found for $PRODUCTION — downloading one sample file"
            log_info "(first file found; it stays in the data cache for later runs)"
            SAMPLE_HOST=$(_analysis_fetch_sample_ao2d "$PRODUCTION") || {
                log_warn "Could not obtain a sample AO2D — checking without it"
                SAMPLE_HOST=""
            }
        fi
        if [ -n "$SAMPLE_HOST" ]; then
            local TREE_RAW
            TREE_RAW=$(_analysis_list_trees "$SAMPLE_HOST") || true
            if ! echo "$TREE_RAW" | grep -q '^###\(TREE\|ERROR\)###'; then
                log_warn "Unexpected answer while reading the input file (last lines):"
                echo "$TREE_RAW" | tail -3 | sed 's/^/    /'
            elif echo "$TREE_RAW" | grep -q '^###ERROR###'; then
                log_warn "Could not read the input file: $(echo "$TREE_RAW" | grep '^###ERROR###' | head -1 | sed 's/^###ERROR### //')"
            else
                TREES=$(echo "$TREE_RAW" | grep '^###TREE### ' | sed 's/^###TREE### //' \
                        | sed -E 's/^O2//' | tr 'A-Z' 'a-z')
                if [ -z "$TREES" ]; then
                    log_warn "The input file lists no trees — checking without it"
                else
                    log_info "Checked against $(echo "$TREE_RAW" | grep '^###DF###' | head -1 | sed 's/^###DF### //'): $(echo "$TREES" | wc -l) trees"
                    log_info "(ONE file only: a production mixing reconstruction passes may differ)"
                fi
            fi
        fi
    fi

    # Second pass: every table the chain reads from the input file must be in
    # it, with its exact version. This is independent of the producer check
    # below, which cannot see this problem: a table nobody produces is assumed
    # to come from the file, without ever asking the file.
    local -i FILE_GAPS=0
    if [ -n "$TREES" ]; then
        local RAW3 LINE3 FT FW NAME3 RES3 KIND3 FOUND3 NOTE3
        local -i N_FILE_TABLES=0
        RAW3=$(_o2_container \
            -B "$CFG_DIR:/analysis_cfg" \
            -- bash -c 'python3 -c "$1" /analysis_cfg/dpl-config.json <<< "$2"' \
            bash "$PY_FILEREQ" "$TASKS_LIST" 2>&1)

        echo
        while IFS= read -r LINE3; do
            case "$LINE3" in
                "###SKIPPED### "*)
                    log_warn "file check: skipped ${LINE3#"###SKIPPED### "}"
                    ;;
                "###NOTE### "*)
                    log_info "file check: ${LINE3#"###NOTE### "}"
                    ;;
                "###FILE-NEED### "*)
                    LINE3="${LINE3#"###FILE-NEED### "}"
                    FT="${LINE3%%$'\t'*}"
                    FW="${LINE3#*$'\t'}"
                    N_FILE_TABLES+=1
                    if RES3=$(_analysis_file_need "$FT" "$TREES"); then
                        continue
                    fi
                    KIND3="${RES3%%|*}"
                    FOUND3="${RES3#*|}"
                    NAME3="${FT#*/}"
                    NAME3="${NAME3,,}"
                    case "$KIND3" in
                        NEWER) NOTE3="the file only has a NEWER version ($FOUND3): a task asks for an older one — typically a legacy converter or an outdated task" ;;
                        OLDER) NOTE3="the file only has an OLDER version ($FOUND3): a converter producing the version needed must be active" ;;
                        OTHER) NOTE3="the file has other version(s) of it ($FOUND3), none matching" ;;
                        *)     NOTE3="the file has no version of this table, and no active task produces it" ;;
                    esac
                    FILE_GAPS+=1
                    log_error "$FT: read from the input file, but tree O2${NAME3} is NOT in it"
                    echo "    $NOTE3"
                    echo "    needed by: $FW"
                    case "$KIND3" in
                        NEWER) echo "    FIX: deactivate the task(s) above in config_tasks.sh for this production" ;;
                        OLDER) echo "    FIX: activate a converter that produces exactly this version (the one listed is not enough), or use a production whose files contain it" ;;
                        *)     echo "    FIX: deactivate the task(s) above for this production, or use a production whose files contain this table" ;;
                    esac
                    echo
                    ;;
            esac
        done <<< "$RAW3"

        if [ "$N_FILE_TABLES" -eq 0 ]; then
            log_warn "file check: could not work out which tables the chain reads from the file — output:"
            echo "$RAW3" | tail -5 | sed 's/^/    /'
        elif [ "$FILE_GAPS" -eq 0 ]; then
            log_info "check-deps: all $N_FILE_TABLES table(s) the chain reads from the input file are present, with the exact version"
        else
            log_error "check-deps: $FILE_GAPS of $N_FILE_TABLES table(s) the chain reads from the input file are MISSING from it"
        fi
    elif [ -z "$PRODUCTION" ]; then
        log_info "(give a <production> to also check the tables the chain reads from the input file)"
    fi

    # Group by TABLE, not by missing producer: a table with two alternative
    # producers (e.g. an old vs. a new converter) is only a real gap if
    # NEITHER is active — grouping by producer would otherwise tell you to
    # activate both, which are mutually exclusive.
    local -a GAP_TABLES=()
    local P C
    for T in "${!NEEDED_BY[@]}"; do
        local -a PRODUCERS=()
        read -ra PRODUCERS <<< "${PRODUCERS_OF[$T]:-}"
        [ "${#PRODUCERS[@]}" -eq 0 ] && continue   # base AOD table, no producer needed at all
        local SATISFIED=0
        for P in "${PRODUCERS[@]}"; do
            for C in "${CHAIN[@]}"; do [ "$P" = "$C" ] && SATISFIED=1 && break 2; done
        done
        [ "$SATISFIED" -eq 0 ] && GAP_TABLES+=("$T")
    done

    if [ "${#GAP_TABLES[@]}" -eq 0 ] && [ "$ANY_LOOKUP_FAILED" -eq 0 ]; then
        if [ "$FILE_GAPS" -gt 0 ]; then
            log_info "producer check: no producer is missing in the chain (direct needs only)"
            log_error "check-deps: FAILED — the input file lacks table(s) the chain reads from it (see above)"
            return 1
        fi
        log_info "check-deps: chain is complete — every table your active tasks need"
        log_info "directly has a producer also active (direct needs only — does not"
        log_info "follow what a candidate producer would itself need in turn)"
        return 0
    fi

    echo
    local ANY_REAL_GAP=0
    local -a SORTED_GAPS=()
    mapfile -t SORTED_GAPS < <(printf '%s\n' "${GAP_TABLES[@]}" | sort)

    for T in "${SORTED_GAPS[@]}"; do
        local VERDICT=""
        [ -n "$TREES" ] && VERDICT=$(_analysis_file_verdict "$T" "$TREES")
        case "$VERDICT" in
            PROVIDED|SPAWNED) continue ;;   # already covered by the input file: not a gap
            MC_ABSENT)        continue ;;   # MC-only table, no MC in this file: harmless
        esac
        ANY_REAL_GAP=1

        local -a CANDIDATES=()
        mapfile -t CANDIDATES < <(printf '%s\n' ${PRODUCERS_OF[$T]} | sort)

        local NOTE=""
        case "$VERDICT" in
            CONVERTER_NEEDED) NOTE=" — confirmed: your input file only has an OLDER version of this table" ;;
            MC_INPUT_UNSEEN)  NOTE=" — your input file has MC trees, but not this exact one: verify by hand" ;;
            "")
                if [[ "$T" =~ _[0-9]{3}$ ]]; then
                    NOTE=" — versioned table: whether you need this depends on your input format (pass a <production> to check)"
                fi
                ;;
        esac

        log_error "$T$NOTE"
        echo "    needed by: ${NEEDED_BY[$T]}"
        if [ "${#CANDIDATES[@]}" -eq 1 ]; then
            echo "    FIX: activate ${CANDIDATES[0]} in config_tasks.sh"
        else
            echo "    FIX: activate ONE of (not both): ${CANDIDATES[*]}"
        fi
        echo
    done

    if [ "$ANY_LOOKUP_FAILED" -eq 1 ]; then
        log_warn "check-deps: one or more tasks could not be looked up — see warnings above"
    fi

    if [ "$ANY_REAL_GAP" -eq 0 ]; then
        if [ "$FILE_GAPS" -gt 0 ]; then
            log_info "producer check: no producer is missing in the chain (every candidate was ruled out by the input file)"
            log_error "check-deps: FAILED — the input file lacks table(s) the chain reads from it (see above)"
            return 1
        fi
        log_info "check-deps: no action needed — every candidate producer above was ruled out"
        log_info "by your input file (already-satisfied table, or no MC content)"
        return 0
    fi

    log_error "check-deps: dependency gap(s) found — see FIX line(s) above"
    return 1
}
