#!/usr/bin/env bash
# pis installer
# Version: 0.3.0
# Usage: curl -sL https://raw.githubusercontent.com/Githubwujinming/pis/main/install.sh | bash

set -euo pipefail

INSTALL_DIR="${PI_ENV_DIR:-$HOME/.pi}"
BIN_DIR="${PI_ENV_BIN:-$HOME/.local/bin}"
VERSION="0.3.0"

# Parse --no-indicator / --install-indicator
INSTALL_INDICATOR=1
if [ $# -gt 0 ]; then
	case "$1" in
	--no-indicator) INSTALL_INDICATOR=0 ;;
	--install-indicator) INSTALL_INDICATOR=1 ;;
	*)
		echo "Usage: $0 [--no-indicator | --install-indicator]"
		exit 1
		;;
	esac
fi

# Check pi — install if missing
if ! command -v pi >/dev/null 2>&1; then
	echo "pi not found. Installing pi-coding-agent..."
	curl -fsSL https://pi.dev/install.sh | sh
	echo ""
	if ! command -v pi >/dev/null 2>&1; then
		echo "Error: pi installation failed. Please install pi-coding-agent manually, then re-run this installer."
		exit 1
	fi
fi

# Create directories
mkdir -p "$INSTALL_DIR" "$BIN_DIR"

# Deploy pis.sh
SCRIPT_SRC="$(cd "$(dirname "$0")" && pwd)/pis.sh"
if [ -f "$SCRIPT_SRC" ]; then
	cp "$SCRIPT_SRC" "$INSTALL_DIR/pis.sh"
else
	echo "Downloading pis.sh..."
	if command -v curl >/dev/null 2>&1; then
		curl -sL "https://raw.githubusercontent.com/Githubwujinming/pis/main/pis.sh" -o "$INSTALL_DIR/pis.sh"
	elif command -v wget >/dev/null 2>&1; then
		wget -q "https://raw.githubusercontent.com/Githubwujinming/pis/main/pis.sh" -O "$INSTALL_DIR/pis.sh"
	else
		echo "Error: curl or wget is required"
		exit 1
	fi
fi

chmod +x "$INSTALL_DIR/pis.sh"
ln -sf "$INSTALL_DIR/pis.sh" "$BIN_DIR/pis"

# If ~/.pi/agent is a real directory (not a symlink), convert it to first environment
if [ -d "$INSTALL_DIR/agent" ] && [ ! -L "$INSTALL_DIR/agent" ]; then
	echo "Existing pi config found at $INSTALL_DIR/agent"
	echo "Converting to first environment: default"
	mv "$INSTALL_DIR/agent" "$INSTALL_DIR/agent-default"
	ln -snf "agent-default" "$INSTALL_DIR/agent"
	echo "  → $INSTALL_DIR/agent now points to $INSTALL_DIR/agent-default"
fi

# ------------------------------------------------------------------
# Ensure pnpm is available for pi's package management
# ------------------------------------------------------------------
if ! command -v pnpm >/dev/null 2>&1; then
	echo ""
	echo "pi requires pnpm for efficient package management across environments."
	echo "pnpm shares package files globally, saving disk space."
	read -r -p "Install pnpm now via 'npm install -g pnpm'? [Y/n] " yn
	case "${yn:-Y}" in
	[Nn]*)
		echo "  pnpm not installed. pi will use npm as fallback."
		echo "  Run 'npm install -g pnpm' later if you want to migrate."
		;;
	*)
		echo "Installing pnpm..."
		if npm install -g pnpm 2>&1; then
			echo "  → pnpm v$(pnpm --version || true) installed"
		else
			echo "  Error: pnpm installation failed."
			echo "  Please install pnpm manually: npm install -g pnpm"
			echo "  Then re-run install.sh."
			exit 1
		fi
		;;
	esac
fi

