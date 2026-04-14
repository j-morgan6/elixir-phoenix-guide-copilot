#!/usr/bin/env bash
# elixir-hook.sh — Elixir/Phoenix guard hooks for Copilot plugin
#
# Called by Copilot's PreToolUse/PostToolUse hooks (configured in hooks.json).
# Receives hook JSON on stdin, runs Elixir/Phoenix code checks.
#
# Usage: echo '{"tool_input":{"command":"..."}}' | elixir-hook.sh <pre|post> <bash|edit>
#
# Exit codes:
#   0 — Allow (with optional advisory message on stderr)
#   2 — Deny (block the tool call in PreToolUse context)

set -uo pipefail

PHASE="${1:-}"
TYPE="${2:-}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Exit early if missing arguments
[ -n "$PHASE" ] && [ -n "$TYPE" ] || exit 0

# Read hook input from stdin
INPUT=$(cat)

# Detect jq availability
HAS_JQ=false
command -v jq > /dev/null 2>&1 && HAS_JQ=true

# Extract fields from hook JSON
extract_json_field() {
  local field="$1"
  if [ "$HAS_JQ" = "true" ]; then
    echo "$INPUT" | jq -r "$field" 2>/dev/null || echo ""
  else
    # Pure bash fallback — basic extraction
    local tmp="${INPUT#*\"${field##*.}\"}"
    tmp="${tmp#*:}"
    tmp="${tmp#*\"}"
    echo "${tmp%%\"*}"
  fi
}

TOOL_ARGS=$(extract_json_field '.tool_input // .toolArgs')
CWD=$(extract_json_field '.cwd // ""')

# Use CWD from JSON if available, fall back to PWD
PROJECT_DIR="${CWD:-$PWD}"

# --- Lazy project detection ---
CACHE_FILE="$PROJECT_DIR/.elixir-phoenix-guide-project.json"
if [ ! -f "$CACHE_FILE" ] && [ -f "$PLUGIN_ROOT/scripts/detect_project.sh" ]; then
  (cd "$PROJECT_DIR" && bash "$PLUGIN_ROOT/scripts/detect_project.sh" 2>/dev/null) || true
fi

# Read project cache for context-aware checks
HAS_LV='true'
HAS_SCOPE='false'
if [ -f "$CACHE_FILE" ]; then
  HAS_LV=$(grep -o '"has_liveview":\s*[a-z]*' "$CACHE_FILE" 2>/dev/null | grep -o '[a-z]*$' || echo 'true')
  HAS_SCOPE=$(grep -o '"phoenix_has_scope":\s*[a-z]*' "$CACHE_FILE" 2>/dev/null | grep -o '[a-z]*$' || echo 'false')
fi

# ============================================================
# PreToolUse — Bash checks
# ============================================================
check_bash_pre() {
  local cmd
  if [ "$HAS_JQ" = "true" ]; then
    cmd=$(echo "$TOOL_ARGS" | jq -r '.command // ""' 2>/dev/null || echo "")
  else
    local tmp="${TOOL_ARGS#*\"command\"}"
    tmp="${tmp#*:}"; tmp="${tmp#*\"}"; cmd="${tmp%%\"*}"
  fi
  [ -n "$cmd" ] || exit 0

  # Hook 1: Block mix ecto.reset
  if echo "$cmd" | grep -qE 'mix\s+ecto\.reset'; then
    echo '{"permissionDecision":"deny","permissionDecisionReason":"Dangerous: mix ecto.reset destroys and recreates the database. Use mix ecto.rollback for safe rollbacks."}'
    exit 2
  fi

  # Hook 2: Block force push
  if echo "$cmd" | grep -qE 'git\s+push\s+.*(-f|--force)'; then
    echo '{"permissionDecision":"deny","permissionDecisionReason":"Dangerous: Force push overwrites remote history. Use --force-with-lease for safer force pushes."}'
    exit 2
  fi

  # Hook 3: Block MIX_ENV=prod
  if echo "$cmd" | grep -qE 'MIX_ENV=prod'; then
    echo '{"permissionDecision":"deny","permissionDecisionReason":"Dangerous: Running with MIX_ENV=prod locally risks unintended production effects."}'
    exit 2
  fi

  exit 0
}

