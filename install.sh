#!/usr/bin/env bash
# ============================================================================
# cw installer
# ============================================================================
# Install:    curl -fsSL https://raw.githubusercontent.com/vidyasagarr7/cw/main/install.sh | bash
# Uninstall:  cw uninstall
# ============================================================================
set -euo pipefail

CW_VERSION="0.1.0"
CW_HOME="${CW_HOME:-$HOME/.cw}"
CW_REPO="https://raw.githubusercontent.com/vidyasagarr7/cw/main"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

c() {
  case "$1" in
    r) shift; printf "\033[0;31m%s\033[0m\n" "$*" ;;
    g) shift; printf "\033[0;32m%s\033[0m\n" "$*" ;;
    y) shift; printf "\033[0;33m%s\033[0m\n" "$*" ;;
    d) shift; printf "\033[0;90m%s\033[0m\n" "$*" ;;
    b) shift; printf "\033[1m%s\033[0m\n" "$*" ;;
    *) shift; printf "%s\n" "$*" ;;
  esac
}

confirm() {
  local prompt=$1 default=${2:-y}
  if [[ "$default" == "y" ]]; then
    printf "%s [Y/n] " "$prompt"
    read -r answer
    [[ -z "$answer" || "$answer" =~ ^[Yy] ]]
  else
    printf "%s [y/N] " "$prompt"
    read -r answer
    [[ "$answer" =~ ^[Yy] ]]
  fi
}

# ---------------------------------------------------------------------------
# Shell detection
# ---------------------------------------------------------------------------

detect_shell() {
  local shell_name
  shell_name=$(basename "${SHELL:-/bin/bash}")
  case "$shell_name" in
    zsh)  echo "zsh" ;;
    bash) echo "bash" ;;
    fish) echo "fish" ;;
    *)    echo "bash" ;;
  esac
}

shell_rc() {
  case "$(detect_shell)" in
    zsh)  echo "$HOME/.zshrc" ;;
    bash)
      # Prefer .bashrc, fall back to .bash_profile on macOS
      if [[ -f "$HOME/.bashrc" ]]; then echo "$HOME/.bashrc"
      else echo "$HOME/.bash_profile"
      fi
      ;;
    fish) echo "$HOME/.config/fish/config.fish" ;;
  esac
}

# ---------------------------------------------------------------------------
# Dependency management
# ---------------------------------------------------------------------------

check_dep() {
  local name=$1 install_cmd=$2 required=${3:-true}
  if command -v "$name" >/dev/null 2>&1; then
    local ver
    ver=$("$name" --version 2>/dev/null | head -1 || echo "installed")
    c g "  ✓ $name  $(c d "($ver)")"
    return 0
  fi

  if [[ "$required" == "true" ]]; then
    c r "  ✗ $name  $(c d "(required)")"
  else
    c y "  ○ $name  $(c d "(optional)")"
  fi
  MISSING_DEPS+=("$name:$install_cmd")
  return 1
}

