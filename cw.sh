#!/usr/bin/env bash
# ============================================================================
# cw — GitHub issues on autopilot
# ============================================================================
# Spawn parallel Claude Code agents on your GitHub issues,
# each in its own git worktree and tmux session. Zero conflicts.
#
# Install:  curl -fsSL https://raw.githubusercontent.com/vidyasagarr7/cw/main/install.sh | bash
# Docs:     https://github.com/vidyasagarr7/cw
# ============================================================================

CW_HOME="${CW_HOME:-$HOME/.cw}"
CW_WORKTREE_DIR="${CW_WORKTREE_DIR:-.claude/worktrees}"
CW_TMUX_PREFIX="${CW_TMUX_PREFIX:-cw}"
CW_DEFAULT_MODEL="${CW_DEFAULT_MODEL:-}"
CW_SKIP_PERMISSIONS="${CW_SKIP_PERMISSIONS:-false}"
CW_SESSION_DIR="${CW_SESSION_DIR:-$CW_HOME/sessions}"

# Two-phase planning: Opus plans, Sonnet executes
CW_PLAN_MODEL="${CW_PLAN_MODEL:-}"
CW_EXEC_MODEL="${CW_EXEC_MODEL:-}"
CW_PLAN_LABELS="${CW_PLAN_LABELS:-feature,epic,complex,architecture,refactor}"

[[ -f "$HOME/.cwrc" ]] && source "$HOME/.cwrc"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_cw_color() {
  local c=$1; shift
  case "$c" in
    red)    echo -e "\033[0;31m$*\033[0m" ;;
    green)  echo -e "\033[0;32m$*\033[0m" ;;
    yellow) echo -e "\033[0;33m$*\033[0m" ;;
    cyan)   echo -e "\033[0;36m$*\033[0m" ;;
    dim)    echo -e "\033[0;90m$*\033[0m" ;;
    bold)   echo -e "\033[1m$*\033[0m" ;;
    *)      echo "$*" ;;
  esac
}

_cw_version() {
  local v="dev"
  [[ -f "$CW_HOME/version" ]] && v=$(cat "$CW_HOME/version")
  echo "cw v${v}"
}

