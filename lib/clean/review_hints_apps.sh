#!/bin/bash
# Row producers for show_data_review_hints (lib/clean/review_hints_data.sh,
# which sources this file). Report-only: every function measures and prints,
# none of them changes a file. Transcript reads stop at 64KB and their
# content is never printed.

set -euo pipefail

# Claude Code transcripts, plus the two subsets worth a closer look.
review_hints_claude() {
    local projects="$HOME/.claude/projects"
    review_hint_path "Claude Code transcripts" "$projects" date || return
    review_hint_path "Claude Code transcripts" "$HOME/.claude/transcripts" || return
    [[ -d "$projects" && ! -L "$projects" ]] || return 0
    review_hints_claude_missing_cwd "$projects" || return
    review_hints_claude_idle_subagents "$projects"
}

# cwd recorded in the first 64KB of a transcript, only when it is a plain
# absolute path with no JSON escapes that could be misread.
review_hint_transcript_cwd() {
    local cwd=""
    cwd=$(head -c "$MOLE_REVIEW_TRANSCRIPT_HEAD_BYTES" "$1" 2> /dev/null |
        LC_ALL=C grep -o '"cwd":"[^"\\]*"' 2> /dev/null) || return 1
    cwd="${cwd%%$'\n'*}"
    cwd="${cwd#\"cwd\":\"}"
    cwd="${cwd%\"}"
    [[ "$cwd" == /* ]] || return 1
    printf '%s\n' "$cwd"
}

# Project dirs whose newest transcript names a cwd that no longer exists.
# memory/ is authored context: excluded from the size and kept.
review_hints_claude_missing_cwd() {
    local projects="$1" dir file newest cwd rc kb
    review_hint_acc_reset
    for dir in "$projects"/*; do
        [[ -d "$dir" && ! -L "$dir" ]] || continue
        review_hint_budget_ok || break
        newest=""
        for file in "$dir"/*.jsonl; do
            [[ ! -f "$file" || (-n "$newest" && ! "$file" -nt "$newest") ]] || newest="$file"
        done
        [[ -n "$newest" ]] || continue
        cwd=$(review_hint_transcript_cwd "$newest") || continue
        [[ ! -e "$cwd" ]] || continue
        rc=0
        review_hint_measure "$dir" || rc=$?
        [[ $rc -lt 128 ]] || return "$rc"
        [[ $rc -eq 0 ]] || continue
        kb=$REVIEW_HINT_KB
        if [[ -d "$dir/memory" && ! -L "$dir/memory" ]]; then
            review_hint_measure "$dir/memory" || rc=$?
            [[ $rc -lt 128 ]] || return "$rc"
            [[ $rc -eq 0 ]] || continue
            kb=$((kb > REVIEW_HINT_KB ? kb - REVIEW_HINT_KB : 0))
        fi
        review_hint_acc_add "$dir" "$kb"
    done
    review_hint_acc_print "Claude transcripts with missing cwd" \
        "mo analyze $(format_path_link "$projects") · memory/ kept"
}

# Subagent transcript dirs with no file changed in MOLE_ORPHAN_AGE_DAYS.
review_hints_claude_idle_subagents() {
    local projects="$1"
    review_hint_filter_untouched "$MOLE_ORPHAN_AGE_DAYS" "$projects"/*/*/subagents || return
    review_hint_acc_reset
    review_hint_acc_paths "${REVIEW_HINT_KEPT[@]+"${REVIEW_HINT_KEPT[@]}"}" || return
    review_hint_acc_print "Claude subagent transcripts idle ${MOLE_ORPHAN_AGE_DAYS}+ days" \
        "mo analyze $(format_path_link "$projects")"
}

review_hints_codex() {
    local root="$HOME/.codex"
    review_hint_path "Codex sessions" "$root/sessions" date || return
    review_hint_path "Codex archived sessions" "$root/archived_sessions" || return
    review_hint_path "Codex generated images" "$root/generated_images" date || return
    review_hint_path "Codex backups" "$root/backups"
}

# Superpowers' conversation archive, index and logs as one row. The note
# says when the Claude plugin that reads the archive is not installed.
review_hints_superpowers() {
    local root="$HOME/.config/superpowers" note=""
    local plugins="$HOME/.claude/plugins/installed_plugins.json"
    [[ -d "$root" && ! -L "$root" ]] || return 0
    review_hint_acc_reset
    review_hint_acc_paths "$root/conversation-archive" "$root/conversation-index" "$root/logs" || return
    [[ $REVIEW_ACC_COUNT -gt 0 ]] || return 0
    if [[ -f "$plugins" ]] && ! grep -q '"episodic-memory@' "$plugins" 2> /dev/null; then
        note=" · (episodic-memory plugin not installed)"
    fi
    review_hint_print "Superpowers conversation archive" "$REVIEW_ACC_KB" \
        "mo analyze $(format_path_link "$root")${note}"
}

# Single-path rows: downloaded models, app data and owner-managed stores.
review_hints_app_data() {
    local support="$HOME/Library/Application Support"
    local maccy="$HOME/Library/Containers/org.p0deje.Maccy/Data/Library/Application Support/Maccy/Storage.sqlite"
    local wechat="$HOME/Library/Containers/com.tencent.xinWeChat/Data/Library/Application Support/com.tencent.xinWeChat/2.0b4.0.9"
    review_hint_path "Models" "$HOME/.insightface" || return
    review_hint_path "Models" "$HOME/.cuena" || return
    review_hint_path "Cue app data" "$HOME/.cue" || return
    review_hint_path "Cue app data" "$support/Cue" || return
    review_hint_path "Token Tracker categorizer cache" "$HOME/.tokentracker/cache/claude-categorizer" || return
    review_hint_path "Office solution packages" \
        "$HOME/Library/Group Containers/UBF8T346G9.Office/SolutionPackages" || return
    review_hint_path "Maccy clipboard history" "$maccy" "clear history in Maccy" || return
    review_hint_path "WeChat 3.x legacy data" "$wechat" date
}

# 0 only for a third-party <publisher.name> id with no installed version in
# either editor. Built-in publishers, odd names, or no extensions dir to
# check all answer "installed" (1).
review_hint_extension_missing() {
    local id="$1" lower root match seen=false
    [[ "$id" =~ ^[A-Za-z0-9][A-Za-z0-9-]*\.[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || return 1
    lower=$(printf '%s' "$id" | LC_ALL=C tr '[:upper:]' '[:lower:]')
    case "$lower" in
        vscode.* | ms-vscode.* | anysphere.* | cursor.*) return 1 ;;
    esac
    for root in "$HOME/.vscode/extensions" "$HOME/.cursor/extensions"; do
        [[ -d "$root" ]] || continue
        seen=true
        for match in "$root/$id"-* "$root/$lower"-*; do
            [[ ! -e "$match" ]] || return 1
        done
    done
    [[ "$seen" == "true" ]]
}

# Per-workspace state of uninstalled extensions, and whole workspace hashes
# idle for MOLE_DOTDIR_ORPHAN_AGE_DAYS, for one editor ($1 dir, $2 label).
# An idle hash is reported once, as a whole, never again per extension.
review_hints_editor_workspaces() {
    local storage="$HOME/Library/Application Support/$1/User/workspaceStorage"
    local label="$2" hash ext rc
    local -a stale=() idle=()
    [[ -d "$storage" && ! -L "$storage" ]] || return 0
    for hash in "$storage"/*; do
        [[ -d "$hash" && ! -L "$hash" ]] || continue
        review_hint_budget_ok || break
        rc=0
        review_hint_untouched "$hash" "$MOLE_DOTDIR_ORPHAN_AGE_DAYS" || rc=$?
        [[ $rc -lt 128 ]] || return "$rc"
        if [[ $rc -eq 0 ]]; then
            idle+=("$hash")
            continue
        fi
        for ext in "$hash"/*.*; do
            [[ -d "$ext" && ! -L "$ext" ]] || continue
            review_hint_extension_missing "${ext##*/}" || continue
            stale+=("$ext")
        done
    done
    review_hint_acc_reset
    review_hint_acc_paths "${stale[@]+"${stale[@]}"}" || return
    review_hint_acc_print "$label workspace state of uninstalled extensions" \
        "mo analyze $(format_path_link "$storage")"
    review_hint_acc_reset
    review_hint_acc_paths "${idle[@]+"${idle[@]}"}" || return
    review_hint_acc_print "$label workspaces idle ${MOLE_DOTDIR_ORPHAN_AGE_DAYS}+ days" \
        "mo analyze $(format_path_link "$storage")"
}

review_hints_editors() {
    local cursor_state="$HOME/Library/Application Support/Cursor/User/globalStorage"
    review_hints_editor_workspaces "Code" "VS Code" || return
    review_hints_editor_workspaces "Cursor" "Cursor" || return
    review_hint_path "Cursor state backup" "$cursor_state/state.vscdb.backup" \
        "quit Cursor, then mo analyze $(format_path_link "$cursor_state")"
}

# Per-version user site-packages; notes a version whose python is gone.
review_hints_python_user() {
    local dir ver note
    for dir in "$HOME/Library/Python"/*; do
        [[ -d "$dir" && ! -L "$dir" ]] || continue
        ver="${dir##*/}"
        [[ "$ver" =~ ^[0-9]+\.[0-9]+$ ]] || continue
        note=""
        command -v "python$ver" > /dev/null 2>&1 || note=" · python$ver not on PATH"
        review_hint_path "Python $ver user packages" "$dir" \
            "mo analyze $(format_path_link "$dir")${note}" || return
    done
}

review_hints_adspower() {
    local root="$HOME/Library/Application Support/adspower_global/cwd_global"
    [[ -d "$root" && ! -L "$root" ]] || return 0
    review_hint_acc_reset
    review_hint_acc_paths "$root"/chrome_* || return
    review_hint_acc_print "AdsPower browser kernels" "manage kernels in AdsPower"
}

# Store paths every installed pnpm resolves to, one per line, into
# REVIEW_HINT_PNPM_ACTIVE. Returns 1 when any binary could not answer.
review_hint_pnpm_active_stores() {
    local bin rc
    REVIEW_HINT_PNPM_ACTIVE=""
    while IFS= read -r bin; do
        [[ -n "$bin" ]] || continue
        rc=0
        review_hint_capture "$MOLE_TIMEOUT_QUICK_DETECT_SEC" env COREPACK_ENABLE_DOWNLOAD_PROMPT=0 \
            COREPACK_ENABLE_NETWORK=0 "$bin" store path || rc=$?
        [[ $rc -lt 128 ]] || return "$rc"
        [[ $rc -eq 0 && "$REVIEW_HINT_OUT" == /* ]] || return 1
        REVIEW_HINT_PNPM_ACTIVE+="${REVIEW_HINT_OUT%/}"$'\n'
    done < <(list_installed_pnpm_binaries)
    return 0
}

# pnpm store generations no installed pnpm uses, and pnpm's own downloaded
# versions. An unanswered `store path` query keeps the generation row out.
review_hints_pnpm() {
    local root="$HOME/Library/pnpm" gen rc=0
    local -a inactive=()
    if [[ -d "$root/store" && ! -L "$root/store" ]]; then
        review_hint_pnpm_active_stores || rc=$?
        [[ $rc -lt 128 ]] || return "$rc"
        for gen in "$root/store"/v*; do
            [[ $rc -eq 0 && -d "$gen" && ! -L "$gen" ]] || continue
            [[ $'\n'"$REVIEW_HINT_PNPM_ACTIVE" == *$'\n'"$gen"$'\n'* ]] || inactive+=("$gen")
        done
    fi
    review_hint_acc_reset
    review_hint_acc_paths "${inactive[@]+"${inactive[@]}"}" || return
    review_hint_acc_print "Inactive pnpm store generations" "mo analyze $(format_path_link "$root/store")"
    review_hint_acc_reset
    review_hint_acc_paths "$root/.tools/pnpm"/* || return
    review_hint_acc_print "pnpm downloaded versions" "mo analyze $(format_path_link "$root/.tools")"
}

# 0 when neither the container's bundle id nor its parent id (last label
# stripped, which covers app extensions) belongs to an installed app. Apple
# and group ids are never probed, and bundle_has_installed_app answers
# "installed" for any lookup it could not finish.
review_hint_container_orphaned() {
    local id="$1" candidate rc
    case "$id" in
        com.apple.* | group.*) return 1 ;;
    esac
    [[ ! "$id" =~ ^[A-Z0-9]{10}\. ]] || return 1
    mole_is_reverse_dns_bundle_id "$id" || return 1
    for candidate in "$id" "${id%.*}"; do
        [[ "$candidate" == *.* ]] || continue
        rc=0
        bundle_has_installed_app "$candidate" "$REVIEW_HINT_DEADLINE" || rc=$?
        if [[ $rc -ge 128 ]]; then
            _mole_record_clean_cancellation "$rc" "review hints"
            return "$rc"
        fi
        [[ $rc -eq 1 ]] || return 1
    done
    return 0
}

review_hints_orphan_containers() {
    local root="$HOME/Library/Containers" dir rc
    local -a orphans=()
    [[ -d "$root" && ! -L "$root" ]] || return 0
    for dir in "$root"/*; do
        [[ -d "$dir" && ! -L "$dir" ]] || continue
        review_hint_budget_ok || break
        rc=0
        review_hint_container_orphaned "${dir##*/}" || rc=$?
        [[ $rc -lt 128 ]] || return "$rc"
        [[ $rc -ne 0 ]] || orphans+=("$dir")
    done
    review_hint_acc_reset
    review_hint_acc_paths "${orphans[@]+"${orphans[@]}"}" || return
    review_hint_acc_print "Orphaned app containers (review)" "mo analyze $(format_path_link "$root")"
}