install_deps() {
  if [[ ${#MISSING_DEPS[@]} -eq 0 ]]; then return 0; fi

  local required_missing=()
  for dep in "${MISSING_DEPS[@]}"; do
    local name="${dep%%:*}"
    case "$name" in
      tmux|git|gh|claude) required_missing+=("$dep") ;;
    esac
  done

  if [[ ${#required_missing[@]} -eq 0 ]]; then return 0; fi

  echo ""
  c b "  Some required tools are missing."
  echo ""

  # Check if we can auto-install
  local can_brew=false can_curl_claude=false
  command -v brew >/dev/null 2>&1 && can_brew=true

  for dep in "${required_missing[@]}"; do
    local name="${dep%%:*}" cmd="${dep#*:}"

    if [[ "$name" == "claude" ]]; then
      if confirm "  Install Claude Code via native installer?"; then
        echo ""
        curl -fsSL https://claude.ai/install.sh | bash
        echo ""
        # shellcheck disable=SC1090
        source "$(shell_rc)" 2>/dev/null || true
        if command -v claude >/dev/null 2>&1; then
          c g "  ✓ Claude Code installed"
        else
          c y "  ⚠ Claude Code installed but not in PATH yet."
          c d "    Restart your terminal after setup completes."
        fi
      else
        c y "  Skipped. Install later: $cmd"
      fi
    elif [[ "$can_brew" == "true" ]]; then
      if confirm "  Install $name via Homebrew?"; then
        brew install "$name" 2>/dev/null
        if command -v "$name" >/dev/null 2>&1; then
          c g "  ✓ $name installed"
        else
          c r "  ✗ Failed to install $name"
        fi
      else
        c y "  Skipped. Install later: $cmd"
      fi
    else
      c d "  Install manually: $cmd"
    fi
  done
}

# ---------------------------------------------------------------------------
# File installation
# ---------------------------------------------------------------------------

install_cw() {
  mkdir -p "$CW_HOME/sessions"

  # If running from a cloned repo, copy local files.
  # If running via curl, download them.
  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"

  if [[ -f "$script_dir/cw.sh" ]]; then
    # Local install
    cp "$script_dir/cw.sh" "$CW_HOME/cw.sh"
  else
    # Remote install (curl | bash)
    c d "  Downloading cw..."
    curl -fsSL "$CW_REPO/cw.sh" -o "$CW_HOME/cw.sh"
  fi

  chmod +x "$CW_HOME/cw.sh"

  # Write version file
  echo "$CW_VERSION" > "$CW_HOME/version"

  c g "  ✓ Installed cw v${CW_VERSION} → $CW_HOME/cw.sh"
}

configure_shell() {
  local rc_file
  rc_file=$(shell_rc)
  local shell_type
  shell_type=$(detect_shell)

  local source_line
  if [[ "$shell_type" == "fish" ]]; then
    source_line="source $CW_HOME/cw.fish"
    # Generate fish wrapper (future — for now, advise bash/zsh)
    c y "  ⚠ Fish shell detected. cw currently requires bash/zsh."
    c d "    Run from a bash/zsh subshell for now."
    return 0
  else
    source_line="[ -f \"$CW_HOME/cw.sh\" ] && source \"$CW_HOME/cw.sh\""
  fi

  # Check if already sourced
  if grep -qF "cw.sh" "$rc_file" 2>/dev/null; then
    # Update the source line in case path changed
    if grep -qF "$source_line" "$rc_file" 2>/dev/null; then
      c d "  ○ Already configured in $rc_file"
    else
      # Remove old cw source lines and add new one
      local tmp
      tmp=$(mktemp)
      grep -vF "cw.sh" "$rc_file" > "$tmp" 2>/dev/null || true
      echo "" >> "$tmp"
      echo "# cw — Claude Code Workflow Orchestrator" >> "$tmp"
      echo "$source_line" >> "$tmp"
      mv "$tmp" "$rc_file"
      c g "  ✓ Updated source line in $rc_file"
    fi
  else
    echo "" >> "$rc_file"
    echo "# cw — Claude Code Workflow Orchestrator" >> "$rc_file"
    echo "$source_line" >> "$rc_file"
    c g "  ✓ Added to $rc_file"
  fi
}

configure_claude_settings() {
  local settings_dir="$HOME/.claude"
  local settings_file="$settings_dir/settings.json"

  mkdir -p "$settings_dir"

  if [[ -f "$settings_file" ]]; then
    # Check if the key settings are already present
    local needs_update=false

    if ! grep -q "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS" "$settings_file" 2>/dev/null; then
      needs_update=true
    fi

    if [[ "$needs_update" == "true" ]]; then
      c y "  ⚠ ~/.claude/settings.json exists but may need updates."
      echo ""
      c d "    Recommended additions:"
      c d "      \"env\": { \"CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS\": \"1\" }"
      c d "      \"teammateMode\": \"tmux\""
      c d "      \"permissions.allow\": [..., \"EnterWorktree\"]"
      echo ""
      if confirm "  Auto-merge these settings?" "y"; then
        _merge_claude_settings "$settings_file"
      else
        c d "  Skipped. Edit manually: $settings_file"
      fi
    else
      c d "  ○ Claude settings already configured"
    fi
  else
    # Write fresh settings
    cat > "$settings_file" <<'SETTINGS'
{
  "env": {
    "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1"
  },
  "permissions": {
    "allow": [
      "Bash(git:*)",
      "Bash(gh:*)",
      "Bash(npm:*)",
      "Bash(npx:*)",
      "Bash(yarn:*)",
      "Bash(pnpm:*)",
      "Bash(pip:*)",
      "Bash(python:*)",
      "Bash(node:*)",
      "Bash(cat:*)",
      "Bash(ls:*)",
      "Bash(find:*)",
      "Bash(grep:*)",
      "Bash(rg:*)",
      "Bash(mkdir:*)",
      "Bash(cp:*)",
      "Bash(mv:*)",
      "Bash(rm:*)",
      "Bash(touch:*)",
      "Bash(echo:*)",
      "Bash(sed:*)",
      "Bash(curl:*)",
      "Bash(make:*)",
      "Bash(docker:*)",
      "Read",
      "Write",
      "Edit",
      "MultiEdit",
      "EnterWorktree"
    ]
  },
  "teammateMode": "tmux"
}
SETTINGS
    c g "  ✓ Created Claude settings → $settings_file"
  fi
}

_merge_claude_settings() {
  local file=$1
  # Use python/node to merge JSON if available, otherwise manual instructions
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$file" <<'PYMERGE'
import json, sys
f = sys.argv[1]
with open(f) as fh:
    data = json.load(fh)

# Merge env
env = data.setdefault("env", {})
env["CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS"] = "1"

# Merge permissions
perms = data.setdefault("permissions", {})
allow = perms.setdefault("allow", [])
for item in ["Bash(git:*)", "Bash(gh:*)", "Read", "Write", "Edit", "MultiEdit", "EnterWorktree"]:
    if item not in allow:
        allow.append(item)

# Set teammate mode
data["teammateMode"] = "tmux"

with open(f, 'w') as fh:
    json.dump(data, fh, indent=2)
PYMERGE
    c g "  ✓ Merged settings into $file"
  else
    c y "  ⚠ python3 not found. Please merge settings manually."
  fi
}

create_config() {
  local cwrc="$HOME/.cwrc"
  if [[ ! -f "$cwrc" ]]; then
    cat > "$cwrc" <<'CWRC'
# ============================================================================
# cw configuration — GitHub issues on autopilot
# ============================================================================

# Model override (leave empty for Claude Code default)
# CW_DEFAULT_MODEL=""          # e.g., "sonnet", "opus", "haiku"

# Skip permission prompts in trusted repos (use with caution)
# CW_SKIP_PERMISSIONS="false"

# Prefix for tmux session names (sessions: cw-issue-423, etc.)
# CW_TMUX_PREFIX="cw"

# Where worktrees are created (relative to repo root)
# CW_WORKTREE_DIR=".claude/worktrees"

# ── Two-Phase Planning ─────────────────────────────────────────────
# When both PLAN and EXEC models are set, complex issues get two phases:
#   Phase 1: PLAN_MODEL reads the issue, explores code, writes plan.md
#   Phase 2: EXEC_MODEL reads plan.md and implements it
#
# Issues with labels matching CW_PLAN_LABELS trigger two-phase mode.
# All other issues go straight to CW_EXEC_MODEL (single phase).

# CW_PLAN_MODEL="opus"
# CW_EXEC_MODEL="sonnet"
# CW_PLAN_LABELS="feature,epic,complex,architecture,refactor"
CWRC
    c g "  ✓ Created config → $cwrc"
  else
    c d "  ○ Config already exists at $cwrc"
  fi
}

verify_gh_auth() {
  if command -v gh >/dev/null 2>&1; then
    if gh auth status >/dev/null 2>&1; then
      c g "  ✓ GitHub CLI authenticated"
    else
      c y "  ⚠ GitHub CLI not authenticated"
      if confirm "  Run 'gh auth login' now?"; then
        gh auth login
      else
        c d "    Run later: gh auth login"
      fi
    fi
  fi
}

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------

do_uninstall() {
  echo ""
  c b "  Uninstall cw"
  c d "  ─────────────────────────────────────────────"
  echo ""

  # Check for active sessions
  local prefix="${CW_TMUX_PREFIX:-cw}"
  local active
  active=$(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep "^${prefix}-" | grep -v "\-dashboard$" || true)
  if [[ -n "$active" ]]; then
    c y "  Active sessions found:"
    echo "$active" | while read -r s; do echo "    $s"; done
    echo ""
    if confirm "  Kill all active sessions?" "n"; then
      echo "$active" | while read -r s; do tmux kill-session -t "$s" 2>/dev/null; done
      c g "  ✓ Sessions killed"
    else
      c d "  Sessions left running."
    fi
    echo ""
  fi

  # Confirm
  if ! confirm "  Remove cw from your system?" "n"; then
    c d "  Cancelled."
    return 0
  fi
  echo ""

  # Remove source line from shell rc
  local rc_file
  rc_file=$(shell_rc)
  if [[ -f "$rc_file" ]]; then
    local tmp
    tmp=$(mktemp)
    grep -v "cw\.sh\|cw — Claude Code" "$rc_file" > "$tmp" 2>/dev/null || true
    mv "$tmp" "$rc_file"
    c g "  ✓ Removed from $rc_file"
  fi

  # Remove cw home
  if [[ -d "$CW_HOME" ]]; then
    rm -rf "$CW_HOME"
    c g "  ✓ Removed $CW_HOME"
  fi

  # Config
  if [[ -f "$HOME/.cwrc" ]]; then
    if confirm "  Remove ~/.cwrc config?" "n"; then
      rm -f "$HOME/.cwrc"
      c g "  ✓ Removed ~/.cwrc"
    else
      c d "  ○ Kept ~/.cwrc"
    fi
  fi

  echo ""
  c g "  ✓ cw uninstalled. Restart your shell."
  c d "    Claude Code settings and repo worktrees were not modified."
  echo ""
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
  # Handle uninstall flag
  if [[ "${1:-}" == "uninstall" || "${1:-}" == "--uninstall" ]]; then
    do_uninstall
    return 0
  fi

  echo ""
  c b "  ⚡ cw — GitHub issues on autopilot"
  c d "  ─────────────────────────────────────────────"
  echo ""

  # Step 1: Check dependencies
  c b "  Checking dependencies..."
  echo ""
  MISSING_DEPS=()
  check_dep "tmux"   "brew install tmux"
  check_dep "git"    "brew install git"
  check_dep "gh"     "brew install gh"
  check_dep "claude" "curl -fsSL https://claude.ai/install.sh | bash"
  echo ""

  # Step 2: Offer to install missing deps
  install_deps

  # Step 3: Install cw
  echo ""
  c b "  Installing cw..."
  echo ""
  install_cw

  # Step 4: Configure shell
  echo ""
  c b "  Configuring shell..."
  echo ""
  configure_shell

  # Step 5: Configure Claude Code settings
  echo ""
  c b "  Configuring Claude Code..."
  echo ""
  configure_claude_settings

  # Step 6: Create user config
  echo ""
  c b "  Setting up config..."
  echo ""
  create_config

  # Step 7: Verify gh auth
  echo ""
  c b "  Checking GitHub auth..."
  echo ""
  verify_gh_auth

  # Done
  echo ""
  c d "  ─────────────────────────────────────────────"
  c g "  ✓ Installation complete!"
  echo ""
  c d "  Restart your shell or run:"
  c d "    source $(shell_rc)"
  echo ""
  c b "  Quick start:"
  echo "    cd your-project"
  echo "    cw 423              # Work on GitHub issue #423"
  echo "    cw new feat/auth    # Start a new feature branch"
  echo "    cw ls               # See what's running"
  echo "    cw doctor           # Verify everything works"
  echo ""
  c d "  Full docs: cw help"
  echo ""
}

main "$@"
