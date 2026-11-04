#!/usr/bin/env bats
# clean_merged_agent_worktrees: merged, clean, idle agent worktrees only.

load helpers/common

setup_file() {
    mole_test_setup_home agent-worktrees
}

teardown_file() {
    mole_test_teardown_home
}

wt_git() {
    git -c user.email=t@example.com -c user.name=t -c init.defaultBranch=main "$@"
}

# $1/code/proj is pushed to $1/origin.git with origin/HEAD set; every case
# adds its worktree with wt_add.
wt_case_home() {
    local case_home="$HOME/wt-$BATS_TEST_NUMBER"
    rm -rf "$case_home"
    mkdir -p "$case_home/code"
    wt_git init -q --bare "$case_home/origin.git"
    wt_git init -q "$case_home/code/proj"
    printf '.env\nnode_modules/\n*.tsbuildinfo\n' > "$case_home/code/proj/.gitignore"
    printf 'a\n' > "$case_home/code/proj/a.txt"
    wt_git -C "$case_home/code/proj" add -A
    wt_git -C "$case_home/code/proj" commit -q -m init
    wt_git -C "$case_home/code/proj" remote add origin "$case_home/origin.git"
    wt_git -C "$case_home/code/proj" push -q origin main
    wt_git -C "$case_home/code/proj" remote set-head origin main
    printf '%s\n' "$case_home"
}

# wt_add <case_home> <worktree path>: detached at main, every file aged 30 days.
wt_add() {
    local case_home="$1" wt="$2"
    mkdir -p "${wt%/*}"
    wt_git -C "$case_home/code/proj" worktree add -q --detach "$wt" main
    wt_age "$case_home" "$wt"
}

wt_age() {
    local case_home="$1" wt="$2" old_stamp
    old_stamp=$(date -v-30d +%Y%m%d%H%M)
    find "$wt" "$case_home/code/proj/.git/worktrees" -exec touch -h -t "$old_stamp" {} +
}

wt_run() {
    local case_home="$1"
    local prelude="${2:-}"
    run env HOME="$case_home" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_NO_AUTH=1 \
        WT_PRELUDE="$prelude" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/bin/clean.sh"
DRY_RUN=false
mole_process_args_reference_paths() { return 1; }
eval "$WT_PRELUDE"
clean_merged_agent_worktrees
EOF
}

@test "merged clean idle Claude worktree is removed, branch and main repo kept" {
    local case_home wt
    case_home=$(wt_case_home)
    wt="$case_home/code/proj/.claude/worktrees/done"
    wt_add "$case_home" "$wt"
    wt_git -C "$case_home/code/proj" branch keep-me

    wt_run "$case_home"

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ ! -e "$wt" ] || { echo "$output"; return 1; }
    [[ "$output" == *"Merged agent worktrees"* ]] || { echo "$output"; return 1; }
    [ ! -e "$case_home/code/proj/.git/worktrees/done" ] || return 1
    [ -f "$case_home/code/proj/a.txt" ] || return 1
    wt_git -C "$case_home/code/proj" show-ref --verify -q refs/heads/keep-me
}

@test "Codex two-level worktree with only rebuildable ignored entries is removed" {
    local case_home wt
    case_home=$(wt_case_home)
    wt="$case_home/.codex/worktrees/a1b2/proj"
    wt_add "$case_home" "$wt"
    mkdir -p "$wt/node_modules/pkg"
    printf 'x\n' > "$wt/node_modules/pkg/index.js"
    printf '{}\n' > "$wt/tsconfig.tsbuildinfo"
    wt_age "$case_home" "$wt"

    wt_run "$case_home"

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ ! -e "$wt" ]
}

@test "an ignored file outside the rebuildable names keeps the worktree" {
    local case_home wt
    case_home=$(wt_case_home)
    wt="$case_home/code/proj/.worktrees/secret"
    wt_add "$case_home" "$wt"
    printf 'TOKEN=1\n' > "$wt/.env"
    wt_age "$case_home" "$wt"

    wt_run "$case_home"

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ -f "$wt/.env" ] || { echo "$output"; return 1; }
    [[ "$output" != *"Merged agent worktrees"* ]]
}

