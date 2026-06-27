#!/usr/bin/env bash
# pi-env installer
# Version: 0.2.0
# Usage: curl -sL https://raw.githubusercontent.com/Githubwujinming/pi-env/main/install.sh | bash

set -euo pipefail

INSTALL_DIR="${PI_ENV_DIR:-$HOME/.pi}"
BIN_DIR="${PI_ENV_BIN:-$HOME/.local/bin}"
VERSION="0.2.0"

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

# Deploy pi-env.sh
SCRIPT_SRC="$(cd "$(dirname "$0")" && pwd)/pi-env.sh"
if [ -f "$SCRIPT_SRC" ]; then
	cp "$SCRIPT_SRC" "$INSTALL_DIR/pi-env.sh"
else
	echo "Downloading pi-env.sh..."
	if command -v curl >/dev/null 2>&1; then
		curl -sL "https://raw.githubusercontent.com/Githubwujinming/pi-env/main/pi-env.sh" -o "$INSTALL_DIR/pi-env.sh"
	elif command -v wget >/dev/null 2>&1; then
		wget -q "https://raw.githubusercontent.com/Githubwujinming/pi-env/main/pi-env.sh" -O "$INSTALL_DIR/pi-env.sh"
	else
		echo "Error: curl or wget is required"
		exit 1
	fi
fi

chmod +x "$INSTALL_DIR/pi-env.sh"
ln -sf "$INSTALL_DIR/pi-env.sh" "$BIN_DIR/pi-env"

# If ~/.pi/agent is a real directory (not a symlink), convert it to first environment
if [ -d "$INSTALL_DIR/agent" ] && [ ! -L "$INSTALL_DIR/agent" ]; then
	echo "Existing pi config found at $INSTALL_DIR/agent"
	echo "Converting to first environment: default"
	mv "$INSTALL_DIR/agent" "$INSTALL_DIR/agent-default"
	ln -snf "agent-default" "$INSTALL_DIR/agent"
	echo "  → $INSTALL_DIR/agent now points to $INSTALL_DIR/agent-default"
fi

# Check PATH
case ":$PATH:" in
*":$BIN_DIR:"*) ;;
*)
	echo "  Hint: $BIN_DIR is not in PATH. Add it to your shell config:"
	echo "    echo 'export PATH=\"\$PATH:$BIN_DIR\"' >> ~/.bashrc"
	echo "    source ~/.bashrc"
	;;
esac

echo "pi-env v$VERSION installed successfully"
echo "Run 'pi-env help' to get started"