_cw_ensure_deps() {
  local missing=()
  command -v tmux   >/dev/null || missing+=(tmux)
  command -v git    >/dev/null || missing+=(git)
  command -v claude >/dev/null || missing+=(claude)
  command -v gh     >/dev/null || missing+=(gh)
  if [[ ${#missing[@]} -gt 0 ]]; then
    _cw_color red "Missing: ${missing[*]}. Run 'cw doctor' for details."
    return 1
  fi
}

_cw_repo_root() { git rev-parse --show-toplevel 2>/dev/null; }
_cw_project_name() { basename "$(_cw_repo_root)" 2>/dev/null || echo "unknown"; }
_cw_session_name() { echo "${CW_TMUX_PREFIX}-${1}" | sed 's/[.:]/-/g'; }

_cw_tmux_attach() {
  local target=$1
  if [[ -n "${TMUX:-}" ]]; then
    tmux switch-client -t "$target"
  else
    tmux attach -t "$target"
  fi
}

_cw_default_branch() {
  local branch
  branch=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')
  if [[ -z "$branch" ]]; then
    git remote set-head origin --auto >/dev/null 2>&1
    branch=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')
  fi
  if [[ -z "$branch" ]]; then
    for c in main master develop; do
      git show-ref --verify --quiet "refs/remotes/origin/$c" 2>/dev/null && branch="$c" && break
    done
  fi
  echo "${branch:-main}"
}

_cw_resolve_base() {
  local branch=$1
  if git show-ref --verify --quiet "refs/remotes/origin/$branch" 2>/dev/null; then
    echo "origin/$branch"
  elif git show-ref --verify --quiet "refs/heads/$branch" 2>/dev/null; then
    echo "$branch"
  else
    return 1
  fi
}

_cw_branch_prefix_from_issue() {
  local labels
  labels=$(gh issue view "$1" --json labels -q '.labels[].name' 2>/dev/null | tr '[:upper:]' '[:lower:]')
  if   echo "$labels" | grep -qiE 'bug|fix|hotfix|defect';                then echo "fix"
  elif echo "$labels" | grep -qiE 'chore|maintenance|refactor|tech.debt'; then echo "chore"
  elif echo "$labels" | grep -qiE 'docs|documentation';                   then echo "docs"
  else echo "feat"
  fi
}

_cw_issue_title_slug() {
  local title
  title=$(gh issue view "$1" --json title -q '.title' 2>/dev/null)
  [[ -n "$title" ]] && echo "$title" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g; s/--*/-/g; s/^-//; s/-$//' | cut -c1-50
}

_cw_create_worktree() {
  local wt_path=$1 branch_name=$2 base_ref=$3
  if [[ -d "$wt_path" ]]; then
    _cw_color yellow "Worktree already exists. Reusing."
    return 0
  fi
  mkdir -p "$(dirname "$wt_path")"
  if git worktree add "$wt_path" -b "$branch_name" "$base_ref" 2>/dev/null; then return 0; fi
  # Branch might already exist (re-running after a kill/crash)
  if git show-ref --verify --quiet "refs/heads/$branch_name" 2>/dev/null; then
    git worktree add "$wt_path" "$branch_name" 2>/dev/null && return 0
  fi
  _cw_color red "Failed to create worktree."
  _cw_color dim "  branch: ${branch_name}  base: ${base_ref}"
  _cw_color dim "  Try: git worktree list; git branch -a"
  return 1
}

_cw_needs_planning() {
  # Returns 0 if issue needs Opus planning phase, 1 if simple (Sonnet-only)
  # Requires: both CW_PLAN_MODEL and CW_EXEC_MODEL to be set
  [[ -z "$CW_PLAN_MODEL" || -z "$CW_EXEC_MODEL" ]] && return 1

  local issue=$1
  local labels
  labels=$(gh issue view "$issue" --json labels -q '.labels[].name' 2>/dev/null | tr '[:upper:]' '[:lower:]')
  [[ -z "$labels" ]] && return 1

  local IFS=','
  for plan_label in $CW_PLAN_LABELS; do
    plan_label=$(echo "$plan_label" | tr -d ' ')
    echo "$labels" | grep -qi "$plan_label" && return 0
  done
  return 1
}

_cw_claude_args() {
  local model=$1
  local args=""
  [[ -n "$model" ]] && args="${args} --model '${model}'"
  [[ "$CW_SKIP_PERMISSIONS" == "true" ]] && args="${args} --dangerously-skip-permissions"
  echo "$args"
}

_cw_launch() {
  local wt_path=$1 prompt_file=$2 session_name=$3
  mkdir -p "$CW_SESSION_DIR"
  local launcher="${CW_SESSION_DIR}/${session_name}.sh"
  local claude_args
  claude_args=$(_cw_claude_args "$CW_DEFAULT_MODEL")

  cat > "$launcher" <<LAUNCHEOF
#!/usr/bin/env bash
cd '${wt_path}'

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  cw · ${session_name}"
echo "  dir: ${wt_path}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

claude${claude_args} -p "\$(cat '${prompt_file}')"
exit_code=\$?

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [[ \$exit_code -eq 0 ]]; then
  echo "  ✓ Agent finished (exit \$exit_code)"
else
  echo "  ✗ Agent exited with error (exit \$exit_code)"
fi
echo "  Scroll up: Ctrl+B, then ["
echo "  Close:     cw kill ${session_name#${CW_TMUX_PREFIX}-}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Keep session alive so user can review output
exec bash
LAUNCHEOF
  chmod +x "$launcher"
  tmux new-session -d -s "$session_name" "$launcher" \; set-option -t "$session_name" history-limit 50000
}

_cw_launch_two_phase() {
  local wt_path=$1 plan_prompt=$2 exec_prompt=$3 session_name=$4
  mkdir -p "$CW_SESSION_DIR"
  local launcher="${CW_SESSION_DIR}/${session_name}.sh"
  local plan_args exec_args
  plan_args=$(_cw_claude_args "$CW_PLAN_MODEL")
  exec_args=$(_cw_claude_args "$CW_EXEC_MODEL")

  cat > "$launcher" <<LAUNCHEOF
#!/usr/bin/env bash
cd '${wt_path}'

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  cw · ${session_name} (two-phase)"
echo "  dir: ${wt_path}"
echo "  Phase 1/2: Planning (${CW_PLAN_MODEL})"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

claude${plan_args} -p "\$(cat '${plan_prompt}')"

if [[ ! -s plan.md ]]; then
  echo ""
  echo "⚠  Opus did not create plan.md — creating a placeholder."
  echo "   Sonnet will plan and implement in one pass."
  echo ""
  echo "# Plan" > plan.md
  echo "" >> plan.md
  echo "No structured plan was produced by the planning phase." >> plan.md
  echo "Read the issue, explore the codebase, plan your approach, and implement." >> plan.md
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✓ plan.md ready (\$(wc -l < plan.md) lines)"
echo "  Phase 2/2: Execution (${CW_EXEC_MODEL})"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

claude${exec_args} -p "\$(cat '${exec_prompt}')"
exit_code=\$?

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [[ \$exit_code -eq 0 ]]; then
  echo "  ✓ Agent finished (exit \$exit_code)"
else
  echo "  ✗ Agent exited with error (exit \$exit_code)"
fi
echo "  Scroll up: Ctrl+B, then ["
echo "  Close:     cw kill ${session_name#${CW_TMUX_PREFIX}-}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

exec bash
LAUNCHEOF
  chmod +x "$launcher"
  tmux new-session -d -s "$session_name" "$launcher" \; set-option -t "$session_name" history-limit 50000
}

# ---------------------------------------------------------------------------
# Core: Start Issue
# ---------------------------------------------------------------------------

_cw_start_issue() {
  local issue=$1; shift
  local extra_message="" base_branch=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -m|--message) extra_message="$2"; shift 2 ;;
      -b|--base)    base_branch="$2";   shift 2 ;;
      *) shift ;;
    esac
  done

  _cw_ensure_deps || return 1
  local root; root=$(_cw_repo_root)
  [[ -z "$root" ]] && { _cw_color red "Not in a git repository."; return 1; }

  local default_branch="${base_branch:-$(_cw_default_branch)}"
  local base_ref; base_ref=$(_cw_resolve_base "$default_branch")
  if [[ $? -ne 0 ]]; then
    _cw_color red "Branch '${default_branch}' not found. Run 'git fetch origin' and retry."
    return 1
  fi

  local prefix; prefix=$(_cw_branch_prefix_from_issue "$issue")
  local slug;   slug=$(_cw_issue_title_slug "$issue")
  local branch_name="${prefix}/issue-${issue}"
  [[ -n "$slug" ]] && branch_name="${prefix}/${issue}-${slug}"

  local worktree_name="issue-${issue}"
  local session_name; session_name=$(_cw_session_name "$worktree_name")
  local project; project=$(_cw_project_name)

  if tmux has-session -t "$session_name" 2>/dev/null; then
    _cw_color yellow "Session already running. Attaching..."
    _cw_tmux_attach "$session_name"
    return 0
  fi

  _cw_color dim "Fetching latest from origin..."
  git fetch origin --quiet 2>/dev/null

  local wt_path="${root}/${CW_WORKTREE_DIR}/${worktree_name}"
  _cw_create_worktree "$wt_path" "$branch_name" "$base_ref" || return 1

  mkdir -p "$CW_SESSION_DIR"

  # Decide: two-phase (plan+exec) or single-phase
  local two_phase=false
  _cw_needs_planning "$issue" && two_phase=true

  if [[ "$two_phase" == "true" ]]; then
    # Phase 1 prompt: Opus plans
    local plan_prompt="${CW_SESSION_DIR}/${session_name}-plan-prompt.md"
    local plan_file="${CW_SESSION_DIR}/${session_name}-plan.md"
    cat > "$plan_prompt" <<PLANEOF
You are a senior architect planning the implementation of GitHub issue #${issue} in the ${project} repository.

YOUR JOB IS TO PLAN, NOT IMPLEMENT.

STEPS:
1. Read the issue thoroughly: gh issue view ${issue}
2. Explore the codebase to understand the architecture, relevant files, patterns, and conventions
3. Identify which files need to change and why
4. Consider edge cases, backward compatibility, and testing strategy
5. Write a detailed implementation plan

OUTPUT YOUR PLAN to the file: plan.md (in the current directory)

The plan should include:
- Summary of what needs to happen
- List of files to create/modify with what changes
- Testing approach (which tests to add/modify)
- Potential risks or things to watch out for
- Step-by-step implementation order

BRANCH: You are on branch '${branch_name}', branched from '${default_branch}'.
Do NOT write any code. Only produce the plan.
PLANEOF
    [[ -n "$extra_message" ]] && printf '\nADDITIONAL CONTEXT FROM USER:\n%s\n' "$extra_message" >> "$plan_prompt"

    # Phase 2 prompt: Sonnet executes
    local exec_prompt="${CW_SESSION_DIR}/${session_name}-exec-prompt.md"
    cat > "$exec_prompt" <<EXECEOF
You are an implementation agent working on GitHub issue #${issue} in the ${project} repository.

A senior architect has already created a detailed plan for you. Read it first:
  cat plan.md

Also read the original issue for full context:
  gh issue view ${issue}

YOUR JOB:
1. Read plan.md carefully — this is your blueprint
2. Implement exactly what the plan describes, step by step
3. Follow the project's coding conventions
4. Write tests as specified in the plan
5. Run the test suite to verify everything works
6. When done, create a PR:
   gh pr create --title '${prefix}: <concise title>' --body 'Closes #${issue}

   ## Changes
   <summary of what you did>

   ## Testing
   <how you verified it works>'

BRANCH: You are on branch '${branch_name}', branched from '${default_branch}'.
Follow the plan. Do not deviate unless you find a clear error in it.
EXECEOF
    [[ -n "$extra_message" ]] && printf '\nADDITIONAL CONTEXT FROM USER:\n%s\n' "$extra_message" >> "$exec_prompt"

    _cw_launch_two_phase "$wt_path" "$plan_prompt" "$exec_prompt" "$session_name"

    echo ""
    _cw_color green "✓ Spawned two-phase agent for issue #${issue}"
    _cw_color dim "  Phase 1:  ${CW_PLAN_MODEL} → plan"
    _cw_color dim "  Phase 2:  ${CW_EXEC_MODEL} → implement"
    _cw_color dim "  Branch:   ${branch_name} (from ${default_branch})"
    _cw_color dim "  Worktree: ${CW_WORKTREE_DIR}/${worktree_name}"
    _cw_color dim "  Session:  ${session_name}"
    echo ""
    _cw_color cyan "  → cw attach ${worktree_name}"
  else
    # Single-phase (original behavior)
    local model="${CW_EXEC_MODEL:-$CW_DEFAULT_MODEL}"
    local prompt_file="${CW_SESSION_DIR}/${session_name}.md"
    cat > "$prompt_file" <<PROMPTEOF
You are working on GitHub issue #${issue} in the ${project} repository.

FIRST STEPS:
1. Read the issue: gh issue view ${issue}
2. Understand the full context, requirements, and acceptance criteria
3. Plan your approach before writing code
4. Implement the fix/feature with appropriate tests
5. Run the test suite to verify nothing is broken
6. When done, create a PR:
   gh pr create --title '${prefix}: <concise title>' --body 'Closes #${issue}

   ## Changes
   <summary of what you did>

   ## Testing
   <how you verified it works>'

BRANCH: You are on branch '${branch_name}', branched from '${default_branch}'.
PROMPTEOF
    [[ -n "$extra_message" ]] && printf '\nADDITIONAL CONTEXT FROM USER:\n%s\n' "$extra_message" >> "$prompt_file"

    # Override model for single-phase if CW_EXEC_MODEL is set
    if [[ -n "$model" ]]; then
      local saved="$CW_DEFAULT_MODEL"
      CW_DEFAULT_MODEL="$model"
      _cw_launch "$wt_path" "$prompt_file" "$session_name"
      CW_DEFAULT_MODEL="$saved"
    else
      _cw_launch "$wt_path" "$prompt_file" "$session_name"
    fi

    echo ""
    _cw_color green "✓ Spawned agent for issue #${issue}"
    [[ -n "$model" ]] && _cw_color dim "  Model:    ${model}"
    _cw_color dim "  Branch:   ${branch_name} (from ${default_branch})"
    _cw_color dim "  Worktree: ${CW_WORKTREE_DIR}/${worktree_name}"
    _cw_color dim "  Session:  ${session_name}"
    echo ""
    _cw_color cyan "  → cw attach ${worktree_name}"
  fi
}

