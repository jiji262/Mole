#!/bin/bash
# Chromium-fork, Electron and automation-profile cache leaves, plus a few
# dot-directory caches. Called at the end of clean_dev_misc.
#
# Deletion authority is a named cache leaf inside an exact root, never the
# root or the leaf itself: each leaf is emptied as <leaf>/*. One tri-state
# owner probe decides a whole root (running defers the family, unknown keeps
# it), and clean_guarded_dev_cache_root rechecks that probe plus the leaf's
# physical containment in the root at the sink. A symlinked root, profile or
# leaf is skipped, never followed.
#
# Measured with du -sk on one Mac (2026-10-15, after a manual cleanup):
#   Tabbit             root GraphiteDawnCache/ShaderCache 6.4 MB,
#                      Default GPU and Dawn caches 6 MB
#   Comet              Default GPU and Dawn caches 6 MB, ShaderCache 0.5 MB
#   Douzy              Partitions/douyin-login GPU and Dawn caches 1.1 MB
#   x-browser-profile  Default Dawn caches 2.1 MB, extensions_crx_cache 0.2 MB
#   gemini-web-pool    profile-acct2 leaves under 0.1 MB
#
# Non-targets, user or session state: Extensions, IndexedDB, Local Storage,
# Session Storage, Cookies, Login Data, Preferences, Web Data, History,
# TransportSecurity, SharedStorage, DIPS, Local State, Service Worker
# Database and ScriptCache, WidevineCdm, Safe Browsing, WasmTtsEngine,
# TabbitUpdater, Douzy license.bin and dy_downloader.db, gemini-web-pool
# acct*.json, ~/.nvm/versions and uv's installed interpreters.
set -euo pipefail

_MOLE_FORK_ROOT_LEAVES=(GraphiteDawnCache GrShaderCache ShaderCache component_crx_cache extensions_crx_cache)
_MOLE_FORK_PROFILE_LEAVES=(Cache "Code Cache" GPUCache DawnCache DawnGraphiteCache DawnWebGPUCache "Shared Dictionary/cache")
_MOLE_FORK_NAME_RE='^[A-Za-z0-9._-]+$'
_MOLE_FORK_PROFILE_RE='^Profile [0-9]+$'

# <root below $HOME>|<label>|<owner probe>|<profile layout>
# chromium: Default and "Profile N". electron: the root and Partitions/<name>.
MOLE_FORK_CHROMIUM_TABLE=(
    "Library/Application Support/Tabbit|Tabbit|fork_tabbit_process_state|chromium"
    "Library/Application Support/Comet|Comet|fork_comet_process_state|chromium"
    "Library/Application Support/Douzy|Douzy|fork_douzy_process_state|electron"
    ".local/share/x-browser-profile|x-browser-profile|fork_profile_args_process_state|chromium"
)

fork_tabbit_process_state() { mole_pgrep_any -x Tabbit -f '/Tabbit[.]app/Contents/'; }
fork_comet_process_state() { mole_pgrep_any -x Comet -f '/Comet[.]app/Contents/'; }
fork_douzy_process_state() { mole_pgrep_any -x Douzy -f '/Douzy[.]app/Contents/'; }

# An automation profile has no app of its own: the browser holding it names
# the root in --user-data-dir. A fresh, delimiter-aware argv probe, so
# profile-acct2 is never read out of profile-acct20.
fork_profile_args_process_state() {
    mole_process_args_reference_paths --fresh "$_MOLE_FORK_ROOT"
}

_fork_real_dir() { [[ -d "$1" && ! -L "$1" ]]; }

# Profile directories of one root into _MOLE_FORK_PROFILES.
_fork_collect_profiles() {
    local root="$1" layout="$2" dir name
    _MOLE_FORK_PROFILES=()
    if [[ "$layout" == "electron" ]]; then
        _MOLE_FORK_PROFILES+=("$root")
        _fork_real_dir "$root/Partitions" || return 0
        for dir in "$root/Partitions"/*; do
            name="${dir##*/}"
            [[ "$name" =~ $_MOLE_FORK_NAME_RE ]] || continue
            _fork_real_dir "$dir" && _MOLE_FORK_PROFILES+=("$dir")
        done
        return 0
    fi
    for dir in "$root/Default" "$root"/Profile\ *; do
        name="${dir##*/}"
        [[ "$name" == "Default" || "$name" =~ $_MOLE_FORK_PROFILE_RE ]] || continue
        _fork_real_dir "$dir" && _MOLE_FORK_PROFILES+=("$dir")
    done
    return 0
}

