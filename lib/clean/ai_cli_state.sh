#!/bin/bash
# Claude Code and Codex disposable state.
#
# Deletion authority here is evidence the owner wrote itself, never name
# similarity (AGENTS.md, "A new cleanup target needs measured value"): Claude
# Code's own .orphaned_at marker, a config temp whose writer pid is dead, and
# (clean_codex_temp_skeletons in dev.sh) Codex temp skeletons that are empty
# or a bare `git init` stub.
# A probe that cannot answer keeps the target. Everything else under ~/.claude and ~/.codex (projects, memory,
# sessions, settings, hooks, marketplaces, plugin data, registries, installed
# versions, worktrees) stays untouched.
set -euo pipefail

_AI_CLI_SECONDS_PER_DAY=86400
_AI_CLI_MARKER_MAX_BYTES=32
_AI_CLI_MS_EPOCH_DIGITS=13
_AI_CLI_CONFIG_TEMP_RE='^\.claude\.json\.tmp\.([0-9]{1,10})\.[A-Za-z0-9]+$'

# Bounded find on one path. 0 = it printed a match; 1 = no match, failure, or
# timeout (unknown keeps); a signal status propagates.
_ai_cli_find_matches() {
    local hit="" rc=0
    hit=$(run_with_timeout "$MOLE_TIMEOUT_QUICK_DETECT_SEC" find -P "$@" -print 2> /dev/null) || rc=$?
    if [[ $rc -ne 0 ]]; then
        mole_rc_timeout_or_signal "$rc" && ! mole_rc_timeout "$rc" && return "$rc"
        return 1
    fi
    [[ -n "$hit" ]]
}

# Tri-state pid probe: 0 = alive (a reused pid counts), 1 = no such process,
# 2 = could not tell. Only `ps` exiting 1 with no output proves absence.
_ai_cli_pid_state() {
    local pid="$1"
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 2
    local out="" rc=0
    out=$(run_with_timeout "$MOLE_TIMEOUT_QUICK_DETECT_SEC" ps -p "$pid" -o pid= 2> /dev/null) || rc=$?
    out="${out//[[:space:]]/}"
    [[ $rc -eq 0 && "$out" == "$pid" ]] && return 0
    [[ $rc -eq 1 && -z "$out" ]] && return 1
    return 2
}

# Print the identity recorded for <path> among "<path>|<identity>" entries.
_ai_cli_recorded_id() {
    local path="$1" entry
    shift
    for entry in "$@"; do
        [[ "${entry%|*}" == "$path" ]] || continue
        printf '%s\n' "${entry##*|}"
        return 0
    done
    return 1
}

# Bind the leaf's parent and target identity for safe_remove at the sink.
_ai_cli_bind_sink() {
    _mole_snapshot_path_identity "$1" || return 1
    _MOLE_SAFE_CLEAN_BOUND_PATH="$1"
    _MOLE_SAFE_CLEAN_EXPECTED_PARENT="$_MOLE_PATH_SNAPSHOT_PARENT"
    _MOLE_SAFE_CLEAN_EXPECTED_PARENT_ID="$_MOLE_PATH_SNAPSHOT_PARENT_ID"
    _MOLE_SAFE_CLEAN_EXPECTED_TARGET_ID="$_MOLE_PATH_SNAPSHOT_TARGET_ID"
}

# Claude Code's config root: CLAUDE_CONFIG_DIR when it is absolute and below
# HOME, otherwise ~/.claude.
claude_code_config_root() {
    local root="${CLAUDE_CONFIG_DIR:-}"
    root="${root%/}"
    case "$root" in
        *'/../'* | */.. | *'/./'* | */. | *'//'*) root="" ;;
        "${HOME%/}"/?*) ;;
        *) root="" ;;
    esac
    printf '%s\n' "${root:-$HOME/.claude}"
}

