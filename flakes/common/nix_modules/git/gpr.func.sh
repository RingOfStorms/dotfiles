# gpr - GitHub PR helper commands
# Usage: gpr <command> [args]
#   gpr create  - Create a new PR from current branch
#   gpr update  - Update existing PR description

gpr() {
  local cmd="${1:-}"
  shift 2>/dev/null || true

  case "$cmd" in
    create) gpr_create "$@" ;;
    update) gpr_update "$@" ;;
    -h|--help|help|"")
      cat <<EOF
Usage: gpr <command>

Commands:
  create    Create a new PR from current branch
  update    Update existing PR description

Both commands generate a PR description using LLM based on:
  - Full diff against base branch
  - All commit messages on the branch
  - Opens in \$EDITOR for review before submitting
EOF
      return 0
      ;;
    *)
      echo "Unknown command: $cmd" >&2
      echo "Run 'gpr help' for usage." >&2
      return 1
      ;;
  esac
}

_gpr_check_deps() {
  if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "Not inside a git repository." >&2
    return 1
  fi

  if ! command -v gh >/dev/null 2>&1; then
    echo "Missing dependency: gh (GitHub CLI)" >&2
    return 1
  fi

  if ! command -v curl >/dev/null 2>&1; then
    echo "Missing dependency: curl" >&2
    return 1
  fi

  if ! command -v jq >/dev/null 2>&1; then
    echo "Missing dependency: jq" >&2
    return 1
  fi

  return 0
}

_gpr_get_base_branch() {
  # Try to get the base branch from git config or default to origin default
  local base
  base=$(git config --get init.defaultBranch 2>/dev/null || true)
  if [ -z "$base" ]; then
    base=$(git remote show origin 2>/dev/null | grep "HEAD branch" | sed 's/.*: //' || true)
  fi
  if [ -z "$base" ]; then
    base="main"
  fi
  echo "$base"
}

_gpr_get_current_branch() {
  git rev-parse --abbrev-ref HEAD
}