# Real leaf directories with at least one eligible child, into
# _MOLE_FORK_LEAF_DIRS. Expects _MOLE_FORK_PROFILES.
_fork_collect_leaf_dirs() {
    local root="$1" leaf profile
    local -a leaves=() _MOLE_FORK_TARGETS=()
    _MOLE_FORK_LEAF_DIRS=()
    for leaf in "${_MOLE_FORK_ROOT_LEAVES[@]}" BrowserMetrics; do
        leaves+=("$root/$leaf")
    done
    for profile in ${_MOLE_FORK_PROFILES[@]+"${_MOLE_FORK_PROFILES[@]}"}; do
        for leaf in "${_MOLE_FORK_PROFILE_LEAVES[@]}"; do
            leaves+=("$profile/$leaf")
        done
    done
    for leaf in "${leaves[@]}"; do
        _fork_real_dir "$leaf" || continue
        _fork_leaf_targets "$leaf"
        mole_cleanup_targets_exist "${_MOLE_FORK_TARGETS[@]}" || continue
        _MOLE_FORK_LEAF_DIRS+=("$leaf")
    done
    return 0
}

# Children of one leaf into _MOLE_FORK_TARGETS. BrowserMetrics gives up its
# .pma histogram files only; every other leaf is emptied whole.
_fork_leaf_targets() {
    local leaf="$1"
    if [[ "${leaf##*/}" == "BrowserMetrics" ]]; then
        _MOLE_FORK_TARGETS=("$leaf"/*.pma)
    else
        _MOLE_FORK_TARGETS=("$leaf"/*)
    fi
}

_fork_clean_leaf() {
    local root="$1" leaf="$2" probe="$3" label="$4"
    local display="$label ${leaf#"$root"/}"
    local -a _MOLE_FORK_TARGETS=()
    _fork_leaf_targets "$leaf"
    clean_guarded_dev_cache_root "$root" "$leaf" "$probe" "$label" "$display" \
        "${_MOLE_FORK_TARGETS[@]}"
}

# Service Worker CacheStorage only, through the cleaner that keeps protected
# web editors and whitelisted origins. Database and ScriptCache stay.
_fork_clean_service_workers() {
    local probe="$1" label="$2" profile
    declare -f clean_service_worker_cache > /dev/null 2>&1 || return 0
    for profile in ${_MOLE_FORK_PROFILES[@]+"${_MOLE_FORK_PROFILES[@]}"}; do
        _fork_service_worker_root_ok "$profile" || continue
        _dev_clean_service_worker_process_guarded "$probe" "$label" \
            "$label Service Worker" "$label" "$profile/Service Worker/CacheStorage" || return 0
    done
}

# One Chromium root: one owner probe for the family, then each leaf.
_fork_clean_chromium_root() {
    local root="$1" label="$2" probe="$3" layout="$4"
    _fork_real_dir "$root" || return 0
    local _MOLE_FORK_ROOT="$root"
    local -a _MOLE_FORK_PROFILES=() _MOLE_FORK_LEAF_DIRS=()
    _fork_collect_profiles "$root" "$layout"
    _fork_collect_leaf_dirs "$root"
    if [[ ${#_MOLE_FORK_LEAF_DIRS[@]} -eq 0 ]] && ! _fork_has_service_worker_cache; then
        return 0
    fi

    local _MOLE_CLEAN_GUARD_REASON=""
    if ! mole_clean_process_guard "$probe" "$label started"; then
        mole_report_guard_stop "$label caches" mole_defer_cleanup_family "$label"
        return 0
    fi
    local leaf rc
    for leaf in ${_MOLE_FORK_LEAF_DIRS[@]+"${_MOLE_FORK_LEAF_DIRS[@]}"}; do
        rc=0
        _fork_clean_leaf "$root" "$leaf" "$probe" "$label" || rc=$?
        mole_rc_timeout_or_signal "$rc" && return "$rc"
    done
    _fork_clean_service_workers "$probe" "$label"
}

_fork_has_service_worker_cache() {
    local profile
    for profile in ${_MOLE_FORK_PROFILES[@]+"${_MOLE_FORK_PROFILES[@]}"}; do
        _fork_service_worker_root_ok "$profile" || continue
        mole_cleanup_targets_exist "$profile/Service Worker/CacheStorage"/* && return 0
    done
    return 1
}

# Real Service Worker and CacheStorage directories, neither a symlink.
_fork_service_worker_root_ok() {
    _fork_real_dir "$1/Service Worker" || return 1
    _fork_real_dir "$1/Service Worker/CacheStorage"
}

# ~/.gemini-web-pool/accounts/<name> is one Chromium user-data-dir per
# account. The acct*.json files next to them hold cookies and stay.
_fork_clean_gemini_web_pool() {
    local accounts="$HOME/.gemini-web-pool/accounts" account name rc
    _fork_real_dir "$HOME/.gemini-web-pool" || return 0
    _fork_real_dir "$accounts" || return 0
    for account in "$accounts"/*; do
        name="${account##*/}"
        [[ "$name" =~ $_MOLE_FORK_NAME_RE ]] || continue
        _fork_real_dir "$account" || continue
        rc=0
        _fork_clean_chromium_root "$account" "gemini-web-pool $name" \
            fork_profile_args_process_state chromium || rc=$?
        mole_rc_timeout_or_signal "$rc" && return "$rc"
    done
    return 0
}