# ============================================================
# PreToolUse — Write/Edit checks
# ============================================================
check_edit_pre() {
  local file_path
  if [ "$HAS_JQ" = "true" ]; then
    file_path=$(echo "$TOOL_ARGS" | jq -r '.file_path // ""' 2>/dev/null || echo "")
  else
    local tmp="${TOOL_ARGS#*\"file_path\"}"
    tmp="${tmp#*:}"; tmp="${tmp#*\"}"; file_path="${tmp%%\"*}"
  fi
  [ -n "$file_path" ] || exit 0

  local ext="${file_path##*.}"
  local is_test=false
  echo "$file_path" | grep -qE '_test\.exs$|/test/' && is_test=true

  # Only check Elixir/HEEx files
  case "$ext" in
    ex|exs|heex) ;;
    *) exit 0 ;;
  esac

  # Get file content (new_string for Edit, content for Write, or read existing file)
  local content=""
  if [ "$HAS_JQ" = "true" ]; then
    content=$(echo "$TOOL_ARGS" | jq -r '.new_string // .content // ""' 2>/dev/null || echo "")
  fi
  # Fallback: read the file if we couldn't get content from toolArgs
  if [ -z "$content" ] && [ -f "$file_path" ]; then
    content=$(cat "$file_path" 2>/dev/null || echo "")
  fi
  [ -n "$content" ] || exit 0

  # Strip comments for analysis
  local filtered
  filtered=$(echo "$content" | grep -v '^\s*#' || echo "$content")

  # --- Blocking checks (exit 2) ---

  # Hook: Missing @impl true before callbacks
  if [ "$HAS_LV" != 'false' ]; then
    if echo "$filtered" | grep -qE 'def\s+(mount|handle_event|handle_info|handle_call|handle_cast|render|init|terminate)\(' \
       && ! echo "$filtered" | grep -E -B1 'def\s+(mount|handle_event|handle_info|handle_call|handle_cast|render|init|terminate)\(' | grep -q '@impl'; then
      echo '{"permissionDecision":"deny","permissionDecisionReason":"Missing @impl true before callback function. Add @impl true on the line before each callback."}'
      exit 2
    fi
  fi

  # Hook: Hardcoded file paths
  if grep -qE '(upload_path|file_path|uploads_dir)\s*=\s*["'"'"'](/|priv/)' <<< "$content" 2>/dev/null; then
    echo '{"permissionDecision":"deny","permissionDecisionReason":"Hardcoded file path detected. Move to Application config: config :my_app, :upload_path, priv/static/uploads"}'
    exit 2
  fi

  # Hook: Hardcoded file size limits
  if grep -qE '(max_file_size|file_size_limit|max_upload|max_size)\s*=\s*[0-9]{7,}' <<< "$content" 2>/dev/null; then
    echo '{"permissionDecision":"deny","permissionDecisionReason":"Hardcoded file size limit detected (7+ digits). Move to Application config."}'
    exit 2
  fi

  # Hook: Block String.to_atom/1 (security — not in test files)
  if [ "$is_test" = "false" ] && [ "$ext" != "heex" ]; then
    if grep -qE 'String\.to_atom\(' <<< "$content" 2>/dev/null; then
      echo '{"permissionDecision":"deny","permissionDecisionReason":"String.to_atom/1 detected — atom table exhaustion risk! Use a whitelist or keep as strings."}'
      exit 2
    fi
  fi

  # Hook: Block SQL injection in fragment
  if [ "$is_test" = "false" ] && [ "$ext" != "heex" ]; then
    if grep -qE 'fragment\(".*#\{' <<< "$content" 2>/dev/null; then
      echo '{"permissionDecision":"deny","permissionDecisionReason":"String interpolation inside Ecto fragment — SQL injection risk! Use parameterized fragments with ? placeholders."}'
      exit 2
    fi
  fi

  # Hook: Block open redirect
  if [ "$is_test" = "false" ] && [ "$ext" != "heex" ]; then
    if grep -qE 'redirect\(.*to:\s*(params|conn\.params|socket\.assigns)\[' <<< "$content" 2>/dev/null; then
      echo '{"permissionDecision":"deny","permissionDecisionReason":"Open redirect detected — redirecting to user-controlled URL! Validate against a whitelist or use verified routes."}'
      exit 2
    fi
  fi

  # Hook: Block deprecated Phoenix components
  if grep -qE '<\.(flash_group|flash)' <<< "$content" 2>/dev/null; then
    echo '{"permissionDecision":"deny","permissionDecisionReason":".flash_group is deprecated in Phoenix 1.8+. Flash handling is automatic in layouts."}'
    exit 2
  fi
  if grep -qE 'form_for\(' <<< "$content" 2>/dev/null; then
    echo '{"permissionDecision":"deny","permissionDecisionReason":"form_for is deprecated. Use <.form for={to_form(@changeset)}> instead."}'
    exit 2
  fi
  if grep -qE 'live_redirect|live_patch' <<< "$content" 2>/dev/null; then
    echo '{"permissionDecision":"deny","permissionDecisionReason":"live_redirect/live_patch are deprecated. Use <.link navigate={path}> or push_navigate/push_patch."}'
    exit 2
  fi
  if [ "$HAS_SCOPE" = 'true' ] && grep -qE '@current_user|current_user' <<< "$content" 2>/dev/null \
     && ! grep -qE '@current_scope|current_scope' <<< "$content" 2>/dev/null; then
    echo '{"permissionDecision":"deny","permissionDecisionReason":"Phoenix 1.8+ detected: Use @current_scope instead of @current_user. Access user via @current_scope.user"}'
    exit 2
  fi

  # Hook: Block static_paths mismatch
  if grep -qE 'def static_paths' <<< "$content" 2>/dev/null; then
    local paths
    paths=$(echo "$content" | grep -A10 'def static_paths' | grep -oE '"[^"]+"' | tr -d '"' | tr '\n' ' ')
    local refs
    refs=$(echo "$content" | grep -hoE '/[a-z_]+/' | sort -u | tr -d '/' | tr '\n' ' ')
    for ref in $refs; do
      if ! echo " $paths " | grep -qw "$ref"; then
        echo "{\"permissionDecision\":\"deny\",\"permissionDecisionReason\":\"Path reference '/$ref/' found but '$ref' not in static_paths(). Add it to your static_paths definition.\"}"
        exit 2
      fi
    done
  fi

  # Hook: Block raw SQL with string interpolation (moved from PostToolUse)
  if [ "$is_test" = "false" ] && [ "$ext" != "heex" ]; then
    if grep -qE 'Ecto\.Adapters\.SQL\.(query|query!)|SQL\.query' <<< "$content" 2>/dev/null; then
      if echo "$content" | grep -qE '".*#\{.*\}.*"|".*\$\{.*\}.*"' || echo "$content" | grep -qE 'query.*<>|<>.*query'; then
        echo '{"permissionDecision":"deny","permissionDecisionReason":"Raw SQL with string interpolation detected — SQL injection risk! Use parameterized queries ($1, $2, ...)."}'
        exit 2
      fi
    fi
  fi

  # --- Warning checks (exit 0 with message) ---

  # Hook: Nested if/else
  local collapsed
  collapsed=$(echo "$content" | tr '\n' ' ')
  if echo "$collapsed" | grep -qE 'if\s+[^d]+\s+do\s+[^e]*if\s+[^d]+\s+do'; then
    echo 'Warning: Nested if/else detected. Replace with case or multi-clause function.' >&2
  fi

  # Hook: Inefficient Enum chains
  if echo "$collapsed" | grep -qE '\|>\s*Enum\.(map|filter)\([^)]+\)\s*\|>\s*Enum\.(map|filter)\('; then
    echo 'Warning: Multiple Enum.map/filter chain detected. Use a for comprehension or combine into one pass.' >&2
  fi

  # Hook: String concatenation in loops
  if grep -qE 'Enum\.(map|reduce|each).*<>' <<< "$content" 2>/dev/null; then
    echo 'Warning: String concatenation with <> in Enum operations. Use IO lists or Enum.join.' >&2
  fi

  # Hook: auto_upload warning
  if [ "$HAS_LV" != 'false' ] && grep -qE 'auto_upload:\s*true' <<< "$content" 2>/dev/null; then
    echo 'Warning: auto_upload: true detected. Requires handle_progress/3. Most apps should use manual upload.' >&2
  fi

  # Hook: Debug statements (not in test files)
  if [ "$is_test" = "false" ] && [ "$ext" != "heex" ]; then
    if grep -qE 'IO\.inspect\(|dbg\(|IO\.puts\(' <<< "$content" 2>/dev/null; then
      echo 'Warning: Debug statement detected (IO.inspect, dbg, or IO.puts). Remove before committing.' >&2
    fi
  fi

  # Hook: Migration safety check
  if echo "$file_path" | grep -qE 'migrations/.*\.exs$'; then
    local issues=""
    if echo "$content" | grep -qE 'references\(' && ! echo "$content" | grep -qE 'create\s+(unique_)?index'; then
      issues="${issues}\n   - Missing index on foreign key column(s)"
    fi
    if echo "$content" | grep -qE 'references\(' && ! echo "$content" | grep -qE 'on_delete:'; then
      issues="${issues}\n   - Missing on_delete strategy on references()"
    fi
    if echo "$content" | grep -qE 'remove\s+:' && ! echo "$content" | grep -qE '#.*safety|#.*two-step|#.*deploy'; then
      issues="${issues}\n   - Removing column without safety comment. Use a two-step migration."
    fi
    if echo "$content" | grep -qE 'modify.*null:\s*false' && ! echo "$content" | grep -qE 'default:'; then
      issues="${issues}\n   - Adding NOT NULL without default. This locks the table on large datasets."
    fi
    if [ -n "$issues" ]; then
      echo -e "Warning: Migration Safety Check:$issues" >&2
    fi
  fi

  # Hook: Warn on raw/1 (XSS) — not in test files
  if [ "$is_test" = "false" ]; then
    if grep -qE '(^|[^a-zA-Z_])raw\(|Phoenix\.HTML\.raw\(' <<< "$content" 2>/dev/null; then
      echo 'Warning: raw/1 detected — XSS risk! Remove raw/1 and let Phoenix auto-escape, or sanitize with HtmlSanitizeEx.' >&2
    fi
  fi

  # Hook: Sensitive data in Logger
  if [ "$is_test" = "false" ] && [ "$ext" != "heex" ]; then
    if grep -qE 'Logger\.(info|warn|warning|error|debug|notice)\(.*\b(password|token|secret|api_key|credentials|private_key)\b' <<< "$content" 2>/dev/null; then
      echo 'Warning: Sensitive data in Logger call detected! Redact before logging.' >&2
    fi
  fi

  # Hook: Timing-unsafe comparison
  if [ "$is_test" = "false" ] && [ "$ext" != "heex" ]; then
    if grep -qE '(token|secret|api_key|password_hash|digest|signature)\s*==\s*|==\s*(token|secret|api_key|password_hash|digest|signature)' <<< "$content" 2>/dev/null; then
      echo 'Warning: Timing-unsafe comparison with secret/token! Use Plug.Crypto.secure_compare/2.' >&2
    fi
  fi

  exit 0
}

