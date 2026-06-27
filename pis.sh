#!/usr/bin/env bash
# pis — Multi pi environment manager
# Version: 0.2.0
# License: MIT
# https://github.com/Githubwujinming/pis

set -euo pipefail

VERSION="0.2.0"
SWAP="${PI_ENV_DIR:-$HOME/.pi}"
BIN="${PI_ENV_BIN:-$HOME/.local/bin}"

# ============================================================
# Cross-platform compatibility helpers
# ============================================================

# macOS readlink lacks -f, use perl instead
abs_path() {
	case "$(uname -s)" in
	Darwin) perl -MCwd -e 'print Cwd::abs_path(shift)' "$1" 2>/dev/null ;;
	*) readlink -f "$1" 2>/dev/null ;;
	esac
}

# Cross-platform sed -i
sed_i() {
	case "$(uname -s)" in
	Darwin) sed -i '' "$@" ;;
	*) sed -i "$@" ;;
	esac
}

# ============================================================
# Command implementations
# ============================================================

cmd_list() {
	echo "Available environments:"
	for d in "$SWAP"/agent-*; do
		[ -d "$d" ] || continue
		name="${d##*agent-}"
		cmd="$BIN/pi-$name"
		linkto=$(readlink "$SWAP/agent" 2>/dev/null || true)
		active=""
		[ "$linkto" = "agent-$name" ] && active=" ← active"
		[ -f "$cmd" ] && note=" (cmd: pi-$name)" || note=""
		echo "  $name${active} $note"
	done
}