# ---------------------------------------------------------------------------
# Core: Start New Branch
# ---------------------------------------------------------------------------

_cw_start_new() {
  local branch_name=$1; shift
  local extra_message="" base_branch=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -m|--message) extra_message="$2"; shift 2 ;;
      -b|--base)    base_branch="$2";   shift 2 ;;
      *) shift ;;
    esac
  done

  _cw_ensure_deps || return 1
  local root; root=$(_cw_repo_root)
  [[ -z "$root" ]] && { _cw_color red "Not in a git repository."; return 1; }

  local default_branch="${base_branch:-$(_cw_default_branch)}"
  local base_ref; base_ref=$(_cw_resolve_base "$default_branch")
  if [[ $? -ne 0 ]]; then
    _cw_color red "Branch '${default_branch}' not found. Run 'git fetch origin' and retry."
    return 1
  fi

  local worktree_name; worktree_name=$(echo "$branch_name" | sed 's/\//-/g')
  local session_name; session_name=$(_cw_session_name "$worktree_name")
  local project; project=$(_cw_project_name)

  if tmux has-session -t "$session_name" 2>/dev/null; then
    _cw_color yellow "Session already running. Attaching..."
    _cw_tmux_attach "$session_name"
    return 0
  fi

  _cw_color dim "Fetching latest from origin..."
  git fetch origin --quiet 2>/dev/null

  local wt_path="${root}/${CW_WORKTREE_DIR}/${worktree_name}"
  _cw_create_worktree "$wt_path" "$branch_name" "$base_ref" || return 1

  mkdir -p "$CW_SESSION_DIR"
  local prompt_file="${CW_SESSION_DIR}/${session_name}.md"
  cat > "$prompt_file" <<PROMPTEOF
