#!/usr/bin/env bash
# tests/test_tools_sync.sh — Test the pis tools sync algorithm
#
# Each test creates a temporary directory tree, runs tools_sync_env
# (the sync helper), and asserts filesystem state. Tests run in
# subshells so that set -e from pis.sh does not abort the runner.
# Cleanup is handled via EXIT trap in each subshell.

set -uo pipefail

PIS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PIS_SH="$PIS_DIR/pis.sh"

PASS=0
FAIL=0
TESTS_RUN=0

run_test() {
	local name="$1"
	shift
	TESTS_RUN=$((TESTS_RUN + 1))
	echo -n "  $TESTS_RUN. $name... "
	# Each test runs in a subshell with temp dir + cleanup trap
	if (
		set -e
		TESTDIR=$(mktemp -d)
		trap 'rm -rf "$TESTDIR"' EXIT
		SWAP="$TESTDIR/swap"
		export SWAP
		mkdir -p "$SWAP/tools"
		mkdir -p "$SWAP/agent-test/bin"
		"$@"
	); then
		echo "PASS"
		PASS=$((PASS + 1))
	else
		echo "FAIL"
		FAIL=$((FAIL + 1))
	fi
}

# === Test functions ===
# Note: tools_sync_env is called directly (not cmd_tools_sync) because
# cmd_tools_sync reads the env name from $3 (dispatcher convention).
# tools_sync_env takes a directory path and is the core algorithm.

test_adds_missing_symlinks() {
	touch "$SWAP/tools/fzf"
	chmod +x "$SWAP/tools/fzf"
	tools_sync_env "$SWAP/agent-test"
	[ -L "$SWAP/agent-test/bin/fzf" ] || return 1
	[ "$(readlink "$SWAP/agent-test/bin/fzf")" = "../../tools/fzf" ] || return 1
	[ -e "$SWAP/agent-test/bin/fzf" ] || return 1
}

test_removes_broken_symlinks() {
	ln -s "../../tools/deleted-tool" "$SWAP/agent-test/bin/deleted-tool"
	tools_sync_env "$SWAP/agent-test"
	[ ! -L "$SWAP/agent-test/bin/deleted-tool" ] || return 1
}

test_leaves_real_files_untouched() {
	touch "$SWAP/tools/fzf"
	chmod +x "$SWAP/tools/fzf"
	echo "real content" >"$SWAP/agent-test/bin/my-script"
	chmod +x "$SWAP/agent-test/bin/my-script"
	tools_sync_env "$SWAP/agent-test"
	[ -f "$SWAP/agent-test/bin/my-script" ] || return 1
	[ "$(cat "$SWAP/agent-test/bin/my-script")" = "real content" ] || return 1
}

test_preserves_valid_symlinks() {
	touch "$SWAP/tools/fzf"
	chmod +x "$SWAP/tools/fzf"
	ln -s "../../tools/fzf" "$SWAP/agent-test/bin/fzf"
	tools_sync_env "$SWAP/agent-test"
	[ -L "$SWAP/agent-test/bin/fzf" ] || return 1
	[ -e "$SWAP/agent-test/bin/fzf" ] || return 1
}

test_idempotent() {
	touch "$SWAP/tools/fzf"
	chmod +x "$SWAP/tools/fzf"
	tools_sync_env "$SWAP/agent-test"
	local first
	first=$(ls -1 "$SWAP/agent-test/bin/")
	tools_sync_env "$SWAP/agent-test"
	local second
	second=$(ls -1 "$SWAP/agent-test/bin/")
	[ "$first" = "$second" ] || return 1
}

test_handles_empty_tools_pool() {
	rm -rf "$SWAP/tools"
	mkdir "$SWAP/tools" # empty
	tools_sync_env "$SWAP/agent-test" || true
	[ -z "$(ls "$SWAP/agent-test/bin/" 2>/dev/null || true)" ] || return 1
}

test_self_heals_missing_tools_dir() {
	rm -rf "$SWAP/tools"
	tools_sync_env "$SWAP/agent-test" || true
	[ -d "$SWAP/tools" ] || return 1
}

test_preserves_non_tools_broken_symlink() {
	ln -s "/nonexistent/path" "$SWAP/agent-test/bin/other-link"
	tools_sync_env "$SWAP/agent-test" || true
	[ -L "$SWAP/agent-test/bin/other-link" ] || return 1
}

# === Main ===

echo "=== pis tools sync test suite ==="
echo ""
cd "$PIS_DIR"

# Source pis.sh to load all functions (suppress main entry help output)
set -- --test-mode
source "$PIS_SH" >/dev/null 2>&1

run_test "adds missing symlinks for tools in pool" test_adds_missing_symlinks
run_test "removes broken symlinks to tools/" test_removes_broken_symlinks
run_test "leaves real files untouched" test_leaves_real_files_untouched
run_test "preserves valid symlinks" test_preserves_valid_symlinks
run_test "is idempotent (second sync same as first)" test_idempotent
run_test "handles empty tools/ pool gracefully" test_handles_empty_tools_pool
run_test "self-heals missing tools/ directory" test_self_heals_missing_tools_dir
run_test "preserves broken symlinks not pointing to tools/" test_preserves_non_tools_broken_symlink

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && echo "All tests passed!" && exit 0
exit 1
