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

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --list)            ACTION="list"   ; shift ;;
            --enable)          ACTION="enable" ; TARGET="$2" ; shift 2 ;;
            --disable)         ACTION="disable"; TARGET="$2" ; shift 2 ;;
            --help|-h)         _analysis_help  ; return ;;
            *) log_error "Unknown option: $1" ; _analysis_help ; return 1 ;;
        esac
    done

    local REGISTRY="$O2_LOCAL_DIR/analysis/analysis.json"
    if [ ! -f "$REGISTRY" ]; then
        log_error "analysis.json not found at $REGISTRY"
        return 1
    fi

    case "$ACTION" in
        list)    _analysis_list    "$REGISTRY" ;;
        enable)  _analysis_toggle  "$REGISTRY" "$TARGET" true  ;;
        disable) _analysis_toggle  "$REGISTRY" "$TARGET" false ;;
        *)       _analysis_list    "$REGISTRY" ;;
    esac
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
    tasks       = analysis.get("tasks", [])

    status = "ON " if enabled else "OFF"
    print(f"  [{status}]  {name:<20} — {description}")

    for task in tasks:
        tfile   = task.get("file", "?")
        dpl     = task.get("dpl", "?")
        tenabled = task.get("enabled", False)
        tstatus = "ON " if tenabled else "OFF"
        print(f"           [{tstatus}]  {tfile:<35} → o2-analysis-{dpl}")

    if not tasks:
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
        # Toggle entire analysis + all its tasks
        analysis["enabled"] = state
        for task in analysis.get("tasks", []):
            task["enabled"] = state
        action = "Enabled" if state else "Disabled"
        print(f"[INFO]    {action} analysis: {analysis_name}")
    else:
        # Toggle specific task
        task_found = False
        for task in analysis.get("tasks", []):
            if task.get("file") == task_file:
                task["enabled"] = state
                task_found = True
                action = "Enabled" if state else "Disabled"
                print(f"[INFO]    {action} task: {analysis_name}/{task_file}")
                # If enabling a task, ensure the analysis itself is enabled
                if state:
                    analysis["enabled"] = True
                break
        if not task_found:
            print(f"[ERROR]   Task not found: {task_file} in analysis {analysis_name}")
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
# Read analysis.json and print "analysis_name task.cxx dpl-name" for each
# enabled task in each enabled analysis. Used by _rebuild_tasks().
# ==============================================================================
_analysis_get_enabled_tasks() {
    local REGISTRY="$1"

    python3 - "$REGISTRY" << 'PYEOF'
import sys, json

with open(sys.argv[1]) as f:
    data = json.load(f)

for analysis in data.get("analysis", []):
    if not analysis.get("enabled", False):
        continue
    name = analysis.get("name", "")
    for task in analysis.get("tasks", []):
        if not task.get("enabled", False):
            continue
        print(f"{name} {task.get('file','')} {task.get('dpl','')}")
PYEOF
}

# ==============================================================================
# _analysis_add_task
# Add a new task entry to an analysis in analysis.json.
# Called by _rebuild_tasks when a task file exists but is not yet registered.
# ==============================================================================
_analysis_add_task() {
    local REGISTRY="$1"
    local ANALYSIS="$2"
    local FILE="$3"
    local DPL="$4"

    python3 - "$REGISTRY" "$ANALYSIS" "$FILE" "$DPL" << 'PYEOF'
import sys, json

registry_path, analysis_name, task_file, dpl_name = sys.argv[1:]

with open(registry_path) as f:
    data = json.load(f)

for analysis in data.get("analysis", []):
    if analysis.get("name") != analysis_name:
        continue
    tasks = analysis.setdefault("tasks", [])
    # Check not already present
    if any(t.get("file") == task_file for t in tasks):
        print(f"[INFO]    Task already registered: {task_file}")
        sys.exit(0)
    tasks.append({"file": task_file, "dpl": dpl_name, "enabled": False})
    print(f"[INFO]    Registered new task: {analysis_name}/{task_file} (disabled by default)")
    print(f"[INFO]    Enable with: o2 analysis --enable {analysis_name}/{task_file}")
    break

with open(registry_path, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PYEOF
}

_analysis_help() {
    cat << 'EOF'
o2 analysis [options]

Manage the analysis registry (analysis.json).

Options:
  --list                       list all analyses and tasks with their state
  --enable  <target>           enable an analysis or a specific task
  --disable <target>           disable an analysis or a specific task
  --help                       show this help

Target formats:
  test                         entire analysis (all tasks)
  test/testTask.cxx            specific task within an analysis

Examples:
  o2 analysis --list
  o2 analysis --enable  test
  o2 analysis --disable proxies
  o2 analysis --enable  proxies/taskProxyBuilder.cxx
  o2 analysis --disable test/testTask.cxx

After enabling tasks, rebuild with:
  o2 build --rebuild-tasks
  o2 deploy --build-only

EOF
}
