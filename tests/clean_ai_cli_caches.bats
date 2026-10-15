#!/usr/bin/env bats

load helpers/common
load helpers/fork_caches

setup_file() {
    mole_test_setup_home ai-cli-caches
}

teardown_file() {
    mole_test_teardown_home
}

setup() {
    [[ "$HOME" == "${BATS_TEST_DIRNAME}/tmp-"* ]] || {
        echo "FATAL: HOME is not a test temp dir: $HOME"
        exit 1
    }
    rm -rf "$HOME/.codex" "$HOME/.gemini" "$HOME/.claude" \
        "$HOME/Library/Application Support/Claude" "$HOME/Library/Caches/Codex"
}

assert_run_success() {
    [ "$status" -eq 0 ] || {
        echo "expected status 0, got $status"
        echo "$output"
        return 1
    }
}

assert_output_contains() {
    local expected="$1"
    [[ "$output" == *"$expected"* ]] || {
        echo "expected output to contain: $expected"
        echo "$output"
        return 1
    }
}

assert_output_not_contains() {
    local unexpected="$1"
    [[ "$output" != *"$unexpected"* ]] || {
        echo "expected output not to contain: $unexpected"
        echo "$output"
        return 1
    }
}

@test "clean_codex_cli skips codex state by default" {
    mkdir -p "$HOME/.codex/cache" "$HOME/.codex/.tmp" "$HOME/.codex/log" "$HOME/.codex/sessions"
    mkdir -p "$HOME/.codex/cache/codex_app_directory"
    touch "$HOME/.codex/cache/c.bin" "$HOME/.codex/cache/session_index.jsonl"
    touch "$HOME/.codex/cache/codex_app_directory/index.json" "$HOME/.codex/.tmp/t.bin" "$HOME/.codex/log/codex-tui.log"
    touch "$HOME/.codex/sessions/s.jsonl" "$HOME/.codex/auth.json" "$HOME/.codex/history.jsonl"
    touch "$HOME/.codex/state_5.sqlite" "$HOME/.codex/logs_2.sqlite" "$HOME/.codex/session_index.jsonl"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
safe_clean() { echo "SAFE_CLEAN:$2|$1"; }
note_activity() { :; }
pgrep() { return 1; }
clean_codex_cli
EOF

    assert_run_success
    assert_output_not_contains "Codex CLI state"
    assert_output_not_contains "SAFE_CLEAN:"
    [ -f "$HOME/.codex/cache/session_index.jsonl" ]
    [ -f "$HOME/.codex/cache/codex_app_directory/index.json" ]
    [ -f "$HOME/.codex/.tmp/t.bin" ]
    [ -f "$HOME/.codex/log/codex-tui.log" ]
    [ -f "$HOME/.codex/sessions/s.jsonl" ]
    [ -f "$HOME/.codex/state_5.sqlite" ]
    [ -f "$HOME/.codex/logs_2.sqlite" ]
}

@test "clean_codex_cli is a no-op when ~/.codex is absent" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
safe_clean() { echo "SAFE_CLEAN:$2|$1"; }
note_activity() { :; }
pgrep() { return 1; }
clean_codex_cli
EOF

    assert_run_success
    assert_output_not_contains "SAFE_CLEAN:"
}

@test "clean_codex_cli reports running Codex without cleaning state" {
    mkdir -p "$HOME/.codex/cache" "$HOME/.codex/.tmp" "$HOME/.codex/log"
    touch "$HOME/.codex/cache/c.bin"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
safe_clean() { echo "SAFE_CLEAN:$2|$1"; }
note_activity() { :; }
pgrep() { return 0; }
clean_codex_cli
EOF

    assert_run_success
    assert_output_not_contains "Codex CLI state"
    assert_output_not_contains "SAFE_CLEAN:"
}

@test "clean_codex_desktop_caches removes only measured fixed cache leaves through the real sink" {
    run env HOME="$HOME/codex-cache-positive" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_NO_AUTH=1 /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
cache_root="$HOME/Library/Caches/Codex"
support_root="$HOME/Library/Application Support/Codex"
mkdir -p \
    "$cache_root/Default/Cache" \
    "$cache_root/Default/Code Cache" \
    "$cache_root/Default/Partitions/codex-browser-app/Cache" \
    "$cache_root/Default/Partitions/codex-browser-app/Code Cache" \
    "$cache_root/codex-browser-app/Cache" \
    "$cache_root/codex-browser-app/Code Cache" \
    "$cache_root/Default/Local Storage" \
    "$support_root/Default/Cache"
touch \
    "$cache_root/Default/Cache/default-cache.bin" \
    "$cache_root/Default/Code Cache/default-code.bin" \
    "$cache_root/Default/Partitions/codex-browser-app/Cache/partition-cache.bin" \
    "$cache_root/Default/Partitions/codex-browser-app/Code Cache/partition-code.bin" \
    "$cache_root/codex-browser-app/Cache/browser-cache.bin" \
    "$cache_root/codex-browser-app/Code Cache/browser-code.bin" \
    "$cache_root/Default/Local Storage/state.bin" \
    "$support_root/Default/Cache/durable-state.bin"

source "$PROJECT_ROOT/bin/clean.sh"
pgrep() { return 1; }
DRY_RUN=false
MOLE_DRY_RUN=0
clean_codex_desktop_caches

for removed in \
    "$cache_root/Default/Cache/default-cache.bin" \
    "$cache_root/Default/Code Cache/default-code.bin" \
    "$cache_root/Default/Partitions/codex-browser-app/Cache/partition-cache.bin" \
    "$cache_root/Default/Partitions/codex-browser-app/Code Cache/partition-code.bin" \
    "$cache_root/codex-browser-app/Cache/browser-cache.bin" \
    "$cache_root/codex-browser-app/Code Cache/browser-code.bin"; do
    [[ ! -e "$removed" ]] || { echo "STILL_PRESENT:$removed"; exit 1; }
done
[[ -f "$cache_root/Default/Local Storage/state.bin" ]] || exit 1
[[ -f "$support_root/Default/Cache/durable-state.bin" ]] || exit 1
echo "EXACT_LEAVES_CLEANED"
EOF

    assert_run_success
    assert_output_contains "EXACT_LEAVES_CLEANED"
    assert_output_not_contains "STILL_PRESENT:"
}

@test "clean_codex_desktop_caches preserves pipe characters in physical target paths" {
    local case_home="$HOME/codex-cache|pipe-home"
    local target="$case_home/Library/Caches/Codex/Default/Cache/owned.bin"
    local truncated_prefix="${case_home%%|*}"

    run env HOME="$case_home" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
target="$HOME/Library/Caches/Codex/Default/Cache/owned.bin"
mkdir -p "$(dirname "$target")"
touch "$target"
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
pgrep() { return 1; }
note_activity() { :; }
safe_clean_guarded() {
    local guard="$1"
    shift
    "$guard" || return 75
    local index
    for ((index = 1; index < $#; index++)); do
        printf 'TARGET:%s\n' "${!index}"
    done
}
clean_codex_desktop_caches
EOF

    assert_run_success
    assert_output_contains "TARGET:$target"
    assert_output_not_contains "TARGET:$truncated_prefix/"
}

@test "clean_codex_desktop_caches stops when Codex starts after the initial probe" {
    run env HOME="$HOME/codex-cache-start-race" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_NO_AUTH=1 /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
target="$HOME/Library/Caches/Codex/Default/Cache/owned.bin"
mkdir -p "$(dirname "$target")"
touch "$target"
source "$PROJECT_ROOT/bin/clean.sh"

probe_count=0
pgrep() {
    probe_count=$((probe_count + 1))
    if [[ $probe_count -ge 5 ]]; then
        return 0
    fi
    return 1
}

clean_codex_desktop_caches || true
[[ -f "$target" ]] || exit 1
printf 'CODEX_START_RACE_CLOSED\n'
EOF

    assert_run_success
    assert_output_contains "CODEX_START_RACE_CLOSED"
    assert_output_not_contains "Codex Desktop caches · stopped"
}

@test "clean_codex_desktop_caches skips while ChatGPT owns the Codex app cache" {
    run env HOME="$HOME/codex-cache-running" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_NO_AUTH=1 /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
target="$HOME/Library/Caches/Codex/Default/Cache/owned.bin"
mkdir -p "$(dirname "$target")"
touch "$target"
source "$PROJECT_ROOT/bin/clean.sh"
pgrep() { [[ "$1" == "-x" && "$2" == "ChatGPT" ]]; }
clean_codex_desktop_caches
[[ -f "$target" ]] || exit 1
EOF

    assert_run_success
    assert_output_not_contains "Codex Desktop caches · skipped"
}

@test "clean_codex_desktop_caches skips when its process probe fails" {
    run env HOME="$HOME/codex-cache-probe-error" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_NO_AUTH=1 /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
target="$HOME/Library/Caches/Codex/Default/Cache/owned.bin"
mkdir -p "$(dirname "$target")"
touch "$target"
source "$PROJECT_ROOT/bin/clean.sh"
pgrep() { return 2; }
clean_codex_desktop_caches
[[ -f "$target" ]] || exit 1
EOF

    assert_run_success
    assert_output_contains "Codex Desktop caches · skipped (process state unknown)"
}

@test "clean_codex_desktop_caches skips when pgrep is unavailable" {
    run env HOME="$HOME/codex-cache-probe-missing" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_NO_AUTH=1 /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
target="$HOME/Library/Caches/Codex/Default/Cache/owned.bin"
mkdir -p "$(dirname "$target")"
touch "$target"
source "$PROJECT_ROOT/bin/clean.sh"
PATH=/nonexistent
clean_codex_desktop_caches
[[ -f "$target" ]] || exit 1
EOF

    assert_run_success
    assert_output_contains "Codex Desktop caches · skipped (process state unknown)"
}

@test "clean_codex_desktop_caches rejects symlinked Library and Caches ancestors" {
    run env HOME="$HOME/codex-cache-ancestor-links" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_NO_AUTH=1 /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
for component in Library Caches; do
    case_home="$HOME/$component-case"
    outside="$case_home/outside"
    if [[ "$component" == "Library" ]]; then
        target="$outside/Caches/Codex/Default/Cache/external.bin"
        mkdir -p "$(dirname "$target")" "$case_home"
        ln -s "$outside" "$case_home/Library"
    else
        target="$outside/Codex/Default/Cache/external.bin"
        mkdir -p "$(dirname "$target")" "$case_home/Library"
        ln -s "$outside" "$case_home/Library/Caches"
    fi
    touch "$target"
    CASE_HOME="$case_home" TARGET="$target" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc <<'INNER'
set -euo pipefail
HOME="$CASE_HOME"
source "$PROJECT_ROOT/bin/clean.sh"
pgrep() { return 1; }
clean_codex_desktop_caches
[[ -f "$TARGET" ]] || exit 1
INNER
done
EOF

    assert_run_success
}

@test "clean_codex_desktop_caches rejects a symlinked Codex root" {
    run env HOME="$HOME/codex-cache-root-link" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_NO_AUTH=1 /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
outside="$HOME/outside-codex"
target="$outside/Default/Cache/external.bin"
mkdir -p "$(dirname "$target")" "$HOME/Library/Caches"
touch "$target"
ln -s "$outside" "$HOME/Library/Caches/Codex"
source "$PROJECT_ROOT/bin/clean.sh"
pgrep() { return 1; }
clean_codex_desktop_caches
[[ -f "$target" ]] || exit 1
EOF

    assert_run_success
}

@test "clean_codex_desktop_caches rejects a symlinked fixed profile" {
    run env HOME="$HOME/codex-cache-profile-link" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_NO_AUTH=1 /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
cache_root="$HOME/Library/Caches/Codex"
outside="$HOME/outside-profile"
target="$outside/Cache/external.bin"
mkdir -p "$(dirname "$target")" "$cache_root"
touch "$target"
ln -s "$outside" "$cache_root/codex-browser-app"
source "$PROJECT_ROOT/bin/clean.sh"
pgrep() { return 1; }
clean_codex_desktop_caches
[[ -f "$target" ]] || exit 1
EOF

    assert_run_success
}

@test "clean_codex_desktop_caches rejects a symlinked cache leaf" {
    run env HOME="$HOME/codex-cache-leaf-link" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_NO_AUTH=1 /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
profile="$HOME/Library/Caches/Codex/Default"
outside="$HOME/outside-leaf"
target="$outside/external.bin"
mkdir -p "$profile" "$outside"
touch "$target"
ln -s "$outside" "$profile/Cache"
source "$PROJECT_ROOT/bin/clean.sh"
pgrep() { return 1; }
clean_codex_desktop_caches
[[ -f "$target" ]] || exit 1
EOF

    assert_run_success
}

@test "clean_antigravity_caches cleans antigravity browser caches" {
    ag="$HOME/.gemini/antigravity-browser-profile"
    mkdir -p "$ag/Default/Cache" "$ag/Default/Code Cache" "$ag/Default/GPUCache"
    mkdir -p "$ag/Default/DawnGraphiteCache" "$ag/Default/DawnWebGPUCache"
    mkdir -p "$ag/GraphiteDawnCache" "$ag/component_crx_cache" "$ag/extensions_crx_cache"
    mkdir -p "$ag/Default/Extensions" "$ag/Default/Storage"
    touch "$ag/Default/Cache/a.bin" "$ag/Default/Code Cache/b.bin" "$ag/Default/GPUCache/c.bin"
    touch "$ag/Default/DawnGraphiteCache/d.bin" "$ag/Default/DawnWebGPUCache/e.bin"
    touch "$ag/GraphiteDawnCache/f.bin" "$ag/component_crx_cache/g.bin" "$ag/extensions_crx_cache/h.bin"
    touch "$ag/Default/Extensions/x.js" "$ag/Default/Storage/y.bin"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
pgrep() {
    printf '%s\n' "$*" >> "$HOME/process-trace"
    return 1
}
safe_clean() { echo "SAFE_CLEAN:$2|$1"; }
clean_service_worker_cache() { echo "SWC:$1"; }
note_activity() { :; }
clean_antigravity_caches
grep -qxF -- '-x Antigravity' "$HOME/process-trace" || exit 1
grep -qxF -- '-x gemini' "$HOME/process-trace" || exit 1
EOF

    assert_run_success || return 1
    assert_output_contains "SAFE_CLEAN:Antigravity browser cache|"
    assert_output_contains "SAFE_CLEAN:Antigravity code cache|"
    assert_output_contains "SAFE_CLEAN:Antigravity GPU cache|"
    assert_output_contains "SAFE_CLEAN:Antigravity Dawn cache|"
    assert_output_contains "SAFE_CLEAN:Antigravity WebGPU cache|"
    assert_output_contains "SAFE_CLEAN:Antigravity Graphite cache|"
    assert_output_contains "SAFE_CLEAN:Antigravity component cache|"
    assert_output_contains "SAFE_CLEAN:Antigravity extension cache|"
    assert_output_contains "SWC:Antigravity"
    assert_output_not_contains "Default/Extensions"
    assert_output_not_contains "Default/Storage"
}

@test "clean_antigravity_caches is a no-op when the profile is absent" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
safe_clean() { echo "SAFE_CLEAN:$2|$1"; }
clean_service_worker_cache() { echo "SWC:$1"; }
note_activity() { :; }
clean_antigravity_caches
EOF

    assert_run_success
    assert_output_not_contains "SAFE_CLEAN:Antigravity"
    assert_output_not_contains "SWC:"
}

@test "clean_antigravity_caches ignores an empty active profile" {
    ag="$HOME/.gemini/antigravity-browser-profile"
    rm -rf "$ag"
    mkdir -p "$ag/Default/Cache" "$ag/Default/Service Worker/CacheStorage"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
pgrep() { return 0; }
defer_cleanup_family() { echo "UNEXPECTED_DEFER:$1"; }
safe_clean() { echo "UNEXPECTED_CLEAN:$2"; }
clean_service_worker_cache() { echo "UNEXPECTED_SWC"; }
clean_antigravity_caches
EOF

    assert_run_success
    assert_output_not_contains "UNEXPECTED_DEFER"
    assert_output_not_contains "UNEXPECTED_CLEAN"
    assert_output_not_contains "UNEXPECTED_SWC"
    assert_output_not_contains "process state unknown"
}

@test "clean_antigravity_caches recognizes root-level cache candidates" {
    ag="$HOME/.gemini/antigravity-browser-profile"
    rm -rf "$ag"
    mkdir -p "$ag/component_crx_cache"
    touch "$ag/component_crx_cache/candidate"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
pgrep() { return 1; }
safe_clean() { echo "SAFE_CLEAN:$2|$1"; }
clean_service_worker_cache() { :; }
clean_antigravity_caches
EOF

    assert_run_success
    assert_output_contains "SAFE_CLEAN:Antigravity component cache|$ag/component_crx_cache/candidate"
}

@test "clean_antigravity_caches never touches gemini tmp chat checkpoints" {
    mkdir -p "$HOME/.gemini/tmp"
    touch "$HOME/.gemini/tmp/work.bin"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
safe_clean() { echo "SAFE_CLEAN:$2|$1"; }
clean_service_worker_cache() { echo "SWC:$1"; }
note_activity() { :; }
clean_antigravity_caches
EOF

    assert_run_success
    assert_output_not_contains "SAFE_CLEAN:"
    assert_output_not_contains "SWC:"
    [[ -f "$HOME/.gemini/tmp/work.bin" ]]
}

@test "clean_antigravity_caches skips browser profile and gemini tmp while running" {
    ag="$HOME/.gemini/antigravity-browser-profile"
    mkdir -p "$ag/Default/Cache" "$HOME/.gemini/tmp"
    touch "$ag/Default/Cache/a.bin" "$HOME/.gemini/tmp/work.bin"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
safe_clean() { echo "SAFE_CLEAN:$2|$1"; }
clean_service_worker_cache() { echo "SWC:$1"; }
note_activity() { echo "NOTE_ACTIVITY"; }
pgrep() {
    [[ "$1" == "-x" && "$2" == "gemini" ]]
}
clean_antigravity_caches
EOF

    assert_run_success
    assert_output_not_contains "Antigravity/Gemini caches · skipped"
    assert_output_not_contains "NOTE_ACTIVITY"
    assert_output_not_contains "SAFE_CLEAN:"
    assert_output_not_contains "SWC:"
}

@test "clean_dev_misc invokes Codex and Antigravity cleanup helpers" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
safe_clean() { :; }
safe_find_delete() { :; }
clean_service_worker_cache() { :; }
clean_codex_runtimes() { :; }
clean_codex_desktop_staging() { echo "CODEX_STAGING_CALLED"; }
clean_codex_desktop_caches() { echo "CODEX_CACHE_CALLED"; }
note_activity() { :; }
clean_codex_cli() { echo "CODEX_CLI_CALLED"; }
clean_antigravity_caches() { echo "ANTIGRAVITY_CALLED"; }
clean_dev_misc
EOF

    assert_run_success
    assert_output_contains "CODEX_CLI_CALLED"
    assert_output_contains "CODEX_CACHE_CALLED"
    assert_output_contains "CODEX_STAGING_CALLED"
    assert_output_contains "ANTIGRAVITY_CALLED"
}