_gpr_generate_description() {
  local base_branch="$1"
  local existing_description="${2:-}"

  local LITELLM_BASE_URL="http://h001.net.joshuabell.xyz:8094"
  local LITELLM_MODEL="azure-gpt-5-mini-2025-08-07"

  local current_branch
  current_branch=$(_gpr_get_current_branch)

  # Get diff against base branch
  local diff
  diff=$(git diff --no-color --no-ext-diff "${base_branch}...HEAD" 2>/dev/null || git diff --no-color --no-ext-diff "${base_branch}..HEAD" 2>/dev/null || true)

  # Truncate diff if too large
  local max_diff_chars=15000
  diff=$(printf "%s" "$diff" | head -c "$max_diff_chars")

  # Get commit messages
  local commits
  commits=$(git log --oneline "${base_branch}..HEAD" 2>/dev/null || true)

  # Get detailed commit messages
  local commit_details
  commit_details=$(git log --pretty=format:"%h %s%n%b" "${base_branch}..HEAD" 2>/dev/null || true)

  # Get file changes summary
  local files_changed
  files_changed=$(git diff --stat "${base_branch}...HEAD" 2>/dev/null || git diff --stat "${base_branch}..HEAD" 2>/dev/null || true)

  local prompt
  if [ -n "$existing_description" ]; then
    prompt=$(cat <<EOF
Update the following GitHub Pull Request description based on the current state of the branch.
The existing description may be stale - update it to reflect the actual changes.

Current PR description:
${existing_description}

---

Branch: ${current_branch}
Base: ${base_branch}

Commits on this branch:
${commits}

Detailed commit messages:
${commit_details}

Files changed:
${files_changed}

Diff (truncated):
${diff}

---

Generate an updated PR description in Markdown format. Include:
1. A brief summary (2-3 sentences) of what this PR does
2. A bullet list of key changes
3. Any breaking changes or migration notes if applicable

Output ONLY the PR description body (no title, no markdown code fences around the whole thing).
EOF
    )
  else
    prompt=$(cat <<EOF
Generate a GitHub Pull Request description for the following changes.

Branch: ${current_branch}
Base: ${base_branch}

Commits on this branch:
${commits}

Detailed commit messages:
${commit_details}

Files changed:
${files_changed}

Diff (truncated):
${diff}

---

Generate a PR description in Markdown format. Include:
1. A brief summary (2-3 sentences) of what this PR does
2. A bullet list of key changes
3. Any breaking changes or migration notes if applicable

Output ONLY the PR description body (no title, no markdown code fences around the whole thing).
EOF
    )
  fi

  local payload
  payload=$(jq -n \
    --arg model "$LITELLM_MODEL" \
    --arg content "$prompt" \
    '{
      model: $model,
      messages: [
        {
          role: "system",
          content: "You write clear, concise GitHub Pull Request descriptions. Focus on the what and why of changes."
        },
        {
          role: "user",
          content: $content
        }
      ],
      temperature: 0.3,
      max_tokens: 1024
    }')

  local curl_out http_code body
  curl_out=$(curl -sS -w "\n%{http_code}" \
    -X POST "${LITELLM_BASE_URL}/v1/chat/completions" \
    -H "Content-Type: application/json" \
    ${LITELLM_API_KEY:+-H "Authorization: Bearer ${LITELLM_API_KEY}"} \
    -d "$payload") || return 1

  http_code=$(printf "%s" "$curl_out" | tail -n 1)
  body=$(printf "%s" "$curl_out" | sed '$d')

  if [ "$http_code" -lt 200 ] || [ "$http_code" -ge 300 ]; then
    echo "LiteLLM request failed (HTTP $http_code)." >&2
    printf "%s\n" "$body" >&2
    return 1
  fi

  local message
  message=$(printf "%s" "$body" | jq -r '
    .choices[0].message.content
    | if type == "string" then .
      elif type == "array" then (map(select(.type=="text") | .text) | join(""))
      else ""
      end
  ' 2>/dev/null || true)

  if [ -z "$message" ] || [ "$message" = "null" ]; then
    echo "Failed to parse model response." >&2
    printf "%s\n" "$body" >&2
    return 1
  fi

  printf "%s" "$message"
}

_gpr_generate_title() {
  local base_branch="$1"

  local LITELLM_BASE_URL="http://h001.net.joshuabell.xyz:8094"
  local LITELLM_MODEL="azure-gpt-5-mini-2025-08-07"

  local current_branch
  current_branch=$(_gpr_get_current_branch)

  # Get commit messages
  local commits
  commits=$(git log --oneline "${base_branch}..HEAD" 2>/dev/null || true)

  local prompt
  prompt=$(cat <<EOF
Generate a concise GitHub Pull Request title for the following changes.

Branch: ${current_branch}
Commits:
${commits}

Rules:
- Output ONLY the PR title (one line)
- Max 72 characters
- Imperative mood (e.g., "Add feature" not "Added feature")
- No quotes, no trailing period
EOF
  )

  local payload
  payload=$(jq -n \
    --arg model "$LITELLM_MODEL" \
    --arg content "$prompt" \
    '{
      model: $model,
      messages: [
        {
          role: "system",
          content: "You write concise PR titles."
        },
        {
          role: "user",
          content: $content
        }
      ],
      temperature: 0.2,
      max_tokens: 64
    }')

  local curl_out http_code body
  curl_out=$(curl -sS -w "\n%{http_code}" \
    -X POST "${LITELLM_BASE_URL}/v1/chat/completions" \
    -H "Content-Type: application/json" \
    ${LITELLM_API_KEY:+-H "Authorization: Bearer ${LITELLM_API_KEY}"} \
    -d "$payload") || return 1

  http_code=$(printf "%s" "$curl_out" | tail -n 1)
  body=$(printf "%s" "$curl_out" | sed '$d')

  if [ "$http_code" -lt 200 ] || [ "$http_code" -ge 300 ]; then
    echo "LiteLLM request failed (HTTP $http_code)." >&2
    return 1
  fi

  local message
  message=$(printf "%s" "$body" | jq -r '.choices[0].message.content' 2>/dev/null || true)
  message=$(printf "%s" "$message" | sed -n '1p' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

  if [ -z "$message" ] || [ "$message" = "null" ]; then
    # Fallback to branch name
    echo "$current_branch"
    return 0
  fi

  printf "%s" "$message"
}

gpr_create() {
  _gpr_check_deps || return 1

  local current_branch
  current_branch=$(_gpr_get_current_branch)

  local base_branch
  base_branch=$(_gpr_get_base_branch)

  # Check we're not on the default branch
  if [ "$current_branch" = "$base_branch" ]; then
    echo "Cannot create PR from the default branch ($base_branch)." >&2
    echo "Create a feature branch first." >&2
    return 1
  fi

  # Check if PR already exists
  local existing_pr
  existing_pr=$(gh pr view --json number,url 2>/dev/null || true)
  if [ -n "$existing_pr" ]; then
    local pr_url
    pr_url=$(printf "%s" "$existing_pr" | jq -r '.url')
    echo "A PR already exists for this branch: $pr_url" >&2
    echo "Use 'gpr update' to update the description instead." >&2
    return 1
  fi

  # Check if branch is pushed to remote
  local remote_branch
  remote_branch=$(git rev-parse --abbrev-ref --symbolic-full-name @{u} 2>/dev/null || true)
  if [ -z "$remote_branch" ]; then
    echo "Branch not pushed to remote. Pushing now..."
    git push -u origin "$current_branch" || return 1
  fi

  echo "Generating PR description with LLM..."
  local description
  description=$(_gpr_generate_description "$base_branch") || return 1

  echo "Generating PR title..."
  local title
  title=$(_gpr_generate_title "$base_branch") || return 1

  # Create temp file for editing
  local tmpfile
  tmpfile=$(mktemp --suffix=.md)
  trap "rm -f '$tmpfile'" EXIT

  cat > "$tmpfile" <<EOF
${title}
---
${description}
EOF

  echo "Opening editor for review..."
  ${EDITOR:-vi} "$tmpfile"

  # Check if user saved (file not empty after title line)
  if [ ! -s "$tmpfile" ]; then
    echo "Aborted: empty file." >&2
    return 1
  fi

  # Parse title (first line) and body (after ---)
  local final_title final_body
  final_title=$(head -n 1 "$tmpfile")
  final_body=$(tail -n +3 "$tmpfile")

  if [ -z "$final_title" ]; then
    echo "Aborted: no title provided." >&2
    return 1
  fi

  echo "Creating PR..."
  gh pr create --title "$final_title" --body "$final_body" --base "$base_branch"
}

gpr_update() {
  _gpr_check_deps || return 1

  local current_branch
  current_branch=$(_gpr_get_current_branch)

  local base_branch
  base_branch=$(_gpr_get_base_branch)

  # Check if PR exists
  local existing_pr
  existing_pr=$(gh pr view --json number,title,body,url 2>/dev/null || true)
  if [ -z "$existing_pr" ]; then
    echo "No PR exists for this branch." >&2
    echo "Use 'gpr create' to create one first." >&2
    return 1
  fi

  local pr_url pr_title pr_body
  pr_url=$(printf "%s" "$existing_pr" | jq -r '.url')
  pr_title=$(printf "%s" "$existing_pr" | jq -r '.title')
  pr_body=$(printf "%s" "$existing_pr" | jq -r '.body')

  echo "Updating PR: $pr_url"
  echo "Generating updated description with LLM..."

  local description
  description=$(_gpr_generate_description "$base_branch" "$pr_body") || return 1

  # Create temp file for editing
  local tmpfile
  tmpfile=$(mktemp --suffix=.md)
  trap "rm -f '$tmpfile'" EXIT

  cat > "$tmpfile" <<EOF
${pr_title}
---
${description}
EOF

  echo "Opening editor for review..."
  ${EDITOR:-vi} "$tmpfile"

  # Check if user saved
  if [ ! -s "$tmpfile" ]; then
    echo "Aborted: empty file." >&2
    return 1
  fi

  # Parse title and body
  local final_title final_body
  final_title=$(head -n 1 "$tmpfile")
  final_body=$(tail -n +3 "$tmpfile")

  if [ -z "$final_title" ]; then
    echo "Aborted: no title provided." >&2
    return 1
  fi

  echo "Updating PR..."
  gh pr edit --title "$final_title" --body "$final_body"

  echo "PR updated: $pr_url"
}
