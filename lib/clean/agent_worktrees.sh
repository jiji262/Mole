#!/bin/bash
# Merged, clean, idle AI agent worktrees (Codex app, Claude Code, superpowers).
#
# Fork maintainer decision 2026-11-04: `mo clean` removes a linked worktree
# found in an agent worktree container (agent_worktree_containers in user.sh)
# only when every check below holds, and keeps it on any probe that cannot
# answer:
#   - it is a linked worktree whose admin dir points back at it, not locked;
#   - `git status` shows no tracked change and no untracked file, and every
#     ignored entry is a rebuildable MOLE_PURGE_TARGETS name or a generated
#     build file (*.tsbuildinfo, next-env.d.ts, .eslintcache, .DS_Store), so
#     an ignored .env, cookie file or agent report keeps the whole worktree;
#   - HEAD is an ancestor of the remote default branch (origin/HEAD, else
#     origin/main or origin/master), read from local refs without fetching;
#   - nothing under it, nor its HEAD or reflog, changed in the last 24 hours;
#   - no running process names it in argv, and the whitelist does not cover it.
# The checks run again at the sink. Branches are never deleted; the repo's
# stale admin entry is dropped with `git worktree prune` afterwards.
set -euo pipefail

_AGENT_WT_IDLE_MINUTES=1440
_AGENT_WT_GIT_DIR=""
_AGENT_WT_COMMON_DIR=""

# Bounded git with inherited routing ignored and fsmonitor hooks disabled,
# the same isolation as mole_git_ls_files. Returns git's, the timeout's or the
# resolver's status.
_agent_wt_git() {
    local wt="$1" MOLE_RESOLVED_GIT_BIN=""
    shift
    _mole_resolve_git_bin "" || return $?
    run_with_timeout "$MOLE_TIMEOUT_MEDIUM_PROBE_SEC" \
        env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_COMMON_DIR \
        GIT_OPTIONAL_LOCKS=0 \
        "$MOLE_RESOLVED_GIT_BIN" -c core.fsmonitor=false -C "$wt" "$@" 2> /dev/null
}

# Map a probe status to the keep status: a signal propagates, anything else
# (no, unknown, timeout, git's fatal 128) becomes $2, by default 1.
_agent_wt_keep_status() {
    if mole_rc_signal "$1"; then
        printf '%s\n' "$1"
    else
        printf '%s\n' "${2:-1}"
    fi
}

_agent_wt_physical() {
    (cd -P "$1" 2> /dev/null && pwd -P)
}

# 0 = <wt> is a linked worktree whose admin dir points back at it and is not
# locked. Sets _AGENT_WT_GIT_DIR and _AGENT_WT_COMMON_DIR.
_agent_wt_is_linked() {
    local wt="$1" git_dir="" common="" backlink="" here="" rc=0
    [[ -d "$wt" && ! -L "$wt" && -f "$wt/.git" && ! -L "$wt/.git" ]] || return 1
    git_dir=$(_agent_wt_git "$wt" rev-parse --absolute-git-dir) || rc=$?
    [[ $rc -eq 0 ]] || return "$(_agent_wt_keep_status "$rc")"
    common=$(_agent_wt_git "$wt" rev-parse --path-format=absolute --git-common-dir) || rc=$?
    [[ $rc -eq 0 ]] || return "$(_agent_wt_keep_status "$rc")"
    [[ -n "$git_dir" && -n "$common" && "$git_dir" != "$common" ]] || return 1
    [[ "$git_dir" == "$common/worktrees/"* && -d "$git_dir" ]] || return 1
    [[ ! -e "$git_dir/locked" ]] || return 1
    backlink=$(head -n 1 "$git_dir/gitdir" 2> /dev/null) || return 1
    here=$(_agent_wt_physical "$wt") || return 1
    [[ "$(_agent_wt_physical "${backlink%/.git}")" == "$here" ]] || return 1
    _AGENT_WT_GIT_DIR="$git_dir"
    _AGENT_WT_COMMON_DIR="$common"
}