@test "clean_dev_ai_agents reaps stale Claude Desktop bundled versions when active version is known" {
    local claude_support="$HOME/Library/Application Support/Claude"
    mkdir -p "$claude_support/claude-code/2.1.140" "$claude_support/claude-code/2.1.142" "$claude_support/claude-code/2.1.150"
    mkdir -p "$claude_support/claude-code-vm/2.1.140" "$claude_support/claude-code-vm/2.1.142" "$claude_support/claude-code-vm/2.1.150"
    echo "2.1.150" > "$claude_support/claude-code-vm/.sdk-version"
    touch -t 202604010000 "$claude_support/claude-code/2.1.140" "$claude_support/claude-code-vm/2.1.140"
    touch -t 202604150000 "$claude_support/claude-code/2.1.142" "$claude_support/claude-code-vm/2.1.142"
    touch -t 202604250000 "$claude_support/claude-code/2.1.150" "$claude_support/claude-code-vm/2.1.150"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
note_activity() { :; }
safe_clean() { echo "SAFE_CLEAN:$2|$1"; }
pgrep() { return 1; }
clean_dev_ai_agents
EOF

    assert_run_success
    assert_output_contains "SAFE_CLEAN:Claude Desktop bundled Claude Code old version|$claude_support/claude-code/2.1.140"
    assert_output_contains "SAFE_CLEAN:Claude Desktop bundled Claude Code VM old version|$claude_support/claude-code-vm/2.1.140"
    assert_output_not_contains "$claude_support/claude-code/2.1.142"
    assert_output_not_contains "$claude_support/claude-code-vm/2.1.142"
    assert_output_not_contains "$claude_support/claude-code/2.1.150"
    assert_output_not_contains "$claude_support/claude-code-vm/2.1.150"
}

@test "clean_dev_ai_agents keeps active Claude Desktop bundled version even when it is older" {
    local claude_support="$HOME/Library/Application Support/Claude"
    mkdir -p "$claude_support/claude-code/2.1.140" "$claude_support/claude-code/2.1.142" "$claude_support/claude-code/2.1.150"
    mkdir -p "$claude_support/claude-code-vm/2.1.140" "$claude_support/claude-code-vm/2.1.142" "$claude_support/claude-code-vm/2.1.150"
    echo "2.1.140" > "$claude_support/claude-code-vm/.sdk-version"
    touch -t 202604010000 "$claude_support/claude-code/2.1.140" "$claude_support/claude-code-vm/2.1.140"
    touch -t 202604150000 "$claude_support/claude-code/2.1.142" "$claude_support/claude-code-vm/2.1.142"
    touch -t 202604250000 "$claude_support/claude-code/2.1.150" "$claude_support/claude-code-vm/2.1.150"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
note_activity() { :; }
safe_clean() { echo "SAFE_CLEAN:$2|$1"; }
pgrep() { return 1; }
clean_dev_ai_agents
EOF

    assert_run_success
    assert_output_contains "SAFE_CLEAN:Claude Desktop bundled Claude Code old version|$claude_support/claude-code/2.1.142"
    assert_output_contains "SAFE_CLEAN:Claude Desktop bundled Claude Code VM old version|$claude_support/claude-code-vm/2.1.142"
    assert_output_not_contains "$claude_support/claude-code/2.1.140"
    assert_output_not_contains "$claude_support/claude-code-vm/2.1.140"
    assert_output_not_contains "$claude_support/claude-code/2.1.150"
    assert_output_not_contains "$claude_support/claude-code-vm/2.1.150"
}

@test "clean_dev_ai_agents leaves single Claude Desktop bundled version alone" {
    local claude_support="$HOME/Library/Application Support/Claude"
    mkdir -p "$claude_support/claude-code/2.1.150" "$claude_support/claude-code-vm/2.1.150"
    echo "2.1.150" > "$claude_support/claude-code-vm/.sdk-version"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
note_activity() { :; }
safe_clean() { echo "SAFE_CLEAN:$2|$1"; }
pgrep() { return 1; }
clean_dev_ai_agents
EOF

    assert_run_success
    assert_output_not_contains "Claude Desktop bundled Claude Code"
    assert_output_not_contains "SAFE_CLEAN:"
}

@test "clean_dev_ai_agents skips Claude Desktop bundled versions when active version is unknown" {
    local claude_support="$HOME/Library/Application Support/Claude"
    mkdir -p "$claude_support/claude-code/2.1.140" "$claude_support/claude-code/2.1.150"
    mkdir -p "$claude_support/claude-code-vm/2.1.140" "$claude_support/claude-code-vm/2.1.150"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
debug_log() { echo "DEBUG:$*"; }
note_activity() { :; }
safe_clean() { echo "SAFE_CLEAN:$2|$1"; }
pgrep() { return 1; }
clean_dev_ai_agents
EOF

    assert_run_success
    # The keep reason is debug-only; the default summary stays silent.
    assert_output_contains "DEBUG:Claude Desktop bundled Claude Code"
    assert_output_contains "kept: active version"
    assert_output_not_contains "skipped ("
    assert_output_not_contains "SAFE_CLEAN:"
}

@test "clean_claude_desktop_bundled_versions validates the active version before deferring" {
    local isolated_home="$HOME/claude-missing-sdk-active"
    local claude_support="$isolated_home/Library/Application Support/Claude"
    mkdir -p "$claude_support/claude-code/2.1.140" "$claude_support/claude-code/2.1.150"
    mkdir -p "$claude_support/claude-code-vm/2.1.140" "$claude_support/claude-code-vm/2.1.150"

    run env HOME="$isolated_home" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
debug_log() { echo "DEBUG:$*"; }
note_activity() { :; }
pgrep() { return 0; }
defer_cleanup_family() { echo "UNEXPECTED_DEFER:$1"; }
safe_clean() { echo "UNEXPECTED_CLEAN:$1"; }
clean_claude_desktop_bundled_versions 1
EOF

    assert_run_success
    assert_output_contains "kept: active version unknown"
    assert_output_not_contains "skipped ("
    assert_output_not_contains "UNEXPECTED_DEFER"
    assert_output_not_contains "UNEXPECTED_CLEAN"
}

@test "clean_claude_desktop_bundled_versions does not defer whitelist-only stale versions" {
    local isolated_home="$HOME/claude-whitelist-only-active"
    local claude_support="$isolated_home/Library/Application Support/Claude"
    local old_cli="$claude_support/claude-code/2.1.140"
    local old_vm="$claude_support/claude-code-vm/2.1.140"
    mkdir -p "$old_cli" "$claude_support/claude-code/2.1.142" "$claude_support/claude-code/2.1.150"
    mkdir -p "$old_vm" "$claude_support/claude-code-vm/2.1.142" "$claude_support/claude-code-vm/2.1.150"
    echo "2.1.150" > "$claude_support/claude-code-vm/.sdk-version"
    touch -t 202604010000 "$old_cli" "$old_vm"
    touch -t 202604250000 "$claude_support/claude-code/2.1.150" "$claude_support/claude-code-vm/2.1.150"

    run env HOME="$isolated_home" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/bin/clean.sh"
old_cli="$HOME/Library/Application Support/Claude/claude-code/2.1.140"
old_vm="$HOME/Library/Application Support/Claude/claude-code-vm/2.1.140"
should_protect_path() { return 1; }
is_path_whitelisted() { [[ "$1" == "$old_cli" || "$1" == "$old_vm" ]]; }
pgrep() { return 0; }
defer_cleanup_family() { echo "UNEXPECTED_DEFER:$1"; }
safe_remove() { echo "UNEXPECTED_DELETE:$1"; return 0; }
clean_claude_desktop_bundled_versions 1
printf 'SKIPPED:%s\n' "$whitelist_skipped_count"
EOF

    assert_run_success
    assert_output_not_contains "UNEXPECTED_DEFER"
    assert_output_not_contains "UNEXPECTED_DELETE"
    assert_output_contains "SKIPPED:2"
}

