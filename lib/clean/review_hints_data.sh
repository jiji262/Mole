#!/bin/bash
# Report-only review rows for large data `mo clean` must never delete: AI
# transcripts, editor state, models, app data and stale stores. Each row is
# "label · size · manual command"; nothing here removes, rewrites or chmods.
# Every probe runs under one wall-clock budget (MOLE_TIMEOUT_HINT_SCAN_SEC);
# a timeout drops the row and the pass ends with "(partial scan)". Callers
# source lib/core/common.sh and lib/clean/dev.sh (pnpm binary list) first.

set -euo pipefail

if [[ -n "${MOLE_REVIEW_HINTS_DATA_LOADED:-}" ]]; then
    return 0
fi
readonly MOLE_REVIEW_HINTS_DATA_LOADED=1

_mole_review_hints_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/clean/hints.sh
source "$_mole_review_hints_dir/hints.sh"

# Same 200MB floor as the Build artifacts hint: below it a review row costs
# more attention than the space is worth. A constant, not a setting.
readonly MOLE_REVIEW_HINT_MIN_KB=$((200 * 1024))
readonly MOLE_REVIEW_HINT_MAX_EXAMPLES=3
# Bytes of a Claude transcript read to find its recorded cwd.
readonly MOLE_REVIEW_TRANSCRIPT_HEAD_BYTES=65536

REVIEW_HINT_DEADLINE=0
REVIEW_HINT_PARTIAL=false
REVIEW_HINT_SPINNER=""
REVIEW_HINT_TIMEOUT=0
REVIEW_HINT_OUT=""
REVIEW_HINT_KB=0
REVIEW_HINT_DATE=""
REVIEW_HINT_KEPT=()
REVIEW_ACC_KB=0
REVIEW_ACC_COUNT=0
REVIEW_ACC_EXAMPLES=""

# Run each row producer under one budget. Only a signal stops the pass, and
# its status is returned so clean stops too; anything else just drops rows.
review_hint_run_steps() {
    local budget="$MOLE_TIMEOUT_HINT_SCAN_SEC" step rc=0
    [[ "$budget" =~ ^[0-9]+$ ]] || budget=0
    REVIEW_HINT_DEADLINE=$((SECONDS + budget))
    REVIEW_HINT_PARTIAL=false
    REVIEW_HINT_SPINNER="$1"
    shift
    start_section_spinner "$REVIEW_HINT_SPINNER"
    for step in "$@"; do
        "$step" || rc=$?
        [[ $rc -lt 128 ]] || break
        rc=0
    done
    stop_section_spinner
    if [[ $rc -eq 0 && "$REVIEW_HINT_PARTIAL" == "true" ]]; then
        note_activity
        echo -e "  ${GRAY}${ICON_REVIEW}${NC} Review hints · ${GRAY}(partial scan)${NC}"
    fi
    return "$rc"
}

# True while budget remains; a spent budget marks the pass partial.
review_hint_budget_ok() {
    [[ $SECONDS -lt $REVIEW_HINT_DEADLINE ]] && return 0
    REVIEW_HINT_PARTIAL=true
    return 1
}

# Set REVIEW_HINT_TIMEOUT to $1 clamped to the remaining budget.
review_hint_clamp() {
    REVIEW_HINT_TIMEOUT=$(_mole_timeout_with_deadline "$1" "$REVIEW_HINT_DEADLINE") && return 0
    REVIEW_HINT_PARTIAL=true
    return 1
}

# Run "$@" bounded by $1 seconds (clamped) into REVIEW_HINT_OUT and return
# the command's own status. A timeout marks the pass partial; a signal is
# recorded as a clean cancellation for the caller to return.
review_hint_capture() {
    local rc=0
    REVIEW_HINT_OUT=""
    review_hint_clamp "$1" || return 1
    shift
    REVIEW_HINT_OUT=$(run_with_timeout "$REVIEW_HINT_TIMEOUT" "$@" < /dev/null 2> /dev/null) || rc=$?
    if [[ $rc -ge 128 ]]; then
        _mole_record_clean_cancellation "$rc" "review hints"
    elif mole_rc_timeout "$rc"; then
        REVIEW_HINT_PARTIAL=true
    fi
    return "$rc"
}

# Measure $1 into REVIEW_HINT_KB through the shared bounded du. Status 0
# measured, 1 unknown (pass marked partial), 128+ a recorded signal.
review_hint_measure() {
    local rc=0
    REVIEW_HINT_KB=0
    review_hint_clamp "$MOLE_TIMEOUT_SHORT_QUERY_SEC" || return 1
    REVIEW_HINT_KB=$(hint_get_path_size_kb_with_timeout "$1" "$REVIEW_HINT_TIMEOUT") || rc=$?
    if [[ $rc -ge 128 ]]; then
        _mole_record_clean_cancellation "$rc" "review hints"
        return "$rc"
    fi
    [[ $rc -eq 0 && "$REVIEW_HINT_KB" =~ ^[0-9]+$ ]] && return 0
    REVIEW_HINT_KB=0
    REVIEW_HINT_PARTIAL=true
    return 1
}

# Print one row with no size floor. The spinner stops first so the row is
# not glued to a spinner frame.
review_hint_emit() {
    stop_section_spinner
    echo -e "  ${YELLOW}${ICON_REVIEW}${NC} $1 · ${GRAY}$2${NC}"
    note_activity
    start_section_spinner "$REVIEW_HINT_SPINNER"
}

# "label · size · detail", hidden (and not section activity) below the floor.
review_hint_print() {
    [[ "$2" -ge $MOLE_REVIEW_HINT_MIN_KB ]] || return 0
    review_hint_emit "$1 · ${GREEN}$(bytes_to_human "$(($2 * 1024))")${NC}" "$3"
}

