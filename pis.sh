#!/usr/bin/env bash
# pis — Multi pi environment manager
# Version: 0.3.0
# License: MIT
# https://github.com/Githubwujinming/pis

set -euo pipefail

VERSION="0.3.0"
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
# Environment helpers
# ============================================================

# Resolve environment directory from name (current / default / <name>)
resolve_env_dir() {
	local name="$1"
	if [ "$name" = "current" ]; then
		abs_path "$SWAP/agent" 2>/dev/null || echo "$SWAP/agent"
	elif [ "$name" = "default" ]; then
		echo "$SWAP/agent-default"
	else
		echo "$SWAP/agent-$name"
	fi
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
	[ -z "$name" ] || [[ "$name" =~ ^- ]] && {
		echo "Usage: pis create <name> [--clone <source>] [--use] [--import <file>] [--install-indicator | --no-indicator]"
		exit 1
	}
	[ -d "$SWAP/agent-$name" ] && {
		echo "  Environment '$name' already exists"
		exit 1
	}

	local do_use=0 impfile="" clone_src="" install_indicator=1
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
		--install-indicator) install_indicator=1 ;;
		--no-indicator) install_indicator=0 ;;
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
		# Rebuild symlinks to shared tools after clone
		if [ -d "$SWAP/tools" ]; then
			rm -rf "$SWAP/agent-$name/bin"
			mkdir -p "$SWAP/agent-$name/bin"
			for tool in "$SWAP/tools"/*; do
				[ -f "$tool" ] && ln -s "../../tools/$(basename "$tool")" "$SWAP/agent-$name/bin/"
			done
		fi
	else
		mkdir -p "$SWAP/tools"
		mkdir -p "$SWAP/agent-$name/bin"
		for tool in "$SWAP/tools"/*; do
			[ -f "$tool" ] && ln -s "../../tools/$(basename "$tool")" "$SWAP/agent-$name/bin/"
		done
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

	# Ensure pnpm is the default package manager for this environment
	# Assumption: no concurrent pi processes are running during this write
	if ! node -e "
const fs = require('fs');
const path = '$SWAP/agent-$name/settings.json';
let s = {};
try { s = JSON.parse(fs.readFileSync(path, 'utf-8')); } catch (e) {}
s.npmCommand = ['pnpm'];
const tmp = path + '.tmp';
fs.writeFileSync(tmp, JSON.stringify(s, null, 2) + '\n');
fs.renameSync(tmp, path);
" 2>&1; then
		echo "  Warning: could not set npmCommand for $name" >&2
	fi

	# Install pis-indicator by default (independent of --import)
	if [ "$install_indicator" = "1" ]; then
		echo "  Installing pis-indicator..."
		if PI_CODING_AGENT_DIR="$SWAP/agent-$name" pi install git:github.com/Githubwujinming/pis-indicator 2>&1; then
			echo "  → pis-indicator installed"
		else
			# pnpm may block build scripts — approve and retry
			echo "  Approving pnpm build scripts..."
			if mkdir -p "$SWAP/agent-$name/npm" && cd "$SWAP/agent-$name/npm" && pnpm approve-builds --all && PI_CODING_AGENT_DIR="$SWAP/agent-$name" pi install git:github.com/Githubwujinming/pis-indicator 2>&1; then
				echo "  → pis-indicator installed"
			else
				echo "  Warning: pis-indicator installation failed"
			fi
		fi
	fi

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
			exit 1
		else
			echo "  Import complete"
		fi
	fi
}

cmd_delete() {
	local name="$2"
	[ -z "$name" ] || [[ "$name" =~ ^- ]] && {
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
	[ -z "$name" ] || [[ "$name" =~ ^- ]] && {
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

	[[ "$name" =~ ^- ]] && {
		echo "Usage: pis export [name] [file]"
		exit 1
	}

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
	[ -z "$name" ] || [[ "$name" =~ ^- ]] && {
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
		exit 1
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
	[[ "$old_name" =~ ^- ]] && {
		echo "Usage: pis rename <old-name> <new-name>"
		exit 1
	}

	# Validate names: only alphanumeric, underscore, hyphen
	if ! echo "$old_name" | grep -qE '^[a-zA-Z0-9_-]+$' || ! echo "$new_name" | grep -qE '^[a-zA-Z0-9_-]+$'; then
		echo "  Error: environment name must only contain letters, numbers, hyphens, and underscores"
		exit 1
	fi

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

	# Rename steps: order matters for safety with set -e
	# Step 1: rename the command script first (lowest impact if interrupted)
	if [ -f "$BIN/pi-$old_name" ]; then
		mv "$BIN/pi-$old_name" "$BIN/pi-$new_name"
		sed_i "s/agent-$old_name/agent-$new_name/g" "$BIN/pi-$new_name"
		echo "  Renamed command: pi-$old_name → pi-$new_name"
	fi

	# Step 2: rename the environment directory
	mv "$SWAP/agent-$old_name" "$SWAP/agent-$new_name"
	echo "  Renamed directory: agent-$old_name → agent-$new_name"

	# Step 3: update active symlink last
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
	[[ "${2:-}" =~ ^- ]] && {
		echo "Usage: pis update"
		exit 1
	}
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
	case "${2:-}" in
	install | i)
		cmd_packages_install "$@"
		;;
	remove | rm)
		cmd_packages_remove "$@"
		;;
	update | up)
		cmd_packages_update "$@"
		;;
	outdated | out)
		cmd_packages_outdated "$@"
		;;
	*)
		# Unknown flags show usage, otherwise list behavior
		[[ "${2:-}" =~ ^- ]] && {
			echo "Usage:"
			echo "  pis pkgs [env]                      List packages"
			echo "  pis pkgs install <pkg> [env]        Install a package"
			echo "  pis pkgs remove <pkg> [env]         Remove a package"
			echo "  pis pkgs update [env]               Update packages"
			echo "  pis pkgs outdated [env|--all]       Show outdated packages"
			exit 1
		}
		local name="${2:-current}" envdir
		envdir=$(resolve_env_dir "$name")
		[ ! -f "$envdir/settings.json" ] && {
			echo "  Environment '$name' has no settings.json"
			exit 1
		}
		local count
		count=$(node -e "
const fs = require('fs');
const s = JSON.parse(fs.readFileSync('$envdir/settings.json', 'utf-8'));
const pkgs = s.packages || [];
const npmPkgPath = '$envdir/npm/package.json';
let declared = {};
try { declared = JSON.parse(fs.readFileSync(npmPkgPath, 'utf-8')).dependencies || {}; } catch (e) {}
const maxLen = pkgs.reduce(function(m, p) { return Math.max(m, p.length); }, 0);
pkgs.forEach(function(p, i) {
  var extra = '';
  if (p.startsWith('npm:')) {
    var name = p.slice(4);
    var range = declared[name] || '?';
    var ver = '?';
    try { ver = JSON.parse(fs.readFileSync('$envdir/npm/node_modules/' + name + '/package.json', 'utf-8')).version; } catch (e) {}
    extra = '  ' + range + '  \u2192  ' + ver;
  } else if (p.startsWith('git:')) {
    extra = '  (git)';
  }
  console.log(String(i + 1).padStart(2) + '. ' + p + ' '.repeat(Math.max(1, maxLen - p.length + 2)) + extra.trimStart());
});
console.log('---');
console.log('Total: ' + pkgs.length + ' packages');
" 2>&1)
		echo "Packages in '$name' environment:"
		echo "$count"
		;;
	esac
}

cmd_packages_install() {
	local pkg="$3" name="${4:-current}"
	[ -z "$pkg" ] && {
		echo "Usage: pis pkgs install <pkg> [env|--all]"
		exit 1
	}
	[[ "$pkg" =~ ^- ]] && {
		echo "Usage: pis pkgs install <pkg> [env|--all]"
		exit 1
	}

	if [ "$name" = "--all" ]; then
		echo "  Installing $pkg to all environments..."
		local fail=0 succ=0 total=0
		for env_dir in "$SWAP"/agent-*; do
			[ -d "$env_dir" ] || continue
			total=$((total + 1))
			local env_name="${env_dir#*/agent-}"
			echo "    $env_name: $pkg"
			if PI_CODING_AGENT_DIR="$env_dir" pi install "$pkg" 2>&1; then
				succ=$((succ + 1))
			else
				fail=$((fail + 1))
			fi
		done
		[ "$fail" -gt 0 ] && echo "  Warning: $fail/$total environment(s) failed"
		[ "$fail" -gt 0 ] && exit 1
		return
	fi

	local envdir
	envdir=$(resolve_env_dir "$name")
	[ ! -d "$envdir" ] && {
		echo "  Environment '$name' does not exist"
		exit 1
	}

	echo "  Installing $pkg to $name..."
	if PI_CODING_AGENT_DIR="$envdir" pi install "$pkg" 2>&1; then
		echo "  → $pkg installed"
	else
		echo "  Warning: $pkg installation failed" >&2
		exit 1
	fi
}