@test "versioned agent retention preserves newline-containing pathnames" {
    local isolated_home="$HOME/agent-newline-path"
    local versions_root="$isolated_home/versions"
    local newline_version=$'2.0\njunk'
    mkdir -p "$versions_root/1.0" "$versions_root/2.0" "$versions_root/3.0" "$versions_root/$newline_version"
    touch -t 202604010000 "$versions_root/1.0"
    touch -t 202604300000 "$versions_root/2.0"
    touch -t 202604200000 "$versions_root/3.0"
    touch -t 202604100000 "$versions_root/$newline_version"

    run env HOME="$isolated_home" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
root="$HOME/versions"
newline_version=$'2.0\njunk'
_plan_versioned_agent_cleanup_targets "$root" 1 "$root/3.0"
[[ ${#_MOLE_VERSIONED_AGENT_RETENTION_TARGETS[@]} -eq 2 ]] || exit 1
found_old=false
found_newline=false
for target in "${_MOLE_VERSIONED_AGENT_RETENTION_TARGETS[@]}"; do
    [[ "$target" != "$root/2.0" ]] || { echo "WRONG_PLANNED_KEEP:$target"; exit 1; }
    [[ "$target" == "$root/1.0" ]] && found_old=true
    [[ "$target" == "$root/$newline_version" ]] && found_newline=true
done
[[ "$found_old" == "true" && "$found_newline" == "true" ]]
EOF

    assert_run_success
    assert_output_not_contains "WRONG_PLANNED_KEEP"
}

@test "versioned agent cleanup discards a partial inventory when find fails" {
    local isolated_home="$HOME/agent-partial-inventory"
    local versions_root="$isolated_home/versions"
    local fake_bin="$isolated_home/fake-bin"
    mkdir -p "$versions_root/1.0" "$versions_root/2.0" "$versions_root/3.0" "$fake_bin"
    touch -t 202604010000 "$versions_root/1.0"
    touch -t 202604100000 "$versions_root/2.0"
    touch -t 202604200000 "$versions_root/3.0"
    cat > "$fake_bin/find" <<'EOF'
#!/bin/bash
root="$1"
printf '%s\0' "$root/1.0" "$root/2.0" "$root/3.0"
exit 73
EOF
    chmod +x "$fake_bin/find"

    run env HOME="$isolated_home" PROJECT_ROOT="$PROJECT_ROOT" \
        PATH="$fake_bin:/usr/bin:/bin" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
note_activity() { :; }
safe_clean() { echo "UNEXPECTED_DELETE:$1"; }
set +e
clean_versioned_agent_root "$HOME/versions" "Agent old version" 1
rc=$?
set -e
printf 'SCAN_RC:%s\n' "$rc"
[[ $rc -eq 0 ]]
EOF

    assert_run_success
    # The family is kept and reported; the status stays local so later
    # developer cleanup still runs.
    assert_output_contains "SCAN_RC:0"
    assert_output_not_contains "UNEXPECTED_DELETE"
}

@test "an unknown agent inventory keeps that family and lets later agent cleanup run" {
    local isolated_home="$HOME/agent-unknown-continues"
    mkdir -p "$isolated_home/.local/share/claude/versions/1.0" "$isolated_home/.local/share/claude/versions/2.0"

    run env HOME="$isolated_home" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
note_activity() { :; }
safe_clean() { echo "UNEXPECTED_DELETE:$1"; }
_plan_versioned_agent_cleanup_targets() { return 1; }
clean_claude_desktop_bundled_versions() { echo "LATER_STEP_RAN"; }
rc=0
clean_dev_ai_agents || rc=$?
echo "AI_AGENTS_RC:$rc"
EOF

    assert_run_success
    assert_output_contains "AI_AGENTS_RC:0"
    assert_output_contains "LATER_STEP_RAN"
    assert_output_not_contains "UNEXPECTED_DELETE"
}

@test "versioned agent delete guard rejects repeated partial active inventories" {
    local isolated_home="$HOME/agent-partial-active-inventory"
    local versions_root="$isolated_home/versions"
    local bin_dir="$isolated_home/bin"
    mkdir -p "$versions_root/1.0" "$versions_root/2.0" "$versions_root/3.0" "$bin_dir"
    touch "$versions_root/1.0/agent" "$versions_root/2.0/agent" "$versions_root/3.0/agent"
    touch -t 202604010000 "$versions_root/1.0"
    touch -t 202604100000 "$versions_root/2.0"
    touch -t 202604200000 "$versions_root/3.0"
    ln -s "$versions_root/3.0/agent" "$bin_dir/agent"

    run env HOME="$isolated_home" PROJECT_ROOT="$PROJECT_ROOT" \
        /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
root="$HOME/versions"
scan_count=0
_materialize_versioned_agent_entries() {
    local versions_root="$1"
    local output_file="$2"
    scan_count=$((scan_count + 1))
    if [[ $scan_count -eq 1 || $scan_count -eq 3 ]]; then
        printf '%s\0' "$versions_root/1.0" "$versions_root/2.0" > "$output_file"
        return 73
    fi
    command find "$versions_root" -mindepth 1 -maxdepth 1 \
        \( -type f -o -type d \) -print0 > "$output_file"
}
_MOLE_VERSIONED_AGENT_GUARD_ROOT="$root"
_MOLE_VERSIONED_AGENT_GUARD_ACTIVE_SYMLINK="$HOME/bin/agent"
_MOLE_VERSIONED_AGENT_GUARD_ACTIVE_REQUIRED=false
_MOLE_VERSIONED_AGENT_GUARD_KEEP=1
set +e
_versioned_agent_delete_guard_allows "$root/1.0"
rc=$?
set -e
printf 'GUARD_RC:%s\n' "$rc"
[[ $rc -eq 73 ]]
EOF

    assert_run_success
    assert_output_contains "GUARD_RC:73"
}

@test "versioned agent inventory has a wall-clock timeout" {
    local isolated_home="$HOME/agent-inventory-timeout"
    local versions_root="$isolated_home/versions"
    local fake_bin="$isolated_home/fake-bin"
    mkdir -p "$versions_root/1.0" "$fake_bin"
    cat > "$fake_bin/find" <<'EOF'
#!/bin/bash
sleep 30
EOF
    chmod +x "$fake_bin/find"

    local started=$SECONDS
    run env HOME="$isolated_home" PROJECT_ROOT="$PROJECT_ROOT" \
        PATH="$fake_bin:/usr/bin:/bin" MOLE_TIMEOUT_DISK_VERIFY_SEC=1 \
        /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
set +e
_plan_versioned_agent_cleanup_targets "$HOME/versions" 1
rc=$?
set -e
printf 'INVENTORY_RC:%s\n' "$rc"
[[ $rc -eq 124 ]]
EOF
    local elapsed=$((SECONDS - started))

    assert_run_success
    assert_output_contains "INVENTORY_RC:124"
    [ "$elapsed" -lt 10 ]
}

@test "versioned agent stat probes share the inventory deadline" {
    local isolated_home="$HOME/agent-stat-timeout"
    local versions_root="$isolated_home/versions"
    local fake_bin="$isolated_home/fake-bin"
    mkdir -p "$versions_root/1.0" "$fake_bin"
    cat > "$fake_bin/stat" <<'EOF'
#!/bin/bash
sleep 30
EOF
    chmod +x "$fake_bin/stat"

    local started=$SECONDS
    run env HOME="$isolated_home" PROJECT_ROOT="$PROJECT_ROOT" \
        PATH="$fake_bin:/usr/bin:/bin" MOLE_TIMEOUT_DISK_VERIFY_SEC=1 \
        /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
STAT_BSD="$HOME/fake-bin/stat"  # Mole calls stat through STAT_BSD
set +e
_plan_versioned_agent_cleanup_targets "$HOME/versions" 1
rc=$?
set -e
printf 'STAT_RC:%s\n' "$rc"
[[ $rc -eq 124 ]]
EOF
    local elapsed=$((SECONDS - started))

    assert_run_success
    assert_output_contains "STAT_RC:124"
    [ "$elapsed" -lt 10 ]
}

@test "versioned agent cleanup rechecks the active symlink after sizing" {
    local isolated_home="$HOME/agent-active-symlink-race"
    local versions_root="$isolated_home/.local/share/claude/versions"
    local bin_dir="$isolated_home/.local/bin"
    mkdir -p "$versions_root/1.0" "$versions_root/2.0" "$versions_root/3.0" "$bin_dir"
    touch "$versions_root/1.0/claude" "$versions_root/2.0/claude" "$versions_root/3.0/claude"
    touch -t 202604010000 "$versions_root/1.0"
    touch -t 202604100000 "$versions_root/2.0"
    touch -t 202604200000 "$versions_root/3.0"
    ln -s "$versions_root/3.0/claude" "$bin_dir/claude"

    run env HOME="$isolated_home" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_NO_AUTH=1 /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/bin/clean.sh"
get_cleanup_path_size_kb() {
    rm -f "$HOME/.local/bin/claude"
    ln -s "$HOME/.local/share/claude/versions/1.0/claude" "$HOME/.local/bin/claude"
    echo 1
}
safe_remove() { echo "UNEXPECTED_DELETE:$1"; return 0; }
clean_dev_ai_agents
[[ -d "$HOME/.local/share/claude/versions/1.0" ]] || exit 1
EOF

    assert_run_success
    assert_output_not_contains "UNEXPECTED_DELETE"
    assert_output_contains "Claude Code old version · stopped (retention changed)"
}

@test "versioned agent cleanup rechecks the active symlink after retention planning" {
    local isolated_home="$HOME/agent-active-plan-race"
    local versions_root="$isolated_home/.local/share/claude/versions"
    local bin_dir="$isolated_home/.local/bin"
    mkdir -p "$versions_root/1.0" "$versions_root/2.0" "$versions_root/3.0" "$bin_dir"
    touch "$versions_root/1.0/claude" "$versions_root/2.0/claude" "$versions_root/3.0/claude"
    touch -t 202604010000 "$versions_root/1.0"
    touch -t 202604100000 "$versions_root/2.0"
    touch -t 202604200000 "$versions_root/3.0"
    ln -s "$versions_root/3.0/claude" "$bin_dir/claude"

    run env HOME="$isolated_home" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_NO_AUTH=1 /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/bin/clean.sh"
get_cleanup_path_size_kb() {
    : > "$HOME/arm-active-plan-race"
    echo 1
}
_versioned_agent_entry_mtime() {
    if [[ -e "$HOME/arm-active-plan-race" && ! -e "$HOME/flipped-active-plan-race" ]]; then
        : > "$HOME/flipped-active-plan-race"
        rm -f "$HOME/.local/bin/claude"
        ln -s "$HOME/.local/share/claude/versions/1.0/claude" "$HOME/.local/bin/claude"
    fi
    /usr/bin/stat -f%m "$1"
}
safe_remove() { echo "UNEXPECTED_DELETE:$1"; return 0; }
clean_dev_ai_agents
[[ -d "$HOME/.local/share/claude/versions/1.0" ]] || exit 1
EOF

    assert_run_success
    assert_output_not_contains "UNEXPECTED_DELETE"
    assert_output_contains "Claude Code old version · stopped (active version changed)"
}

@test "Claude Desktop bundled cleanup rechecks activity after sizing" {
    local isolated_home="$HOME/claude-size-race"
    local claude_support="$isolated_home/Library/Application Support/Claude"
    mkdir -p "$claude_support/claude-code/2.1.140" "$claude_support/claude-code/2.1.142" "$claude_support/claude-code/2.1.150"
    mkdir -p "$claude_support/claude-code-vm/2.1.140" "$claude_support/claude-code-vm/2.1.142" "$claude_support/claude-code-vm/2.1.150"
    echo "2.1.150" > "$claude_support/claude-code-vm/.sdk-version"
    touch -t 202604010000 "$claude_support/claude-code/2.1.140" "$claude_support/claude-code-vm/2.1.140"
    touch -t 202604150000 "$claude_support/claude-code/2.1.142" "$claude_support/claude-code-vm/2.1.142"
    touch -t 202604250000 "$claude_support/claude-code/2.1.150" "$claude_support/claude-code-vm/2.1.150"

    run env HOME="$isolated_home" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_NO_AUTH=1 /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/bin/clean.sh"
pgrep() {
    [[ -e "$HOME/claude-started" ]] && return 0
    return 1
}
get_cleanup_path_size_kb() {
    : > "$HOME/claude-started"
    echo 1
}
safe_remove() { echo "UNEXPECTED_DELETE:$1"; return 0; }
rm -f "$HOME/claude-started"
clean_claude_desktop_bundled_versions 1
[[ -d "$HOME/Library/Application Support/Claude/claude-code/2.1.140" ]] || exit 1
[[ -d "$HOME/Library/Application Support/Claude/claude-code-vm/2.1.140" ]] || exit 1
printf 'DEFER:%s\n' "$(format_deferred_cleanup_families)"
EOF

    assert_run_success
    assert_output_not_contains "UNEXPECTED_DELETE"
    assert_output_contains "DEFER:Claude Desktop"
}

@test "Claude Desktop bundled cleanup rechecks active-version evidence after sizing" {
    local isolated_home="$HOME/claude-active-evidence-race"
    local claude_support="$isolated_home/Library/Application Support/Claude"
    mkdir -p "$claude_support/claude-code/2.1.140" "$claude_support/claude-code/2.1.142" "$claude_support/claude-code/2.1.150"
    mkdir -p "$claude_support/claude-code-vm/2.1.140" "$claude_support/claude-code-vm/2.1.142" "$claude_support/claude-code-vm/2.1.150"
    echo "2.1.150" > "$claude_support/claude-code-vm/.sdk-version"
    touch -t 202604010000 "$claude_support/claude-code/2.1.140" "$claude_support/claude-code-vm/2.1.140"
    touch -t 202604150000 "$claude_support/claude-code/2.1.142" "$claude_support/claude-code-vm/2.1.142"
    touch -t 202604250000 "$claude_support/claude-code/2.1.150" "$claude_support/claude-code-vm/2.1.150"

    run env HOME="$isolated_home" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_NO_AUTH=1 /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/bin/clean.sh"
pgrep() { return 1; }
get_cleanup_path_size_kb() {
    local active="$HOME/Library/Application Support/Claude/claude-code/2.1.150"
    if [[ -d "$active" ]]; then
        mv "$active" "$HOME/relocated-active-version"
    fi
    echo 1
}
safe_remove() { echo "UNEXPECTED_DELETE:$1"; return 0; }
clean_claude_desktop_bundled_versions 1
[[ -d "$HOME/Library/Application Support/Claude/claude-code/2.1.140" ]] || exit 1
[[ -d "$HOME/Library/Application Support/Claude/claude-code-vm/2.1.140" ]] || exit 1
EOF

    assert_run_success
    assert_output_not_contains "UNEXPECTED_DELETE"
    assert_output_contains "stopped (active version changed)"
}

@test "Claude Desktop bundled cleanup rechecks the SDK after retention planning" {
    local isolated_home="$HOME/claude-sdk-plan-race"
    local claude_support="$isolated_home/Library/Application Support/Claude"
    mkdir -p "$claude_support/claude-code/2.1.140" "$claude_support/claude-code/2.1.142" "$claude_support/claude-code/2.1.150"
    mkdir -p "$claude_support/claude-code-vm/2.1.140" "$claude_support/claude-code-vm/2.1.142" "$claude_support/claude-code-vm/2.1.150"
    echo "2.1.150" > "$claude_support/claude-code-vm/.sdk-version"
    touch -t 202604010000 "$claude_support/claude-code/2.1.140" "$claude_support/claude-code-vm/2.1.140"
    touch -t 202604150000 "$claude_support/claude-code/2.1.142" "$claude_support/claude-code-vm/2.1.142"
    touch -t 202604250000 "$claude_support/claude-code/2.1.150" "$claude_support/claude-code-vm/2.1.150"

    run env HOME="$isolated_home" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_NO_AUTH=1 /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/bin/clean.sh"
pgrep() { return 1; }
get_cleanup_path_size_kb() {
    : > "$HOME/arm-sdk-plan-race"
    echo 1
}
_versioned_agent_entry_mtime() {
    if [[ -e "$HOME/arm-sdk-plan-race" && ! -e "$HOME/flipped-sdk-plan-race" ]]; then
        : > "$HOME/flipped-sdk-plan-race"
        echo "2.1.140" > "$HOME/Library/Application Support/Claude/claude-code-vm/.sdk-version"
    fi
    /usr/bin/stat -f%m "$1"
}
safe_remove() { echo "UNEXPECTED_DELETE:$1"; return 0; }
clean_claude_desktop_bundled_versions 1
[[ -d "$HOME/Library/Application Support/Claude/claude-code/2.1.140" ]] || exit 1
[[ -d "$HOME/Library/Application Support/Claude/claude-code-vm/2.1.140" ]] || exit 1
EOF

    assert_run_success
    assert_output_not_contains "UNEXPECTED_DELETE"
    assert_output_contains "stopped (active version changed)"
}

@test "Claude Desktop bundled cleanup rechecks compiled-model policy after sizing" {
    local isolated_home="$HOME/claude-policy-race"
    local claude_support="$isolated_home/Library/Application Support/Claude"
    mkdir -p "$claude_support/claude-code/2.1.140" "$claude_support/claude-code/2.1.142" "$claude_support/claude-code/2.1.150"
    mkdir -p "$claude_support/claude-code-vm/2.1.140" "$claude_support/claude-code-vm/2.1.142" "$claude_support/claude-code-vm/2.1.150"
    echo "2.1.150" > "$claude_support/claude-code-vm/.sdk-version"
    touch -t 202604010000 "$claude_support/claude-code/2.1.140" "$claude_support/claude-code-vm/2.1.140"
    touch -t 202604150000 "$claude_support/claude-code/2.1.142" "$claude_support/claude-code-vm/2.1.142"
    touch -t 202604250000 "$claude_support/claude-code/2.1.150" "$claude_support/claude-code-vm/2.1.150"

    run env HOME="$isolated_home" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_NO_AUTH=1 /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/bin/clean.sh"
pgrep() { return 1; }
get_cleanup_path_size_kb() {
    mkdir -p "$1/com.apple.e5rt.e5bundlecache"
    echo 1
}
safe_remove() { echo "UNEXPECTED_DELETE:$1"; return 0; }
clean_claude_desktop_bundled_versions 1
[[ -d "$HOME/Library/Application Support/Claude/claude-code/2.1.140" ]] || exit 1
EOF

    assert_run_success
    assert_output_not_contains "UNEXPECTED_DELETE"
    assert_output_contains "stopped (retention changed)"
}

@test "clean_dev_ai_agents skips Claude Desktop bundled versions when sdk version is path-like" {
    local claude_support="$HOME/Library/Application Support/Claude"
    mkdir -p "$claude_support/claude-code/2.1.140" "$claude_support/claude-code/2.1.150"
    mkdir -p "$claude_support/claude-code-vm/2.1.140" "$claude_support/claude-code-vm/2.1.150"
    echo "../2.1.150" > "$claude_support/claude-code-vm/.sdk-version"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
debug_log() { echo "DEBUG:$*"; }
note_activity() { :; }
safe_clean() { echo "SAFE_CLEAN:$2|$1"; }
pgrep() { return 1; }
clean_dev_ai_agents
EOF

    assert_run_success
    # The keep reason is debug-only; the default summary stays silent.
    assert_output_contains "DEBUG:Claude Desktop bundled Claude Code"
    assert_output_contains "kept: active version"
    assert_output_not_contains "skipped ("
    assert_output_not_contains "SAFE_CLEAN:"
}

@test "clean_dev_ai_agents skips Claude Desktop cleanup when active version is missing from one bundled root" {
    local claude_support="$HOME/Library/Application Support/Claude"
    mkdir -p "$claude_support/claude-code/2.1.140" "$claude_support/claude-code/2.1.142"
    mkdir -p "$claude_support/claude-code-vm/2.1.140" "$claude_support/claude-code-vm/2.1.142" "$claude_support/claude-code-vm/2.1.150"
    echo "2.1.150" > "$claude_support/claude-code-vm/.sdk-version"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
debug_log() { echo "DEBUG:$*"; }
note_activity() { :; }
safe_clean() { echo "SAFE_CLEAN:$2|$1"; }
pgrep() { return 1; }
clean_dev_ai_agents
EOF

    assert_run_success
    # The keep reason is debug-only; the default summary stays silent.
    assert_output_contains "DEBUG:Claude Desktop bundled Claude Code"
    assert_output_contains "kept: active version"
    assert_output_not_contains "skipped ("
    assert_output_not_contains "SAFE_CLEAN:"
}

@test "clean_dev_ai_agents skips Claude Desktop cleanup when only one bundled root can identify active version" {
    local claude_support="$HOME/Library/Application Support/Claude"
    mkdir -p "$claude_support/claude-code/2.1.140" "$claude_support/claude-code/2.1.150"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
debug_log() { echo "DEBUG:$*"; }
note_activity() { :; }
safe_clean() { echo "SAFE_CLEAN:$2|$1"; }
pgrep() { return 1; }
clean_dev_ai_agents
EOF

    assert_run_success
    # The keep reason is debug-only; the default summary stays silent.
    assert_output_contains "DEBUG:Claude Desktop bundled Claude Code"
    assert_output_contains "kept: active version"
    assert_output_not_contains "skipped ("
    assert_output_not_contains "SAFE_CLEAN:"
}

@test "clean_dev_ai_agents skips Claude Desktop bundled versions while Claude Desktop is running" {
    local claude_support="$HOME/Library/Application Support/Claude"
    mkdir -p "$claude_support/claude-code/2.1.140" "$claude_support/claude-code/2.1.150"
    mkdir -p "$claude_support/claude-code-vm/2.1.140" "$claude_support/claude-code-vm/2.1.150"
    echo "2.1.150" > "$claude_support/claude-code-vm/.sdk-version"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
note_activity() { :; }
safe_clean() { echo "SAFE_CLEAN:$2|$1"; }
pgrep() {
    [[ "$1" == "-x" && "$2" == "Claude" ]]
}
clean_dev_ai_agents
EOF

    assert_run_success
    assert_output_not_contains "Claude Desktop bundled Claude Code · skipped"
    assert_output_not_contains "SAFE_CLEAN:"
}

@test "clean_codex_marketplace_staging removes only aged staging prefixes (#1389)" {
    local tmp="$HOME/.codex/.tmp"
    local bundled="$tmp/bundled-marketplaces"
    local staging="$tmp/marketplaces/.staging"
    mkdir -p "$bundled/openai-bundled" \
        "$bundled/openai-bundled.staging-old" \
        "$bundled/openai-bundled.staging-fresh" \
        "$tmp/marketplaces/my-marketplace" \
        "$staging/marketplace-upgrade-old" \
        "$staging/marketplace-add-old" \
        "$staging/marketplace-backup-old"
    touch "$bundled/openai-bundled/KEEP" \
        "$bundled/openai-bundled.staging-old/GONE" \
        "$bundled/openai-bundled.staging-fresh/KEEP" \
        "$tmp/marketplaces/my-marketplace/KEEP" \
        "$staging/marketplace-upgrade-old/GONE" \
        "$staging/marketplace-add-old/GONE" \
        "$staging/marketplace-backup-old/KEEP"
    touch -t 202001010000 \
        "$bundled/openai-bundled" \
        "$bundled/openai-bundled.staging-old" \
        "$tmp/marketplaces/my-marketplace" \
        "$staging/marketplace-upgrade-old" \
        "$staging/marketplace-add-old" \
        "$staging/marketplace-backup-old"
    # Fresh staging must stay (age gate).
    touch "$bundled/openai-bundled.staging-fresh"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=false /bin/bash --noprofile --norc << 'INNER'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
_MOLE_COMPLETE_LSOF_MODE=direct
pgrep() { return 1; }
lsof() { return 1; }
run_with_timeout() { shift; "$@"; }
is_path_whitelisted() { return 1; }
# The staging cleanup has no engine-absent fallback (see the audited-count
# gate in clean_core.bats), so a standalone case supplies the guard itself,
# called per target with its path like the engine.
safe_clean_guarded() {
    local guard="$1"
    shift
    local label="${*: -1}" path
    for path in "${@:1:$#-1}"; do
        _MOLE_SAFE_CLEAN_SKIP_PATH=""
        if ! "$guard" "$path"; then
            [[ "$_MOLE_SAFE_CLEAN_SKIP_PATH" == "$path" ]] && continue
            return 75
        fi
        echo "SAFE_CLEAN:$label|$path"
    done
}
note_activity() { :; }
clean_codex_marketplace_staging
INNER

    [ "$status" -eq 0 ]
    [[ "$output" == *"SAFE_CLEAN:Codex marketplace staging|$bundled/openai-bundled.staging-old"* ]] || return 1
    [[ "$output" == *"SAFE_CLEAN:Codex marketplace staging|$staging/marketplace-upgrade-old"* ]] || return 1
    [[ "$output" == *"SAFE_CLEAN:Codex marketplace staging|$staging/marketplace-add-old"* ]] || return 1
    [[ "$output" != *"openai-bundled|"* ]] || return 1
    [[ "$output" != *"openai-bundled.staging-fresh"* ]] || return 1
    [[ "$output" != *"my-marketplace"* ]] || return 1
    [[ "$output" != *"marketplace-backup-old"* ]] || return 1
}

@test "clean_codex_marketplace_staging cleans a large backlog as one row with one root probe (#1742)" {
    # 94 abandoned upgrade folders used to print 94 rows and probe the whole
    # root twice per folder, which read as a hang. One row per root now; the
    # per-entry guard probes only the folder it removes, and a folder that
    # changed before removal is skipped alone.
    local staging="$HOME/.codex/.tmp/marketplaces/.staging"
    local i
    for ((i = 1; i <= 94; i++)); do
        mkdir -p "$staging/marketplace-upgrade-$i"
    done
    touch -t 202001010000 "$staging"/marketplace-upgrade-*

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=false /bin/bash --noprofile --norc << 'INNER'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
staging="$HOME/.codex/.tmp/marketplaces/.staging"
_MOLE_COMPLETE_LSOF_MODE=direct
pgrep() { return 1; }
lsof() { echo "${*: -1}" >> "$HOME/lsof-targets"; return 1; }
_mole_run_complete_lsof() { shift; lsof "$@"; }
run_with_timeout() { shift; "$@"; }
is_path_whitelisted() { return 1; }
note_activity() { :; }
calls=0
safe_clean_guarded() {
    local guard="$1"
    shift
    calls=$((calls + 1))
    local label="${*: -1}" path cleaned=0
    for path in "${@:1:$#-1}"; do
        # Entry 7 is touched by a new Codex run between sizing and removal.
        [[ "$path" == "$staging/marketplace-upgrade-7" ]] && touch "$path"
        _MOLE_SAFE_CLEAN_SKIP_PATH=""
        if ! "$guard" "$path"; then
            [[ "$_MOLE_SAFE_CLEAN_SKIP_PATH" == "$path" ]] && continue
            return 75
        fi
        cleaned=$((cleaned + 1))
    done
    echo "ROW:$label|$cleaned"
}
clean_codex_marketplace_staging
echo "CALLS:$calls"
echo "ROOT_PROBES:$(grep -cx "$staging" "$HOME/lsof-targets")"
echo "ENTRY_PROBES:$(grep -c "$staging/marketplace-upgrade-" "$HOME/lsof-targets")"
INNER

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"CALLS:1"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"ROW:Codex marketplace staging|93"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"ROOT_PROBES:1"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"ENTRY_PROBES:93"* ]] || { echo "$output"; return 1; }
}

@test "clean_codex_marketplace_staging defers while Codex runtime is active" {
    local staging="$HOME/.codex/.tmp/marketplaces/.staging"
    mkdir -p "$staging/marketplace-upgrade-old"
    touch "$staging/marketplace-upgrade-old/payload"
    touch -t 202001010000 "$staging/marketplace-upgrade-old"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=false /bin/bash --noprofile --norc << 'INNER'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
pgrep() {
    if [[ "$*" == *codex* ]] || [[ "$*" == *Codex* ]] || [[ "$*" == *ChatGPT* ]]; then
        return 0
    fi
    return 1
}
lsof() { return 1; }
safe_clean() { echo "UNEXPECTED:$1"; }
mole_defer_cleanup_family() { echo "DEFER:$1"; }
note_activity() { :; }
clean_codex_marketplace_staging
INNER

    [ "$status" -eq 0 ]
    [[ "$output" == *"DEFER:Codex"* ]] || return 1
    [[ "$output" != *"UNEXPECTED:"* ]] || return 1
    [[ -f "$staging/marketplace-upgrade-old/payload" ]]
}

# Codex app-server daemon releases (#1704). The stub reports each removal the
# real guard approves, and SKIP for a release the guard refused on its own.
codex_daemon_fixture() {
    local root="$HOME/.codex/packages/app-server-daemon"
    mkdir -p "$root/releases" "$root/standalone/0.150.0"
    local name
    for name in 0.157.0-aarch64-apple-darwin 0.158.0-aarch64-apple-darwin \
        0.159.0-aarch64-apple-darwin 0.160.1-aarch64-apple-darwin \
        0.161.0-aarch64-apple-darwin local-0a1b2c3d4e5f-aarch64-apple-darwin; do
        mkdir -p "$root/releases/$name/bin"
        touch "$root/releases/$name/bin/codex"
    done
    mkdir -p "$root/releases/.unpack-tmp"
    ln -s "$root/releases/0.161.0-aarch64-apple-darwin" "$root/current"
    printf '%s' "0.160.1-aarch64-apple-darwin" > "$root/auto-update-version"
    : > "$root/install.lock"
}

codex_daemon_run() {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN="${1:-false}" \
        BUSY_RELEASE="${2:-}" REPOINT="${3:-}" /bin/bash --noprofile --norc << 'INNER'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
_MOLE_COMPLETE_LSOF_MODE=direct
run_with_timeout() { shift; "$@"; }
lsof() {
    if [[ -n "$BUSY_RELEASE" && "$*" == *"/releases/$BUSY_RELEASE"* ]]; then
        printf 'p1\nn%s/bin/codex\n' "$HOME/.codex/packages/app-server-daemon/releases/$BUSY_RELEASE"
        return 0
    fi
    return 1
}
is_path_whitelisted() { return 1; }
note_activity() { :; }
safe_clean_guarded() {
    local guard="$1"
    shift
    local label="${*: -1}" path rc
    for path in "${@:1:$#-1}"; do
        rc=0
        # A release becomes `current` after the scan listed it as a candidate.
        if [[ -n "$REPOINT" ]]; then
            ln -sfn "$HOME/.codex/packages/app-server-daemon/releases/$REPOINT" "$HOME/.codex/packages/app-server-daemon/current"
        fi
        "$guard" "$path" || rc=$?
        if [[ $rc -eq 0 ]]; then
            echo "REMOVE:$label|${path##*/}"
            [[ "$DRY_RUN" == "true" ]] || rm -rf "$path" # SAFE: test fixture under the temp HOME.
        elif [[ "$_MOLE_SAFE_CLEAN_SKIP_PATH" == "$path" ]]; then
            echo "SKIP:${path##*/}"
        else
            return 75
        fi
    done
}
clean_codex_daemon_releases
if /usr/bin/python3 -c 'import fcntl, sys
f = open(sys.argv[1], "r+")
fcntl.lockf(f, fcntl.LOCK_EX | fcntl.LOCK_NB)' "$HOME/.codex/packages/app-server-daemon/install.lock" 2> /dev/null; then
    echo "LOCK_RELEASED"
fi
INNER
}

@test "clean_codex_daemon_releases keeps a release that becomes current after the scan (#1704)" {
    codex_daemon_fixture
    local releases="$HOME/.codex/packages/app-server-daemon/releases"

    codex_daemon_run false "" 0.159.0-aarch64-apple-darwin

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"SKIP:0.159.0-aarch64-apple-darwin"* ]] || return 1
    [[ "$output" != *"REMOVE:Codex daemon old releases|0.159.0-aarch64-apple-darwin"* ]] || return 1
    [[ -d "$releases/0.159.0-aarch64-apple-darwin" ]] || return 1
}