You are working on branch '${branch_name}' in the ${project} repository, branched from '${default_branch}'.

WORKFLOW:
1. Understand the task fully before writing code
2. Implement with clean, idiomatic code matching the project's style
3. Add or update tests for your changes
4. Run the test suite to verify nothing is broken
5. Commit your work with clear, atomic commit messages
6. Push your branch: git push -u origin ${branch_name}
7. When done, create a PR:
   gh pr create --title '<type>: <concise title>' --body '## Changes
   <summary of what you did>

   ## Testing
   <how you verified it works>'
PROMPTEOF
  [[ -n "$extra_message" ]] && printf '\nYOUR TASK:\n%s\n' "$extra_message" >> "$prompt_file"

  _cw_launch "$wt_path" "$prompt_file" "$session_name"

  echo ""
  _cw_color green "✓ Spawned agent for '${branch_name}'"
  _cw_color dim "  Base:     ${default_branch}"
  _cw_color dim "  Worktree: ${CW_WORKTREE_DIR}/${worktree_name}"
  _cw_color dim "  Session:  ${session_name}"
  echo ""
  _cw_color cyan "  → cw attach ${worktree_name}"
}

# ---------------------------------------------------------------------------
# Management: ls, attach, kill, cleanup, dashboard, pr
# ---------------------------------------------------------------------------

