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
        *)          _analysis_list        "$REGISTRY" ;;
    esac
}

# ==============================================================================
# _analysis_migrate_schema
# Ensure every analysis entry has a "status" field (default "dev" for
# anything written before this field existed). Runs on every 'o2 analysis'
# call — safe to call repeatedly, only writes the file if something was
# actually missing, so there is no separate migration step to remember.
# ==============================================================================
_analysis_migrate_schema() {
    local REGISTRY="$1"

    python3 - "$REGISTRY" << 'PYEOF'
import sys, json

registry_path = sys.argv[1]
with open(registry_path) as f:
    data = json.load(f)

changed = False
for analysis in data.get("analysis", []):
    if "status" not in analysis:
        analysis["status"] = "dev"
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
    tasks       = analysis.get("tasks", [])

    on_off = "ON " if enabled else "OFF"
    print(f"  [{on_off}]  {name:<20} [{life_status:<13}] — {description}")

    for task in tasks:
        tfile   = task.get("file", "?")
        dpl     = task.get("dpl", "?")
        tenabled = task.get("enabled", False)
        tstatus = "ON " if tenabled else "OFF"
        print(f"           [{tstatus}]  {tfile:<35} → o2-analysis-{dpl}")

    files = analysis.get("files", [])
    for fentry in files:
        fpath    = fentry.get("path", "?")
        dpl      = fentry.get("dpl")
        fenabled = fentry.get("enabled", False)
        fstatus  = "ON " if fenabled else "OFF"
        label    = f"→ o2-analysis-{dpl}" if dpl else "(plain file, not a DPL task)"
        print(f"           [{fstatus}]  {fpath:<35} {label}")

    if not tasks and not files:
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
        # Toggle entire analysis + all its tasks and tracked files
        analysis["enabled"] = state
        for task in analysis.get("tasks", []):
            task["enabled"] = state
        for fentry in analysis.get("files", []):
            fentry["enabled"] = state
        action = "Enabled" if state else "Disabled"
        print(f"[INFO]    {action} analysis: {analysis_name}")
    else:
        # Toggle specific task — check the legacy tasks[] array first
        # (bare filename), then files[] (full path, from --add-file).
        task_found = False
        for task in analysis.get("tasks", []):
            if task.get("file") == task_file:
                task["enabled"] = state
                task_found = True
                action = "Enabled" if state else "Disabled"
                print(f"[INFO]    {action} task: {analysis_name}/{task_file}")
                if state:
                    analysis["enabled"] = True
                break
        if not task_found:
            for fentry in analysis.get("files", []):
                if fentry.get("path") == task_file:
                    fentry["enabled"] = state
                    task_found = True
                    action = "Enabled" if state else "Disabled"
                    print(f"[INFO]    {action} file: {analysis_name}/{task_file}")
                    if state:
                        analysis["enabled"] = True
                    break
        if not task_found:
            print(f"[ERROR]   Task/file not found: {task_file} in analysis {analysis_name}")
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
# _rebuild_tasks(). Merges both schemas so callers never need to know
# which one an entry came from:
#   - legacy "tasks[]"  (bare filename) -> full path computed against the
#     single default O2_PHYSICS_COMPONENTS directory (the only location
#     that schema ever supported)
#   - new "files[]"     (full path, from --add-file/--register) -> used
#     as-is, already correct for any PWG or shared location
# ==============================================================================
_analysis_get_enabled_tasks() {
    local REGISTRY="$1"

    python3 - "$REGISTRY" "$O2_PHYSICS_COMPONENTS" << 'PYEOF'
import sys, json

registry_path, default_components = sys.argv[1:]
with open(registry_path) as f:
    data = json.load(f)

for analysis in data.get("analysis", []):
    if not analysis.get("enabled", False):
        continue
    name = analysis.get("name", "")

    for task in analysis.get("tasks", []):
        if not task.get("enabled", False):
            continue
        full_path = f"{default_components}/{task.get('file', '')}"
        print(f"{name} {full_path} {task.get('dpl', '')}")

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
# Print "full_path dpl_or_dash" for every ENABLED file/task belonging to
# ONE analysis (both legacy tasks[] and new files[]). Unlike
# _analysis_get_enabled_tasks (which only lists DPL tasks, across ALL
# enabled analyses, for _rebuild_tasks), this lists everything — plain
# files included — for a single named analysis, for 'o2 build --cut-pr'
# to know exactly which files belong in its PR branch. "-" means "plain
# file, not a DPL task".
# ==============================================================================
_analysis_get_files() {
    local REGISTRY="$1"
    local ANALYSIS="$2"

    python3 - "$REGISTRY" "$ANALYSIS" "$O2_PHYSICS_COMPONENTS" << 'PYEOF'
import sys, json

registry_path, analysis_name, default_components = sys.argv[1:]
with open(registry_path) as f:
    data = json.load(f)

for analysis in data.get("analysis", []):
    if analysis.get("name") != analysis_name:
        continue
    for task in analysis.get("tasks", []):
        if not task.get("enabled", False):
            continue
        full_path = f"{default_components}/{task.get('file', '')}"
        print(f"{full_path} {task.get('dpl', '-')}")
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
        "tasks": [],
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

After enabling tasks, rebuild with:
  o2 build --rebuild-tasks
  o2 deploy --build-only

EOF
}
