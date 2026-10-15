#!/bin/bash
# Report-only "Review" section of `mo clean`: git repo hygiene, Downloads
# junk and duplicates, stale top-level dot-directories, and credential-shaped
# files other users can read. Rows print manual commands only: Mole runs no
# rm, chmod or mutating git command here, and never opens credential files.
# These rows are counts, not space, so only sized rows keep the 200MB floor.

set -euo pipefail

if [[ -n "${MOLE_REVIEW_HINTS_HOME_LOADED:-}" ]]; then
    return 0
fi
readonly MOLE_REVIEW_HINTS_HOME_LOADED=1

# shellcheck source=lib/clean/review_hints_data.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/review_hints_data.sh"

# git's documented gc.auto default: loose objects before an automatic gc.
readonly MOLE_GIT_GC_AUTO_DEFAULT=6700
# Depth limits: .git dirs under purge roots, Downloads entries, credentials.
readonly MOLE_REVIEW_REPO_DEPTH=2
readonly MOLE_REVIEW_DOWNLOADS_DEPTH=2
readonly MOLE_REVIEW_CREDENTIAL_DEPTH=3
# Top-level dot-directories that hold keys, config or live tool state.
readonly MOLE_REVIEW_DOTDIR_KEEP=(.ssh .gnupg .aws .config .local .cache .Trash .claude .codex .npm .cargo .rustup)
readonly MOLE_REVIEW_CREDENTIAL_NAMES=(
    \( -name .env -o \( -name '.env.*' ! -name '*.example' ! -name '*.sample' ! -name '*.template' \)
    -o -name 'client_secret*.json' -o -name client_secrets.json -o -name token.json
    -o -name '*.pem' -o -name '*.p12' -o -name id_rsa -o -name id_ed25519
    -o -name '*ssh*.zip' -o -name '*service-account*.json' -o -name '*.remote-service-role.env' \)
)
# shellcheck disable=SC2016 # literal $RECYCLE.BIN and ~$ lock-file names
readonly MOLE_REVIEW_DOWNLOADS_JUNK=(
    \( -type d \( -name '$RECYCLE.BIN' -o -name node_modules \) -prune -print \)
    -o \( -type f \( -name desktop.ini -o -name '~$*.doc' -o -name '~$*.docx' -o -name '~$*.xls'
    -o -name '~$*.xlsx' -o -name '~$*.ppt' -o -name '~$*.pptx' \) -print \)
)

# Read-only git: no fsmonitor, no hooks, no optional index lock.
review_hint_git() {
    local repo="$1"
    shift
    review_hint_capture "$MOLE_TIMEOUT_QUICK_DETECT_SEC" env GIT_OPTIONAL_LOCKS=0 \
        git -c core.fsmonitor=false -c core.hooksPath=/dev/null -C "$repo" "$@"
}

# Repos (.git directories at depth <= 2) under the purge search roots, into
# REVIEW_HINT_KEPT.
review_hint_git_repos() {
    local root line rc
    REVIEW_HINT_KEPT=()
    while IFS= read -r root; do
        [[ -d "$root" && ! -L "$root" ]] || continue
        review_hint_budget_ok || break
        rc=0
        review_hint_capture "$MOLE_TIMEOUT_SHORT_QUERY_SEC" find "$root" \
            -maxdepth "$MOLE_REVIEW_REPO_DEPTH" -name .git -type d -prune -print || rc=$?
        [[ $rc -lt 128 ]] || return "$rc"
        [[ $rc -eq 0 ]] || continue
        while IFS= read -r line; do
            [[ -z "$line" ]] || REVIEW_HINT_KEPT+=("${line%/.git}")
        done <<< "$REVIEW_HINT_OUT"
    done < <(load_quick_purge_hint_paths)
    return 0
}