@test "clean_codex_daemon_releases removes only superseded releases (#1704)" {
    codex_daemon_fixture
    local releases="$HOME/.codex/packages/app-server-daemon/releases"

    codex_daemon_run false 0.158.0-aarch64-apple-darwin

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"REMOVE:Codex daemon old releases|0.157.0-aarch64-apple-darwin"* ]] || return 1
    [[ "$output" == *"REMOVE:Codex daemon old releases|0.159.0-aarch64-apple-darwin"* ]] || return 1
    [[ "$output" == *"REMOVE:Codex daemon old releases|local-0a1b2c3d4e5f-aarch64-apple-darwin"* ]] || return 1
    [[ "$output" == *"LOCK_RELEASED"* ]] || return 1
    [[ ! -d "$releases/0.157.0-aarch64-apple-darwin" ]] || return 1
    [[ ! -d "$releases/0.159.0-aarch64-apple-darwin" ]] || return 1
    # current, the auto-update-version release, an open release, a name that
    # is not a release, and the legacy standalone layout all stay.
    [[ -f "$releases/0.161.0-aarch64-apple-darwin/bin/codex" ]] || return 1
    [[ -f "$releases/0.160.1-aarch64-apple-darwin/bin/codex" ]] || return 1
    [[ -f "$releases/0.158.0-aarch64-apple-darwin/bin/codex" ]] || return 1
    [[ -d "$releases/.unpack-tmp" ]] || return 1
    [[ -d "$HOME/.codex/packages/app-server-daemon/standalone/0.150.0" ]]
}