cmd_packages_remove() {
	local pkg="$3" name="${4:-current}"
	[ -z "$pkg" ] && {
		echo "Usage: pis pkgs remove <pkg> [env|--all]"
		exit 1
	}
	[[ "$pkg" =~ ^- ]] && {
		echo "Usage: pis pkgs remove <pkg> [env|--all]"
		exit 1
	}

	if [ "$name" = "--all" ]; then
		echo "  Removing $pkg from all environments..."
		local fail=0 succ=0 total=0
		for env_dir in "$SWAP"/agent-*; do
			[ -d "$env_dir" ] || continue
			total=$((total + 1))
			local env_name="${env_dir#*/agent-}"
			echo "    $env_name: $pkg"
			if PI_CODING_AGENT_DIR="$env_dir" pi remove "$pkg" 2>&1; then
				succ=$((succ + 1))
			else
				fail=$((fail + 1))
			fi
		done
		[ "$fail" -gt 0 ] && echo "  Warning: $fail/$total environment(s) failed"
		[ "$fail" -gt 0 ] && exit 1
		return
	fi

	local envdir
	envdir=$(resolve_env_dir "$name")
	[ ! -d "$envdir" ] && {
		echo "  Environment '$name' does not exist"
		exit 1
	}

	echo "  Removing $pkg from $name..."
	if PI_CODING_AGENT_DIR="$envdir" pi remove "$pkg" 2>&1; then
		echo "  → $pkg removed"
	else
		echo "  Warning: $pkg removal failed" >&2
		exit 1
	fi
}