@test "tracked changes and untracked files keep the worktree" {
    local case_home dirty untracked
    case_home=$(wt_case_home)
    dirty="$case_home/code/proj/.claude/worktrees/dirty"
    untracked="$case_home/code/proj/.claude/worktrees/untracked"
    wt_add "$case_home" "$dirty"
    wt_add "$case_home" "$untracked"
    printf 'changed\n' > "$dirty/a.txt"
    printf 'new\n' > "$untracked/notes.md"
    wt_age "$case_home" "$dirty"
    wt_age "$case_home" "$untracked"

    wt_run "$case_home"

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ -f "$dirty/a.txt" ] || { echo "$output"; return 1; }
    [ -f "$untracked/notes.md" ]
}

@test "a commit not in the remote default branch keeps the worktree" {
    local case_home wt
    case_home=$(wt_case_home)
    wt="$case_home/code/proj/.claude/worktrees/ahead"
    wt_add "$case_home" "$wt"
    printf 'b\n' > "$wt/b.txt"
    wt_git -C "$wt" add b.txt
    wt_git -C "$wt" commit -q -m local-only
    wt_age "$case_home" "$wt"

    wt_run "$case_home"

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ -f "$wt/b.txt" ]
}

@test "a worktree changed within 24 hours is kept" {
    local case_home wt
    case_home=$(wt_case_home)
    wt="$case_home/code/proj/.claude/worktrees/fresh"
    wt_add "$case_home" "$wt"
    touch "$wt/a.txt"

    wt_run "$case_home"

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ -d "$wt" ]
}

@test "locked and orphaned worktrees are kept" {
    local case_home locked orphan
    case_home=$(wt_case_home)
    locked="$case_home/code/proj/.claude/worktrees/locked"
    orphan="$case_home/code/proj/.claude/worktrees/orphan"
    wt_add "$case_home" "$locked"
    wt_add "$case_home" "$orphan"
    wt_git -C "$case_home/code/proj" worktree lock "$locked"
    rm -rf "$case_home/code/proj/.git/worktrees/orphan" # SAFE: test fixture admin dir
    wt_age "$case_home" "$locked"

    wt_run "$case_home"

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ -d "$locked" ] || { echo "$output"; return 1; }
    [ -d "$orphan" ]
}

@test "no origin default branch keeps the worktree" {
    local case_home wt
    case_home=$(wt_case_home)
    wt="$case_home/code/proj/.claude/worktrees/noremote"
    wt_add "$case_home" "$wt"
    wt_git -C "$case_home/code/proj" remote remove origin
    wt_age "$case_home" "$wt"

    wt_run "$case_home"

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ -d "$wt" ]
}

@test "a worktree named by a running process is kept" {
    local case_home wt
    case_home=$(wt_case_home)
    wt="$case_home/code/proj/.claude/worktrees/busy"
    wt_add "$case_home" "$wt"

    wt_run "$case_home" 'mole_process_args_reference_paths() { return 0; }'

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ -d "$wt" ]
}

@test "dry run previews the worktree and keeps it" {
    local case_home wt
    case_home=$(wt_case_home)
    wt="$case_home/code/proj/.claude/worktrees/preview"
    wt_add "$case_home" "$wt"

    wt_run "$case_home" 'DRY_RUN=true'

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"Merged agent worktrees"* ]] || { echo "$output"; return 1; }
    [ -d "$wt" ]
}

@test "the sink guard skips a worktree that became dirty after the scan" {
    local case_home wt
    case_home=$(wt_case_home)
    wt="$case_home/code/proj/.claude/worktrees/late"
    wt_add "$case_home" "$wt"
    printf 'late edit\n' > "$wt/a.txt"
    wt_age "$case_home" "$wt"

    run env HOME="$case_home" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_NO_AUTH=1 WT="$wt" \
        /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/bin/clean.sh"
mole_process_args_reference_paths() { return 1; }
_MOLE_SAFE_CLEAN_SKIP_PATH=""
rc=0
_agent_wt_delete_guard "$WT" || rc=$?
printf 'rc=%s skip=%s\n' "$rc" "$_MOLE_SAFE_CLEAN_SKIP_PATH"
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == "rc=1 skip=$wt" ]] || { echo "$output"; return 1; }
    [ -f "$wt/a.txt" ]
}

# One clean run in the child shell, then its status and the clean
# cancellation marker.
# shellcheck disable=SC2016 # Expanded by the child shell.
WT_SIGNAL_SCRIPT='set -euo pipefail
source "$PROJECT_ROOT/bin/clean.sh"
DRY_RUN=false
export MOLE_CURRENT_COMMAND=clean MOLE_CLEAN_CANCEL_STATUS=0
mole_process_args_reference_paths() { return 1; }
eval "$WT_PRELUDE"
rc=0
clean_merged_agent_worktrees || rc=$?
printf "RC=%s CANCEL=%s\n" "$rc" "$MOLE_CLEAN_CANCEL_STATUS"'

