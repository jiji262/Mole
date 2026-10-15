#!/usr/bin/env bats
# Report-only review hints (lib/clean/review_hints_data.sh and
# lib/clean/review_hints_home.sh). Every case asserts that nothing the hint
# names was changed: these rows print manual commands and never act on them.

load helpers/common

setup_file() {
    mole_test_setup_home clean-review-hints-home
    PRELUDE="$BATS_FILE_TMPDIR/review-prelude.sh"
    export PRELUDE
    cat > "$PRELUDE" << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/lib/core/common.sh"
source "$PROJECT_ROOT/lib/clean/dev.sh"
source "$PROJECT_ROOT/lib/clean/review_hints_home.sh"
start_section_spinner() { :; }
stop_section_spinner() { :; }
note_activity() { :; }
bytes_to_human() { echo "$(($1 / 1024))KB"; }
EOF
}

teardown_file() {
    mole_test_teardown_home
}

setup() {
    if [[ "$HOME" != "${BATS_TEST_DIRNAME}/tmp-"* ]]; then
        printf 'FATAL: HOME is not a test temp dir: %s\n' "$HOME" >&2
        return 1
    fi
    rm -rf "${HOME:?}"/*
    rm -rf "${HOME:?}"/.[!.]* "${HOME:?}"/..?* 2> /dev/null || true
    mkdir -p "$HOME/.config/mole"
}

# Fixture repos ignore any system git config on the host.
git_fixture() {
    GIT_CONFIG_NOSYSTEM=1 git "$@"
}

run_review() {
    run env HOME="$HOME" PROJECT_ROOT="$PROJECT_ROOT" PRELUDE="$PRELUDE" NO_COLOR=1 \
        MOLE_CURRENT_COMMAND=clean MOLE_CLEAN_CANCEL_STATUS=0 "$@"
}

@test "prints Claude transcripts row with mo analyze command" {
    mkdir -p "$HOME/.claude/projects/-x"
    echo '{"type":"user"}' > "$HOME/.claude/projects/-x/a.jsonl"

    run_review /bin/bash --noprofile --norc << 'EOF'
source "$PRELUDE"
hint_get_path_size_kb_with_timeout() {
    case "$1" in "$HOME/.claude/projects") echo 300000 ;; *) echo 0 ;; esac
}
show_data_review_hints
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"Claude Code transcripts · 300000KB"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"mo analyze ~/.claude/projects"* ]] || { echo "$output"; return 1; }
    [[ "$output" != *"safe to delete"* ]] || return 1
    [ -f "$HOME/.claude/projects/-x/a.jsonl" ]
}

@test "rows below the review floor stay hidden" {
    mkdir -p "$HOME/.codex/sessions/2026"

    run_review /bin/bash --noprofile --norc << 'EOF'
source "$PRELUDE"
hint_get_path_size_kb_with_timeout() { echo 1024; }
show_data_review_hints
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" != *"Codex sessions"* ]] || { echo "$output"; return 1; }
    [ -d "$HOME/.codex/sessions/2026" ]
}

@test "missing-cwd transcripts counted only when cwd is absent" {
    local gone="$HOME/.claude/projects/-gone" here="$HOME/.claude/projects/-here"
    mkdir -p "$gone/memory" "$here"
    printf '{"cwd":"%s/gone","type":"user"}\n' "$HOME" > "$gone/s.jsonl"
    printf '{"cwd":"%s","type":"user"}\n' "$HOME" > "$here/s.jsonl"

    run_review /bin/bash --noprofile --norc << 'EOF'
source "$PRELUDE"
hint_get_path_size_kb_with_timeout() {
    case "$1" in
        */-gone/memory) echo 50000 ;;
        */-gone | */-here) echo 300000 ;;
        *) echo 0 ;;
    esac
}
show_data_review_hints
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"Claude transcripts with missing cwd · 250000KB · 1 found"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"-gone"* ]] || { echo "$output"; return 1; }
    [[ "$output" != *"-here"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"memory/ kept"* ]] || { echo "$output"; return 1; }
    [ -d "$gone/memory" ] || return 1
    [ -f "$gone/s.jsonl" ]
}