cmd_packages_update() {
	local name="${3:-current}"
	[ "$name" != "--all" ] && [[ "$name" =~ ^- ]] && {
		echo "Usage: pis pkgs update [env|--all]"
		exit 1
	}

	if [ "$name" = "--all" ]; then
		echo "  Updating all environments..."
		local fail=0 succ=0 total=0
		for env_dir in "$SWAP"/agent-*; do
			[ -d "$env_dir" ] || continue
			total=$((total + 1))
			local env_name="${env_dir#*/agent-}"
			echo "    $env_name: updating packages..."
			if PI_CODING_AGENT_DIR="$env_dir" pi update --extensions 2>&1; then
				succ=$((succ + 1))
			else
				fail=$((fail + 1))
			fi
			# pnpm treats @latest as a no-op when the existing range already covers it,
			# so pi update --extensions may not actually update npm packages.
			# Run pnpm update directly to force actual updates within range.
			if [ -d "$env_dir/npm" ]; then
				(cd "$env_dir/npm" && pnpm update --config.minimumReleaseAge=0 2>&1) || true
			fi
		done
		[ "$fail" -gt 0 ] && echo "  Warning: $fail/$total environment(s) failed"
		[ "$fail" -gt 0 ] && exit 1
		return
	fi

	local envdir
	envdir=$(resolve_env_dir "$name")
	[ ! -d "$envdir" ] && {
		echo "  Environment '$name' does not exist"
		exit 1
	}

	echo "  Updating packages in $name..."
	if PI_CODING_AGENT_DIR="$envdir" pi update --extensions 2>&1; then
		echo "  → pi extensions updated"
	else
		echo "  Warning: pi update --extensions failed for $name" >&2
	fi
	# pnpm treats @latest as a no-op when the existing range already covers it,
	# so pi update --extensions may not actually update npm packages.
	# Run pnpm update directly to force actual updates within range.
	if [ -d "$envdir/npm" ]; then
		cd "$envdir/npm" && pnpm update --config.minimumReleaseAge=0 2>&1
	fi
	echo "  → $name packages updated"
	echo "  Note: updates respect semver ranges (e.g. ^0.19.9 blocks 0.20.x)."
	echo "  To check: cd $envdir/npm && npm outdated"
	echo "  To force upgrade: cd $envdir/npm && pnpm install <pkg>@<version>"
	echo "  (use the version from npm outdated's 'Latest' column)"
}