# ------------------------------------------------------------------
# Migrate existing agent-* environments to use pnpm
# ------------------------------------------------------------------
if command -v pnpm >/dev/null 2>&1; then
	echo "Checking existing pi environments..."
	for env_dir in "$INSTALL_DIR"/agent-*; do
		[ -d "$env_dir" ] || continue
		env_name="${env_dir#*/agent-}"
		settings_file="$env_dir/settings.json"
		[ -f "$settings_file" ] || continue

		if grep -q '"npmCommand"' "$settings_file" 2>/dev/null; then
			echo "  $env_name already has npmCommand configured (skipping)"
			continue
		fi

		echo "  Migrating $env_name to pnpm..."
		# Assumption: no concurrent pi processes are running during this write
		if ! node -e "
const fs = require('fs');
const path = '$settings_file';
let s = {};
try { s = JSON.parse(fs.readFileSync(path, 'utf-8')); } catch (e) { process.exit(1); }
s.npmCommand = ['pnpm'];
const tmp = path + '.tmp';
fs.writeFileSync(tmp, JSON.stringify(s, null, 2) + '\n');
fs.renameSync(tmp, path);
" 2>&1; then
			echo "  Warning: could not set npmCommand for $env_name" >&2
			continue
		fi

		# Delete old node_modules to force clean rebuild with pnpm
		rm -rf "$env_dir/npm/node_modules"
		# Remove orphaned npm lockfile (pnpm uses pnpm-lock.yaml)
		rm -f "$env_dir/npm/package-lock.json"
		echo "    Rebuilding packages with pnpm..."
		if PI_CODING_AGENT_DIR="$env_dir" pi update --extensions 2>&1; then
			echo "    → $env_name migrated to pnpm"
		else
			# pnpm blocks build scripts for new packages — approve and retry
			echo "    Approving pnpm build scripts..."
			if cd "$env_dir/npm" && pnpm approve-builds --all && PI_CODING_AGENT_DIR="$env_dir" pi update --extensions 2>&1; then
				echo "    → $env_name migrated to pnpm"
			else
				echo "    Warning: pi update --extensions failed for $env_name" >&2
				echo "    settings.json already updated. Run manually:" >&2
				echo "      cd $env_dir/npm && pnpm approve-builds --all" >&2
				echo "      PI_CODING_AGENT_DIR=$env_dir pi update --extensions" >&2
			fi
		fi
	done
fi

# Auto-add to PATH
case "$SHELL" in
*zsh*) rc="$HOME/.zshrc" ;;
*bash*) rc="$HOME/.bashrc" ;;
*) rc="$HOME/.profile" ;;
esac

if echo ":$PATH:" | grep -q ":$BIN_DIR:"; then
	: # already in PATH
elif [ -f "$rc" ] && grep -q "$BIN_DIR" "$rc" 2>/dev/null; then
	: # already configured in rc file (waiting for source)
else
	echo "  Adding $BIN_DIR to $rc ..."
	{
		echo ""
		echo "# pis"
		echo "export PATH=\"\$PATH:$BIN_DIR\""
	} >>"$rc"
	echo "  → Please run: source $rc"
fi

# Install pis-indicator by default
if [ "$INSTALL_INDICATOR" = "1" ]; then
	echo "Installing pis-indicator..."
	if PI_CODING_AGENT_DIR="$INSTALL_DIR/agent" pi install git:github.com/Githubwujinming/pis-indicator 2>&1; then
		echo "  → pis-indicator installed"
	else
		# pnpm may block build scripts — approve and retry
		echo "  Approving pnpm build scripts..."
		if mkdir -p "$INSTALL_DIR/agent/npm" && cd "$INSTALL_DIR/agent/npm" && pnpm approve-builds --all && PI_CODING_AGENT_DIR="$INSTALL_DIR/agent" pi install git:github.com/Githubwujinming/pis-indicator 2>&1; then
			echo "  → pis-indicator installed"
		else
			echo "  Warning: pis-indicator installation failed"
			echo "  You can install later with: pi install git:github.com/Githubwujinming/pis-indicator"
		fi
	fi
fi

echo "pis v$VERSION installed successfully"
echo "Run 'pis help' to get started"
