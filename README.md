# pi-env

Multi-environment management tool for pi-coding-agent. Create, clone, import, export, and switch between independent pi-coding-agent environments.

> 📖 中文版见 [README.zh-CN.md](README.zh-CN.md)

## Installation

```bash
# One-liner install
curl -sL https://raw.githubusercontent.com/Githubwujinming/pi-env/main/install.sh | bash

# Clone repo
git clone https://github.com/Githubwujinming/pi-env.git
cd pi-env
./install.sh
```

## Quick Start

```bash
# Create a blank environment
pi-env create test

# Launch it
pi-test

# Clone from the current environment
pi-env create rpiv-test --clone current

# Create and set as default
pi-env create work --use

# Export package list
pi-env export

# Import packages from a file
pi-env import test pi-packages.txt

# List installed packages in the current environment
pi-env packages
pi-env pkgs

# Update pi-env to the latest version
pi-env update
```

## Recommended Packages

A curated list of recommended pi packages is available in [`vibecoding_pkgs.txt`](vibecoding_pkgs.txt).

To create a new environment and install all recommended packages in one go:

```bash
pi-env create vibe --use --import vibecoding_pkgs.txt
```

## Use Cases

pi-env lets you create isolated pi environments for different workflows, avoiding package bloat and conflicts in a single pi installation.

### 🧑‍💻 Vibecoding / Programming

Create a dedicated coding environment packed with development tools:

```bash
pi-env create vibe --clone current --use
# Then install coding packages
pi-env import vibe vibecoding_pkgs.txt
```

This environment can include: `pi-subagent`, `rpiv-workflow`, `rpiv-todo`, `pi-lens`, `pi-shazam`, `pi-agent-browser-native`, and other development-focused packages.

### 📋 General / Office / Research

Create a lightweight environment for daily tasks, research, and web browsing:

```bash
pi-env create general --use
pi install npm:pi-btw
pi install npm:web-tool
# ... install only what you need
```

This environment keeps only essentials like `pi-btw`, `pi-powerline-footer`, `pi-llm-wiki`, `web-tool`, and browsing tools.

### 🧹 Why isolate?

Installing every package into a single pi environment can lead to:

- Slower startup as pi loads all extensions and skills
- Command conflicts between similar packages
- Harder debugging when something breaks
- Difficulty reproducing a setup on another machine

With pi-env, each scenario gets its own `~/.pi/agent-<name>/` directory — completely isolated settings, packages, sessions, and auth.

## Commands

| Command | Description |
|---------|-------------|
| `create <name>` | Create a new blank environment |
| `create <name> --clone <source>` | Clone from an existing environment |
| `create <name> --use` | Create and set as default immediately |
| `create <name> --import <file>` | Create and import packages from file |
| `use <name>` | Set the default pi target environment |
| `delete <name>` | Delete an environment |
| `export [name] [file]` | Export an environment's package list |
| `import <name> [file]` | Import packages from a file into an environment |
| `list` | List all environments |
| `status` | Show current status |
| `packages` / `pkgs` [name] | List installed packages in an environment |
| `update` | Update pi-env to the latest version |
| `uninstall` | Remove pi-env and restore single-directory mode |

## How It Works

Each environment corresponds to a separate config directory `~/.pi/agent-<name>/`, keeping them fully isolated.

- The `pi` command reads `~/.pi/agent/` — a symlink pointing to the current environment
- The `pi-<name>` command launches a specific environment via `PI_CODING_AGENT_DIR`
- `pi-env use <name>` switches the symlink to change the default `pi` target

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `PI_ENV_DIR` | `~/.pi` | pi config root directory |
| `PI_ENV_BIN` | `~/.local/bin` | Command installation directory |

## Dependencies

| Dependency | Required | Used By | Notes |
|------------|----------|---------|-------|
| **pi-coding-agent** | Yes | All commands | The tool being managed. Installer checks and aborts if missing. |
| **Node.js** (`node`) | Yes | `pi-env export` | Reads `settings.json`. pi itself requires Node.js, so it's typically already available. |
| **Perl** | macOS only | `abs_path()` fallback | Pre-installed on macOS. Linux uses `readlink -f` instead. |
| **curl** or **wget** | Remote install | `install.sh` | At least one is needed for the one-liner install method. |

## Cross-Platform

pi-env works on **macOS** and **Linux**. It includes built-in compatibility shims for platform differences:

| Difference | Fallback |
|------------|----------|
| `readlink -f` (macOS lacks `-f`) | Falls back to `perl -MCwd` on Darwin |
| `sed -i` (macOS requires empty extension) | Wrapped `sed_i()` function with `uname -s` branch |

## License

MIT