_cw_list() {
  local sessions
  sessions=$(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep "^${CW_TMUX_PREFIX}-" | grep -v "\-dashboard$" | sort)

  echo ""

  if [[ -z "$sessions" ]]; then
    _cw_color dim "  No active sessions."
    echo ""
    _cw_color dim "  Start one:"
    _cw_color dim "    cw <issue>          e.g. cw 423"
    _cw_color dim "    cw new <branch>     e.g. cw new feat/auth"
    echo ""
    return 0
  fi

  _cw_color bold "  ⚡ Active Sessions"
  _cw_color dim "  ─────────────────────────────────────────────"
  echo ""

  local root; root=$(_cw_repo_root)
  local idx=0

  while IFS= read -r session; do
    ((idx++))
    local name="${session#${CW_TMUX_PREFIX}-}"

    # Activity / status
    local activity age="" status_icon
    activity=$(tmux display-message -t "$session" -p '#{session_activity}' 2>/dev/null)
    if [[ -n "$activity" ]]; then
      local diff=$(( $(date +%s) - activity ))
      if   (( diff < 60 ));    then age="active now"; status_icon="🟢"
      elif (( diff < 300 ));   then age="$((diff/60))m ago"; status_icon="🟢"
      elif (( diff < 3600 ));  then age="$((diff/60))m ago"; status_icon="🟡"
      else                          age="$((diff/3600))h ago"; status_icon="🔴"
      fi
    else
      age="unknown"; status_icon="⚪"
    fi

    # Branch
    local branch=""
    if [[ -n "$root" ]]; then
      local wt_path="${root}/${CW_WORKTREE_DIR}/${name}"
      [[ -d "$wt_path" ]] && branch=$(git -C "$wt_path" branch --show-current 2>/dev/null)
    fi

    # Issue title (if it's an issue session)
    local title=""
    if [[ "$name" =~ ^issue-([0-9]+)$ ]]; then
      local issue_num="${BASH_REMATCH[1]}"
      title=$(gh issue view "$issue_num" --json title -q '.title' 2>/dev/null | cut -c1-40)
    fi

    # Print entry
    echo -e "  ${status_icon} $(_cw_color bold "$name")"
    [[ -n "$branch" ]] && echo -e "     $(_cw_color dim "⎇") ${branch}"
    [[ -n "$title" ]]  && echo -e "     $(_cw_color dim "↳") ${title}"
    echo -e "     $(_cw_color dim "${age}")"
    echo ""
  done <<< "$sessions"

  _cw_color dim "  ─────────────────────────────────────────────"

  # Show quick commands with the first session name as example
  local first_name
  first_name=$(echo "$sessions" | head -1)
  first_name="${first_name#${CW_TMUX_PREFIX}-}"
  echo -e "  $(_cw_color dim "attach")  cw a ${first_name}"
  echo -e "  $(_cw_color dim "kill")    cw k ${first_name}"
  echo -e "  $(_cw_color dim "all")     cw dash"
  echo ""
}

_cw_attach() {
  local name=$1
  local session_name; session_name=$(_cw_session_name "$name")
  if ! tmux has-session -t "$session_name" 2>/dev/null; then
    local match; match=$(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep "${CW_TMUX_PREFIX}-.*${name}" | head -1)
    [[ -n "$match" ]] && session_name="$match" || { _cw_color red "No session '${name}'. Run 'cw ls'."; return 1; }
  fi
  _cw_tmux_attach "$session_name"
}

_cw_kill() {
  local name=$1
  local session_name; session_name=$(_cw_session_name "$name")
  if ! tmux has-session -t "$session_name" 2>/dev/null; then
    local match; match=$(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep "${CW_TMUX_PREFIX}-.*${name}" | head -1)
    [[ -n "$match" ]] && session_name="$match" || { _cw_color red "No session '${name}'."; return 1; }
  fi
  tmux kill-session -t "$session_name"
  _cw_color green "✓ Killed '${session_name}'"
  _cw_color dim "  Worktree preserved. Run 'cw cleanup' to prune."
}

_cw_cleanup() {
  local root; root=$(_cw_repo_root)
  [[ -z "$root" ]] && { _cw_color red "Not in a git repository."; return 1; }

  local wt_dir="${root}/${CW_WORKTREE_DIR}"
  [[ ! -d "$wt_dir" ]] && { _cw_color dim "No worktrees to clean."; return 0; }

  _cw_color bold "Cleaning up worktrees..."
  echo ""
  local cleaned=0 kept=0

  for wt_path in "$wt_dir"/*/; do
    [[ -d "$wt_path" ]] || continue
    local wt_name; wt_name=$(basename "$wt_path")
    local sn; sn=$(_cw_session_name "$wt_name")

    if tmux has-session -t "$sn" 2>/dev/null; then
      _cw_color yellow "  ⏳ ${wt_name} — session active"; ((kept++)); continue
    fi

    local status; status=$(git -C "$wt_path" status --porcelain 2>/dev/null)
    if [[ -n "$status" ]]; then
      _cw_color yellow "  ⚠  ${wt_name} — uncommitted changes"; ((kept++)); continue
    fi

    local branch; branch=$(git -C "$wt_path" branch --show-current 2>/dev/null)
    if [[ -n "$branch" ]]; then
      local unpushed; unpushed=$(git -C "$wt_path" log "origin/${branch}..${branch}" --oneline 2>/dev/null)
      if [[ -n "$unpushed" ]]; then
        _cw_color yellow "  ⚠  ${wt_name} — unpushed commits"; ((kept++)); continue
      fi
    fi

    git worktree remove "$wt_path" --force 2>/dev/null
    if [[ $? -eq 0 ]]; then
      _cw_color green "  ✓ ${wt_name}"
      rm -f "${CW_SESSION_DIR}/${sn}.md" "${CW_SESSION_DIR}/${sn}.sh" \
           "${CW_SESSION_DIR}/${sn}-plan-prompt.md" "${CW_SESSION_DIR}/${sn}-exec-prompt.md" \
           "${CW_SESSION_DIR}/${sn}-plan.md" 2>/dev/null
      ((cleaned++))
    else
      _cw_color red "  ✗ ${wt_name}"; ((kept++))
    fi
  done

  git worktree prune 2>/dev/null
  echo ""
  _cw_color dim "  Cleaned: ${cleaned}  |  Kept: ${kept}"
}

_cw_dashboard() {
  local sessions
  sessions=$(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep "^${CW_TMUX_PREFIX}-" | grep -v "\-dashboard$" | sort)
  [[ -z "$sessions" ]] && { _cw_color dim "No active sessions."; return 0; }

  local count; count=$(echo "$sessions" | wc -l | tr -d ' ')
  [[ $count -eq 1 ]] && { _cw_tmux_attach "$(echo "$sessions" | head -1)"; return 0; }

  local first; first=$(echo "$sessions" | head -1)
  if [[ -n "${TMUX:-}" ]]; then
    tmux switch-client -t "$first" \; choose-tree -s -f "#{m:${CW_TMUX_PREFIX}-*,#{session_name}}"
  else
    tmux attach -t "$first" \; choose-tree -s -f "#{m:${CW_TMUX_PREFIX}-*,#{session_name}}"
  fi
}

_cw_pr() {
  local name=$1
  local root; root=$(_cw_repo_root)
  [[ -z "$root" ]] && { _cw_color red "Not in a git repository."; return 1; }

  local wt_path="${root}/${CW_WORKTREE_DIR}/${name}"
  if [[ ! -d "$wt_path" ]]; then
    _cw_color red "No worktree '${name}'."
    _cw_color dim "  Available:"
    for d in "${root}/${CW_WORKTREE_DIR}"/*/; do
      [[ -d "$d" ]] && _cw_color dim "    $(basename "$d")"
    done
    return 1
  fi
  (cd "$wt_path" && gh pr create --web)
}