review_hint_acc_reset() {
    REVIEW_ACC_KB=0
    REVIEW_ACC_COUNT=0
    REVIEW_ACC_EXAMPLES=""
}

# Add one item (path, KB) to the count row; only the first few are named.
review_hint_acc_add() {
    REVIEW_ACC_KB=$((REVIEW_ACC_KB + ${2:-0}))
    REVIEW_ACC_COUNT=$((REVIEW_ACC_COUNT + 1))
    if [[ $REVIEW_ACC_COUNT -le $MOLE_REVIEW_HINT_MAX_EXAMPLES ]]; then
        REVIEW_ACC_EXAMPLES+="${REVIEW_ACC_EXAMPLES:+, }${1/#$HOME/~}"
    elif [[ $REVIEW_ACC_COUNT -eq $((MOLE_REVIEW_HINT_MAX_EXAMPLES + 1)) ]]; then
        REVIEW_ACC_EXAMPLES+=", …"
    fi
}

# "N found · examples · command" for the accumulated count row.
review_hint_acc_detail() {
    printf '%s found · %s · %s' "$REVIEW_ACC_COUNT" "$REVIEW_ACC_EXAMPLES" "$1"
}

# Print the count row; $2 is the manual command. Sized rows keep the floor.
review_hint_acc_print() {
    [[ $REVIEW_ACC_COUNT -gt 0 ]] || return 0
    review_hint_print "$1" "$REVIEW_ACC_KB" "$(review_hint_acc_detail "$2")"
}

# Measure every existing, non-symlink path in "$@" into the count row.
review_hint_acc_paths() {
    local path rc
    for path in "$@"; do
        [[ -e "$path" && ! -L "$path" ]] || continue
        review_hint_budget_ok || return 0
        rc=0
        review_hint_measure "$path" || rc=$?
        [[ $rc -lt 128 ]] || return "$rc"
        [[ $rc -ne 0 ]] || review_hint_acc_add "$path" "$REVIEW_HINT_KB"
    done
    return 0
}

# REVIEW_HINT_DATE = date of the newest direct child, from one bounded
# listing. Any failure leaves it empty rather than showing an older date.
review_hint_newest_date() {
    local newest
    REVIEW_HINT_DATE=""
    review_hint_capture "$MOLE_TIMEOUT_SHORT_QUERY_SEC" \
        find "$1" -mindepth 1 -maxdepth 1 -exec "$STAT_BSD" -f '%m' {} + || return
    newest=$(printf '%s\n' "$REVIEW_HINT_OUT" | sort -n | tail -1)
    [[ "$newest" =~ ^[0-9]+$ ]] || return 0
    REVIEW_HINT_DATE=$("$_DATE_CMD" -r "$newest" '+%Y-%m-%d' 2> /dev/null) || REVIEW_HINT_DATE=""
}

# Size row for one dir or file (never a symlink). $3 "date" adds the newest
# child's date; any other value replaces the `mo analyze <path>` command.
review_hint_path() {
    local label="$1" path="$2" opt="${3:-}" rc=0 detail
    [[ -e "$path" && ! -L "$path" ]] || return 0
    review_hint_budget_ok || return 0
    review_hint_measure "$path" || rc=$?
    [[ $rc -lt 128 ]] || return "$rc"
    [[ $rc -eq 0 && $REVIEW_HINT_KB -ge $MOLE_REVIEW_HINT_MIN_KB ]] || return 0
    detail="mo analyze $(format_path_link "$path")"
    if [[ "$opt" == "date" ]]; then
        review_hint_newest_date "$path" || rc=$?
        [[ $rc -lt 128 ]] || return "$rc"
        [[ -z "$REVIEW_HINT_DATE" ]] || detail="${REVIEW_HINT_DATE} · ${detail}"
    elif [[ -n "$opt" ]]; then
        detail="$opt"
    fi
    review_hint_print "$label" "$REVIEW_HINT_KB" "$detail"
}

# 0 when nothing under $1 changed within $2 days. "shallow" as $3 checks $1
# and its direct children only, else every file below it. A probe that
# cannot finish is never idle; its status is returned.
review_hint_untouched() {
    local -a scope=(-type f)
    [[ "${3:-}" != "shallow" ]] || scope=(-maxdepth 1)
    review_hint_capture "$MOLE_TIMEOUT_SHORT_QUERY_SEC" \
        find "$1" "${scope[@]}" -mtime "-$2" -print -quit || return
    [[ -z "$REVIEW_HINT_OUT" ]]
}

# Keep each "$@" path for which `review_hint_untouched <path> $1` holds, in
# REVIEW_HINT_KEPT. Returns a signal status, else 0.
review_hint_filter_untouched() {
    local days="$1" path rc
    shift
    REVIEW_HINT_KEPT=()
    for path in "$@"; do
        [[ -d "$path" && ! -L "$path" ]] || continue
        review_hint_budget_ok || return 0
        rc=0
        review_hint_untouched "$path" "$days" || rc=$?
        [[ $rc -lt 128 ]] || return "$rc"
        [[ $rc -ne 0 ]] || REVIEW_HINT_KEPT+=("$path")
    done
    return 0
}

# shellcheck source=lib/clean/review_hints_apps.sh
source "$_mole_review_hints_dir/review_hints_apps.sh"

# Large files section: report-only data rows, after the fixed large rows.
show_data_review_hints() {
    review_hint_run_steps "Reviewing app data..." \
        review_hints_claude review_hints_codex review_hints_superpowers \
        review_hints_app_data review_hints_editors review_hints_python_user \
        review_hints_adspower review_hints_pnpm review_hints_orphan_containers
}