@test "subagent dir with a recent file is not idle" {
    local base="$HOME/.claude/projects/-p"
    mkdir -p "$base/old-session/subagents" "$base/new-session/subagents"
    touch -t 202001010000 "$base/old-session/subagents/agent.jsonl"
    touch "$base/new-session/subagents/agent.jsonl"

    run_review /bin/bash --noprofile --norc << 'EOF'
source "$PRELUDE"
hint_get_path_size_kb_with_timeout() {
    case "$1" in */subagents) echo 300000 ;; *) echo 0 ;; esac
}
show_data_review_hints
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"Claude subagent transcripts"*"300000KB · 1 found"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"old-session"* ]] || { echo "$output"; return 1; }
    [[ "$output" != *"new-session"* ]] || { echo "$output"; return 1; }
    [ -f "$base/old-session/subagents/agent.jsonl" ]
}

@test "vscode workspace state of uninstalled extension reported; installed one not" {
    local ws="$HOME/Library/Application Support/Code/User/workspaceStorage/abc123"
    local idle_ws="${ws%/*}/old456"
    mkdir -p "$ws/ms-python.python" "$ws/gone-pub.gone-ext" "$ws/vscode.git" "$idle_ws/gone-pub.gone-ext"
    mkdir -p "$HOME/.vscode/extensions/ms-python.python-2024.1.0"
    touch "$ws/workspace.json"
    touch -t 202001010000 "$idle_ws/workspace.json"

    run_review /bin/bash --noprofile --norc << 'EOF'
source "$PRELUDE"
hint_get_path_size_kb_with_timeout() {
    case "$1" in */abc123/* | */old456) echo 300000 ;; *) echo 0 ;; esac
}
show_data_review_hints
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"VS Code workspace state of uninstalled extensions · 300000KB · 1 found"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"VS Code workspaces idle 60+ days · 300000KB · 1 found"*"old456"* ]] || { echo "$output"; return 1; }
    [[ "$output" != *"old456/gone-pub"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"gone-pub.gone-ext"* ]] || { echo "$output"; return 1; }
    [[ "$output" != *"ms-python.python"* ]] || { echo "$output"; return 1; }
    [[ "$output" != *"vscode.git"* ]] || { echo "$output"; return 1; }
    [ -d "$ws/gone-pub.gone-ext" ]
}