@test "clean_codex_daemon_releases skips while an install holds the lockf lock (#1704)" {
    codex_daemon_fixture
    local lock="$HOME/.codex/packages/app-server-daemon/install.lock"
    local ready="$HOME/lock-ready"
    rm -f "$ready"
    /usr/bin/python3 -c 'import fcntl, sys, time
f = open(sys.argv[1], "r+")
fcntl.lockf(f, fcntl.LOCK_EX)
open(sys.argv[2], "w").close()
time.sleep(20)' "$lock" "$ready" &
    local holder=$!
    local waited=0
    while [[ ! -f "$ready" && $waited -lt 50 ]]; do
        sleep 0.1
        waited=$((waited + 1))
    done
    [[ -f "$ready" ]] || {
        kill "$holder" 2> /dev/null || true
        return 1
    }

    codex_daemon_run false

    kill "$holder" 2> /dev/null || true
    wait "$holder" 2> /dev/null || true
    [ "$status" -eq 0 ] || return 1
    [[ "$output" != *"REMOVE:"* ]] || return 1
    [[ -d "$HOME/.codex/packages/app-server-daemon/releases/0.157.0-aarch64-apple-darwin" ]]
}

@test "clean_codex_daemon_releases fails closed on a dangling current or unreadable marker (#1704)" {
    codex_daemon_fixture
    local root="$HOME/.codex/packages/app-server-daemon"
    rm "$root/current"
    ln -s "$root/releases/0.999.0-aarch64-apple-darwin" "$root/current"

    codex_daemon_run false
    [ "$status" -eq 0 ] || return 1
    [[ "$output" != *"REMOVE:"* ]] || return 1

    rm "$root/current"
    ln -s "$root/releases/0.161.0-aarch64-apple-darwin" "$root/current"
    printf 'not a release\n' > "$root/auto-update-version"

    codex_daemon_run false
    [ "$status" -eq 0 ] || return 1
    [[ "$output" != *"REMOVE:"* ]] || return 1
    [[ -d "$root/releases/0.157.0-aarch64-apple-darwin" ]]
}

@test "clean_codex_daemon_releases dry run lists the same plan and deletes nothing (#1704)" {
    codex_daemon_fixture
    local releases="$HOME/.codex/packages/app-server-daemon/releases"

    codex_daemon_run true

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"REMOVE:Codex daemon old releases|0.157.0-aarch64-apple-darwin"* ]] || return 1
    [[ "$output" == *"REMOVE:Codex daemon old releases|0.158.0-aarch64-apple-darwin"* ]] || return 1
    [[ "$output" == *"REMOVE:Codex daemon old releases|0.159.0-aarch64-apple-darwin"* ]] || return 1
    [[ "$output" != *"0.160.1-aarch64-apple-darwin"* ]] || return 1
    [[ "$output" != *"REMOVE:Codex daemon old releases|0.161.0"* ]] || return 1
    [[ -d "$releases/0.157.0-aarch64-apple-darwin" ]]
}

@test "clean_codex_daemon_releases skips an install.lock.d protocol and a symlinked releases root (#1704)" {
    codex_daemon_fixture
    local root="$HOME/.codex/packages/app-server-daemon"
    mkdir "$root/install.lock.d"

    codex_daemon_run false
    [ "$status" -eq 0 ] || return 1
    [[ "$output" != *"REMOVE:"* ]] || return 1

    rmdir "$root/install.lock.d"
    mv "$root/releases" "$HOME/elsewhere-releases"
    ln -s "$HOME/elsewhere-releases" "$root/releases"

    codex_daemon_run false
    [ "$status" -eq 0 ] || return 1
    [[ "$output" != *"REMOVE:"* ]] || return 1
    [[ -d "$HOME/elsewhere-releases/0.157.0-aarch64-apple-darwin" ]] || return 1
    rm "$root/releases"
    rm -rf "$HOME/elsewhere-releases"
}

@test "clean_codex_daemon_releases says so when open files cannot be checked (#1704)" {
    codex_daemon_fixture

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" DRY_RUN=true /bin/bash --noprofile --norc << 'INNER'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
_MOLE_COMPLETE_LSOF_MODE=unknown
_mole_complete_lsof_mode() { return 2; }
is_path_whitelisted() { return 1; }
note_activity() { :; }
safe_clean_guarded() { echo "UNEXPECTED:$*"; }
clean_codex_daemon_releases
INNER

    [ "$status" -eq 0 ] || return 1
    [[ "$output" == *"Codex daemon old releases · skipped (open-file check unavailable)"* ]] || return 1
    [[ "$output" != *"UNEXPECTED:"* ]]
}

@test "clean_codex_daemon_releases removes through the real safe_clean_guarded sink (#1704)" {
    codex_daemon_fixture
    local releases="$HOME/.codex/packages/app-server-daemon/releases"

    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_MODE=1 /bin/bash --noprofile --norc << 'INNER'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/bin/clean.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
DRY_RUN=false
files_cleaned=0
total_size_cleaned=0
total_items=0
start_section_spinner() { :; }
stop_section_spinner() { :; }
start_inline_spinner() { :; }
stop_inline_spinner() { :; }
note_activity() { :; }
is_path_whitelisted() { return 1; }
_MOLE_COMPLETE_LSOF_MODE=direct
run_with_timeout() { shift; "$@"; }
lsof() { return 1; }
clean_codex_daemon_releases
INNER

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"Codex daemon old releases"* ]] || return 1
    [[ ! -d "$releases/0.157.0-aarch64-apple-darwin" ]] || return 1
    [[ ! -d "$releases/local-0a1b2c3d4e5f-aarch64-apple-darwin" ]] || return 1
    [[ -d "$releases/0.161.0-aarch64-apple-darwin" ]] || return 1
    [[ -d "$releases/0.160.1-aarch64-apple-darwin" ]] || return 1
    [[ -d "$releases/.unpack-tmp" ]]
}

