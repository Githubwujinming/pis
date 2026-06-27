#!/usr/bin/env bash
# pis installer
# Version: 0.2.0
# Usage: curl -sL https://raw.githubusercontent.com/Githubwujinming/pis/main/install.sh | bash

set -euo pipefail

INSTALL_DIR="${PI_ENV_DIR:-$HOME/.pi}"
BIN_DIR="${PI_ENV_BIN:-$HOME/.local/bin}"
VERSION="0.2.0"

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
	if PI_CODING_AGENT_DIR="$INSTALL_DIR/agent" pi install github:Githubwujinming/pis-indicator 2>&1; then
		echo "  → pis-indicator installed"
	else
		echo "  Warning: pis-indicator installation failed"
		echo "  You can install later with: pi install github:Githubwujinming/pis-indicator"
	fi
fi

echo "pis v$VERSION installed successfully"
echo "Run 'pis help' to get started"