cmd_packages_outdated() {
	local name="${3:-current}"
	[ "$name" != "--all" ] && [[ "$name" =~ ^- ]] && {
		echo "Usage: pis pkgs outdated [env|--all]"
		exit 1
	}

	if [ "$name" = "--all" ]; then
		echo "  Checking outdated packages in all environments..."
		local fail=0 succ=0 total=0
		for env_dir in "$SWAP"/agent-*; do
			[ -d "$env_dir" ] || continue
			total=$((total + 1))
			local env_name="${env_dir#*/agent-}"
			echo "    $env_name:"
			if [ ! -d "$env_dir/npm" ]; then
				echo "      (no npm directory)"
				continue
			fi
			if outdated_output=$(cd "$env_dir/npm" && npm outdated 2>&1); then
				echo "      All packages are up to date"
				succ=$((succ + 1))
			else
				local rc=$?
				if [ $rc -eq 2 ]; then
					echo "      Error: npm outdated failed" >&2
					fail=$((fail + 1))
				else
					echo "$outdated_output" | sed 's/^/      /'
					succ=$((succ + 1))
				fi
			fi
			echo ""
		done
		[ "$fail" -gt 0 ] && echo "  Warning: $fail/$total environment(s) had errors"
		[ "$fail" -gt 0 ] && exit 1
		return
	fi

	local envdir
	envdir=$(resolve_env_dir "$name")
	[ ! -d "$envdir" ] && {
		echo "  Environment '$name' does not exist"
		exit 1
	}

	if [ ! -d "$envdir/npm" ]; then
		echo "  Environment '$name' has no npm directory"
		exit 1
	fi

	echo "Outdated packages in '$name' environment:"
	if outdated_output=$(cd "$envdir/npm" && npm outdated 2>&1); then
		echo "  All packages are up to date"
	else
		local rc=$?
		if [ $rc -eq 2 ]; then
			echo "  Error: npm outdated failed" >&2
			exit 1
		fi
		echo "$outdated_output"
	fi
}

# ============================================================
# Tool management
# ============================================================

cmd_tools() {
	case "${2:-}" in
	list | ls)
		cmd_tools_list "$@"
		;;
	install | i)
		cmd_tools_install "$@"
		;;
	remove | rm)
		cmd_tools_remove "$@"
		;;
	sync)
		cmd_tools_sync "$@"
		;;
	*)
		[[ "${2:-}" =~ ^- ]] && {
			echo "Usage: pis tools list | install <name> --url <URL> | remove <name> | sync [env|--all]"
			exit 1
		}
		# Unknown subcommand — show error instead of silently listing
		if [ -n "${2:-}" ]; then
			echo "  Unknown subcommand: $2"
			echo "Usage: pis tools list | install <name> --url <URL> | remove <name> | sync [env|--all]"
			exit 1
		fi
		cmd_tools_list "$@"
		;;
	esac
}