# ---------------------------------------------------------------------------
# Doctor: validate the full setup
# ---------------------------------------------------------------------------

_cw_doctor() {
  echo ""
  _cw_color bold "  cw doctor"
  _cw_color dim "  ─────────────────────────────────────────────"
  echo ""

  local all_ok=true

  # Dependencies
  _cw_color bold "  Dependencies"
  for dep in tmux git gh claude; do
    if command -v "$dep" >/dev/null 2>&1; then
      local ver; ver=$("$dep" --version 2>/dev/null | head -1 || echo "ok")
      _cw_color green "  ✓ $dep ($ver)"
    else
      _cw_color red "  ✗ $dep — not found"
      all_ok=false
    fi
  done
  echo ""

  # GitHub auth
  _cw_color bold "  GitHub"
  if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    _cw_color green "  ✓ Authenticated"
  else
    _cw_color red "  ✗ Not authenticated — run: gh auth login"
    all_ok=false
  fi
  echo ""

  # Claude Code auth
  _cw_color bold "  Claude Code"
  if command -v claude >/dev/null 2>&1; then
    # Check if claude can at least start (we can't fully test auth without API call)
    _cw_color green "  ✓ Installed"
  else
    _cw_color red "  ✗ Not installed"
    all_ok=false
  fi
  echo ""

  # Settings
  _cw_color bold "  Claude Settings"
  local sf="$HOME/.claude/settings.json"
  if [[ -f "$sf" ]]; then
    if grep -q "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS" "$sf" 2>/dev/null; then
      _cw_color green "  ✓ Agent teams enabled"
    else
      _cw_color yellow "  ○ Agent teams not enabled in settings.json"
    fi
    if grep -q "EnterWorktree" "$sf" 2>/dev/null; then
      _cw_color green "  ✓ Worktree permission allowed"
    else
      _cw_color yellow "  ○ EnterWorktree not in permissions.allow"
    fi
    if grep -q "teammateMode" "$sf" 2>/dev/null; then
      _cw_color green "  ✓ Teammate mode configured"
    else
      _cw_color yellow "  ○ teammateMode not set (default: in-process)"
    fi
  else
    _cw_color yellow "  ○ No settings.json — run installer to create"
  fi
  echo ""

  # cw installation
  _cw_color bold "  cw Installation"
  _cw_color green "  ✓ $(_cw_version)"
  if [[ -d "$CW_SESSION_DIR" ]]; then
    _cw_color green "  ✓ Session dir: $CW_SESSION_DIR"
  else
    _cw_color yellow "  ○ Session dir missing — will be created on first use"
  fi
  if [[ -f "$HOME/.cwrc" ]]; then
    _cw_color green "  ✓ Config: ~/.cwrc"
  else
    _cw_color yellow "  ○ No ~/.cwrc (using defaults)"
  fi

  # Planning mode
  if [[ -n "$CW_PLAN_MODEL" && -n "$CW_EXEC_MODEL" ]]; then
    _cw_color green "  ✓ Two-phase: ${CW_PLAN_MODEL} plans → ${CW_EXEC_MODEL} executes"
    _cw_color dim "    Plan labels: ${CW_PLAN_LABELS}"
  elif [[ -n "$CW_DEFAULT_MODEL" ]]; then
    _cw_color dim "  ○ Single model: ${CW_DEFAULT_MODEL}"
  else
    _cw_color dim "  ○ Using Claude Code default model"
  fi
  echo ""

  # Current repo
  _cw_color bold "  Current Repository"
  local root; root=$(_cw_repo_root)
  if [[ -n "$root" ]]; then
    _cw_color green "  ✓ $root"
    local db; db=$(_cw_default_branch)
    _cw_color green "  ✓ Default branch: $db"

    local gitignore="${root}/.gitignore"
    if [[ -f "$gitignore" ]] && grep -q ".claude/worktrees" "$gitignore" 2>/dev/null; then
      _cw_color green "  ✓ .claude/worktrees in .gitignore"
    else
      _cw_color yellow "  ○ Add '.claude/worktrees/' to .gitignore"
    fi
  else
    _cw_color dim "  ○ Not in a git repository"
  fi
  echo ""

  if [[ "$all_ok" == "true" ]]; then
    _cw_color green "  Everything looks good! 🎉"
  else
    _cw_color yellow "  Some issues found. Fix them and run 'cw doctor' again."
  fi
  echo ""
}

