#!/usr/bin/env bats

load helpers/common

setup_file() {
	mole_test_setup_home installers-home
}

teardown_file() {
	mole_test_teardown_home
}

setup() {
	# Safety: refuse to operate on a real home directory.
	if [[ "$HOME" != "${BATS_TEST_DIRNAME}/tmp-"* ]]; then
		printf 'FATAL: HOME is not a test temp dir: %s\n' "$HOME" >&2
		return 1
	fi
	export TERM="xterm-256color"
	export MO_DEBUG=0

	# Create standard scan directories
	mkdir -p "$HOME/Downloads"
	mkdir -p "$HOME/Desktop"
	mkdir -p "$HOME/Documents"
	mkdir -p "$HOME/Public"
	mkdir -p "$HOME/Library/Downloads"

	# Clear previous test files
	rm -rf "${HOME:?}/Downloads"/*
	rm -rf "${HOME:?}/Desktop"/*
	rm -rf "${HOME:?}/Documents"/*
}

# Test arguments

@test "installer.sh rejects unknown options" {
	run "$PROJECT_ROOT/bin/installer.sh" --unknown-option

	[ "$status" -eq 1 ]
	[[ "$output" == *"Unknown option"* ]]
}

@test "installer.sh accepts --dry-run option" {
	run env HOME="$HOME" TERM="xterm-256color" "$PROJECT_ROOT/bin/installer.sh" --dry-run

	[[ "$status" -eq 0 || "$status" -eq 2 ]] || return 1
	[[ "$output" == *"DRY RUN MODE"* ]]
}

# Test scan_installers_in_path function directly

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Tests using find (forced fallback by hiding fd)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

@test "scan_installers_in_path (fallback find): finds .dmg files" {
	touch "$HOME/Downloads/Chrome.dmg"

	run env PATH="/usr/bin:/bin" /bin/bash -euo pipefail -c "
        export MOLE_TEST_MODE=1
        source \"\$1\"
        scan_installers_in_path \"\$2\"
    " bash "$PROJECT_ROOT/bin/installer.sh" "$HOME/Downloads"

	[ "$status" -eq 0 ]
	[[ "$output" == *"Chrome.dmg"* ]]
}

@test "scan_installers_in_path (fallback find): finds multiple installer types" {
	touch "$HOME/Downloads/App1.dmg"
	touch "$HOME/Downloads/App2.pkg"
	touch "$HOME/Downloads/App3.iso"
	touch "$HOME/Downloads/App.mpkg"

	run env PATH="/usr/bin:/bin" /bin/bash -euo pipefail -c "
        export MOLE_TEST_MODE=1
        source \"\$1\"
        scan_installers_in_path \"\$2\"
    " bash "$PROJECT_ROOT/bin/installer.sh" "$HOME/Downloads"

	[ "$status" -eq 0 ]
	[[ "$output" == *"App1.dmg"* ]] || return 1
	[[ "$output" == *"App2.pkg"* ]] || return 1
	[[ "$output" == *"App3.iso"* ]] || return 1
	[[ "$output" == *"App.mpkg"* ]]
}

@test "scan_installers_in_path (fallback find): respects max depth" {
	mkdir -p "$HOME/Downloads/level1/level2/level3"
	touch "$HOME/Downloads/shallow.dmg"
	touch "$HOME/Downloads/level1/mid.dmg"
	touch "$HOME/Downloads/level1/level2/deep.dmg"
	touch "$HOME/Downloads/level1/level2/level3/too-deep.dmg"

	run env PATH="/usr/bin:/bin" /bin/bash -euo pipefail -c "
        export MOLE_TEST_MODE=1
        source \"\$1\"
        scan_installers_in_path \"\$2\"
    " bash "$PROJECT_ROOT/bin/installer.sh" "$HOME/Downloads"

	[ "$status" -eq 0 ]
	# Default max depth is 2 (INSTALLER_SCAN_MAX_DEPTH_DEFAULT), so level2 and below
	# must be excluded. Assert on the containing path, not the bare filename:
	# *"deep.dmg"* also matches too-deep.dmg, which hid the boundary entirely.
	[[ "$output" == *"/shallow.dmg"* ]] || return 1
	[[ "$output" == *"/level1/mid.dmg"* ]] || return 1
	[[ "$output" != *"/level1/level2/deep.dmg"* ]] || return 1
	[[ "$output" != *"/level1/level2/level3/too-deep.dmg"* ]]
}

@test "scan_installers_in_path (fallback find): honors MOLE_INSTALLER_SCAN_MAX_DEPTH" {
	mkdir -p "$HOME/Downloads/level1"
	touch "$HOME/Downloads/top.dmg"
	touch "$HOME/Downloads/level1/nested.dmg"

	run env PATH="/usr/bin:/bin" MOLE_INSTALLER_SCAN_MAX_DEPTH=1 /bin/bash -euo pipefail -c "
        export MOLE_TEST_MODE=1
        source \"\$1\"
        scan_installers_in_path \"\$2\"
    " bash "$PROJECT_ROOT/bin/installer.sh" "$HOME/Downloads"

	[ "$status" -eq 0 ]
	[[ "$output" == *"top.dmg"* ]] || return 1
	[[ "$output" != *"nested.dmg"* ]]
}

@test "scan_installers_in_path (fallback find): handles non-existent directory" {
	run env PATH="/usr/bin:/bin" /bin/bash -euo pipefail -c "
        export MOLE_TEST_MODE=1
        source \"\$1\"
        scan_installers_in_path \"\$2\"
    " bash "$PROJECT_ROOT/bin/installer.sh" "$HOME/NonExistent"

	[ "$status" -eq 0 ]
	[[ -z "$output" ]]
}

@test "scan_installers_in_path (fallback find): ignores non-installer files" {
	touch "$HOME/Downloads/document.pdf"
	touch "$HOME/Downloads/image.jpg"
	touch "$HOME/Downloads/archive.tar.gz"
	touch "$HOME/Downloads/Installer.dmg"

	run env PATH="/usr/bin:/bin" /bin/bash -euo pipefail -c "
        export MOLE_TEST_MODE=1
        source \"\$1\"
        scan_installers_in_path \"\$2\"
    " bash "$PROJECT_ROOT/bin/installer.sh" "$HOME/Downloads"

	[ "$status" -eq 0 ]
	[[ "$output" != *"document.pdf"* ]] || return 1
	[[ "$output" != *"image.jpg"* ]] || return 1
	[[ "$output" != *"archive.tar.gz"* ]] || return 1
	[[ "$output" == *"Installer.dmg"* ]]
}

@test "scan_all_installers: handles missing paths gracefully" {
	# Don't create all scan directories, some may not exist
	# Only create Downloads, delete others if they exist
	rm -rf "$HOME/Desktop"
	rm -rf "$HOME/Documents"
	rm -rf "$HOME/Public"
	rm -rf "$HOME/Public/Downloads"
	rm -rf "$HOME/Library/Downloads"
	mkdir -p "$HOME/Downloads"

	# Add an installer to the one directory that exists
	touch "$HOME/Downloads/test.dmg"

	run /bin/bash -euo pipefail -c '
        export MOLE_TEST_MODE=1
        source "$1"
        scan_all_installers
    ' bash "$PROJECT_ROOT/bin/installer.sh"

	# Should succeed even with missing paths
	[ "$status" -eq 0 ]
	# Should still find the installer in the existing directory
	[[ "$output" == *"test.dmg"* ]]
}

# Test edge cases

@test "scan_installers_in_path (fallback find): handles filenames with spaces" {
	touch "$HOME/Downloads/My App Installer.dmg"

	run env PATH="/usr/bin:/bin" /bin/bash -euo pipefail -c "
        export MOLE_TEST_MODE=1
        source \"\$1\"
        scan_installers_in_path \"\$2\"
    " bash "$PROJECT_ROOT/bin/installer.sh" "$HOME/Downloads"

	[ "$status" -eq 0 ]
	[[ "$output" == *"My App Installer.dmg"* ]]
}

@test "scan_installers_in_path (fallback find): handles filenames with special characters" {
	touch "$HOME/Downloads/App-v1.2.3_beta.pkg"

	run env PATH="/usr/bin:/bin" /bin/bash -euo pipefail -c "
        export MOLE_TEST_MODE=1
        source \"\$1\"
        scan_installers_in_path \"\$2\"
    " bash "$PROJECT_ROOT/bin/installer.sh" "$HOME/Downloads"

	[ "$status" -eq 0 ]
	[[ "$output" == *"App-v1.2.3_beta.pkg"* ]]
}

@test "scan_installers_in_path (fallback find): returns empty for directory with no installers" {
	# Create some non-installer files
	touch "$HOME/Downloads/document.pdf"
	touch "$HOME/Downloads/image.png"

	run env PATH="/usr/bin:/bin" /bin/bash -euo pipefail -c "
        export MOLE_TEST_MODE=1
        source \"\$1\"
        scan_installers_in_path \"\$2\"
    " bash "$PROJECT_ROOT/bin/installer.sh" "$HOME/Downloads"

	[ "$status" -eq 0 ]
	[[ -z "$output" ]]
}

# Symlink handling tests

@test "scan_installers_in_path (fallback find): skips symlinks to regular files" {
	touch "$HOME/Downloads/real.dmg"
	ln -s "$HOME/Downloads/real.dmg" "$HOME/Downloads/symlink.dmg"
	ln -s /nonexistent "$HOME/Downloads/dangling.lnk"

	run env PATH="/usr/bin:/bin" /bin/bash -euo pipefail -c "
        export MOLE_TEST_MODE=1
        source \"\$1\"
        scan_installers_in_path \"\$2\"
    " bash "$PROJECT_ROOT/bin/installer.sh" "$HOME/Downloads"

	[ "$status" -eq 0 ]
	[[ "$output" == *"real.dmg"* ]] || return 1
	[[ "$output" != *"symlink.dmg"* ]] || return 1
	[[ "$output" != *"dangling.lnk"* ]]
}

@test "delete_selected_installers removes selected files and records successes" {
	local first="$HOME/Downloads/First.dmg"
	local second="$HOME/Downloads/Second.pkg"
	printf 'one' > "$first"
	printf 'two' > "$second"

	# shellcheck disable=SC2016
	run env HOME="$HOME" TERM="$TERM" /bin/bash -euo pipefail -c '
        export MOLE_TEST_MODE=1
        export MOLE_TEST_NO_AUTH=1
        export MOLE_DELETE_LOG="$HOME/deletions.log"
        source "$1"

        INSTALLER_PATHS=("$2" "$3")
        INSTALLER_SIZES=(3 3)
        MOLE_SELECTION_RESULT="0,1"

        delete_selected_installers < <(printf "\n")
        printf "deleted=%s failed=%s freed=%s\n" "$total_deleted" "${total_delete_failed:-0}" "$total_size_freed_kb"
        [[ ! -e "$2" ]] || return 1
        [[ ! -e "$3" ]] || return 1
        grep -F "[installer] REMOVED $2" "$HOME/Library/Logs/mole/operations.log" > /dev/null
    ' bash "$PROJECT_ROOT/bin/installer.sh" "$first" "$second"

	[ "$status" -eq 0 ]
	[[ "$output" == *"deleted=2 failed=0"* ]]
}

@test "delete_selected_installers records protected-path failures" {
	local removable="$HOME/Downloads/Good.dmg"
	printf 'good' > "$removable"

	# shellcheck disable=SC2016
	run env HOME="$HOME" TERM="$TERM" /bin/bash -euo pipefail -c '
        export MOLE_TEST_MODE=1
        export MOLE_TEST_NO_AUTH=1
        export MOLE_DELETE_LOG="$HOME/deletions.log"
        source "$1"

        system_size=$(get_file_size "/System")
        INSTALLER_PATHS=("$2" "/System")
        INSTALLER_SIZES=(4 "$system_size")
        MOLE_SELECTION_RESULT="0,1"

        set +e
        delete_selected_installers < <(printf "\n")
        rc=$?
        set -e
        printf "rc=%s deleted=%s failed=%s\n" "$rc" "$total_deleted" "${total_delete_failed:-0}"
        if [[ ${total_delete_failed:-0} -gt 0 ]]; then
            printf "failure=%s\n" "${INSTALLER_DELETE_FAILURES[0]}"
        fi
        [[ ! -e "$2" ]] || return 1
    ' bash "$PROJECT_ROOT/bin/installer.sh" "$removable"

	[ "$status" -eq 0 ]
	[[ "$output" == *"rc=3 deleted=1 failed=1"* ]] || return 1
	[[ "$output" == *"failure=/System (delete failed)"* ]]
}

@test "execute_installer_delete_plan refuses replaced files" {
	local target="$HOME/Downloads/Replaced.dmg"
	local replacement="$HOME/Downloads/Replacement.dmg"
	printf 'one' > "$target"
	printf 'one' > "$replacement"

	# shellcheck disable=SC2016
	run env HOME="$HOME" TERM="$TERM" /bin/bash -euo pipefail -c '
        export MOLE_TEST_MODE=1
        export MOLE_TEST_NO_AUTH=1
        source "$1"

        INSTALLER_PATHS=("$2")
        INSTALLER_SIZES=("$(get_file_size "$2")")
        build_installer_delete_plan 0
        mv "$2" "$2.old"
        mv "$3" "$2"

        set +e
        execute_installer_delete_plan
        rc=$?
        set -e

        printf "rc=%s deleted=%s failed=%s failure=%s\n" "$rc" "$total_deleted" "$total_delete_failed" "${INSTALLER_DELETE_FAILURES[0]}"
        [[ -e "$2" ]] || return 1
        [[ -e "$2.old" ]] || return 1
    ' bash "$PROJECT_ROOT/bin/installer.sh" "$target" "$replacement"

	[ "$status" -eq 0 ]
	[[ "$output" == *"rc=3 deleted=0 failed=1"* ]] || return 1
	[[ "$output" == *"Replaced.dmg (changed since scan)"* ]]
}

@test "execute_installer_delete_plan refuses size drift" {
	local target="$HOME/Downloads/Grew.dmg"
	printf 'one' > "$target"

	# shellcheck disable=SC2016
	run env HOME="$HOME" TERM="$TERM" /bin/bash -euo pipefail -c '
        export MOLE_TEST_MODE=1
        export MOLE_TEST_NO_AUTH=1
        source "$1"

        INSTALLER_PATHS=("$2")
        INSTALLER_SIZES=("$(get_file_size "$2")")
        build_installer_delete_plan 0
        printf "two" >> "$2"

        set +e
        execute_installer_delete_plan
        rc=$?
        set -e

        printf "rc=%s deleted=%s failed=%s failure=%s\n" "$rc" "$total_deleted" "$total_delete_failed" "${INSTALLER_DELETE_FAILURES[0]}"
        [[ -e "$2" ]] || return 1
    ' bash "$PROJECT_ROOT/bin/installer.sh" "$target"

	[ "$status" -eq 0 ]
	[[ "$output" == *"rc=3 deleted=0 failed=1"* ]] || return 1
	[[ "$output" == *"Grew.dmg (changed since scan)"* ]]
}

@test "show_summary reports installer delete failures" {
	# shellcheck disable=SC2016
	run env HOME="$HOME" TERM="$TERM" /bin/bash -euo pipefail -c '
        export MOLE_TEST_MODE=1
        source "$1"

        total_deleted=1
        total_size_freed_kb=1
        total_delete_failed=2
        INSTALLER_DELETE_FAILURES=("$HOME/Downloads/Blocked.dmg (protected path)" "$HOME/Downloads/Stale.pkg (still exists)")

        show_summary
    ' bash "$PROJECT_ROOT/bin/installer.sh"

	[ "$status" -eq 0 ]
	[[ "$output" == *"Installer cleanup incomplete"* ]] || return 1
	[[ "$output" == *"Failed to remove"* ]] || return 1
	[[ "$output" == *"Blocked.dmg"* ]] || return 1
	[[ "$output" == *"protected path"* ]] || return 1
	[[ "$output" == *"Stale.pkg"* ]] || return 1
	[[ "$output" == *"still exists"* ]] || return 1
	[[ "$output" != *"Your Mac is cleaner now!"* ]]
}

@test "main exits nonzero after real incomplete installer cleanup" {
	local removable="$HOME/Downloads/MainGood.dmg"
	printf 'good' > "$removable"

	# shellcheck disable=SC2016
	run env HOME="$HOME" TERM="$TERM" /bin/bash -euo pipefail -c '
        export MOLE_TEST_MODE=1
        export MOLE_TEST_NO_AUTH=1
        export MOLE_DELETE_LOG="$HOME/deletions.log"
        source "$1"
        test_removable="$2"

        collect_installers() {
            local system_size
            system_size=$(get_file_size "/System")
            INSTALLER_PATHS=("$test_removable" "/System")
            INSTALLER_SIZES=(4 "$system_size")
            DISPLAY_NAMES=("MainGood.dmg" "System")
            return 0
        }

        show_installer_menu() {
            MOLE_SELECTION_RESULT="0,1"
            return 0
        }

        set +e
        main < <(printf "\n")
        rc=$?
        set -e
        printf "rc=%s removed=%s\n" "$rc" "$([[ ! -e "$test_removable" ]] && echo yes || echo no)"
    ' bash "$PROJECT_ROOT/bin/installer.sh" "$removable"

	[ "$status" -eq 0 ]
	[[ "$output" == *"Installer cleanup incomplete"* ]] || return 1
	[[ "$output" == *"rc=1"* ]] || return 1
	[[ "$output" == *"removed=yes"* ]]
}

@test "main reports incomplete cleanup under errexit" {
	local removable="$HOME/Downloads/ErrexitGood.dmg"
	printf 'good' > "$removable"

	# Production runs installer.sh with set -euo pipefail active, so main must
	# not let a nonzero perform_installers status trip errexit before the
	# incomplete-cleanup summary is printed.
	# shellcheck disable=SC2016
	run env HOME="$HOME" TERM="$TERM" /bin/bash -euo pipefail -c '
        export MOLE_TEST_MODE=1
        export MOLE_TEST_NO_AUTH=1
        export MOLE_DELETE_LOG="$HOME/deletions.log"
        source "$1"
        test_removable="$2"

        collect_installers() {
            local system_size
            system_size=$(get_file_size "/System")
            INSTALLER_PATHS=("$test_removable" "/System")
            INSTALLER_SIZES=(4 "$system_size")
            DISPLAY_NAMES=("ErrexitGood.dmg" "System")
            return 0
        }

        show_installer_menu() {
            MOLE_SELECTION_RESULT="0,1"
            return 0
        }

        main < <(printf "\n")
    ' bash "$PROJECT_ROOT/bin/installer.sh" "$removable"

	[ "$status" -eq 1 ]
	[[ "$output" == *"Installer cleanup incomplete"* ]] || return 1
	[[ "$output" == *"Failed to remove"* ]] || return 1
	[[ ! -e "$removable" ]]
}

@test "main reports a delete-phase timeout instead of ending silently" {
	local first="$HOME/Downloads/TimeoutFirst.dmg"
	local second="$HOME/Downloads/TimeoutSecond.dmg"
	printf 'first' > "$first"
	printf 'second' > "$second"

	# shellcheck disable=SC2016
	run env HOME="$HOME" TERM="$TERM" /bin/bash -euo pipefail -c '
        export MOLE_TEST_MODE=1
        export MOLE_TEST_NO_AUTH=1
        export MOLE_DELETE_LOG="$HOME/deletions.log"
        source "$1"
        test_first="$2"
        test_second="$3"

        collect_installers() {
            INSTALLER_PATHS=("$test_first" "$test_second")
            INSTALLER_SIZES=(5 6)
            DISPLAY_NAMES=("TimeoutFirst.dmg" "TimeoutSecond.dmg")
            return 0
        }

        show_installer_menu() {
            MOLE_SELECTION_RESULT="0,1"
            return 0
        }

        mole_delete() {
            [[ "$1" == "$test_second" ]] && return 124
            /bin/rm -f -- "$1"
        }

        set +e
        main < <(printf "\n")
        rc=$?
        set -e
        printf "rc=%s\n" "$rc"
    ' bash "$PROJECT_ROOT/bin/installer.sh" "$first" "$second"

	[ "$status" -eq 0 ]
	[[ "$output" == *"rc=124"* ]] || return 1
	[[ "$output" == *"Installer cleanup incomplete"* ]] || return 1
	[[ "$output" == *"Removed "* ]] || return 1
	[[ "$output" == *"TimeoutSecond.dmg (delete failed)"* ]] || return 1
	[[ "$output" == *"A file check timed out"* ]] || return 1
	[[ ! -e "$first" ]] || return 1
	[[ -e "$second" ]]
}

@test "installer deletion binds the confirmed identity at the final sink" {
    local mode
    for mode in real dry; do
        local fixture_root="$BATS_TEST_TMPDIR/identity-$mode"
        mkdir -p "$fixture_root"
        printf 'old' > "$fixture_root/selected.dmg"
        printf 'new' > "$fixture_root/replacement.dmg"
        # shellcheck disable=SC2016 # The child shell evaluates this script.
        run /bin/bash --noprofile --norc -c '
            export MOLE_TEST_MODE=1 MOLE_TEST_NO_AUTH=1 MOLE_DELETE_MODE=permanent
            source "$1"
            target="$2/selected.dmg"
            export MOLE_DELETE_LOG="$2/deletions.log"
            INSTALLER_PATHS=("$target")
            INSTALLER_SIZES=(3)
            build_installer_delete_plan 0
            [[ "$3" != dry ]] || export MOLE_DRY_RUN=1
            installer_file_size_bytes() {
                /bin/mv "$target" "${target}.original"
                /bin/mv "${target%/*}/replacement.dmg" "$target"
                printf "3\n"
            }
            rc=0
            execute_installer_delete_plan || rc=$?
            [[ $rc -eq $INSTALLER_EXIT_INCOMPLETE ]] || exit 1
            [[ $total_deleted -eq 0 && $total_size_freed_kb -eq 0 && $total_delete_failed -eq 1 ]] || exit 1
            [[ -f "$target" && -f "${target}.original" ]] || exit 1
            [[ "$(cat "$target")" == new ]] || exit 1
            [[ "$(cat "${target}.original")" == old ]] || exit 1
            grep -F "identity-changed" "$MOLE_DELETE_LOG" >/dev/null
        ' bash "$PROJECT_ROOT/bin/installer.sh" "$fixture_root" "$mode"
        [ "$status" -eq 0 ] || return 1
    done
}

# Downloads that are not .dmg/.pkg (U6): Parallels ISOs, Windows installers,
# and stale Chrome partial downloads. All stay selection-only.

installer_days_ago_stamp() {
	date -v-"$1"d +%Y%m%d%H%M
}

# setup's Downloads/* glob skips dotfiles such as Chrome's temp names.
installer_reset_downloads() {
	rm -rf "${HOME:?}/Downloads"
	mkdir -p "$HOME/Downloads"
}

@test "installer scans ~/Library/Parallels/Downloads for iso" {
	installer_reset_downloads
	mkdir -p "$HOME/Library/Parallels/Downloads"
	printf 'iso' > "$HOME/Library/Parallels/Downloads/Win.iso"

	run env HOME="$HOME" TERM="xterm-256color" MOLE_TEST_NO_AUTH=1 \
		"$PROJECT_ROOT/mole" installer --dry-run < /dev/null

	rm -rf "$HOME/Library/Parallels"
	[ "$status" -eq 0 ] || return 1
	[[ "$output" == *"Win.iso"* ]] || return 1
	[[ "$output" == *"Parallels"* ]] || return 1
	[[ "$output" == *"0 selected"* ]]
}

@test "installer keeps the listed Parallels iso after a dry run" {
	installer_reset_downloads
	mkdir -p "$HOME/Library/Parallels/Downloads"
	printf 'iso' > "$HOME/Library/Parallels/Downloads/Win.iso"

	run env HOME="$HOME" TERM="xterm-256color" MOLE_TEST_NO_AUTH=1 \
		"$PROJECT_ROOT/mole" installer --dry-run < /dev/null

	local survived=no
	[[ -f "$HOME/Library/Parallels/Downloads/Win.iso" ]] && survived=yes
	rm -rf "$HOME/Library/Parallels"
	[ "$status" -eq 0 ] || return 1
	[[ "$output" == *"Win.iso"* ]] || return 1
	[ "$survived" = yes ]
}

@test "installer lists .exe and .msi installers unselected" {
	installer_reset_downloads
	printf 'exe' > "$HOME/Downloads/Setup.exe"
	printf 'msi' > "$HOME/Downloads/Tool.msi"

	run env HOME="$HOME" TERM="xterm-256color" MOLE_TEST_NO_AUTH=1 \
		"$PROJECT_ROOT/mole" installer --dry-run < /dev/null

	[ "$status" -eq 0 ] || return 1
	[[ "$output" == *"Setup.exe"* ]] || return 1
	[[ "$output" == *"Tool.msi"* ]] || return 1
	[[ "$output" == *"Windows installer"* ]] || return 1
	[[ "$output" == *"Windows executable"* ]] || return 1
	[[ "$output" == *"0 selected"* ]] || return 1
	[[ -f "$HOME/Downloads/Setup.exe" ]] || return 1
	[[ -f "$HOME/Downloads/Tool.msi" ]]
}

# An .exe or .msi carries no installer evidence of its own, so only a
# download-origin root offers one. A portable tool or an app's own executable
# kept under Documents, Desktop, Public or /Users/Shared is the user's file.
@test "installer offers .exe and .msi only from download folders" {
	installer_reset_downloads
	mkdir -p "$HOME/Documents/Tools" "$HOME/Desktop" "$HOME/Downloads/Telegram Desktop" \
		"$HOME/Library/Parallels/Downloads"
	: > "$HOME/Documents/Tools/putty.exe"
	: > "$HOME/Documents/Tools/Agent.msi"
	: > "$HOME/Documents/Tools/Disk.dmg"
	: > "$HOME/Desktop/game.exe"
	: > "$HOME/Downloads/Telegram Desktop/Setup.exe"
	: > "$HOME/Library/Parallels/Downloads/Tools.msi"

	run env PATH="/usr/bin:/bin" /bin/bash -euo pipefail -c "
        export MOLE_TEST_MODE=1
        source \"\$1\"
        for root in \"\$HOME/Documents\" \"\$HOME/Desktop\" \"\$HOME/Downloads\" \"\$HOME/Library/Parallels/Downloads\"; do
            scan_installers_in_path \"\$root\" | tr '\0' '\n'
        done
    " bash "$PROJECT_ROOT/bin/installer.sh"

	rm -rf "$HOME/Documents/Tools" "$HOME/Desktop/game.exe" "$HOME/Library/Parallels"
	[ "$status" -eq 0 ] || { echo "$output"; return 1; }
	# Control: the same Documents scan still lists a disk image.
	[[ "$output" == *"/Documents/Tools/Disk.dmg"* ]] || { echo "$output"; return 1; }
	[[ "$output" == *"/Downloads/Telegram Desktop/Setup.exe"* ]] || { echo "$output"; return 1; }
	[[ "$output" == *"/Library/Parallels/Downloads/Tools.msi"* ]] || { echo "$output"; return 1; }
	[[ "$output" != *"putty.exe"* ]] || { echo "$output"; return 1; }
	[[ "$output" != *"Agent.msi"* ]] || { echo "$output"; return 1; }
	[[ "$output" != *"game.exe"* ]] || { echo "$output"; return 1; }
}

@test "installer lists an aged Chrome partial download and hides a fresh one" {
	installer_reset_downloads
	local old
	old=$(installer_days_ago_stamp 30)
	: > "$HOME/Downloads/.com.google.Chrome.AbC123"
	: > "$HOME/Downloads/.com.google.Chrome.XyZ789"
	: > "$HOME/Downloads/Movie.mp4.crdownload"
	: > "$HOME/Downloads/Fresh.zip.crdownload"
	: > "$HOME/Downloads/.com.google.Chrome.Short"
	: > "$HOME/Downloads/.com.google.Chrome.TooLong1"
	touch -t "$old" "$HOME/Downloads/.com.google.Chrome.AbC123" \
		"$HOME/Downloads/Movie.mp4.crdownload" \
		"$HOME/Downloads/.com.google.Chrome.Short" \
		"$HOME/Downloads/.com.google.Chrome.TooLong1"

	run env PATH="/usr/bin:/bin" /bin/bash -euo pipefail -c "
        export MOLE_TEST_MODE=1
        source \"\$1\"
        scan_installers_in_path \"\$2\" | tr '\0' '\n'
    " bash "$PROJECT_ROOT/bin/installer.sh" "$HOME/Downloads"

	[ "$status" -eq 0 ] || return 1
	[[ "$output" == *"/.com.google.Chrome.AbC123"* ]] || return 1
	[[ "$output" == *"/Movie.mp4.crdownload"* ]] || return 1
	[[ "$output" != *"XyZ789"* ]] || return 1
	[[ "$output" != *"Fresh.zip.crdownload"* ]] || return 1
	[[ "$output" != *"Chrome.Short"* ]] || return 1
	[[ "$output" != *"TooLong1"* ]]
}

@test "installer labels a stale partial download with its age" {
	installer_reset_downloads
	: > "$HOME/Downloads/.com.google.Chrome.AbC123"
	touch -t "$(installer_days_ago_stamp 30)" "$HOME/Downloads/.com.google.Chrome.AbC123"

	run env HOME="$HOME" TERM="xterm-256color" MOLE_TEST_NO_AUTH=1 \
		"$PROJECT_ROOT/mole" installer --dry-run < /dev/null

	[ "$status" -eq 0 ] || return 1
	[[ "$output" == *".com.google.Chrome.AbC123"* ]] || return 1
	[[ "$output" == *"Partial download · 30d"* ]] || return 1
	[[ "$output" == *"0 selected"* ]] || return 1
	[[ -f "$HOME/Downloads/.com.google.Chrome.AbC123" ]]
}

@test "installer does not list .tar.gz or desktop.ini" {
	installer_reset_downloads
	mkdir -p "$HOME/Downloads/\$RECYCLE.BIN" "$HOME/Downloads/Tool.app/Contents"
	: > "$HOME/Downloads/backup.tar.gz"
	: > "$HOME/Downloads/source.tgz"
	: > "$HOME/Downloads/desktop.ini"
	: > "$HOME/Downloads/~\$Report.docx"
	: > "$HOME/Downloads/\$RECYCLE.BIN/Old.exe"
	: > "$HOME/Downloads/.Claude-1.0.dmg.js"
	touch -t "$(installer_days_ago_stamp 30)" "$HOME/Downloads/.Claude-1.0.dmg.js"

	run env PATH="/usr/bin:/bin" /bin/bash -euo pipefail -c "
        export MOLE_TEST_MODE=1
        source \"\$1\"
        scan_installers_in_path \"\$2\" | tr '\0' '\n'
    " bash "$PROJECT_ROOT/bin/installer.sh" "$HOME/Downloads"

	[ "$status" -eq 0 ] || return 1
	[[ "$output" != *"backup.tar.gz"* ]] || return 1
	[[ "$output" != *"source.tgz"* ]] || return 1
	[[ "$output" != *"desktop.ini"* ]] || return 1
	[[ "$output" != *"Report.docx"* ]] || return 1
	[[ "$output" != *"Tool.app"* ]] || return 1
	[[ "$output" != *"Claude-1.0.dmg.js"* ]]
}

@test "installer deletes a selected stale partial download only while its identity holds" {
	installer_reset_downloads
	local old
	old=$(installer_days_ago_stamp 30)
	local stale="$HOME/Downloads/.com.google.Chrome.AbC123"
	local revived="$HOME/Downloads/Paused.crdownload"
	local swapped="$HOME/Downloads/.com.google.Chrome.SwP456"
	printf 'part' > "$stale"
	printf 'part' > "$revived"
	printf 'part' > "$swapped"
	printf 'part' > "$swapped.new"
	touch -t "$old" "$stale" "$revived" "$swapped" "$swapped.new"

	# shellcheck disable=SC2016
	run env HOME="$HOME" TERM="$TERM" /bin/bash -euo pipefail -c '
        export MOLE_TEST_MODE=1
        export MOLE_TEST_NO_AUTH=1
        export MOLE_DELETE_LOG="$HOME/deletions.log"
        source "$1"

        INSTALLER_PATHS=("$2" "$3" "$4")
        INSTALLER_SIZES=(4 4 4)
        # Chrome resumed the paused download after the scan listed it.
        touch "$3"
        build_installer_delete_plan 0 1 2 || true
        # Another file took the selected name before confirmation.
        /bin/mv "$4.new" "$4"

        set +e
        execute_installer_delete_plan
        rc=$?
        set -e
        printf "rc=%s deleted=%s failed=%s\n" "$rc" "$total_deleted" "$total_delete_failed"
        printf "failure=%s\n" "${INSTALLER_DELETE_FAILURES[@]}"
        [[ ! -e "$2" ]] || exit 1
        [[ -f "$3" && -f "$4" ]] || exit 1
    ' bash "$PROJECT_ROOT/bin/installer.sh" "$stale" "$revived" "$swapped"

	rm -f "$revived" "$swapped"
	[ "$status" -eq 0 ] || return 1
	[[ "$output" == *"rc=3 deleted=1 failed=2"* ]] || return 1
	[[ "$output" == *"Paused.crdownload (changed since scan)"* ]] || return 1
	[[ "$output" == *".com.google.Chrome.SwP456 (changed since scan)"* ]]
}