# nvm keeps downloaded node tarballs and sources in $NVM_DIR/.cache. Removing
# aged files there is what `nvm cache clear` does, but nvm is a shell
# function Mole must not source. NVM_DIR counts only when absolute, below
# $HOME and an nvm install (it holds nvm.sh); anything else is ignored rather
# than followed, so NVM_DIR=~/Documents never empties ~/Documents/.cache.
_fork_nvm_cache_dir() {
    local nvm_dir="${NVM_DIR:-$HOME/.nvm}"
    nvm_dir="${nvm_dir%/}"
    [[ "$nvm_dir" == "$HOME"/* ]] || return 1
    case "$nvm_dir" in
        *'/../'* | */.. | *'/./'* | */. | *'//'*) return 1 ;;
    esac
    [[ -f "$nvm_dir/nvm.sh" && ! -L "$nvm_dir/nvm.sh" ]] || return 1
    printf '%s\n' "$nvm_dir/.cache"
}

uv_process_state() { mole_pgrep_any -x uv; }

# `uv python install` stages downloads in python/.temp. Files older than
# MOLE_TEMP_FILE_AGE_DAYS cannot be an install in flight, and a running uv
# keeps the whole directory. The installed interpreters next to it stay.
_fork_clean_uv_python_temp() {
    local temp_dir="$HOME/.local/share/uv/python/.temp"
    _fork_real_dir "$temp_dir" || return 0
    mole_cleanup_targets_exist "$temp_dir"/* || return 0
    local _MOLE_CLEAN_GUARD_REASON=""
    if ! mole_clean_process_guard uv_process_state "uv started"; then
        mole_report_guard_stop "uv Python install temp" mole_defer_cleanup_family "uv"
        return 0
    fi
    safe_find_delete "$temp_dir" "*" "$MOLE_TEMP_FILE_AGE_DAYS" "f"
}

_fork_clean_dot_dir_caches() {
    local nvm_cache="" rc=0
    if nvm_cache=$(_fork_nvm_cache_dir) && _fork_real_dir "$nvm_cache"; then
        safe_find_delete "$nvm_cache" "*" "$MOLE_TEMP_FILE_AGE_DAYS" "f" || rc=$?
        mole_rc_timeout_or_signal "$rc" && return "$rc"
    fi
    rc=0
    _fork_clean_uv_python_temp || rc=$?
    mole_rc_timeout_or_signal "$rc" && return "$rc"
    return 0
}

clean_fork_app_caches() {
    local row rel label probe layout rc
    for row in "${MOLE_FORK_CHROMIUM_TABLE[@]}"; do
        IFS='|' read -r rel label probe layout <<< "$row"
        rc=0
        _fork_clean_chromium_root "$HOME/$rel" "$label" "$probe" "$layout" || rc=$?
        mole_rc_timeout_or_signal "$rc" && return "$rc"
    done
    rc=0
    _fork_clean_gemini_web_pool || rc=$?
    mole_rc_timeout_or_signal "$rc" && return "$rc"
    _fork_clean_dot_dir_caches
}