# ---------------------------------------------------------------------------
# Update: pull latest from GitHub
# ---------------------------------------------------------------------------

_cw_update() {
  local repo_url="${CW_REPO_URL:-https://raw.githubusercontent.com/vidyasagarr7/cw/main}"

  _cw_color dim "Checking for updates..."

  local remote_version
  remote_version=$(curl -fsSL "${repo_url}/VERSION" 2>/dev/null || echo "")

  local local_version="dev"
  [[ -f "$CW_HOME/version" ]] && local_version=$(cat "$CW_HOME/version")

  if [[ -z "$remote_version" ]]; then
    _cw_color yellow "Could not reach update server. Check your network."
    return 1
  fi

  if [[ "$remote_version" == "$local_version" ]]; then
    _cw_color green "Already on latest version (v${local_version})."
    return 0
  fi

  _cw_color dim "Updating v${local_version} → v${remote_version}..."

  curl -fsSL "${repo_url}/cw.sh" -o "$CW_HOME/cw.sh"
  chmod +x "$CW_HOME/cw.sh"
  echo "$remote_version" > "$CW_HOME/version"

  _cw_color green "✓ Updated to v${remote_version}. Restart your shell to use."
}

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------

_cw_uninstall() {
  echo ""
  _cw_color bold "  Uninstall cw"
  _cw_color dim "  ─────────────────────────────────────────────"
  echo ""

  # Check for active sessions
  local active
  active=$(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep "^${CW_TMUX_PREFIX}-" | grep -v "\-dashboard$" || true)
  if [[ -n "$active" ]]; then
    _cw_color yellow "  Active sessions found:"
    echo "$active" | while read -r s; do echo "    $s"; done
    echo ""
    printf "  Kill all active sessions? [y/N] "
    read -r answer
    if [[ "$answer" =~ ^[Yy] ]]; then
      echo "$active" | while read -r s; do tmux kill-session -t "$s" 2>/dev/null; done
      _cw_color green "  ✓ Sessions killed"
    else
      _cw_color dim "  Sessions left running."
    fi
    echo ""
  fi

  # Confirm
  printf "  Remove cw from your system? [y/N] "
  read -r answer
  if [[ ! "$answer" =~ ^[Yy] ]]; then
    _cw_color dim "  Cancelled."
    return 0
  fi
  echo ""

  # Remove source line from shell rc
  local rc_file
  case "$(basename "${SHELL:-bash}")" in
    zsh)  rc_file="$HOME/.zshrc" ;;
    bash) [[ -f "$HOME/.bashrc" ]] && rc_file="$HOME/.bashrc" || rc_file="$HOME/.bash_profile" ;;
    *)    rc_file="$HOME/.bashrc" ;;
  esac

  if [[ -f "$rc_file" ]]; then
    local tmp; tmp=$(mktemp)
    grep -v "cw\.sh\|cw — Claude Code" "$rc_file" > "$tmp" 2>/dev/null || true
    mv "$tmp" "$rc_file"
    _cw_color green "  ✓ Removed from $rc_file"
  fi

  # Remove cw home (sessions, cw.sh, version)
  if [[ -d "$CW_HOME" ]]; then
    rm -rf "$CW_HOME"
    _cw_color green "  ✓ Removed $CW_HOME"
  fi

  # Ask about config
  if [[ -f "$HOME/.cwrc" ]]; then
    printf "  Remove ~/.cwrc config? [y/N] "
    read -r answer
    if [[ "$answer" =~ ^[Yy] ]]; then
      rm -f "$HOME/.cwrc"
      _cw_color green "  ✓ Removed ~/.cwrc"
    else
      _cw_color dim "  ○ Kept ~/.cwrc"
    fi
  fi

  echo ""
  _cw_color green "  ✓ cw uninstalled."
  _cw_color dim "  Restart your shell to complete."
  _cw_color dim "  Note: Claude Code settings and repo worktrees were not modified."
  _cw_color dim "  To clean worktrees: cd <repo> && git worktree list && git worktree prune"
  echo ""

  # Unset the function so it can't be called again in this session
  unset -f cw _cw_help _cw_list _cw_attach _cw_kill _cw_cleanup _cw_dashboard _cw_pr \
    _cw_start_issue _cw_start_new _cw_launch _cw_create_worktree _cw_doctor _cw_update \
    _cw_uninstall _cw_color _cw_version _cw_ensure_deps _cw_repo_root _cw_project_name \
    _cw_session_name _cw_tmux_attach _cw_default_branch _cw_resolve_base \
    _cw_branch_prefix_from_issue _cw_issue_title_slug 2>/dev/null
}

# ---------------------------------------------------------------------------
# Help
# ---------------------------------------------------------------------------

