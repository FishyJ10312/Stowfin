#!/bin/zsh
# Runs every automated check group, keeps going after a failing group, prints a
# summary, and exits non-zero when any group failed.
#
# Fixtures: the checks create their disposable fixtures under /Users/Shared
# (qingsweep-*, QingSweep-*) and in this directory (testdata-*). The app's
# SafetyPolicy only permits paths inside the home folder or /Volumes and rejects
# symlinked components, which is why fixtures are not under /var/folders.
# A failing check exits immediately and skips its own cleanup, so this script
# removes, after the run, only fixture directories that did not exist before it
# started. Directories that existed before the run are never touched.
# Set STOWFIN_KEEP_FIXTURES=1 to keep this run's fixtures for debugging.
# Do not run two copies of this script at the same time.
set -euo pipefail
setopt null_glob
project_dir="${0:A:h}"
cd "$project_dir"
mkdir -p .build
log_dir=".build/check-logs"
rm -rf "$log_dir"
mkdir -p "$log_dir"
source ./source-list.sh
common=("${core[@]}")
compiler=(xcrun swiftc -swift-version 5 -O -module-cache-path .build/module-cache)

fixture_candidates() {
    local entry
    for entry in /Users/Shared/qingsweep-* /Users/Shared/QingSweep-* "$project_dir"/testdata-*; do
        [[ -d "$entry" && ! -L "$entry" && -O "$entry" ]] && print -r -- "$entry"
    done
    return 0
}
typeset -A preexisting
for entry in "${(@f)$(fixture_candidates)}"; do [[ -n "$entry" ]] && preexisting[$entry]=1; done

cleanup_fixtures() {
    local entry removed=0
    if [[ "${STOWFIN_KEEP_FIXTURES:-0}" == 1 ]]; then
        print "Fixtures kept (STOWFIN_KEEP_FIXTURES=1)."
        return 0
    fi
    for entry in "${(@f)$(fixture_candidates)}"; do
        [[ -z "$entry" || -n "${preexisting[$entry]:-}" ]] && continue
        rm -rf -- "$entry" && removed=$((removed + 1))
    done
    print "Removed $removed fixture director(ies) created by this run."
    if (( ${#preexisting} > 0 )); then
        print "Left untouched (existed before this run):"
        print -l -- "  ${(@ok)^preexisting}"
    fi
}
trap cleanup_fixtures EXIT
# zsh does not run the EXIT trap when a signal ends the script, so turn
# interrupts into a normal exit and still remove this run's fixtures.
trap 'exit 130' INT
trap 'exit 143' TERM HUP

passed=()
failed=()
started=$SECONDS

total_checks=0

# Each group ends with its own total, such as "53 checks passed" or
# "Startup state checks: 61 passed, 0 failed". PASS lines alone undercount
# groups that only print a total.
record() {
    local name=$1 log_file=$2 group_status=$3 seconds=$4 count summary
    if (( group_status == 0 )); then
        summary=$(grep -E 'checks passed|checks: [0-9]+ passed' "$log_file" | tail -n 1 || true)
        count=$(print -r -- "$summary" | grep -Eo '[0-9]+' | head -n 1 || true)
        [[ -z "$count" ]] && count=$(grep -c '^PASS' "$log_file" || true)
        total_checks=$((total_checks + count))
        passed+=("$name")
        print "== $name: ok ($count checks, ${seconds}s)"
    else
        count=$(grep -c '^PASS' "$log_file" || true)
        failed+=("$name")
        print "== $name: FAILED (exit $group_status, $count PASS lines before failure, ${seconds}s, log $log_file)"
    fi
}

# run_group <name> <source files...>: compiles the sources into .build/<name>
# and runs the binary.
run_group() {
    local name=$1; shift
    local log_file="$log_dir/$name.log" group_started=$SECONDS group_status=0
    print "== $name"
    { "${compiler[@]}" "$@" -o ".build/$name" && ".build/$name" } 2>&1 | tee "$log_file" || group_status=$?
    record "$name" "$log_file" $group_status $((SECONDS - group_started))
}

# run_script <name> <script>: runs a check script that builds its own fixtures.
run_script() {
    local name=$1 script=$2
    local log_file="$log_dir/$name.log" group_started=$SECONDS group_status=0
    print "== $name"
    "$script" 2>&1 | tee "$log_file" || group_status=$?
    record "$name" "$log_file" $group_status $((SECONDS - group_started))
}

run_group core-tests "${common[@]}" Tests/CoreTests.swift
run_group interaction-tests "${common[@]}" Sources/InteractionSupport.swift Tests/InteractionSupportTests.swift
run_group storage-audit-tests "${common[@]}" Sources/StorageAudit.swift Sources/StorageVolumes.swift Tests/StorageAuditTests.swift
run_group model-tests "${engine[@]}" Tests/AppModelTests.swift
run_group index-tests "${engine[@]}" Tests/StorageIndexTests.swift
run_group cleanup-flow-tests "${engine[@]}" Tests/CleanupFlowTests.swift
run_group manual-cleanup-tests "${engine[@]}" Tests/ManualCleanupTests.swift
run_group execution-tests "${common[@]}" Sources/CleanupExecution.swift Tests/CleanupExecutionTests.swift
run_script native-quit-tests ./check-native-quit.sh
run_group coverage-tests "${engine[@]}" Tests/StorageCoverageTests.swift
run_group resume-tests "${engine[@]}" Tests/StorageResumeTests.swift
run_group complete-list-tests "${common[@]}" Tests/CompleteListTests.swift
run_group release16-tests "${engine[@]}" Tests/Release16Tests.swift
run_group release17-tests "${engine[@]}" Sources/Design.swift Sources/SpaceMap.swift Tests/Release17Tests.swift
run_group release18-tests "${engine[@]}" Tests/Release18Tests.swift
run_group retained-retry-tests "${common[@]}" Tests/RetainedRetryTests.swift
run_group startup-state-tests "${common[@]}" Sources/StartupItems.swift Tests/StartupStateTests.swift
run_group storage-scope-tests "${engine[@]}" Tests/StorageScopeTests.swift
run_group scope-and-review-tests "${engine[@]}" Tests/ScopeAndReviewTests.swift
run_group first-use-tests "${engine[@]}" Tests/FirstUseTests.swift
run_group media-classification-tests "${common[@]}" Tests/MediaClassificationTests.swift
run_group crash-recovery-tests "${engine[@]}" Tests/CrashRecoveryTests.swift
run_group localization-tests "${engine[@]}" Tests/LocalizationTests.swift

print ""
print "Summary: ${#passed} group(s) passed ($total_checks checks), ${#failed} failed, $((SECONDS - started))s. Logs: $log_dir/"
if (( ${#failed} > 0 )); then
    print "Failed groups: ${failed[*]}"
    exit 1
fi