# ---------------------------------------------------------------------------
# Claude Code orphaned plugin versions: <C>/plugins/cache/<mkt>/<plugin>/<ver>
# ---------------------------------------------------------------------------
# Claude Code writes <ver>/.orphaned_at when an update leaves a version behind
# and reaps it itself after 7 days; both the marker epoch and its mtime must be
# older than MOLE_TEMP_FILE_AGE_DAYS. Accepted residual risk: a session that
# loaded the plugin before it was orphaned can hold it with no argv naming the
# version dir, so one of its later hook calls could fail. The marker age
# mirrors the owner's own reaping policy; argv references are checked per path.

_claude_plugin_level_ok() {
    local name="${1##*/}"
    [[ -n "$name" && "$name" != .* && -d "$1" && ! -L "$1" ]]
}

# 0 = the version carries an aged, well-formed marker; 1 = it does not.
_claude_plugin_marker_aged() {
    local marker="$1/.orphaned_at"
    [[ -f "$marker" && ! -L "$marker" ]] || return 1
    local size="" content=""
    size=$("$STAT_BSD" -f%z "$marker" 2> /dev/null) || return 1
    [[ "$size" =~ ^[0-9]+$ && $size -le $_AI_CLI_MARKER_MAX_BYTES ]] || return 1
    content=$(< "$marker") || return 1
    [[ "$content" =~ ^[0-9]{10,13}$ ]] || return 1
    local epoch=$((10#$content))
    [[ ${#content} -eq $_AI_CLI_MS_EPOCH_DIGITS ]] && epoch=$((epoch / 1000))
    local cutoff=$(($(get_epoch_seconds) - MOLE_TEMP_FILE_AGE_DAYS * _AI_CLI_SECONDS_PER_DAY))
    [[ $epoch -le $cutoff ]] || return 1
    _ai_cli_find_matches "$marker" -maxdepth 0 -type f -mtime +"$MOLE_TEMP_FILE_AGE_DAYS"
}

# Load every installPath (and its physical form) from installed_plugins.json
# into _MOLE_CLAUDE_PLUGIN_INSTALLED, through plutil XML, never plutil -p. A
# missing or unparsable registry, or one with no installPath at all (a schema
# Mole does not know), is 2: nothing can be proven orphaned.
_claude_plugin_read_installed() {
    local registry="$1" xml="" paths="" path physical
    _MOLE_CLAUDE_PLUGIN_INSTALLED=""
    [[ -f "$registry" && ! -L "$registry" ]] || return 2
    xml=$(run_with_timeout "$MOLE_TIMEOUT_QUICK_DETECT_SEC" \
        plutil -convert xml1 -o - "$registry" 2> /dev/null) || return 2
    [[ "$xml" == *"<plist"* ]] || return 2
    paths=$(LC_ALL=C awk '
        { sub(/^[ \t]+/, ""); sub(/[ \t\r]+$/, "") }
        want && /^<string>.*<\/string>$/ { v = substr($0, 9, length($0) - 17)
            gsub(/&lt;/, "<", v); gsub(/&gt;/, ">", v); gsub(/&quot;/, "\"", v)
            gsub(/&apos;/, "\047", v); gsub(/&amp;/, "\\&", v); print v }
        { want = ($0 == "<key>installPath</key>") }
    ' <<< "$xml") || return 2
    [[ -n "$paths" ]] || return 2
    while IFS= read -r path; do
        [[ -n "$path" ]] || continue
        _MOLE_CLAUDE_PLUGIN_INSTALLED+="${path%/}"$'\n'
        physical=$(cd -P "$path" 2> /dev/null && pwd -P) || continue
        _MOLE_CLAUDE_PLUGIN_INSTALLED+="$physical"$'\n'
    done <<< "$paths"
}

# 0 = the lexical or physical path is a registered installPath (or unresolvable).
_claude_plugin_is_installed() {
    local physical=""
    physical=$(cd -P "$1" 2> /dev/null && pwd -P) || return 0
    case $'\n'"$_MOLE_CLAUDE_PLUGIN_INSTALLED" in
        *$'\n'"$1"$'\n'* | *$'\n'"$physical"$'\n'*) return 0 ;;
    esac
    return 1
}

# Sink recheck: the marker is still aged and is the one seen at the scan, and a
# fresh registry read still does not list the path.
_claude_plugin_version_still_orphaned() {
    local path="$1" expected="" current=""
    expected=$(_ai_cli_recorded_id "$path" "${_MOLE_CLAUDE_PLUGIN_RECORDS[@]}") || return 1
    _claude_plugin_marker_aged "$path" || return 1
    current=$(mole_deletion_identity "$path/.orphaned_at") || return 1
    [[ "$current" == "$expected" ]] || return 1
    _claude_plugin_read_installed "$_MOLE_CLAUDE_PLUGIN_REGISTRY" || return 1
    ! _claude_plugin_is_installed "$path"
}

# Process probe for clean_guarded_dev_cache_root. At the deletion boundary it
# judges only the leaf, owner evidence first; before that, every version still
# eligible in the group.
claude_plugin_version_process_state() {
    local guarded="${_MOLE_DEV_GUARDED_PATH:-}"
    if [[ -n "$guarded" ]]; then
        _claude_plugin_version_still_orphaned "$guarded" || return 2
        mole_process_args_reference_paths --fresh "$guarded"
        return $?
    fi
    [[ ${#_MOLE_CLAUDE_PLUGIN_ELIGIBLE[@]} -gt 0 ]] || return 1
    mole_process_args_reference_paths --fresh "${_MOLE_CLAUDE_PLUGIN_ELIGIBLE[@]}"
}

# One plugin group: aged marked versions that are not an installPath go to the
# guarded dev-cache sink. The plugin dir is the cache root because that sink
# requires the leaf parent to equal the physical root. Returns 3 when the
# registry is unreadable.
_claude_plugin_clean_group() {
    local cache_root="$1" plugin_dir="$2" version marker_id state
    local -a _MOLE_CLAUDE_PLUGIN_ELIGIBLE=() _MOLE_CLAUDE_PLUGIN_RECORDS=()
    for version in "$plugin_dir"/*; do
        _claude_plugin_level_ok "$version" || continue
        state=0
        _claude_plugin_marker_aged "$version" || state=$?
        [[ $state -le 1 ]] || return "$state"
        [[ $state -eq 0 ]] || continue
        if [[ "$_MOLE_CLAUDE_PLUGIN_REGISTRY_STATE" != "ok" ]]; then
            _claude_plugin_read_installed "$_MOLE_CLAUDE_PLUGIN_REGISTRY" || return 3
            _MOLE_CLAUDE_PLUGIN_REGISTRY_STATE="ok"
        fi
        _claude_plugin_is_installed "$version" && continue
        marker_id=$(mole_deletion_identity "$version/.orphaned_at") || continue
        _MOLE_CLAUDE_PLUGIN_ELIGIBLE+=("$version")
        _MOLE_CLAUDE_PLUGIN_RECORDS+=("$version|$marker_id")
    done
    [[ ${#_MOLE_CLAUDE_PLUGIN_ELIGIBLE[@]} -gt 0 ]] || return 0
    clean_guarded_dev_cache_root "$cache_root" "$plugin_dir" \
        claude_plugin_version_process_state "Claude Code plugins" \
        "Claude Code orphaned plugin versions" "${_MOLE_CLAUDE_PLUGIN_ELIGIBLE[@]}"
}

clean_claude_plugin_orphans() {
    local config_root market plugin rc
    config_root=$(claude_code_config_root)
    local cache_root="$config_root/plugins/cache"
    [[ -d "$cache_root" && ! -L "$cache_root" ]] || return 0
    local _MOLE_CLAUDE_PLUGIN_REGISTRY="$config_root/plugins/installed_plugins.json"
    local _MOLE_CLAUDE_PLUGIN_REGISTRY_STATE="" _MOLE_CLAUDE_PLUGIN_INSTALLED=""
    for market in "$cache_root"/*; do
        _claude_plugin_level_ok "$market" || continue
        for plugin in "$market"/*; do
            _claude_plugin_level_ok "$plugin" || continue
            rc=0
            _claude_plugin_clean_group "$cache_root" "$plugin" || rc=$?
            mole_rc_timeout_or_signal "$rc" && return "$rc"
            [[ $rc -eq 3 ]] || continue
            echo -e "  ${GRAY}${ICON_WARNING}${NC} Claude Code plugin cache · stopped (plugin registry unreadable)"
            note_activity
            return 0
        done
    done
}

# ---------------------------------------------------------------------------
# Claude Code config temps: ~/.claude.json.tmp.<pid>.<rand>
# ---------------------------------------------------------------------------
# Stale atomic-write copies of ~/.claude.json. A temp can be the only complete
# copy after a crash mid-rename, so it goes only when its writer pid is dead and
# a well-formed live config was written after it. ~/.claude.json, its .backup,
# and any other .claude.json.* name never match.

# 0 = the live config exists, looks complete, and is newer than the temp.
_claude_config_supersedes() {
    local config="$HOME/.claude.json" first="" last=""
    [[ -f "$config" && ! -L "$config" && -s "$config" && "$config" -nt "$1" ]] || return 1
    first=$(LC_ALL=C head -c 1 "$config" 2> /dev/null) || return 1
    last=$(LC_ALL=C tail -c 2 "$config" 2> /dev/null) || return 1
    [[ "$first" == "{" && "$last" == *"}" ]]
}

# 0 = stale temp from a dead writer, 1 = keep. A signal propagates.
_claude_config_temp_is_stale() {
    local path="$1" uid="" owner="" pid_state=0
    [[ "${path%/*}" == "$HOME" && "${path##*/}" =~ $_AI_CLI_CONFIG_TEMP_RE ]] || return 1
    local pid="${BASH_REMATCH[1]}"
    [[ -f "$path" && ! -L "$path" ]] || return 1
    uid=$(get_invoking_uid 2> /dev/null) || return 1
    owner=$("$STAT_BSD" -f%u "$path" 2> /dev/null) || return 1
    [[ -n "$uid" && "$owner" == "$uid" ]] || return 1
    _ai_cli_find_matches "$path" -maxdepth 0 -type f -mtime +"$MOLE_TEMP_FILE_AGE_DAYS" || return $?
    _claude_config_supersedes "$path" || return 1
    _ai_cli_pid_state "$pid" || pid_state=$?
    [[ $pid_state -eq 1 ]]
}

# Delete guard: rerun every check and require the identity seen at the scan.
_claude_config_temp_delete_guard() {
    local path="$1" expected="" current=""
    _MOLE_CLEAN_GUARD_REASON="config temp changed"
    expected=$(_ai_cli_recorded_id "$path" "${_MOLE_CLAUDE_TEMP_RECORDS[@]}") || return 1
    _claude_config_temp_is_stale "$path" || return $?
    current=$(mole_deletion_identity "$path") || return 1
    [[ "$current" == "$expected" ]] || return 1
    _ai_cli_bind_sink "$path"
}

clean_claude_config_temps() {
    local -a paths=() _MOLE_CLAUDE_TEMP_RECORDS=()
    local path identity state
    for path in "$HOME"/.claude.json.tmp.*; do
        state=0
        _claude_config_temp_is_stale "$path" || state=$?
        [[ $state -le 1 ]] || return "$state"
        [[ $state -eq 0 ]] || continue
        identity=$(mole_deletion_identity "$path") || continue
        paths+=("$path")
        _MOLE_CLAUDE_TEMP_RECORDS+=("$path|$identity")
    done
    [[ ${#paths[@]} -gt 0 ]] || return 0

    local _MOLE_CLEAN_GUARD_REASON="" rc=0
    safe_clean_guarded _claude_config_temp_delete_guard \
        "${paths[@]}" "Claude Code config temps" || rc=$?
    [[ $rc -eq 75 ]] && debug_log "Claude Code config temps kept: $_MOLE_CLEAN_GUARD_REASON"
    mole_rc_timeout_or_signal "$rc" && return "$rc"
    return 0
}

clean_claude_code_disposable_state() {
    clean_claude_plugin_orphans || return $?
    clean_claude_config_temps
}