@test "clean_agent_browser_old_chrome removes superseded builds and keeps the one agent-browser launches (#1748)" {
    run env HOME="$HOME/agent-browser-positive" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_NO_AUTH=1 /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
root="$HOME/.agent-browser/browsers"
app="Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing"
build() {
    mkdir -p "$root/$1/chrome-mac-arm64"
    if [[ "$2" == binary ]]; then
        mkdir -p "$root/$1/chrome-mac-arm64/${app%/*}"
        touch "$root/$1/chrome-mac-arm64/$app"
    fi
    [[ "$3" == today ]] || touch -t 202601010000 "$root/$1"
}
# agent-browser walks names in byte order, so it launches 99, not 152.
build chrome-99.0.4844.51 binary old
build chrome-152.0.7977.64 binary old
build chrome-151.0.7922.47 binary old
build chrome-149.0.7827.54 binary old
build chrome-146.0.7680.165 none old
build chrome-146.0.7680.153 binary today
mkdir -p "$HOME/.agent-browser/sessions"
touch "$HOME/.agent-browser/sessions/state.json"
printf '{"executablePath": "%s"}\n' "$root/chrome-149.0.7827.54/chrome-mac-arm64/$app" > "$HOME/.agent-browser/config.json"

source "$PROJECT_ROOT/bin/clean.sh"
pgrep() { return 1; }
DRY_RUN=false
MOLE_DRY_RUN=0
clean_agent_browser_old_chrome

for gone in chrome-152.0.7977.64 chrome-151.0.7922.47; do
    [[ ! -e "$root/$gone" ]] || { echo "STILL_PRESENT:$gone"; exit 1; }
done
for kept in chrome-99.0.4844.51 chrome-149.0.7827.54 chrome-146.0.7680.165 chrome-146.0.7680.153; do
    [[ -d "$root/$kept" ]] || { echo "REMOVED:$kept"; exit 1; }
done
[[ -f "$HOME/.agent-browser/sessions/state.json" && -f "$HOME/.agent-browser/config.json" ]] || exit 1
echo "AGENT_BROWSER_PLAN_HELD"
EOF

    assert_run_success
    assert_output_contains "AGENT_BROWSER_PLAN_HELD"
    assert_output_not_contains "STILL_PRESENT:"
    assert_output_not_contains "REMOVED:"
}

@test "clean_agent_browser_old_chrome keeps builds pinned through a symlink" {
    run env HOME="$HOME/agent-browser-symlink-pin" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_NO_AUTH=1 /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
root="$HOME/.agent-browser/browsers"
app="Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing"
for name in chrome-99.0.4844.51 chrome-152.0.7977.64 chrome-151.0.7922.47 chrome-150.0.7900.10; do
    mkdir -p "$root/$name/chrome-mac-arm64/${app%/*}"
    touch "$root/$name/chrome-mac-arm64/$app"
    touch -t 202601010000 "$root/$name"
done
# Neither pin names its build in text: one is an env var symlink, the other a
# config path through a symlinked folder.
mkdir -p "$HOME/bin"
ln -s "$root/chrome-152.0.7977.64/chrome-mac-arm64/$app" "$HOME/bin/chrome"
ln -s "$root/chrome-150.0.7900.10" "$HOME/pinned-build"
printf '{"executablePath": "%s"}\n' "$HOME/pinned-build/chrome-mac-arm64/$app" > "$HOME/.agent-browser/config.json"
export AGENT_BROWSER_EXECUTABLE_PATH="$HOME/bin/chrome"

source "$PROJECT_ROOT/bin/clean.sh"
pgrep() { return 1; }
DRY_RUN=false
MOLE_DRY_RUN=0
clean_agent_browser_old_chrome

[[ ! -e "$root/chrome-151.0.7922.47" ]] || { echo "STILL_PRESENT:chrome-151.0.7922.47"; exit 1; }
for kept in chrome-99.0.4844.51 chrome-152.0.7977.64 chrome-150.0.7900.10; do
    [[ -d "$root/$kept" ]] || { echo "REMOVED:$kept"; exit 1; }
done
echo "SYMLINK_PINS_HELD"
EOF

    assert_run_success
    assert_output_contains "SYMLINK_PINS_HELD"
    assert_output_not_contains "STILL_PRESENT:"
    assert_output_not_contains "REMOVED:"
}

@test "clean_agent_browser_old_chrome names a changed plan instead of deferring as active" {
    run env HOME="$HOME/agent-browser-plan-changed" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_NO_AUTH=1 /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
root="$HOME/.agent-browser/browsers"
mkdir -p "$root/chrome-151.0.7922.47"
source "$PROJECT_ROOT/bin/clean.sh"
pgrep() { return 1; }
DRY_RUN=false
MOLE_DRY_RUN=0
plan_calls=0
# The recheck at the delete boundary sees a different retention set.
_plan_agent_browser_chrome_targets() {
    plan_calls=$((plan_calls + 1))
    _MOLE_AGENT_BROWSER_TARGETS=()
    [[ $plan_calls -gt 1 ]] || _MOLE_AGENT_BROWSER_TARGETS=("$root/chrome-151.0.7922.47")
    return 0
}
mole_defer_cleanup_family() { echo "DEFERRED_AS_ACTIVE:$1"; }
clean_agent_browser_old_chrome
[[ -d "$root/chrome-151.0.7922.47" ]] || { echo "REMOVED"; exit 1; }
EOF

    assert_run_success
    assert_output_contains "agent-browser old Chrome · stopped (retention changed)"
    assert_output_not_contains "DEFERRED_AS_ACTIVE"
    assert_output_not_contains "REMOVED"
}

@test "clean_agent_browser_old_chrome keeps every build while its Chrome runs" {
    run env HOME="$HOME/agent-browser-running" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_NO_AUTH=1 /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
root="$HOME/.agent-browser/browsers"
app="Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing"
for name in chrome-152.0.7977.64 chrome-151.0.7922.47; do
    mkdir -p "$root/$name/chrome-mac-arm64/${app%/*}"
    touch "$root/$name/chrome-mac-arm64/$app"
    touch -t 202601010000 "$root/$name"
done
source "$PROJECT_ROOT/bin/clean.sh"
pgrep() { [[ "$1" == "-f" && "$2" == "/.agent-browser/browsers/" ]]; }
DRY_RUN=false
MOLE_DRY_RUN=0
clean_agent_browser_old_chrome
[[ -d "$root/chrome-151.0.7922.47" ]] || { echo "REMOVED_WHILE_RUNNING"; exit 1; }
echo "AGENT_BROWSER_RUNNING_KEPT"
EOF

    assert_run_success
    assert_output_contains "AGENT_BROWSER_RUNNING_KEPT"
    assert_output_not_contains "agent-browser old Chrome · stopped"
}

@test "clean_agent_browser_old_chrome keeps every build when its process probe fails" {
    run env HOME="$HOME/agent-browser-unknown" PROJECT_ROOT="$PROJECT_ROOT" MOLE_TEST_NO_AUTH=1 /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
root="$HOME/.agent-browser/browsers"
app="Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing"
for name in chrome-152.0.7977.64 chrome-151.0.7922.47; do
    mkdir -p "$root/$name/chrome-mac-arm64/${app%/*}"
    touch "$root/$name/chrome-mac-arm64/$app"
    touch -t 202601010000 "$root/$name"
done
source "$PROJECT_ROOT/bin/clean.sh"
pgrep() { return 2; }
DRY_RUN=false
MOLE_DRY_RUN=0
clean_agent_browser_old_chrome
[[ -d "$root/chrome-151.0.7922.47" ]] || { echo "REMOVED_WITH_UNKNOWN_STATE"; exit 1; }
echo "AGENT_BROWSER_UNKNOWN_KEPT"
EOF

    assert_run_success
    assert_output_contains "AGENT_BROWSER_UNKNOWN_KEPT"
    assert_output_contains "agent-browser old Chrome · stopped (process state unknown)"
}

# Claude Code and Codex disposable state. Deletion authority is evidence the
# owner wrote itself: Claude Code's .orphaned_at marker, a config temp whose
# writer pid is gone, or an empty Codex temp skeleton. Each case runs in its own
# HOME and reaches the real sink through bin/clean.sh.
ai_state_case_home() {
    local case_home="$HOME/ai-state-$BATS_TEST_NUMBER"
    rm -rf "$case_home"
    mkdir -p "$case_home"
    printf '%s\n' "$case_home"
}

ai_state_age_tree() {
    local old_stamp
    old_stamp=$(date -v-30d +%Y%m%d%H%M)
    find "$1" -exec touch -h -t "$old_stamp" {} +
}

# ps double: `-p <pid>` answers from $HOME/ps-alive (or fails when
# $HOME/ps-error exists); the argv table names every path in $HOME/ps-busy.
ai_state_fake_ps_body() {
    cat << 'BODY'
if [[ "${1:-}" == "-p" ]]; then
    [[ -f "$HOME/ps-error" ]] && { echo "ps: broken" >&2; exit 2; }
    if [[ -f "$HOME/ps-alive" ]] && grep -qx "$2" "$HOME/ps-alive"; then
        printf '%5s\n' "$2"
        exit 0
    fi
    exit 1
fi
[[ "$*" == *args* ]] || exit 0
printf '  PID  PPID COMM ARGS\n'
printf '  100     1 launchd /sbin/launchd\n'
if [[ -f "$HOME/ps-busy" ]]; then
    while IFS= read -r busy; do
        printf '  4242     1 node node %s\n' "$busy"
    done < "$HOME/ps-busy"
fi
BODY
}

# Usage: ai_state_run <case_home> <function> [prelude]
ai_state_run() {
    local case_home="$1"
    local call="$2"
    local prelude="${3:-}"
    mole_test_fake_command ps "$(ai_state_fake_ps_body)"
    run env -u CLAUDE_CONFIG_DIR HOME="$case_home" PROJECT_ROOT="$PROJECT_ROOT" \
        MOLE_TEST_NO_AUTH=1 AI_STATE_CALL="$call" AI_STATE_PRELUDE="$prelude" \
        /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/bin/clean.sh"
DRY_RUN=false
mole_defer_cleanup_family() { printf 'DEFER=%s\n' "$1"; }
pgrep() { return 1; }
eval "$AI_STATE_PRELUDE"
"$AI_STATE_CALL"
EOF
}

# cache/m/p/old carries an orphan marker from 30 days ago; cache/m/p/new is the
# registered installPath. Every file is aged 30 days.
claude_plugin_fixture() {
    local case_home="$1"
    local marker="${2:-}"
    local plugins="$case_home/.claude/plugins"
    mkdir -p "$plugins/cache/m/p/old" "$plugins/cache/m/p/new" \
        "$plugins/marketplaces/m" "$plugins/data/p"
    printf 'old\n' > "$plugins/cache/m/p/old/server.js"
    printf 'new\n' > "$plugins/cache/m/p/new/server.js"
    printf 'state\n' > "$plugins/data/p/state.json"
    if [[ -z "$marker" ]]; then
        marker="$(($(date -v-30d +%s) * 1000))"
    fi
    printf '%s' "$marker" > "$plugins/cache/m/p/old/.orphaned_at"
    printf '{"version":2,"plugins":{"p@m":[{"scope":"user","installPath":"%s","version":"new"}]}}\n' \
        "$plugins/cache/m/p/new" > "$plugins/installed_plugins.json"
    ai_state_age_tree "$plugins"
}

@test "claude orphan plugin version with an aged marker is removed" {
    local case_home
    case_home=$(ai_state_case_home)
    claude_plugin_fixture "$case_home"
    local cache="$case_home/.claude/plugins/cache/m/p"

    ai_state_run "$case_home" clean_claude_plugin_orphans

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ ! -e "$cache/old" ] || { echo "$output"; return 1; }
    [ -f "$cache/new/server.js" ] || return 1
    [ -f "$case_home/.claude/plugins/installed_plugins.json" ] || return 1
    [ -f "$case_home/.claude/plugins/data/p/state.json" ] || return 1
    [ -d "$case_home/.claude/plugins/marketplaces/m" ] || return 1
    [[ "$output" == *"Claude Code orphaned plugin versions"* ]]
}

@test "claude orphan plugin version keeps an orphan version referenced by a running MCP" {
    local case_home
    case_home=$(ai_state_case_home)
    claude_plugin_fixture "$case_home"
    local cache="$case_home/.claude/plugins/cache/m/p"
    printf '%s\n' "$cache/old/server.js" > "$case_home/ps-busy"

    ai_state_run "$case_home" clean_claude_plugin_orphans

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ -f "$cache/old/server.js" ] || { echo "$output"; return 1; }
    [[ "$output" == *"DEFER=Claude Code plugins"* ]]
}

@test "claude orphan plugin version keeps when the marker is younger than 7d" {
    local case_home
    case_home=$(ai_state_case_home)
    claude_plugin_fixture "$case_home" "$(($(date -v-2d +%s) * 1000))"
    local cache="$case_home/.claude/plugins/cache/m/p"

    ai_state_run "$case_home" clean_claude_plugin_orphans

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ -f "$cache/old/server.js" ] || { echo "$output"; return 1; }
    [[ "$output" != *"Claude Code orphaned plugin versions"* ]]
}