@test "orphaned container hint skips an extension container of an installed app" {
    local containers="$HOME/Library/Containers"
    mkdir -p "$containers/com.vendor.App.ShareExtension" "$containers/com.gone.App" \
        "$containers/com.apple.Notes" "$containers/group.com.vendor.shared"

    run_review /bin/bash --noprofile --norc << 'EOF'
source "$PRELUDE"
hint_get_path_size_kb_with_timeout() {
    case "$1" in */Containers/*) echo 300000 ;; *) echo 0 ;; esac
}
bundle_has_installed_app() {
    echo "probe:$1" >&2
    [[ "$1" == "com.vendor.App" ]]
}
show_data_review_hints
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"Orphaned app containers (review) · 300000KB · 1 found"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"com.gone.App"* ]] || { echo "$output"; return 1; }
    [[ "$output" != *"ShareExtension ·"* && "$output" != *"ShareExtension,"* ]] || { echo "$output"; return 1; }
    [[ "$output" != *"probe:com.apple"* ]] || { echo "$output"; return 1; }
    [[ "$output" != *"probe:group."* ]] || { echo "$output"; return 1; }
    [ -d "$containers/com.gone.App" ]
}

@test "credential hint reports a 644 .env and ignores 600 and .env.example" {
    mkdir -p "$HOME/Downloads/proj" "$HOME/Downloads/locked"
    echo 'TOKEN=x' > "$HOME/Downloads/proj/.env"
    echo 'TOKEN=x' > "$HOME/Downloads/locked/.env"
    echo 'TOKEN=' > "$HOME/Downloads/proj/.env.example"
    chmod 644 "$HOME/Downloads/proj/.env" "$HOME/Downloads/proj/.env.example"
    chmod 600 "$HOME/Downloads/locked/.env"

    run_review /bin/bash --noprofile --norc << 'EOF'
source "$PRELUDE"
show_home_review_hints
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"1 found"*"~/Downloads/proj/.env"*"chmod 600"* ]] || { echo "$output"; return 1; }
    [[ "$output" != *"locked/.env"* ]] || { echo "$output"; return 1; }
    [[ "$output" != *".env.example"* ]] || { echo "$output"; return 1; }
    [[ "$output" != *"TOKEN"* ]] || { echo "$output"; return 1; }
    [ "$(stat -f %Lp "$HOME/Downloads/proj/.env")" = "644" ] || return 1
    [ "$(stat -f %Lp "$HOME/Downloads/locked/.env")" = "600" ]
}

@test "git hint reports an aged tmp_pack and prunable worktree" {
    local root="$HOME/code" repo="$HOME/code/repo"
    printf '%s\n' "$root" > "$HOME/.config/mole/purge_paths"
    mkdir -p "$repo"
    git_fixture -C "$repo" init -q
    git_fixture -C "$repo" -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m init
    git_fixture -C "$repo" worktree add -q "$root/wt-gone"
    rm -rf "$root/wt-gone"
    printf 'pack' > "$repo/.git/objects/pack/tmp_pack_abc123"
    touch -t 202001010000 "$repo/.git/objects/pack/tmp_pack_abc123"

    run_review /bin/bash --noprofile --norc << 'EOF'
source "$PRELUDE"
show_home_review_hints
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"Git temp packs"*"git -C"*"gc"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"Prunable git worktrees"*"git -C"*"worktree prune"* ]] || { echo "$output"; return 1; }
    [[ "$output" != *"safe to delete"* ]] || return 1
    compgen -G "$repo/.git/worktrees/*" > /dev/null || return 1
    [ -f "$repo/.git/objects/pack/tmp_pack_abc123" ]
}

@test "git hint skips locked, unmounted-volume and parentless prunable worktrees" {
    # git itself never marks a locked worktree prunable, so the listings are
    # written by hand to pin the guard rather than the git version.
    mkdir -p "$HOME/code"

    run_review /bin/bash --noprofile --norc << 'EOF'
source "$PRELUDE"
check() {
    local listing
    listing=$(printf 'worktree %s\nHEAD abc\ndetached\n%s\n\nworktree %s\nHEAD def\n' "$HOME/code/main" "$2" "$1")
    listing+=$'\n'"$3"
    if review_hint_has_prunable_worktree "$listing"; then echo "REPORT:$4"; else echo "SKIP:$4"; fi
}
check "$HOME/code/wt" "" "prunable gitdir file points to non-existent location" plain
check "$HOME/code/wt" "" $'locked\nprunable gitdir file points to non-existent location' locked
check "/Volumes/Ext/wt" "" "prunable gitdir file points to non-existent location" volume
check "$HOME/gone-parent/wt" "" "prunable gitdir file points to non-existent location" parentless
check "$HOME/code/wt" "" "" not-prunable
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"REPORT:plain"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"SKIP:locked"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"SKIP:volume"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"SKIP:parentless"* ]] || { echo "$output"; return 1; }
    [[ "$output" == *"SKIP:not-prunable"* ]]
}

@test "downloads duplicate hint finds byte-identical files and ignores same-size different files" {
    mkdir -p "$HOME/Downloads/sub"
    mkfile -n 210m "$HOME/Downloads/a.bin"
    mkfile -n 210m "$HOME/Downloads/sub/a-copy.bin"
    mkfile -n 210m "$HOME/Downloads/c.bin"
    printf 'x' | dd of="$HOME/Downloads/c.bin" bs=1 seek=4096 conv=notrunc 2> /dev/null

    run_review /bin/bash --noprofile --norc << 'EOF'
source "$PRELUDE"
show_home_review_hints
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"Duplicate downloads · 215040KB · 1 found"* ]] || { echo "$output"; return 1; }
    [[ "$output" != *"c.bin"* ]] || { echo "$output"; return 1; }
    [ -f "$HOME/Downloads/a.bin" ] || return 1
    [ -f "$HOME/Downloads/sub/a-copy.bin" ]
}

@test "downloads junk hint counts recycle bins and office lock files" {
    mkdir -p "$HOME/Downloads/usb/\$RECYCLE.BIN"
    touch "$HOME/Downloads/usb/desktop.ini" "$HOME/Downloads/~\$report.docx" "$HOME/Downloads/report.docx"

    run_review /bin/bash --noprofile --norc << 'EOF'
source "$PRELUDE"
show_home_review_hints
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"Downloads junk"*"3 found"* ]] || { echo "$output"; return 1; }
    [[ "$output" != *"~/Downloads/report.docx"* ]] || { echo "$output"; return 1; }
    [ -f "$HOME/Downloads/usb/desktop.ini" ]
}

@test "stale dotdir hint excludes .ssh and recent dirs" {
    mkdir -p "$HOME/.ssh/keys" "$HOME/.moletestorphan/data" "$HOME/.moletestrecent/data"
    touch -t 202001010000 "$HOME/.ssh/keys" "$HOME/.ssh" \
        "$HOME/.moletestorphan/data" "$HOME/.moletestorphan"
    touch -t 202001010000 "$HOME/.moletestrecent"

    run_review /bin/bash --noprofile --norc << 'EOF'
source "$PRELUDE"
hint_get_path_size_kb_with_timeout() {
    case "$1" in "$HOME"/.*) echo 300000 ;; *) echo 0 ;; esac
}
show_home_review_hints
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"Stale dot-directories"*"1 found"*"~/.moletestorphan"*"ls -la"* ]] || { echo "$output"; return 1; }
    [[ "$output" != *"~/.ssh"* ]] || { echo "$output"; return 1; }
    [[ "$output" != *"moletestrecent"* ]] || { echo "$output"; return 1; }
    [ -d "$HOME/.moletestorphan/data" ]
}

@test "hints stop at the wall-clock budget and print (partial scan)" {
    mkdir -p "$HOME/.claude/projects/-x"

    run_review MOLE_TIMEOUT_HINT_SCAN_SEC=0 /bin/bash --noprofile --norc << 'EOF'
source "$PRELUDE"
hint_get_path_size_kb_with_timeout() { echo 300000; }
show_data_review_hints
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"(partial scan)"* ]] || { echo "$output"; return 1; }
    [[ "$output" != *"Claude Code transcripts"* ]] || { echo "$output"; return 1; }
}

@test "a signal during sizing propagates cancellation" {
    mkdir -p "$HOME/.claude/projects/-x"
    mole_test_fake_command du 'exit 130'

    run_review /bin/bash --noprofile --norc << 'EOF'
source "$PRELUDE"
rc=0
show_data_review_hints || rc=$?
printf 'RC=%s CANCEL=%s\n' "$rc" "$MOLE_CLEAN_CANCEL_STATUS"
EOF

    [ "$status" -eq 0 ] || { echo "$output"; return 1; }
    [[ "$output" == *"RC=130 CANCEL=130"* ]] || { echo "$output"; return 1; }
    [ -d "$HOME/.claude/projects/-x" ]
}

@test "clean wires data hints into Large files and a Review section after Project artifacts" {
    local clean="$PROJECT_ROOT/bin/clean.sh"
    grep -qF "source \"\$SCRIPT_DIR/../lib/clean/review_hints_home.sh\"" "$clean" || return 1
    run awk '/check_large_file_candidates \|\| return/ {large=NR} /show_data_review_hints \|\| return/ {data=NR}
        /show_project_artifact_hint_notice \|\| return/ {proj=NR} /start_section "Review"/ {rev=NR}
        /show_home_review_hints \|\| return/ {home=NR}
        END {print (large && data == large + 1 && proj && rev > proj && home == rev + 1) ? "ok" : "bad"}' "$clean"
    [ "$output" = "ok" ]
}

@test "review hint modules contain no deletion or permission mutation" {
    local file
    for file in "$PROJECT_ROOT/lib/clean/review_hints_data.sh" "$PROJECT_ROOT/lib/clean/review_hints_home.sh"; do
        run grep -nE '(^|[^-])\b(rm|rmdir|chmod|chown|mv|unlink)\b +[-"$/~]|safe_remove|mole_delete|safe_clean|find_delete|-delete\b' "$file"
        [ "$status" -eq 1 ] || { echo "$output"; return 1; }
    done
}