cmd_create() {
	local name="$2"
	[ -z "$name" ] && {
		echo "Usage: pis create <name> [--clone <source>] [--use] [--import <file>]"
		exit 1
	}
	[ -d "$SWAP/agent-$name" ] && {
		echo "  Environment '$name' already exists"
		exit 1
	}

	local do_use=0 impfile="" clone_src=""
	shift 2
	while [ $# -gt 0 ]; do
		case "$1" in
		--use | -u) do_use=1 ;;
		--clone)
			clone_src="$2"
			shift
			;;
		--import)
			impfile="$2"
			shift
			;;
		esac
		shift
	done

	if [ -n "$clone_src" ]; then
		if [ "$clone_src" = "current" ]; then
			local realdir
			realdir=$(abs_path "$SWAP/agent" 2>/dev/null || echo "$SWAP/agent")
			[ -d "$realdir" ] || {
				echo "  No active environment"
				exit 1
			}
			cp -a "$realdir" "$SWAP/agent-$name"
		elif [ -d "$SWAP/agent-$clone_src" ]; then
			cp -a "$SWAP/agent-$clone_src" "$SWAP/agent-$name"
		else
			echo "  Source environment '$clone_src' does not exist"
			exit 1
		fi
		echo "  Cloned from '$clone_src': $name"
	else
		mkdir -p "$SWAP/agent-$name/bin"
		if [ -d "$SWAP/tools" ]; then
			for tool in "$SWAP/tools"/*; do
				[ -f "$tool" ] && ln -s "../../tools/$(basename "$tool")" "$SWAP/agent-$name/bin/"
			done
		fi
		echo "  Created blank environment: $name"
	fi

	cat >"$BIN/pi-$name" <<-SCRIPT
		#!/usr/bin/env bash
		export PI_CODING_AGENT_DIR="\$HOME/.pi/agent-$name"
		exec pi "\$@"
	SCRIPT
	chmod +x "$BIN/pi-$name"
	echo "  Command: pi-$name"

	[ "$do_use" = "1" ] && ln -snf "agent-$name" "$SWAP/agent" && echo "  Set as default"

	if [ -n "$impfile" ]; then
		[ ! -f "$impfile" ] && {
			echo "  File $impfile does not exist"
			exit 1
		}
		echo "  Importing packages..."
		local fail=0 succ=0
		while IFS= read -r pkg; do
			[ -z "$pkg" ] && continue
			echo "    $pkg"
			if PI_CODING_AGENT_DIR="$SWAP/agent-$name" pi install "$pkg" 2>&1; then
				succ=$((succ + 1))
			else
				fail=$((fail + 1))
			fi
		done <"$impfile"
		if [ "$fail" -gt 0 ]; then
			echo "  Warning: $fail package(s) failed to install."
			echo "  Import complete ($succ succeeded, $fail failed)"
		else
			echo "  Import complete"
		fi
	fi
}

cmd_delete() {
	local name="$2"
	[ -z "$name" ] && {
		echo "Usage: pis delete <name>"
		exit 1
	}
	[ ! -d "$SWAP/agent-$name" ] && {
		echo "  Environment '$name' does not exist"
		exit 1
	}
	local linkto
	linkto=$(readlink "$SWAP/agent" 2>/dev/null || true)
	[ "$linkto" = "agent-$name" ] && {
		echo "  Cannot delete the active environment"
		exit 1
	}
	rm -rf "$SWAP/agent-$name"
	rm -f "$BIN/pi-$name"
	echo "  Deleted: $name"
}

cmd_use() {
	local name="$2"
	[ -z "$name" ] && {
		echo "Usage: pis use <name>"
		exit 1
	}
	[ ! -d "$SWAP/agent-$name" ] && {
		echo "  Environment '$name' does not exist"
		exit 1
	}

	# If agent is a real directory (legacy state before pis), convert it
	if [ -d "$SWAP/agent" ] && [ ! -L "$SWAP/agent" ]; then
		echo "  Converting existing pi config to environment: legacy"
		mv "$SWAP/agent" "$SWAP/agent-legacy"
		echo "  → Moved to $SWAP/agent-legacy"
	fi

	ln -snf "agent-$name" "$SWAP/agent"
	echo "  Default pi environment set to: $name"
}

cmd_export() {
	local name="${2:-default}" outfile="${3:-pi-packages-${2:-default}.txt}" envdir

	if [ "$name" = "current" ]; then
		envdir=$(abs_path "$SWAP/agent" 2>/dev/null)
	elif [ "$name" = "default" ]; then
		envdir="$SWAP/agent-default"
	else
		envdir="$SWAP/agent-$name"
	fi
	[ ! -f "$envdir/settings.json" ] && {
		echo "  Environment '$name' has no settings.json"
		exit 1
	}

	node -e "
    const fs = require('fs');
    const s = JSON.parse(fs.readFileSync('$envdir/settings.json', 'utf-8'));
    (s.packages || []).forEach(p => console.log(p));
  " >"$outfile"
	local count
	count=$(wc -l <"$outfile" | tr -d ' ')
	echo "  Exported $count packages to $outfile"
}

cmd_import() {
	local name="$2" infile="$3" envdir
	[ -z "$name" ] && {
		echo "Usage: pis import <name> [file]"
		exit 1
	}
	[ -z "$infile" ] && infile="pi-packages-${name}.txt"
	[ ! -f "$infile" ] && {
		echo "  File $infile does not exist"
		exit 1
	}

	if [ "$name" = "default" ]; then
		envdir="$SWAP/agent-default"
	else
		envdir="$SWAP/agent-$name"
	fi
	[ ! -d "$envdir" ] && {
		echo "  Environment '$name' does not exist"
		exit 1
	}

	local fail=0 succ=0
	while IFS= read -r pkg; do
		[ -z "$pkg" ] && continue
		echo "    $pkg"
		if PI_CODING_AGENT_DIR="$envdir" pi install "$pkg" 2>&1; then
			succ=$((succ + 1))
		else
			fail=$((fail + 1))
		fi
	done <"$infile"
	if [ "$fail" -gt 0 ]; then
		echo "  Warning: $fail package(s) failed to install."
		echo "  Import complete ($succ succeeded, $fail failed)"
	else
		echo "  Import complete"
	fi
}

cmd_status() {
	echo "=== pi Environment Status ==="
	local linkto
	linkto=$(readlink "$SWAP/agent" 2>/dev/null || true)
	if [ -n "$linkto" ]; then
		echo "Current: agent → $linkto"
	elif [ -d "$SWAP/agent" ]; then
		echo "Current: agent (real directory, not symlink)"
	fi
	echo ""
	echo "Saved environments:"
	for d in "$SWAP"/agent-*; do
		[ -d "$d" ] || continue
		local name="${d##*agent-}"
		local cmd="$BIN/pi-$name"
		local active=""
		[ "$linkto" = "agent-$name" ] && active=" ← active"
		[ -f "$cmd" ] && note=" (cmd: pi-$name)" || note=""
		echo "  $name${active} $note"
	done
}

cmd_rename() {
	local old_name="$2" new_name="$3"
	[ -z "$old_name" ] || [ -z "$new_name" ] && {
		echo "Usage: pis rename <old-name> <new-name>"
		exit 1
	}
	[ "$old_name" = "$new_name" ] && {
		echo "  New name is the same as old name"
		exit 1
	}
	[ ! -d "$SWAP/agent-$old_name" ] && {
		echo "  Environment '$old_name' does not exist"
		exit 1
	}
	[ -d "$SWAP/agent-$new_name" ] && {
		echo "  Environment '$new_name' already exists"
		exit 1
	}

	# Rename the environment directory
	mv "$SWAP/agent-$old_name" "$SWAP/agent-$new_name"
	echo "  Renamed directory: agent-$old_name → agent-$new_name"

	# Rename the command script
	if [ -f "$BIN/pi-$old_name" ]; then
		mv "$BIN/pi-$old_name" "$BIN/pi-$new_name"
		# Update the PI_CODING_AGENT_DIR in the new wrapper script
		sed_i "s/agent-$old_name/agent-$new_name/g" "$BIN/pi-$new_name"
		echo "  Renamed command: pi-$old_name → pi-$new_name"
	fi

	# Update active symlink if it points to the old environment
	local linkto
	linkto=$(readlink "$SWAP/agent" 2>/dev/null || true)
	if [ "$linkto" = "agent-$old_name" ]; then
		ln -snf "agent-$new_name" "$SWAP/agent"
		echo "  Updated active symlink → $new_name"
	fi

	echo "  Renamed: $old_name → $new_name"
}

cmd_uninstall() {
	local answer
	echo "This will remove pis and restore pi to normal single-directory mode."
	echo "Pi environments under $SWAP/agent-* will be kept."
	read -r -p "Continue? [y/N] " answer
	case "$answer" in
	[Yy] | [Yy][Ee][Ss]) ;;
	*)
		echo "  Cancelled."
		exit 0
		;;
	esac

	# Restore agent symlink to real directory if possible
	if [ -L "$SWAP/agent" ]; then
		local target
		target=$(readlink "$SWAP/agent")
		if [ -d "$SWAP/$target" ]; then
			rm "$SWAP/agent"
			mv "$SWAP/$target" "$SWAP/agent"
			echo "  Restored $SWAP/agent to real directory ($target)"
		fi
	fi

	# Remove pis files
	rm -f "$SWAP/pis.sh"
	echo "  Removed $SWAP/pis.sh"
	rm -f "$BIN/pis"
	echo "  Removed $BIN/pis"

	echo ""
	echo "pis uninstalled. pi continues to use $SWAP/agent as normal."
	echo "To clean up leftover environments, remove $SWAP/agent-* directories manually."
}

cmd_update() {
	echo "Updating pis..."

	local repo="Githubwujinming/pis"
	local url="https://raw.githubusercontent.com/$repo/main/pis.sh"

	if command -v curl >/dev/null 2>&1; then
		curl -sL "$url" -o "$SWAP/pis.sh"
	elif command -v wget >/dev/null 2>&1; then
		wget -q "$url" -O "$SWAP/pis.sh"
	else
		echo "Error: curl or wget is required"
		exit 1
	fi

	chmod +x "$SWAP/pis.sh"
	ln -sf "$SWAP/pis.sh" "$BIN/pis"

	local new_ver
	new_ver=$(grep '^VERSION=' "$SWAP/pis.sh" | cut -d'=' -f2 | tr -d '"')
	echo "  Updated to v$new_ver"
	echo "  Run 'pis help' to get started"
}

cmd_packages() {
	local name="${2:-current}" envdir

	if [ "$name" = "current" ]; then
		envdir=$(abs_path "$SWAP/agent" 2>/dev/null) || envdir="$SWAP/agent"
	elif [ "$name" = "default" ]; then
		envdir="$SWAP/agent-default"
	else
		envdir="$SWAP/agent-$name"
	fi

	[ ! -f "$envdir/settings.json" ] && {
		echo "  Environment '$name' has no settings.json"
		exit 1
	}

	local count
	count=$(node -e "
const fs = require('fs');
const s = JSON.parse(fs.readFileSync('$envdir/settings.json', 'utf-8'));
const pkgs = s.packages || [];
pkgs.forEach((p, i) => console.log((i + 1) + '. ' + p));
console.log('---');
console.log('Total: ' + pkgs.length + ' packages');
" 2>&1)
	echo "Packages in '$name' environment:"
	echo "$count"
}

cmd_help() {
	echo "pis v$VERSION — Multi pi environment manager"
	echo ""
	echo "Usage: pis <command> [options]"
	echo ""
	echo "Commands:"
	echo "  create <name>                  Create a blank environment"
	echo "  create <name> --clone <src>    Clone from an environment"
	echo "  create <name> --use           Set as default on creation"
	echo "  create <name> --import <file>  Import packages on creation"
	echo "  delete <name>                  Delete an environment"
	echo "  rename <old> <new>             Rename an environment"
	echo "  use <name>                     Set default pi environment"
	echo "  export [name] [file]           Export package list"
	echo "  import <name> [file]           Import packages from file"
	echo "  list                           List all environments"
	echo "  status                         Show current status"
	echo "  packages [name]                List installed packages in an environment"
	echo "  uninstall                      Remove pis and restore single-directory mode"
	echo "  update                         Update pis to the latest version"
	echo "  --version, -V                  Show version"
	echo "  help                           Show this help"
	echo ""
	echo "Examples:"
	echo "  pis create test                           Create a blank environment"
	echo "  pis create test --use --import pkgs.txt   Create + default + import"
	echo "  pis create rpiv --clone default           Clone from default"
	echo "  pis export                                Export current package list"
	echo "  pis import rpiv pkgs.txt                  Import packages to rpiv"
	echo "  pis list                                  List all environments"
	echo "  pis rename old new                        Rename environment"
}

# ============================================================
# Main entry
# ============================================================

case "${1:-help}" in
list | ls) cmd_list "$@" ;;
rename) cmd_rename "$@" ;;
create | new) cmd_create "$@" ;;
delete | rm) cmd_delete "$@" ;;
use) cmd_use "$@" ;;
export) cmd_export "$@" ;;
import) cmd_import "$@" ;;
status | st) cmd_status "$@" ;;
uninstall) cmd_uninstall "$@" ;;
update) cmd_update "$@" ;;
packages | pkgs) cmd_packages "$@" ;;
--version | -V) echo "pis v$VERSION" ;;
-h | --help | help | *) cmd_help ;;
esac