# 0 = something under <wt> or its HEAD/reflog changed within the idle window.
# Rebuildable artifact dirs are pruned: their churn is not agent work.
# A find failure or timeout counts as recent (unknown keeps); a signal
# status propagates.
_agent_wt_recently_changed() {
    local wt="$1" git_dir="$2" hit="" rc=0 name
    local -a prune=() meta=()
    for name in "${MOLE_PURGE_TARGETS[@]}"; do
        prune+=(-o -name "$name")
    done
    hit=$(run_with_timeout "$MOLE_TIMEOUT_PKG_LIST_SEC" find -P "$wt" \
        \( -name .git "${prune[@]}" \) -prune -o -mmin "-$_AGENT_WT_IDLE_MINUTES" -print -quit 2> /dev/null) || rc=$?
    [[ $rc -eq 0 ]] || return "$(_agent_wt_keep_status "$rc" 0)"
    [[ -z "$hit" ]] || return 0
    for name in "$git_dir/HEAD" "$git_dir/logs/HEAD"; do
        [[ -e "$name" ]] && meta+=("$name")
    done
    [[ ${#meta[@]} -gt 0 ]] || return 1
    hit=$(find -P "${meta[@]}" -maxdepth 0 -mmin "-$_AGENT_WT_IDLE_MINUTES" -print 2> /dev/null) || rc=$?
    [[ $rc -eq 0 ]] || return "$(_agent_wt_keep_status "$rc" 0)"
    [[ -n "$hit" ]]
}

_agent_wt_rebuildable_name() {
    local name="$1" target
    case "$name" in
        .DS_Store | .eslintcache | next-env.d.ts | *.tsbuildinfo) return 0 ;;
    esac
    for target in "${MOLE_PURGE_TARGETS[@]}"; do
        [[ "$name" == "$target" ]] && return 0
    done
    return 1
}

# 0 = no tracked change, no untracked file, and only rebuildable ignored
# entries. "matching" reports an ignored directory once (`!! dist/`) instead of
# every file inside it. Porcelain quotes unusual names, so a quoted entry
# never matches a target name and keeps the worktree.
_agent_wt_status_clean() {
    local wt="$1" out="" rc=0 line name
    out=$(_agent_wt_git "$wt" status --porcelain=v1 --ignored=matching --untracked-files=all) || rc=$?
    [[ $rc -eq 0 ]] || return "$(_agent_wt_keep_status "$rc")"
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        [[ "$line" == '!! '* ]] || return 1
        name="${line#!! }"
        name="${name%/}"
        _agent_wt_rebuildable_name "${name##*/}" || return 1
    done <<< "$out"
    return 0
}

# 0 = HEAD is already contained in the remote default branch.
_agent_wt_merged() {
    local wt="$1" ref="" candidate rc=0
    ref=$(_agent_wt_git "$wt" symbolic-ref -q refs/remotes/origin/HEAD) || rc=$?
    mole_rc_signal "$rc" && return "$rc"
    [[ $rc -eq 0 ]] || ref=""
    if [[ -z "$ref" ]]; then
        for candidate in refs/remotes/origin/main refs/remotes/origin/master; do
            rc=0
            _agent_wt_git "$wt" show-ref --verify -q "$candidate" || rc=$?
            mole_rc_signal "$rc" && return "$rc"
            if [[ $rc -eq 0 ]]; then
                ref="$candidate"
                break
            fi
        done
    fi
    [[ -n "$ref" ]] || return 1
    rc=0
    _agent_wt_git "$wt" merge-base --is-ancestor HEAD "$ref" || rc=$?
    [[ $rc -eq 0 ]] || return "$(_agent_wt_keep_status "$rc")"
}

# 0 = <wt> may be removed; 1 = keep; a signal status propagates.
_agent_wt_state() {
    local wt="$1" rc=0
    _AGENT_WT_GIT_DIR=""
    _AGENT_WT_COMMON_DIR=""
    is_path_whitelisted "$wt" && return 1
    _agent_wt_is_linked "$wt" || return $?
    _agent_wt_recently_changed "$wt" "$_AGENT_WT_GIT_DIR" || rc=$?
    [[ $rc -eq 1 ]] || return "$(_agent_wt_keep_status "$rc")"
    _agent_wt_status_clean "$wt" || return $?
    _agent_wt_merged "$wt" || return $?
    rc=0
    mole_process_args_reference_paths --fresh "$wt" || rc=$?
    [[ $rc -eq 1 ]] || return "$(_agent_wt_keep_status "$rc")"
    return 0
}

# Print the worktree roots inside one container, one per line: direct
# children, plus <name>/<repo> for Codex and T3 Code two-level layouts. Output
# only from a scan that completed.
_agent_wt_list_in() {
    local container="$1" max_depth=2 out="" rc=0 marker
    [[ "$container" == "$HOME/.codex/worktrees" || "$container" == "$HOME/.t3/worktrees" ]] && max_depth=3
    out=$(run_with_timeout "$MOLE_TIMEOUT_PKG_LIST_SEC" find -P "$container" \
        -mindepth 2 -maxdepth "$max_depth" -name .git -type f -print 2> /dev/null) || rc=$?
    if [[ $rc -ne 0 ]]; then
        [[ "$(_agent_wt_keep_status "$rc")" == "1" ]] || return "$rc"
        return 0
    fi
    while IFS= read -r marker; do
        [[ -n "$marker" ]] && printf '%s\n' "${marker%/.git}"
    done <<< "$out"
}

# safe_clean_guarded callback: recheck the full state at the sink and bind
# the target identity; a changed worktree is skipped, not the whole batch.
_agent_wt_delete_guard() {
    local path="$1" rc=0
    _agent_wt_state "$path" || rc=$?
    if [[ $rc -ne 0 ]]; then
        _MOLE_SAFE_CLEAN_SKIP_PATH="$path"
        [[ $rc -ge 128 ]] && return "$rc"
        return 1
    fi
    if ! _ai_cli_bind_sink "$path"; then
        _MOLE_SAFE_CLEAN_SKIP_PATH="$path"
        return 1
    fi
}

# Drop the admin entries of removed worktrees; locked entries are never pruned.
# A failed prune is only logged; a signal propagates.
_agent_wt_prune_admin() {
    local MOLE_RESOLVED_GIT_BIN="" common rc=0
    _mole_resolve_git_bin "" || rc=$?
    [[ $rc -eq 0 ]] || return "$(_agent_wt_keep_status "$rc" 0)"
    for common in "$@"; do
        [[ -d "$common" ]] || continue
        rc=0
        run_with_timeout "$MOLE_TIMEOUT_MEDIUM_PROBE_SEC" \
            env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_COMMON_DIR \
            "$MOLE_RESOLVED_GIT_BIN" -c core.fsmonitor=false --git-dir="$common" worktree prune 2> /dev/null || rc=$?
        mole_rc_signal "$rc" && return "$rc"
        [[ $rc -eq 0 ]] || debug_log "git worktree prune failed for $common"
    done
    return 0
}

_agent_wt_clean() {
    local MOLE_RESOLVED_GIT_BIN="" rc=0
    _mole_resolve_git_bin "" || rc=$?
    [[ $rc -eq 0 ]] || return "$(_agent_wt_keep_status "$rc" 0)"
    local -a candidates=() commons=() removed_commons=()
    local container wt state idx listing
    while IFS= read -r -d '' container; do
        listing=$(_agent_wt_list_in "$container") || rc=$?
        [[ $rc -eq 0 ]] || return "$rc"
        while IFS= read -r wt; do
            [[ -n "$wt" ]] || continue
            state=0
            _agent_wt_state "$wt" || state=$?
            [[ $state -lt 128 ]] || return "$state"
            [[ $state -eq 0 ]] || continue
            candidates+=("$wt")
            commons+=("$_AGENT_WT_COMMON_DIR")
        done <<< "$listing"
    done < <(agent_worktree_containers)
    [[ ${#candidates[@]} -gt 0 ]] || return 0

    safe_clean_guarded _agent_wt_delete_guard "${candidates[@]}" "Merged agent worktrees" || rc=$?
    mole_rc_timeout_or_signal "$rc" && return "$rc"
    [[ "${DRY_RUN:-false}" == "true" ]] && return 0
    for idx in "${!candidates[@]}"; do
        [[ -e "${candidates[$idx]}" ]] || removed_commons+=("${commons[$idx]}")
    done
    [[ ${#removed_commons[@]} -gt 0 ]] || return 0
    _agent_wt_prune_admin "${removed_commons[@]}"
}

# clean_dev_misc does not read this status, so a signal, or a timeout at the
# sink, is also left as the clean cancellation that stops the later steps.
clean_merged_agent_worktrees() {
    local rc=0
    _agent_wt_clean || rc=$?
    mole_rc_timeout_or_signal "$rc" && _mole_record_clean_cancellation "$rc" "agent worktrees"
    return "$rc"
}