_cw_help() {
  echo ""
  echo "  cw  $(_cw_version)"
  echo "  GitHub issues on autopilot. One command → branch → agent → PR."
  echo ""
  echo "  USAGE"
  echo "    cw <issue> [-b base] [-m \"context\"]    Spawn agent for a GitHub issue"
  echo "    cw new <branch> [-b base] [-m \"task\"]  Spawn agent for a new branch"
  echo ""
  echo "  MANAGEMENT"
  echo "    cw ls                  List active sessions"
  echo "    cw a[ttach] <name>     Attach to a session"
  echo "    cw k[ill] <name>       Kill a session (worktree kept)"
  echo "    cw cleanup             Remove finished worktrees"
  echo "    cw dash                Session picker"
  echo "    cw pr <name>           Create PR from worktree"
  echo ""
  echo "  SETUP"
  echo "    cw doctor            Check that everything is configured"
  echo "    cw update            Update to the latest version"
  echo "    cw uninstall         Remove cw from your system"
  echo "    cw --version         Show version"
  echo ""
  echo "  OPTIONS"
  echo "    -b, --base <branch>  Base branch (default: auto-detect)"
  echo "    -m, --message <text> Extra context for the agent"
  echo ""
  echo "  EXAMPLES"
  echo "    cw 423                         Work on issue #423"
  echo "    cw 423 -b staging              Branch from staging"
  echo "    cw 423 -m \"focus on auth\"      With extra context"
  echo "    cw new feat/onboarding         New feature branch"
  echo "    cw new fix/db -b develop       Off develop"
  echo ""
  echo "  CONFIG (~/.cwrc)"
  echo "    CW_DEFAULT_MODEL=\"\"             Model (\"sonnet\", \"opus\")"
  echo "    CW_SKIP_PERMISSIONS=\"false\"     Skip prompts"
  echo "    CW_TMUX_PREFIX=\"cw\"             Session prefix"
  echo ""
  echo "  TWO-PHASE PLANNING"
  echo "    CW_PLAN_MODEL=\"opus\"            Opus plans the approach"
  echo "    CW_EXEC_MODEL=\"sonnet\"          Sonnet implements the plan"
  echo "    CW_PLAN_LABELS=\"feature,epic\"   Labels that trigger planning"
  echo "    (Issues without these labels go straight to CW_EXEC_MODEL)"
  echo ""
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

cw() {
  case "${1:-}" in
    ""|help|--help|-h) _cw_help ;;
    -v|--version)      _cw_version ;;
    ls|list)           _cw_list ;;
    doctor|doc)        _cw_doctor ;;
    update|upgrade)    _cw_update ;;
    uninstall)         _cw_uninstall ;;
    attach|a)   [[ -z "${2:-}" ]] && { _cw_color red "Usage: cw attach <n>"; return 1; }; _cw_attach "$2" ;;
    kill|k)     [[ -z "${2:-}" ]] && { _cw_color red "Usage: cw kill <n>"; return 1; };   _cw_kill "$2" ;;
    cleanup|clean|prune) _cw_cleanup ;;
    dash|dashboard)      _cw_dashboard ;;
    pr)         [[ -z "${2:-}" ]] && { _cw_color red "Usage: cw pr <n>"; return 1; };     _cw_pr "$2" ;;
    new)
      [[ -z "${2:-}" ]] && { _cw_color red "Usage: cw new <branch> [-b base] [-m \"task\"]"; return 1; }
      shift; _cw_start_new "$@" ;;
    *)
      if [[ "$1" =~ ^[0-9]+$ ]]; then _cw_start_issue "$@"
      else _cw_color red "Unknown: $1"; _cw_help; return 1
      fi ;;
  esac
}

# Tab completion
if [[ -n "${ZSH_VERSION:-}" ]]; then
  _cw_completions() {
    local -a commands
    commands=('ls:List sessions' 'attach:Attach' 'kill:Kill' 'new:New branch' 'cleanup:Clean'
              'dash:Dashboard' 'pr:Create PR' 'doctor:Check setup' 'update:Update cw'
              'uninstall:Remove cw' 'help:Help')
    if [[ ${#words[@]} -eq 2 ]]; then _describe 'command' commands
    elif [[ ${#words[@]} -eq 3 ]]; then
      case "${words[2]}" in
        attach|a|kill|k|pr)
          local -a sess; sess=($(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep "^${CW_TMUX_PREFIX}-" | sed "s/^${CW_TMUX_PREFIX}-//"))
          _describe 'session' sess ;;
      esac
    fi
  }
  compdef _cw_completions cw
elif [[ -n "${BASH_VERSION:-}" ]]; then
  _cw_bash_comp() {
    local cur="${COMP_WORDS[COMP_CWORD]}" prev="${COMP_WORDS[COMP_CWORD-1]}"
    if [[ $COMP_CWORD -eq 1 ]]; then
      COMPREPLY=($(compgen -W "ls attach kill new cleanup dash pr doctor update uninstall help" -- "$cur"))
    elif [[ $COMP_CWORD -eq 2 ]]; then
      case "$prev" in
        attach|a|kill|k|pr)
          COMPREPLY=($(compgen -W "$(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep "^${CW_TMUX_PREFIX}-" | sed "s/^${CW_TMUX_PREFIX}-//")" -- "$cur")) ;;
      esac
    fi
  }
  complete -F _cw_bash_comp cw
fi
