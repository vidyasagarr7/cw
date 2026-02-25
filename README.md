# cw

Spawn parallel Claude Code agents on your GitHub issues — each in its own worktree, branch, and tmux session. Zero conflicts.

```
cw 423                     →  agent starts fixing issue #423 in the background
cw 423 -b staging          →  branching from staging instead of main
cw 587 -m "focus on auth"  →  another agent with extra context
cw ls                      →  see what's running
cw attach issue-423        →  jump in when it needs input
cw cleanup                 →  prune finished worktrees
```

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/vidyasagarr7/cw/main/install.sh | bash
```

The installer checks dependencies, offers to install missing ones, configures your shell and Claude Code settings, and sets up GitHub auth. Restart your terminal after installing.

Or clone and install:

```bash
git clone https://github.com/vidyasagarr7/cw.git
cd cw && ./install.sh
```

### Requirements

- [Claude Code](https://claude.ai/install.sh) (Pro, Max, Teams, or Enterprise)
- [tmux](https://github.com/tmux/tmux)
- [git](https://git-scm.com)
- [gh](https://cli.github.com) (GitHub CLI)

## Usage

### Work on a GitHub issue

```bash
cw 423                              # auto-detects base branch and branch type
cw 423 -b staging                   # branch from staging
cw 423 -b feature/auth-v2           # branch from in-progress work
cw 423 -m "the bug is in auth.ts"   # extra context for the agent
cw 423 -b develop -m "use new ORM"  # combine flags
```

When you run `cw 423`, it:

1. Detects your repo's default branch (main, master, develop)
2. Reads the issue's labels to pick a prefix (`fix/`, `feat/`, `chore/`, `docs/`)
3. Slugifies the title into a branch name (`fix/423-login-redirect-broken`)
4. Creates an isolated git worktree
5. Launches a tmux session with Claude Code, pre-prompted to read the issue, fix it, and create a PR

### Start a feature without an issue

```bash
cw new feat/onboarding
cw new refactor/db -b develop -m "migrate to drizzle"
```

### Manage sessions

```bash
cw ls               # list active sessions
cw attach issue-423  # jump into a session (fuzzy match)
cw kill issue-423    # kill session (worktree preserved)
cw dash              # tmux session picker
cw cleanup           # remove finished worktrees safely
cw pr issue-423      # create PR from worktree
```

### Detach without killing

Inside a session: `Ctrl+B`, then `D`

## Setup & diagnostics

```bash
cw doctor      # check dependencies, auth, settings — everything
cw update      # update to latest version
cw uninstall   # clean removal
cw --version   # show version
```

`cw doctor` validates your full setup: dependencies, GitHub auth, Claude Code settings (worktree permissions, teammate mode), and gitignore.

## Configuration

Edit `~/.cwrc`:

```bash
CW_DEFAULT_MODEL="sonnet"      # use Sonnet for cheaper/faster runs
CW_SKIP_PERMISSIONS="false"    # set "true" for trusted repos (YOLO mode)
CW_TMUX_PREFIX="cw"            # prefix for tmux session names
CW_WORKTREE_DIR=".claude/worktrees"  # where worktrees go (relative to repo root)
```

### Two-phase planning: Opus plans, Sonnet executes

For complex issues, you can have Opus analyze the codebase and write a plan, then hand it off to Sonnet for implementation:

```bash
CW_PLAN_MODEL="opus"
CW_EXEC_MODEL="sonnet"
CW_PLAN_LABELS="feature,epic,complex,architecture,refactor"
```

When you run `cw 423`, cw checks the issue's labels:

- **Labels match `CW_PLAN_LABELS`** → two-phase mode:
  - Phase 1: Opus reads the issue, explores the codebase, writes `plan.md`
  - Phase 2: Sonnet reads `plan.md` and implements it step by step
- **Labels don't match** (e.g., `bug`, `chore`, `docs`) → single-phase:
  - Sonnet handles everything directly (cheaper, faster for routine work)

This gives you the best of both: Opus-level reasoning on complex architecture decisions, Sonnet-level speed and cost for straightforward execution. A typical `feature` issue costs ~$0.30 for the Opus planning phase and ~$0.10 for Sonnet execution, vs ~$2+ for Opus doing everything.

## Per-project setup

```bash
cd your-project
echo ".claude/worktrees/" >> .gitignore
```

## Parallel agents

For large migrations or features, spawn multiple agents off the same base branch:

```bash
# Create a shared base branch first
git checkout -b feat/big-migration && git push -u origin feat/big-migration

# Spawn 3 agents in parallel — each gets its own worktree and branch
cw new feat/db-migration -b feat/big-migration -m "Migrate the database schema to the new format"
cw new feat/api-update -b feat/big-migration -m "Update the API layer for the new schema"
cw new feat/frontend-update -b feat/big-migration -m "Update frontend components for the new API"

# Monitor all three
cw ls
cw dash
```

Each agent works in complete isolation. When they're done, each creates its own PR targeting `feat/big-migration`. You merge them in order.

## How it works

```
cw 423 -b staging
│
├─ Resolves base:      origin/staging
├─ Reads issue #423:   labels → fix, title → "login redirect broken"
├─ Creates branch:     fix/423-login-redirect-broken (from origin/staging)
├─ Creates worktree:   .claude/worktrees/issue-423/
├─ Writes prompt:      ~/.cw/sessions/cw-issue-423.md
├─ Launches tmux:      session "cw-issue-423" running Claude Code
└─ Returns to shell    (agent works in background)
```

Prompts and launchers are stored in `~/.cw/sessions/` (not in the repo).

## Tips

- **Scroll up in sessions**: `cw attach issue-423`, then press `Ctrl+B` then `[` to enter scroll mode. Arrow keys to scroll, `q` to exit.
- **Sessions stay alive**: When an agent finishes, the tmux session stays open so you can review all output. Use `cw kill` to close.
- **Rate limits**: 3+ Opus sessions burn tokens fast. Use `CW_DEFAULT_MODEL="sonnet"` for routine work.
- **Disk space**: Worktrees are lightweight (shared `.git`), but `node_modules` multiplies. Run `cw cleanup` regularly.
- **Port conflicts**: If your project runs servers, each worktree may fight for the same port.
- **Cleanup safety**: `cw cleanup` won't remove worktrees with uncommitted changes or unpushed commits.

## License

MIT