# wt_signal_case <name> <want> <prelude> [removed]: one run over a fresh
# merged, clean, idle worktree with <prelude>. It must return <want> and leave
# it in the clean cancellation marker; the worktree stays unless "removed".
wt_signal_case() {
    local name="$1" want="$2" case_home wt out rc=0
    case_home=$(wt_case_home)
    wt="$case_home/code/proj/.claude/worktrees/done"
    wt_add "$case_home" "$wt"
    out=$(env HOME="$case_home" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_NO_AUTH=1 \
        WT_PRELUDE="$3" /bin/bash --noprofile --norc -c "$WT_SIGNAL_SCRIPT" 2>&1) || rc=$?
    [[ $rc -eq 0 && "$out" == *"RC=$want CANCEL=$want"* ]] || { echo "$name: exit $rc: $out"; return 1; }
    if [[ "${4:-}" == removed ]]; then
        [ ! -e "$wt" ] || { echo "$name: worktree kept"; return 1; }
    else
        [ -d "$wt" ] || { echo "$name: worktree removed"; return 1; }
    fi
}

@test "a signal in any worktree probe stops the run; git's fatal 128 only keeps" {
    # run_with_timeout answers $WT_FAIL_RC for the probe whose command line
    # holds $WT_FAIL_AT and runs everything else for real.
    # shellcheck disable=SC2016 # The preludes are evaluated by the child shell.
    local fail='eval "_wt_real_rwt() $(declare -f run_with_timeout | tail -n +2)"
run_with_timeout() { [[ "$*" != *"$WT_FAIL_AT"* ]] || return "$WT_FAIL_RC"; _wt_real_rwt "$@"; }'
    # shellcheck disable=SC2016 # The preludes are evaluated by the child shell.
    local head_log='find() { [[ "$*" != *"-maxdepth 0 -mmin"* ]] || return 130; command find "$@"; }'
    # shellcheck disable=SC2016 # The preludes are evaluated by the child shell.
    local no_head='git -C "$HOME/code/proj" remote set-head origin -d;'

    wt_signal_case resolver 130 '_mole_resolve_git_bin() { return 130; }' || return 1
    wt_signal_case listing 130 "WT_FAIL_AT='-name .git -type f -print' WT_FAIL_RC=130; $fail" || return 1
    wt_signal_case linked 130 "WT_FAIL_AT='rev-parse --absolute-git-dir' WT_FAIL_RC=130; $fail" || return 1
    wt_signal_case recency 130 "WT_FAIL_AT='-print -quit' WT_FAIL_RC=130; $fail" || return 1
    wt_signal_case head-log 130 "$head_log" || return 1
    wt_signal_case remote-head 130 "WT_FAIL_AT='symbolic-ref' WT_FAIL_RC=130; $fail" || return 1
    wt_signal_case show-ref 130 "$no_head WT_FAIL_AT='show-ref' WT_FAIL_RC=130; $fail" || return 1
    wt_signal_case process 130 'mole_process_args_reference_paths() { return 130; }' || return 1
    wt_signal_case git-fatal 0 "WT_FAIL_AT='merge-base' WT_FAIL_RC=128; $fail" || return 1
    wt_signal_case prune 130 "WT_FAIL_AT='worktree prune' WT_FAIL_RC=130; $fail" removed
}

@test "agent_worktree_containers lists .worktrees and worktrees under purge_paths roots, not .git/worktrees" {
    local case_home
    case_home=$(wt_case_home)
    mkdir -p "$case_home/work/repo/.worktrees" "$case_home/work/worktrees" "$case_home/.config/mole"
    printf '%s\n' "$case_home/work" > "$case_home/.config/mole/purge_paths"
    wt_add "$case_home" "$case_home/code/proj/.claude/worktrees/one"

    run env HOME="$case_home" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/user.sh"
agent_worktree_containers | tr '\0' '\n'
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"$case_home/work/repo/.worktrees"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"$case_home/work/worktrees"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"$case_home/code/proj/.claude/worktrees"* ]] || { echo "$output"; return 1; }
    [[ "$output" != *".git/worktrees"* ]]
}