review_hints_git() {
    review_hint_git_repos || return
    local -a repos=("${REVIEW_HINT_KEPT[@]+"${REVIEW_HINT_KEPT[@]}"}")
    [[ ${#repos[@]} -gt 0 ]] || return 0
    review_hints_git_packs "${repos[@]}" || return
    review_hints_git_worktrees "${repos[@]}" || return
    review_hints_git_loose "${repos[@]}"
}

# tmp_pack_* left by an interrupted fetch or repack, older than
# MOLE_TEMP_FILE_AGE_DAYS; `git gc` owns their removal.
review_hints_git_packs() {
    local repo size bytes rc
    review_hint_acc_reset
    for repo in "$@"; do
        [[ -d "$repo/.git/objects/pack" ]] || continue
        review_hint_budget_ok || break
        rc=0
        review_hint_capture "$MOLE_TIMEOUT_SHORT_QUERY_SEC" find "$repo/.git/objects/pack" -maxdepth 1 \
            -type f -name 'tmp_pack_*' -mtime "+$MOLE_TEMP_FILE_AGE_DAYS" -exec "$STAT_BSD" -f '%z' {} + || rc=$?
        [[ $rc -lt 128 ]] || return "$rc"
        [[ $rc -eq 0 && -n "$REVIEW_HINT_OUT" ]] || continue
        bytes=0
        while IFS= read -r size; do
            [[ ! "$size" =~ ^[0-9]+$ ]] || bytes=$((bytes + size))
        done <<< "$REVIEW_HINT_OUT"
        review_hint_acc_add "$repo" "$((bytes / 1024))"
    done
    [[ $REVIEW_ACC_COUNT -gt 0 ]] || return 0
    review_hint_emit "Git temp packs · ${GREEN}$(bytes_to_human "$((REVIEW_ACC_KB * 1024))")${NC}" \
        "$(review_hint_acc_detail "git -C <repo> gc")"
}

# A prunable worktree is reported only when unlocked and its parent dir is
# on a mounted local path: a worktree on an unplugged disk or share also
# reads as prunable, and pruning it would drop live metadata.
review_hint_worktree_reportable() {
    [[ "$2" == "true" && "$3" == "false" && "$1" == /* ]] || return 1
    case "$1" in
        /Volumes/* | /Network/* | /net/*) return 1 ;;
    esac
    [[ -d "${1%/*}" ]]
}

# 0 when the porcelain listing in $1 has a reportable prunable worktree.
review_hint_has_prunable_worktree() {
    local line wt="" prunable=false locked=false
    while IFS= read -r line; do
        case "$line" in
            "worktree "*) wt="${line#worktree }" prunable=false locked=false ;;
            prunable*) prunable=true ;;
            locked*) locked=true ;;
            "") ! review_hint_worktree_reportable "$wt" "$prunable" "$locked" || return 0 ;;
        esac
    done <<< "$1"$'\n'
    return 1
}

review_hints_git_worktrees() {
    local repo rc
    review_hint_acc_reset
    for repo in "$@"; do
        review_hint_budget_ok || break
        rc=0
        review_hint_git "$repo" worktree list --porcelain || rc=$?
        [[ $rc -lt 128 ]] || return "$rc"
        [[ $rc -eq 0 ]] || continue
        ! review_hint_has_prunable_worktree "$REVIEW_HINT_OUT" || review_hint_acc_add "$repo" 0
    done
    [[ $REVIEW_ACC_COUNT -gt 0 ]] || return 0
    review_hint_emit "Prunable git worktrees" "$(review_hint_acc_detail "git -C <repo> worktree prune")"
}

# Loose objects at or above the repo's own gc.auto (unset: git's default;
# 0 means the user turned automatic gc off, so no row).
review_hints_git_loose() {
    local repo rc count limit
    review_hint_acc_reset
    for repo in "$@"; do
        review_hint_budget_ok || break
        rc=0
        review_hint_git "$repo" count-objects -v || rc=$?
        [[ $rc -lt 128 ]] || return "$rc"
        [[ $rc -eq 0 ]] || continue
        count=$(printf '%s\n' "$REVIEW_HINT_OUT" | awk '$1 == "count:" {print $2; exit}')
        review_hint_git "$repo" config --default "$MOLE_GIT_GC_AUTO_DEFAULT" --get gc.auto || rc=$?
        [[ $rc -lt 128 ]] || return "$rc"
        limit="$REVIEW_HINT_OUT"
        [[ $rc -eq 0 && "$count" =~ ^[0-9]+$ && "$limit" =~ ^[0-9]+$ && $limit -gt 0 ]] || continue
        [[ $count -lt $limit ]] || review_hint_acc_add "$repo" 0
    done
    [[ $REVIEW_ACC_COUNT -gt 0 ]] || return 0
    review_hint_emit "Git repos due for gc" "$(review_hint_acc_detail "git -C <repo> gc")"
}

review_hints_downloads() {
    local root="$HOME/Downloads"
    [[ -d "$root" && ! -L "$root" ]] || return 0
    review_hints_downloads_junk "$root" || return
    review_hints_downloads_dupes "$root"
}

# Windows recycle bins, desktop.ini, Office lock files and stray
# node_modules dirs at depth <= 2.
review_hints_downloads_junk() {
    local root="$1" path rc=0
    review_hint_budget_ok || return 0
    review_hint_capture "$MOLE_TIMEOUT_SHORT_QUERY_SEC" find "$root" \
        -maxdepth "$MOLE_REVIEW_DOWNLOADS_DEPTH" "${MOLE_REVIEW_DOWNLOADS_JUNK[@]}" || rc=$?
    [[ $rc -lt 128 ]] || return "$rc"
    [[ $rc -eq 0 && -n "$REVIEW_HINT_OUT" ]] || return 0
    review_hint_acc_reset
    while IFS= read -r path; do
        [[ -z "$path" ]] || review_hint_acc_add "$path" 0
    done <<< "$REVIEW_HINT_OUT"
    review_hint_emit "Downloads junk" "$(review_hint_acc_detail "mo analyze $(format_path_link "$root")")"
}

# 0 when $1 is byte-identical to one of "$@" after it. A comparison that
# cannot finish counts as different.
review_hint_is_duplicate_of() {
    local path="$1" other rc
    shift
    for other in "$@"; do
        review_hint_budget_ok || return 1
        rc=0
        review_hint_capture "$MOLE_TIMEOUT_SHORT_QUERY_SEC" cmp -s "$other" "$path" || rc=$?
        [[ $rc -ne 0 ]] || return 0
        [[ $rc -lt 128 ]] || return "$rc"
    done
    return 1
}

# Large byte-identical files: grouped by size, each compared with the
# distinct files of its size seen so far. Every later copy is reclaimable.
review_hints_downloads_dupes() {
    local root="$1" line size path prev="" rc=0
    local -a group=()
    review_hint_budget_ok || return 0
    review_hint_capture "$MOLE_TIMEOUT_SHORT_QUERY_SEC" find "$root" -maxdepth "$MOLE_REVIEW_DOWNLOADS_DEPTH" \
        -type f -size "+$((MOLE_REVIEW_HINT_MIN_KB - 1))k" -exec "$STAT_BSD" -f '%z %N' {} + || rc=$?
    [[ $rc -lt 128 ]] || return "$rc"
    [[ $rc -eq 0 && -n "$REVIEW_HINT_OUT" ]] || return 0
    review_hint_acc_reset
    while IFS= read -r line; do
        size="${line%% *}" path="${line#* }"
        [[ "$size" == "$prev" ]] || group=()
        prev="$size"
        rc=0
        review_hint_is_duplicate_of "$path" "${group[@]+"${group[@]}"}" || rc=$?
        [[ $rc -lt 128 ]] || return "$rc"
        if [[ $rc -eq 0 ]]; then
            review_hint_acc_add "$path" "$((size / 1024))"
        else
            group+=("$path")
        fi
    done < <(printf '%s\n' "$REVIEW_HINT_OUT" | sort -n)
    review_hint_acc_print "Duplicate downloads" "mo analyze $(format_path_link "$root")"
}

# 0 when a command, or an app in $2 (lowercased .app names, one per line),
# carries the dot-directory's name.
review_hint_tool_present() {
    local lower
    command -v "$1" > /dev/null 2>&1 && return 0
    lower=$(printf '%s' "$1" | /usr/bin/tr '[:upper:]' '[:lower:]')
    [[ $'\n'"$2"$'\n' == *$'\n'"$lower.app"$'\n'* ]]
}

# Top-level ~/.<name> dirs untouched for MOLE_DOTDIR_ORPHAN_AGE_DAYS (own
# and direct-children mtimes) whose tool is neither on PATH nor installed.
review_hints_dotdirs() {
    local dir name apps keep rc
    local -a candidates=() stale=()
    for dir in "$HOME"/.[!.]*; do
        [[ -d "$dir" && ! -L "$dir" ]] || continue
        name="${dir##*/}"
        for keep in "${MOLE_REVIEW_DOTDIR_KEEP[@]}"; do
            [[ "$name" != "$keep" ]] || continue 2
        done
        candidates+=("$dir")
    done
    [[ ${#candidates[@]} -gt 0 ]] || return 0
    apps=$(printf '%s\n' /Applications/*.app "$HOME"/Applications/*.app | sed 's|.*/||' | /usr/bin/tr '[:upper:]' '[:lower:]')
    for dir in "${candidates[@]}"; do
        review_hint_budget_ok || break
        rc=0
        review_hint_untouched "$dir" "$MOLE_DOTDIR_ORPHAN_AGE_DAYS" shallow || rc=$?
        [[ $rc -lt 128 ]] || return "$rc"
        [[ $rc -eq 0 ]] || continue
        name="${dir##*/}"
        review_hint_tool_present "${name#.}" "$apps" || stale+=("$dir")
    done
    review_hint_acc_reset
    review_hint_acc_paths "${stale[@]+"${stale[@]}"}" || return
    review_hint_acc_print "Stale dot-directories" "ls -la <dir>"
}

review_hint_credential_roots() {
    printf '%s\n' "$HOME/Downloads" "$HOME/Desktop" "$HOME/Documents"
    load_quick_purge_hint_paths
}

# Credential-shaped files the user owns that group or other can read. Only
# names and modes are inspected; contents are never opened.
review_hints_credentials() {
    local root line mode rc me
    me=$(id -u)
    review_hint_acc_reset
    while IFS= read -r root; do
        [[ -d "$root" && ! -L "$root" ]] || continue
        review_hint_budget_ok || break
        rc=0
        review_hint_capture "$MOLE_TIMEOUT_SHORT_QUERY_SEC" find "$root" -maxdepth "$MOLE_REVIEW_CREDENTIAL_DEPTH" \
            -type f -user "$me" "${MOLE_REVIEW_CREDENTIAL_NAMES[@]}" -exec "$STAT_BSD" -f '%Lp %N' {} + || rc=$?
        [[ $rc -lt 128 ]] || return "$rc"
        [[ $rc -eq 0 ]] || continue
        while IFS= read -r line; do
            mode="${line%% *}"
            [[ "$mode" =~ ^[0-7]{3,4}$ ]] || continue
            ((8#$mode & 8#044)) || continue
            review_hint_acc_add "${line#* }" 0
        done <<< "$REVIEW_HINT_OUT"
    done < <(review_hint_credential_roots)
    [[ $REVIEW_ACC_COUNT -gt 0 ]] || return 0
    review_hint_emit "Credential files readable by others" "$(review_hint_acc_detail "chmod 600 <path>")"
}

# Review section: report-only home hygiene rows, after Project artifacts.
show_home_review_hints() {
    review_hint_run_steps "Reviewing home..." \
        review_hints_git review_hints_downloads review_hints_dotdirs review_hints_credentials
}
