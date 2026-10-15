#!/usr/bin/env bash
# shellcheck shell=bash
# Fixtures for the named-app, automation-profile, QQ and dot-dir cache rows.
# The process doubles read $HOME/ps-busy (one argv line per running process)
# and fail when $HOME/ps-error exists, so every probe stays inside the case
# HOME. Nothing here touches the real HOME.

fork_caches_fake_ps_body() {
	cat << 'BODY'
[[ -f "$HOME/ps-error" ]] && { echo "ps: broken" >&2; exit 2; }
[[ "$*" == *args* ]] || exit 0
printf '  PID  PPID COMM ARGS\n'
printf '  100     1 launchd /sbin/launchd\n'
pid=4000
if [[ -f "$HOME/ps-busy" ]]; then
    while IFS= read -r busy; do
        pid=$((pid + 1))
        exe="${busy%% *}"
        printf '  %s     1 %s %s\n' "$pid" "${exe##*/}" "$busy"
    done < "$HOME/ps-busy"
fi
BODY
}

# pgrep -x <name> matches the executable's basename (the argv before the
# first ' --' or, for a plain command, the first word); -f <ERE> the line.
fork_caches_fake_pgrep_body() {
	cat << 'BODY'
[[ -f "$HOME/ps-error" ]] && exit 3
[[ -f "$HOME/ps-busy" ]] || exit 1
selector="$1" pattern="$2"
while IFS= read -r busy; do
    exe="${busy%% --*}"
    word="${busy%% *}"
    case "$selector" in
        -x) [[ "${exe##*/}" == "$pattern" || "${word##*/}" == "$pattern" ]] && exit 0 ;;
        -f) [[ "$busy" =~ $pattern ]] && exit 0 ;;
    esac
done < "$HOME/ps-busy"
exit 1
BODY
}

fork_caches_case_home() {
	local case_home="$HOME/u5-$BATS_TEST_NUMBER"
	rm -rf "$case_home"
	mkdir -p "$case_home"
	printf '%s\n' "$case_home"
}

# Age every entry below $1 by $2 days (default 30).
fork_caches_age_tree() {
	local stamp
	stamp=$(date -v-"${2:-30}"d +%Y%m%d%H%M)
	find "$1" -exec touch -h -t "$stamp" {} +
}

# Run <function> through bin/clean.sh's real sink in <case_home>.
# MOLE_DRY_RUN in the caller's environment selects preview mode.
# Usage: fork_caches_run <case_home> <function> [prelude]
fork_caches_run() {
	local case_home="$1" call="$2" prelude="${3:-}"
	mole_test_fake_command ps "$(fork_caches_fake_ps_body)"
	mole_test_fake_command pgrep "$(fork_caches_fake_pgrep_body)"
	run env -u NVM_DIR HOME="$case_home" PROJECT_ROOT="$PROJECT_ROOT" \
		MOLE_TEST_NO_AUTH=1 MOLE_DRY_RUN="${MOLE_DRY_RUN:-0}" \
		FORK_CALL="$call" FORK_PRELUDE="$prelude" \
		/bin/bash --noprofile --norc << 'EOF'
set -euo pipefail
source "$PROJECT_ROOT/bin/clean.sh"
mole_defer_cleanup_family() { printf 'DEFER=%s\n' "$1"; }
eval "$FORK_PRELUDE"
"$FORK_CALL"
EOF
}