@test "claude orphan plugin version keeps when the marker mtime is fresh" {
    local case_home
    case_home=$(ai_state_case_home)
    claude_plugin_fixture "$case_home"
    local cache="$case_home/.claude/plugins/cache/m/p"
    touch "$cache/old/.orphaned_at"

    ai_state_run "$case_home" clean_claude_plugin_orphans

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ -f "$cache/old/server.js" ] || { echo "$output"; return 1; }
}

@test "claude orphan plugin version keeps when the marker content is not numeric" {
    local case_home
    case_home=$(ai_state_case_home)
    claude_plugin_fixture "$case_home" "yesterday"
    local cache="$case_home/.claude/plugins/cache/m/p"

    ai_state_run "$case_home" clean_claude_plugin_orphans

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ -f "$cache/old/server.js" ] || { echo "$output"; return 1; }
}

@test "claude orphan plugin version keeps a marked dir that is still an installPath" {
    local case_home
    case_home=$(ai_state_case_home)
    claude_plugin_fixture "$case_home"
    local cache="$case_home/.claude/plugins/cache/m/p"
    printf '{"version":2,"plugins":{"p@m":[{"installPath":"%s"},{"installPath":"%s"}]}}\n' \
        "$cache/new" "$cache/old" > "$case_home/.claude/plugins/installed_plugins.json"

    ai_state_run "$case_home" clean_claude_plugin_orphans

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ -f "$cache/old/server.js" ] || { echo "$output"; return 1; }
}

@test "claude orphan plugin version keeps everything when installed_plugins.json is malformed" {
    local case_home
    case_home=$(ai_state_case_home)
    claude_plugin_fixture "$case_home"
    local cache="$case_home/.claude/plugins/cache/m/p"
    printf '{"version":2,"plugins":{' > "$case_home/.claude/plugins/installed_plugins.json"

    ai_state_run "$case_home" clean_claude_plugin_orphans

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ -f "$cache/old/server.js" ] || { echo "$output"; return 1; }
    [[ "$output" == *"Claude Code plugin cache · stopped (plugin registry unreadable)"* ]]
}

@test "claude orphan plugin version keeps everything when the registry lists no installPath" {
    local case_home
    case_home=$(ai_state_case_home)
    claude_plugin_fixture "$case_home"
    local cache="$case_home/.claude/plugins/cache/m/p"
    printf '{"version":3,"plugins":{"p@m":[{"scope":"user","install_path":"%s"}]}}\n' \
        "$cache/new" > "$case_home/.claude/plugins/installed_plugins.json"

    ai_state_run "$case_home" clean_claude_plugin_orphans

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ -f "$cache/old/server.js" ] || { echo "$output"; return 1; }
    [[ "$output" == *"Claude Code plugin cache · stopped (plugin registry unreadable)"* ]]
}

@test "claude orphan plugin version rejects a symlinked plugin level" {
    local case_home
    case_home=$(ai_state_case_home)
    claude_plugin_fixture "$case_home"
    local outside="$case_home/outside-plugin"
    mv "$case_home/.claude/plugins/cache/m/p" "$outside"
    ln -s "$outside" "$case_home/.claude/plugins/cache/m/p"

    ai_state_run "$case_home" clean_claude_plugin_orphans

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ -f "$outside/old/server.js" ] || { echo "$output"; return 1; }
    [ -f "$outside/old/.orphaned_at" ] || return 1
    # Rejected at the scan, before the sink's own containment check.
    [[ "$output" != *"stopped"* ]]
}

@test "claude orphan plugin version whitelist of ~/.claude keeps it" {
    local case_home
    case_home=$(ai_state_case_home)
    claude_plugin_fixture "$case_home"
    local cache="$case_home/.claude/plugins/cache/m/p"

    # shellcheck disable=SC2016 # The prelude is evaluated by the child shell.
    ai_state_run "$case_home" clean_claude_plugin_orphans 'WHITELIST_PATTERNS=("$HOME/.claude")'

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ -f "$cache/old/server.js" ] || { echo "$output"; return 1; }
}

@test "claude orphan plugin version keeps when the marker is replaced before the sink" {
    local case_home
    case_home=$(ai_state_case_home)
    claude_plugin_fixture "$case_home"
    local cache="$case_home/.claude/plugins/cache/m/p"

    # Swap in a new, equally old marker right before the deletion boundary.
    # shellcheck disable=SC2016 # The prelude is evaluated by the child shell.
    ai_state_run "$case_home" clean_claude_plugin_orphans '
eval "_ai_state_orig_guard() $(declare -f _dev_process_delete_guard_allows | tail -n +2)"
_dev_process_delete_guard_allows() {
    if [[ -n "${1:-}" ]]; then
        printf "%s" "$(($(date -v-20d +%s) * 1000))" > "$1/.orphaned_at.new"
        mv "$1/.orphaned_at.new" "$1/.orphaned_at"
        touch -t "$(date -v-30d +%Y%m%d%H%M)" "$1/.orphaned_at"
    fi
    _ai_state_orig_guard "$@"
}'

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ -f "$cache/old/server.js" ] || { echo "$output"; return 1; }
    [[ "$output" == *"stopped (process or cache path state unknown)"* ]]
}

# Prelude: right before the deletion boundary, replace installed_plugins.json
# with the staged installed_plugins.next.
# shellcheck disable=SC2016 # The prelude is evaluated by the child shell.
CLAUDE_PLUGIN_SWAP_REGISTRY='
eval "_ai_state_orig_guard() $(declare -f _dev_process_delete_guard_allows | tail -n +2)"
_dev_process_delete_guard_allows() {
    if [[ -n "${1:-}" ]]; then
        cp "$HOME/.claude/plugins/installed_plugins.next" "$HOME/.claude/plugins/installed_plugins.json"
    fi
    _ai_state_orig_guard "$@"
}'

@test "claude orphan plugin version keeps when it is registered again before the sink" {
    local case_home
    case_home=$(ai_state_case_home)
    claude_plugin_fixture "$case_home"
    local plugins="$case_home/.claude/plugins"
    local cache="$plugins/cache/m/p"
    printf '{"version":2,"plugins":{"p@m":[{"scope":"user","installPath":"%s","version":"old"}]}}\n' \
        "$cache/old" > "$plugins/installed_plugins.next"

    ai_state_run "$case_home" clean_claude_plugin_orphans "$CLAUDE_PLUGIN_SWAP_REGISTRY"

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ -f "$cache/old/server.js" ] || { echo "$output"; return 1; }
    [[ "$output" == *"stopped (process or cache path state unknown)"* ]] || { echo "$output"; return 1; }
}

@test "claude orphan plugin version keeps when the registry turns unreadable before the sink" {
    local case_home
    case_home=$(ai_state_case_home)
    claude_plugin_fixture "$case_home"
    local plugins="$case_home/.claude/plugins"
    local cache="$plugins/cache/m/p"
    printf 'not a registry\n' > "$plugins/installed_plugins.next"

    ai_state_run "$case_home" clean_claude_plugin_orphans "$CLAUDE_PLUGIN_SWAP_REGISTRY"

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ -f "$cache/old/server.js" ] || { echo "$output"; return 1; }
    [[ "$output" == *"stopped (process or cache path state unknown)"* ]] || { echo "$output"; return 1; }
}

# A 30-day-old atomic-write temp from pid 999999 next to a fresher live config.
claude_config_temp_fixture() {
    local case_home="$1"
    local name="${2:-.claude.json.tmp.999999.abc123}"
    printf '{"old":true}\n' > "$case_home/$name"
    printf '{"backup":true}\n' > "$case_home/.claude.json.backup"
    ai_state_age_tree "$case_home/$name"
    ai_state_age_tree "$case_home/.claude.json.backup"
    printf '{"live":true}\n' > "$case_home/.claude.json"
}

@test "claude config temp from a dead writer is removed" {
    local case_home
    case_home=$(ai_state_case_home)
    claude_config_temp_fixture "$case_home"

    ai_state_run "$case_home" clean_claude_config_temps

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ ! -e "$case_home/.claude.json.tmp.999999.abc123" ] || { echo "$output"; return 1; }
    [ -f "$case_home/.claude.json" ] || return 1
    [ -f "$case_home/.claude.json.backup" ]
}

@test "claude config temp keeps a config temp whose pid is alive" {
    local case_home
    case_home=$(ai_state_case_home)
    claude_config_temp_fixture "$case_home"
    printf '999999\n' > "$case_home/ps-alive"

    ai_state_run "$case_home" clean_claude_config_temps

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ -f "$case_home/.claude.json.tmp.999999.abc123" ] || { echo "$output"; return 1; }
}

@test "claude config temp keeps when ps errors" {
    local case_home
    case_home=$(ai_state_case_home)
    claude_config_temp_fixture "$case_home"
    : > "$case_home/ps-error"

    ai_state_run "$case_home" clean_claude_config_temps

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ -f "$case_home/.claude.json.tmp.999999.abc123" ] || { echo "$output"; return 1; }
}

@test "claude config temp ignores .claude.json.tmp.x.y with a non-numeric pid" {
    local case_home
    case_home=$(ai_state_case_home)
    claude_config_temp_fixture "$case_home" ".claude.json.tmp.x.y"

    ai_state_run "$case_home" clean_claude_config_temps

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ -f "$case_home/.claude.json.tmp.x.y" ] || { echo "$output"; return 1; }
}

@test "claude config temp keeps a fresh temp" {
    local case_home
    case_home=$(ai_state_case_home)
    claude_config_temp_fixture "$case_home"
    touch -t "$(date -v-1d +%Y%m%d%H%M)" "$case_home/.claude.json.tmp.999999.abc123"

    ai_state_run "$case_home" clean_claude_config_temps

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ -f "$case_home/.claude.json.tmp.999999.abc123" ] || { echo "$output"; return 1; }
}

@test "claude config temp keeps the temp when the live config is missing or older" {
    local case_home
    case_home=$(ai_state_case_home)
    claude_config_temp_fixture "$case_home"
    rm -f "$case_home/.claude.json"

    ai_state_run "$case_home" clean_claude_config_temps

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ -f "$case_home/.claude.json.tmp.999999.abc123" ] || { echo "$output"; return 1; }

    printf '{"live":true}\n' > "$case_home/.claude.json"
    touch -t "$(date -v-40d +%Y%m%d%H%M)" "$case_home/.claude.json"

    ai_state_run "$case_home" clean_claude_config_temps

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ -f "$case_home/.claude.json.tmp.999999.abc123" ] || { echo "$output"; return 1; }
}

# Empty, 30-day-old Codex temp skeletons plus a non-empty clone dir.
codex_skeleton_fixture() {
    local case_home="$1"
    mkdir -p "$case_home/.codex/.tmp/git-AbC123" "$case_home/.codex/.tmp/git-busy01" \
        "$case_home/.codex/.tmp/git-ABCDEFG" "$case_home/.codex/tmp/arg0/codex-arg0Xy9Z01" \
        "$case_home/.codex/tmp/path/keep"
    printf 'ref\n' > "$case_home/.codex/.tmp/git-busy01/HEAD"
    ai_state_age_tree "$case_home/.codex"
}

@test "codex empty git skeleton older than 7d is removed" {
    local case_home
    case_home=$(ai_state_case_home)
    codex_skeleton_fixture "$case_home"

    ai_state_run "$case_home" clean_codex_temp_skeletons

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ ! -e "$case_home/.codex/.tmp/git-AbC123" ] || { echo "$output"; return 1; }
    [ ! -e "$case_home/.codex/tmp/arg0/codex-arg0Xy9Z01" ] || { echo "$output"; return 1; }
    [ -d "$case_home/.codex/tmp/path/keep" ] || return 1
    [ -d "$case_home/.codex/tmp/arg0" ]
}

@test "codex empty git skeleton keeps a non-empty git-* dir" {
    local case_home
    case_home=$(ai_state_case_home)
    codex_skeleton_fixture "$case_home"

    ai_state_run "$case_home" clean_codex_temp_skeletons

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ -f "$case_home/.codex/.tmp/git-busy01/HEAD" ] || { echo "$output"; return 1; }
}

@test "codex empty git skeleton keeps everything while codex runs" {
    local case_home
    case_home=$(ai_state_case_home)
    codex_skeleton_fixture "$case_home"

    ai_state_run "$case_home" clean_codex_temp_skeletons \
        'pgrep() { [[ "$*" == *codex* ]] && return 0; return 1; }'

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ -d "$case_home/.codex/.tmp/git-AbC123" ] || { echo "$output"; return 1; }
    [ -d "$case_home/.codex/tmp/arg0/codex-arg0Xy9Z01" ] || return 1
    [[ "$output" == *"DEFER=Codex"* ]]
}

@test "codex empty git skeleton stops when the process state is unknown" {
    local case_home
    case_home=$(ai_state_case_home)
    codex_skeleton_fixture "$case_home"

    ai_state_run "$case_home" clean_codex_temp_skeletons 'pgrep() { return 3; }'

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ -d "$case_home/.codex/.tmp/git-AbC123" ] || { echo "$output"; return 1; }
    [[ "$output" == *"Codex temp dirs · stopped (process state unknown)"* ]]
}