cmd_tools_list() {
	echo "Installed tools:"
	local count=0
	for f in "$SWAP/tools"/*; do
		[ -f "$f" ] || continue
		echo "  $(basename "$f")"
		count=$((count + 1))
	done
	[ "$count" -eq 0 ] && echo "  (none)"
}

cmd_tools_install() {
	local name="$3" url=""
	[ -z "$name" ] || [[ "$name" =~ ^- ]] && {
		echo "Usage: pis tools install <name> --url <URL>"
		exit 1
	}

	shift 3
	while [ $# -gt 0 ]; do
		case "$1" in
		--url)
			url="$2"
			shift
			;;
		*)
			echo "  Unknown option: $1"
			exit 1
			;;
		esac
		shift
	done

	[ -z "$url" ] && {
		echo "Usage: pis tools install <name> --url <URL>"
		exit 1
	}

	mkdir -p "$SWAP/tools"

	local toolpath="$SWAP/tools/$name"
	echo "  Downloading $name..."
	if ! curl -sL --fail "$url" -o "$toolpath"; then
		rm -f "$toolpath"
		echo "  Error: download failed for $name" >&2
		exit 1
	fi

	# Content validation: must be ELF (Linux) or Mach-O (macOS)
	if command -v file >/dev/null 2>&1; then
		if ! file "$toolpath" | grep -qE 'ELF|Mach-O'; then
			rm -f "$toolpath"
			echo "  Error: downloaded file is not a valid binary (ELF/Mach-O)" >&2
			exit 1
		fi
	fi

	chmod +x "$toolpath"
	echo "  → Tool '$name' installed"
}

cmd_tools_remove() {
	local name="$3"
	[ -z "$name" ] || [[ "$name" =~ ^- ]] && {
		echo "Usage: pis tools remove <name>"
		exit 1
	}

	local toolpath="$SWAP/tools/$name"
	[ ! -f "$toolpath" ] && {
		echo "  Tool '$name' is not installed"
		exit 1
	}

	rm -f "$toolpath"
	echo "  → Tool '$name' removed"
}

cmd_tools_sync() {
	local name="${3:-current}"

	if [ "$name" = "--all" ]; then
		echo "  Syncing tools to all environments..."
		local fail=0 succ=0 total=0
		for env_dir in "$SWAP"/agent-*; do
			[ -d "$env_dir" ] || continue
			total=$((total + 1))
			local env_name="${env_dir#*/agent-}"
			echo "    $env_name: syncing tools..."
			if tools_sync_env "$env_dir"; then
				succ=$((succ + 1))
			else
				fail=$((fail + 1))
			fi
		done
		[ "$fail" -gt 0 ] && echo "  Warning: $fail/$total environment(s) had errors"
		[ "$fail" -gt 0 ] && exit 1
		return
	fi

	local envdir
	envdir=$(resolve_env_dir "$name")
	[ ! -d "$envdir" ] && {
		echo "  Environment '$name' does not exist"
		exit 1
	}

	echo "  Syncing tools to $name..."
	if tools_sync_env "$envdir"; then
		local count
		count=$(find "$SWAP/tools" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')
		echo "  → Tools synced ($count tools)"
	else
		echo "  Warning: sync failed for $name" >&2
		exit 1
	fi
}

# Helper: sync tools to a single environment directory
tools_sync_env() {
	local envdir="$1"
	local bindir="$envdir/bin"

	# Self-healing: create tools/ if missing
	mkdir -p "$SWAP/tools"
	mkdir -p "$bindir"

	# Pass 1: Create/repair symlinks for all shared tools
	for tool in "$SWAP/tools"/*; do
		[ -f "$tool" ] || continue
		local name
		name=$(basename "$tool")
		ln -snf "../../tools/$name" "$bindir/$name"
	done

	# Pass 2: Remove broken symlinks pointing to tools/ (cleanup)
	for f in "$bindir"/*; do
		[ -L "$f" ] || continue # skip real files
		[ -e "$f" ] && continue # skip valid symlinks
		local target
		target=$(readlink "$f")
		case "$target" in
		../../tools/*)
			rm -f "$f"
			;;
		esac
	done
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
	echo "  create <name> --import <file>            Import packages on creation
  create <name> --install-indicator  Install pis-indicator (default)
  create <name> --no-indicator       Skip pis-indicator installation"
	echo "  delete <name>                  Delete an environment"
	echo "  rename <old> <new>             Rename an environment"
	echo "  use <name>                     Set default pi environment"
	echo "  export [name] [file]           Export package list"
	echo "  import <name> [file]           Import packages from file"
	echo "  list                           List all environments"
	echo "  status                         Show current status"
	echo "  packages [name]                List installed packages in an environment"
	echo "  pkgs install <pkg> [env]       Install a package (omit env for current, --all for all)"
	echo "  pkgs remove <pkg> [env]        Remove a package (omit env for current, --all for all)"
	echo "  pkgs update [env]              Update all packages (omit env for current, --all for all)"
	echo "  pkgs outdated [env]            Show outdated packages in an environment (omit env for current, --all for all)"
	echo "  tools list                     List installed tools"
	echo "  tools install <name> --url <URL>  Install a tool from URL"
	echo "  tools remove <name>            Remove a tool"
	echo "  tools sync [env|--all]         Sync tools to environment(s)"
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
tools) cmd_tools "$@" ;;
--version | -V) echo "pis v$VERSION" ;;
-h | --help | help | *) cmd_help ;;
esac