# ============================================================
# PostToolUse — Write/Edit checks (advisory only)
# ============================================================
check_edit_post() {
  local file_path
  if [ "$HAS_JQ" = "true" ]; then
    file_path=$(echo "$TOOL_ARGS" | jq -r '.file_path // ""' 2>/dev/null || echo "")
  else
    local tmp="${TOOL_ARGS#*\"file_path\"}"
    tmp="${tmp#*:}"; tmp="${tmp#*\"}"; file_path="${tmp%%\"*}"
  fi
  [ -n "$file_path" ] || exit 0

  local ext="${file_path##*.}"
  local is_test=false
  echo "$file_path" | grep -qE '_test\.exs$|/test/' && is_test=true

  # Hook: Skill invocation reminder (Elixir/HEEx files only)
  case "$ext" in
    ex|exs|heex)
      if [ "$HAS_LV" = 'false' ]; then
        echo 'Reminder: API-only project detected (no LiveView). LiveView skills/hooks are inactive. Did you invoke the relevant elixir-phoenix-guide skill?' >&2
      else
        echo 'Reminder: Did you invoke the relevant elixir-phoenix-guide skill before writing this file? If not, invoke it now and verify your code follows the rules.' >&2
      fi
      ;;
  esac

  # Hook: mix.exs security audit reminder
  if echo "$file_path" | grep -qE 'mix\.exs$'; then
    echo 'Dependencies file (mix.exs) modified. Consider running: mix deps.audit, mix hex.audit, mix sobelow' >&2
  fi

  # Hook: Template duplication (HEEx files)
  if [ "$ext" = "heex" ] && [ -f "$PLUGIN_ROOT/scripts/detect_template_duplication.sh" ]; then
    bash "$PLUGIN_ROOT/scripts/detect_template_duplication.sh" "$file_path" 2>/dev/null || true
    exit 0
  fi

  # Only continue for .ex/.exs files
  case "$ext" in
    ex|exs) ;;
    *) exit 0 ;;
  esac

  local content=""
  [ -f "$file_path" ] && content=$(cat "$file_path" 2>/dev/null || echo "")
  [ -n "$content" ] || exit 0

  # Hook: Code quality analysis (if Elixir is available)
  if command -v elixir >/dev/null 2>&1 && [ -f "$PLUGIN_ROOT/scripts/code_quality.exs" ]; then
    elixir "$PLUGIN_ROOT/scripts/code_quality.exs" all "$file_path" 2>/dev/null || true
  fi

  # Hook: Missing preload warning (not in test files)
  if [ "$is_test" = "false" ]; then
    if echo "$content" | grep -qE '\.(posts|comments|users|items|entries|tasks|categories|tags|orders|products|messages|notifications|accounts|roles|permissions|memberships|addresses|invoices|images|attachments|events|sessions|tokens)\b' \
       && ! echo "$content" | grep -qE 'preload|Repo\.preload|from.*preload|join.*assoc'; then
      echo 'Warning: Possible missing preload — association accessor found without a visible preload.' >&2
    fi
  fi

  # Hook: with missing else clause
  if echo "$content" | grep -qE 'with\s' && ! echo "$content" | grep -qE 'with.*do.*else|else\s*do'; then
    local collapsed
    collapsed=$(echo "$content" | tr '\n' ' ')
    if echo "$collapsed" | grep -qE 'with\s+[^}]+<-[^}]+do\s+[^}]+end' \
       && ! echo "$collapsed" | grep -qE 'with\s+[^}]+<-[^}]+do\s+[^}]+else[^}]+end'; then
      echo 'Warning: with statement without else clause. Add an else clause to handle errors.' >&2
    fi
  fi

  # Hook: Repo calls in LiveView (context boundary violation)
  if [ "$HAS_LV" != 'false' ]; then
    if echo "$file_path" | grep -qE '_live\.ex$|_live/|live/'; then
      if grep -qE 'Repo\.(all|one|get|get!|get_by|insert|update|delete|aggregate|exists\?|preload)' <<< "$content" 2>/dev/null; then
        echo 'Warning: Context boundary violation — Repo called directly in a LiveView module. Use context functions instead.' >&2
      fi
    fi
  fi

  exit 0
}

# --- Route to appropriate checks ---
case "${PHASE}_${TYPE}" in
  pre_bash)   check_bash_pre ;;
  pre_edit)   check_edit_pre ;;
  post_edit)  check_edit_post ;;
  *)          exit 0 ;;
esac