@test "codex empty git skeleton keeps a dir that gains an entry before the sink" {
    local case_home
    case_home=$(ai_state_case_home)
    codex_skeleton_fixture "$case_home"

    # shellcheck disable=SC2016 # The prelude is evaluated by the child shell.
    ai_state_run "$case_home" clean_codex_temp_skeletons '
eval "_ai_state_orig_guard() $(declare -f _dev_process_delete_guard_allows | tail -n +2)"
_dev_process_delete_guard_allows() {
    if [[ -n "${1:-}" ]]; then
        printf "ref\n" > "$1/HEAD"
        touch -t "$(date -v-30d +%Y%m%d%H%M)" "$1"
    fi
    _ai_state_orig_guard "$@"
}'

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ -f "$case_home/.codex/.tmp/git-AbC123/HEAD" ] || { echo "$output"; return 1; }
    [[ "$output" == *"Codex temp dirs · stopped (process state unknown)"* ]]
}

# The shape Codex actually leaks: `git init` left HEAD and empty objects/
# and refs/, and nothing was ever fetched.
codex_git_stub() {
    mkdir -p "$1/objects" "$1/refs"
    printf 'ref: refs/heads/main\n' > "$1/HEAD"
}

@test "codex git init stub older than 7d is removed" {
    local case_home tmp
    case_home=$(ai_state_case_home)
    tmp="$case_home/.codex/.tmp"
    codex_git_stub "$tmp/git-StUb01"
    ai_state_age_tree "$case_home/.codex"

    ai_state_run "$case_home" clean_codex_temp_skeletons

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ ! -e "$tmp/git-StUb01" ] || { echo "$output"; return 1; }
    [ -d "$tmp" ]
}

@test "codex git init stub keeps fetched objects, extra entries and fresh stubs" {
    local case_home tmp
    case_home=$(ai_state_case_home)
    tmp="$case_home/.codex/.tmp"
    codex_git_stub "$tmp/git-Fetch1"
    mkdir -p "$tmp/git-Fetch1/objects/pack"
    printf 'pack\n' > "$tmp/git-Fetch1/objects/pack/pack-1.pack"
    codex_git_stub "$tmp/git-Extra1"
    printf '[core]\n' > "$tmp/git-Extra1/config"
    codex_git_stub "$tmp/git-Fresh1"
    ai_state_age_tree "$case_home/.codex"
    printf 'ref: refs/heads/main\n' > "$tmp/git-Fresh1/HEAD"

    ai_state_run "$case_home" clean_codex_temp_skeletons

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ -f "$tmp/git-Fetch1/objects/pack/pack-1.pack" ] || { echo "$output"; return 1; }
    [ -f "$tmp/git-Extra1/config" ] || return 1
    [ -f "$tmp/git-Fresh1/HEAD" ]
}

@test "codex empty git skeleton ignores git-ABCDEFG (7 chars)" {
    local case_home
    case_home=$(ai_state_case_home)
    codex_skeleton_fixture "$case_home"

    ai_state_run "$case_home" clean_codex_temp_skeletons

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ -d "$case_home/.codex/.tmp/git-ABCDEFG" ] || { echo "$output"; return 1; }
}

@test "ai cli disposable state dry-run lists only eligible paths and writes nothing" {
    local case_home
    case_home=$(ai_state_case_home)
    claude_plugin_fixture "$case_home"
    claude_config_temp_fixture "$case_home"
    codex_skeleton_fixture "$case_home"
    local cache="$case_home/.claude/plugins/cache/m/p"

    # shellcheck disable=SC2016 # The prelude is evaluated by the child shell.
    ai_state_run "$case_home" ai_state_dry_run_all '
DRY_RUN=true
ai_state_dry_run_all() {
    clean_claude_code_disposable_state
    clean_codex_temp_skeletons
    printf "LEDGER=%s\n" "$(tr "\0" "\n" < "$CLEAN_PREVIEW_LEDGER_FILE" 2> /dev/null || true)"
}
CLEAN_PREVIEW_LEDGER_FILE="$HOME/ledger"
: > "$CLEAN_PREVIEW_LEDGER_FILE"'

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ -f "$cache/old/server.js" ] || { echo "$output"; return 1; }
    [ -f "$cache/old/.orphaned_at" ] || return 1
    [ -f "$case_home/.claude.json.tmp.999999.abc123" ] || return 1
    [ -d "$case_home/.codex/.tmp/git-AbC123" ] || return 1
    [ -d "$case_home/.codex/tmp/arg0/codex-arg0Xy9Z01" ] || return 1
    [[ "$output" == *"$cache/old"* ]] || return 1
    [[ "$output" == *"$case_home/.claude.json.tmp.999999.abc123"* ]] || return 1
    [[ "$output" == *"$case_home/.codex/.tmp/git-AbC123"* ]] || return 1
    [[ "$output" != *"$cache/new"* ]] || return 1
    [[ "$output" != *"git-busy01"* ]] || return 1
    [[ "$output" != *"git-ABCDEFG"* ]] || return 1
    [[ "$output" != *"$case_home/.claude.json.backup"* ]]
}

# ----------------------------------------------------------------------------
# Automation browser profiles and dot-directory caches (clean_fork_app_caches)
# ----------------------------------------------------------------------------

# Chromium user-data-dir with cache leaves and login state.
automation_profile_fixture() {
    local root="$1"
    mkdir -p "$root/Default/GPUCache" "$root/Default/Local Storage" "$root/extensions_crx_cache"
    printf 'g\n' > "$root/Default/GPUCache/g"
    printf 'l\n' > "$root/Default/Local Storage/l"
    printf 'cookies\n' > "$root/Default/Cookies"
    printf 'x\n' > "$root/extensions_crx_cache/x"
    printf '{}\n' > "$root/Local State"
}

@test "x-browser-profile caches kept while a browser uses --user-data-dir" {
    local case_home root
    case_home=$(fork_caches_case_home)
    root="$case_home/.local/share/x-browser-profile"
    automation_profile_fixture "$root"
    printf 'Chrome --user-data-dir=%s --remote-debugging-port=9222\n' "$root" > "$case_home/ps-busy"

    fork_caches_run "$case_home" clean_fork_app_caches

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ -f "$root/Default/GPUCache/g" ] || { echo "$output"; return 1; }
    [ -f "$root/extensions_crx_cache/x" ] || return 1
    [[ "$output" == *"DEFER=x-browser-profile"* ]] || return 1

    rm -f "$case_home/ps-busy"
    fork_caches_run "$case_home" clean_fork_app_caches

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ ! -e "$root/Default/GPUCache/g" ] || { echo "$output"; return 1; }
    [ ! -e "$root/extensions_crx_cache/x" ] || return 1
    [ -f "$root/Default/Cookies" ] || return 1
    [ -f "$root/Default/Local Storage/l" ] || return 1
    [ -f "$root/Local State" ]
}

@test "x-browser-profile caches kept when the process table is unreadable" {
    local case_home root
    case_home=$(fork_caches_case_home)
    root="$case_home/.local/share/x-browser-profile"
    automation_profile_fixture "$root"
    touch "$case_home/ps-error"

    fork_caches_run "$case_home" clean_fork_app_caches

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ -f "$root/Default/GPUCache/g" ] || { echo "$output"; return 1; }
    [[ "$output" == *"x-browser-profile caches · stopped (process state unknown)"* ]]
}

@test "gemini-web-pool account profile-acct2 is cleaned while profile-acct20 is in use" {
    local case_home accounts
    case_home=$(fork_caches_case_home)
    accounts="$case_home/.gemini-web-pool/accounts"
    automation_profile_fixture "$accounts/profile-acct2"
    automation_profile_fixture "$accounts/profile-acct20"
    printf '{"cookie":"secret"}\n' > "$accounts/acct2.json"
    printf 'Chrome --user-data-dir=%s\n' "$accounts/profile-acct20" > "$case_home/ps-busy"

    fork_caches_run "$case_home" clean_fork_app_caches

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ ! -e "$accounts/profile-acct2/Default/GPUCache/g" ] || { echo "$output"; return 1; }
    [ -f "$accounts/profile-acct2/Default/Cookies" ] || return 1
    [ -f "$accounts/profile-acct20/Default/GPUCache/g" ] || return 1
    [ -f "$accounts/acct2.json" ] || return 1
    [[ "$output" == *"DEFER=gemini-web-pool profile-acct20"* ]]
}

@test "gemini-web-pool skips a symlinked account profile" {
    local case_home accounts
    case_home=$(fork_caches_case_home)
    accounts="$case_home/.gemini-web-pool/accounts"
    automation_profile_fixture "$case_home/outside-profile"
    mkdir -p "$accounts"
    ln -s "$case_home/outside-profile" "$accounts/profile-acct3"

    fork_caches_run "$case_home" clean_fork_app_caches

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ -f "$case_home/outside-profile/Default/GPUCache/g" ] || { echo "$output"; return 1; }
    [ -f "$case_home/outside-profile/extensions_crx_cache/x" ]
}

@test "nvm cache keeps files younger than 7d" {
    local case_home cache
    case_home=$(fork_caches_case_home)
    cache="$case_home/.nvm/.cache/bin/node-v20.0.0-darwin-arm64"
    mkdir -p "$cache" "$case_home/.nvm/versions/node/v20.0.0/bin"
    printf 'old\n' > "$cache/old.tar.xz"
    printf 'node\n' > "$case_home/.nvm/versions/node/v20.0.0/bin/node"
    printf '# nvm\n' > "$case_home/.nvm/nvm.sh"
    fork_caches_age_tree "$case_home/.nvm"
    printf 'new\n' > "$cache/new.tar.xz"

    fork_caches_run "$case_home" clean_fork_app_caches

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ ! -e "$cache/old.tar.xz" ] || { echo "$output"; return 1; }
    [ -f "$cache/new.tar.xz" ] || return 1
    [ -f "$case_home/.nvm/versions/node/v20.0.0/bin/node" ]
}

@test "nvm cache ignores an NVM_DIR outside HOME" {
    local case_home outside
    case_home=$(fork_caches_case_home)
    outside="$BATS_TEST_TMPDIR/nvm-outside"
    mkdir -p "$outside/.cache/bin"
    printf 'old\n' > "$outside/.cache/bin/old.tar.xz"
    fork_caches_age_tree "$outside"

    fork_caches_run "$case_home" clean_fork_app_caches "NVM_DIR='$outside'"

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ -f "$outside/.cache/bin/old.tar.xz" ] || { echo "$output"; return 1; }
}

@test "nvm cache ignores an NVM_DIR that is not an nvm install" {
    local case_home docs
    case_home=$(fork_caches_case_home)
    docs="$case_home/Documents"
    mkdir -p "$docs/.cache/bin"
    printf 'old\n' > "$docs/.cache/bin/old.tar.xz"
    fork_caches_age_tree "$docs"

    fork_caches_run "$case_home" clean_fork_app_caches "NVM_DIR='$docs'"

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ -f "$docs/.cache/bin/old.tar.xz" ] || { echo "$output"; return 1; }
}

@test "uv python .temp never touches interpreter dirs" {
    local case_home python_root
    case_home=$(fork_caches_case_home)
    python_root="$case_home/.local/share/uv/python"
    mkdir -p "$python_root/.temp/partial" "$python_root/cpython-3.12.0-macos-aarch64-none/bin"
    printf 'part\n' > "$python_root/.temp/partial/download.tar.gz"
    printf 'py\n' > "$python_root/cpython-3.12.0-macos-aarch64-none/bin/python3"
    fork_caches_age_tree "$python_root"

    fork_caches_run "$case_home" clean_fork_app_caches

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ ! -e "$python_root/.temp/partial/download.tar.gz" ] || { echo "$output"; return 1; }
    [ -f "$python_root/cpython-3.12.0-macos-aarch64-none/bin/python3" ]
}

@test "uv python .temp is kept while uv runs" {
    local case_home python_root
    case_home=$(fork_caches_case_home)
    python_root="$case_home/.local/share/uv/python"
    mkdir -p "$python_root/.temp/partial"
    printf 'part\n' > "$python_root/.temp/partial/download.tar.gz"
    fork_caches_age_tree "$python_root"
    printf '%s\n' "/opt/homebrew/bin/uv python install 3.13" > "$case_home/ps-busy"

    fork_caches_run "$case_home" clean_fork_app_caches

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [ -f "$python_root/.temp/partial/download.tar.gz" ] || { echo "$output"; return 1; }
    [[ "$output" == *"DEFER=uv"* ]]
}

@test "electron-gyp headers row is present in the frontend caches" {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
safe_clean() { printf 'SAFE:%s|%s\n' "$1" "${*: -1}"; }
clean_dev_frontend
EOF
    assert_run_success
    assert_output_contains "SAFE:$HOME/.electron-gyp/*|electron-gyp headers cache"
}

@test "clean_dev_misc registers the fork app caches step" {
    mole_test_fake_command mdfind
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" /bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
safe_clean() { :; }
safe_find_delete() { :; }
clean_service_worker_cache() { :; }
note_activity() { :; }
pgrep() { return 1; }
clean_fork_app_caches() { echo "FORK_CALLED"; }
clean_dev_misc
EOF
    assert_run_success
    assert_output_contains "FORK_CALLED"
}
