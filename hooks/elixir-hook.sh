#!/usr/bin/env bash
# elixir-hook.sh - Elixir/Phoenix guard hooks for the Copilot edition of
# elixir-phoenix-guide. Configured in .github/hooks/elixir-guard.json.
# Port of the Claude Code plugin's scripts/hooks/bash_guard.sh and
# check_file.sh; elixir-hook.ps1 is the PowerShell twin and must stay
# behaviourally identical (tests/run_tests.sh runs against both).
#
# Usage: <hook JSON on stdin> | elixir-hook.sh <pre|post> <bash|edit>
#   pre bash   block destructive commands (Elixir projects only)
#   pre edit   block near-certain bugs in the text about to be written
#   post edit  review notes on the lines just written
#
# Input: Copilot's {"cwd", "toolArgs"} (object or JSON string) or the
# VS Code-compatible {"cwd", "tool_input"}. Edit arguments are read from
# file_path|filePath|path and new_string|newString|new_str (edits),
# content|file_text (whole-file writes), plus a MultiEdit-style edits[].
#
# Output contract:
#   deny     {"permissionDecision":"deny","permissionDecisionReason":"..."}
#            on stdout, exit 2 (preToolUse only)
#   advisory {"additionalContext":"..."} on stdout, exit 0 (postToolUse only;
#            Copilot ignores additionalContext from preToolUse)
#   nothing  exit 0, no output
# A preToolUse hook that exits non-zero for any other reason denies the tool
# call, so this script never uses set -e/-u and fails open (exit 0) on bad
# input, a missing jq, or an internal error. Must run on macOS /bin/bash 3.2.

PHASE="${1:-}"
TYPE="${2:-}"
[ -n "$PHASE" ] && [ -n "$TYPE" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

INPUT=$(cat)
[ -n "$INPUT" ] || exit 0
ARGS=$(printf '%s' "$INPUT" | jq -c '
  (.tool_input // .toolArgs // {})
  | if type == "string" then (try fromjson catch {}) else . end
  | if type == "object" then . else {} end' 2>/dev/null) || exit 0
[ -n "$ARGS" ] || exit 0
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty | strings' 2>/dev/null)
if [ -z "$CWD" ] || [ ! -d "$CWD" ]; then CWD="$PWD"; fi

TMPD=""
# shellcheck disable=SC2329 # invoked by the EXIT trap
cleanup() { [ -n "$TMPD" ] && rm -rf "$TMPD"; }
trap cleanup EXIT

deny() {
  jq -cn --arg r "$1" '{permissionDecision: "deny", permissionDecisionReason: $r}'
  exit 2
}

advise() {
  jq -cn --arg c "$1" '{additionalContext: $c}'
  exit 0
}

# Nearest ancestor of $1 (inclusive) that is an Elixir project: has mix.exs,
# or is an umbrella-style root with apps/*/mix.exs. An umbrella child
# (.../apps/<name>) resolves to the umbrella root.
find_project_root() {
  local dir="$1" f parent
  while [ -n "$dir" ] && [ "$dir" != "/" ] && [ "$dir" != "." ]; do
    if [ -f "$dir/mix.exs" ]; then
      parent=$(dirname "$dir")
      if [ "$(basename "$parent")" = apps ] && [ -f "$(dirname "$parent")/mix.exs" ]; then
        dir=$(dirname "$parent")
      fi
      echo "$dir"
      return 0
    fi
    for f in "$dir"/apps/*/mix.exs; do
      [ -f "$f" ] && { echo "$dir"; return 0; }
    done
    dir=$(dirname "$dir")
  done
  return 1
}

# ============================================================================
# pre bash - destructive commands
#   mix ecto.reset / mix ecto.drop, unless MIX_ENV=test for that command
#   git push --force / -f / combined short flags with f / +refspec
#   (--force-with-lease and --force-if-includes are allowed)
# Opt-out: EPG_ALLOW=force_push,ecto_reset,ecto_drop in the hook's
# environment, exported earlier in the same command line, or as a prefix.
# The command is split on ; && || | & ( ) $( ` and newlines; quoted text,
# comments and heredoc bodies are ignored. Known limits: bash -c/eval
# strings, aliases, functions, $(...) inside double quotes.
# ============================================================================
has_allow() { # $1 = token, $2.. = comma lists
  local tok="$1" list
  shift
  for list in "$@"; do
    case ",$list," in *",$tok,"*|*",all,"*) return 0 ;; esac
  done
  return 1
}

block_cmd() {
  deny "elixir-phoenix-guide blocked this command: $1"
}

check_segment() {
  local seg_env="" seg_allow="" w name val cmd sub a cluster env tok task
  while [ $# -gt 0 ]; do
    w="$1"
    case "$w" in
      *=*)
        name="${w%%=*}"; val="${w#*=}"
        case "$name" in
          ''|[0-9]*|*[!A-Za-z0-9_]*) break ;;
        esac
        [ "$name" = MIX_ENV ] && seg_env="$val"
        [ "$name" = EPG_ALLOW ] && seg_allow="$val"
        shift ;;
      env)
        shift
        while [ $# -gt 0 ]; do
          case "$1" in
            -u|-C|-S) shift; [ $# -gt 0 ] && shift ;;
            -*) shift ;;
            *) break ;;
          esac
        done ;;
      '{'|'}'|'!'|if|then|else|elif|do|while|until|time|nohup|command|exec|builtin|sudo|xargs) shift ;;
      *) break ;;
    esac
  done
  [ $# -gt 0 ] || return 0
  cmd="${1##*/}"; shift

  case "$cmd" in
    export)
      for a in "$@"; do
        case "$a" in
          MIX_ENV=*) EXP_MIX_ENV="${a#MIX_ENV=}" ;;
          EPG_ALLOW=*) EXP_ALLOW="${a#EPG_ALLOW=}" ;;
        esac
      done ;;
    mix)
      while [ $# -gt 0 ]; do case "$1" in -*) shift ;; *) break ;; esac; done
      [ $# -gt 0 ] || return 0
      if [ "$1" = "do" ]; then
        shift
        set -f
        # shellcheck disable=SC2046 # split "a, b + c" into task words
        set -- $(printf '%s\n' "$*" | tr ',+' '  ')
        set +f
      else
        set -- "$1"
      fi
      env="${seg_env:-${EXP_MIX_ENV:-${HOOK_MIX_ENV:-dev}}}"
      for task in "$@"; do
        case "$task" in
          ecto.reset|ecto.drop)
            [ "$env" = test ] && continue
            tok=ecto_reset; [ "$task" = ecto.drop ] && tok=ecto_drop
            has_allow "$tok" "$seg_allow" "$EXP_ALLOW" "$HOOK_ALLOW" && continue
            block_cmd "\`mix $task\` drops the $env database and all of its data. For the test database run \`MIX_ENV=test mix $task\`; for schema changes use \`mix ecto.rollback\` / \`mix ecto.migrate\`. If the user explicitly asked for this, re-run it prefixed with \`EPG_ALLOW=$tok\`."
            ;;
        esac
      done ;;
    git)
      while [ $# -gt 0 ]; do
        case "$1" in
          -C|-c|--git-dir|--work-tree|--namespace|--config-env|--exec-path|--super-prefix) shift; [ $# -gt 0 ] && shift ;;
          -*) shift ;;
          *) break ;;
        esac
      done
      [ $# -gt 0 ] || return 0
      sub="$1"; shift
      [ "$sub" = push ] || return 0
      for a in "$@"; do
        case "$a" in
          --force-with-lease|--force-with-lease=*|--force-if-includes) ;;
          --force) force=1 ;;
          --*) ;;
          -?*)
            cluster="${a#-}"; cluster="${cluster%%o*}"   # -o takes an argument
            case "$cluster" in *f*) force=1 ;; esac ;;
          +?*) force=1 ;;
        esac
      done
      if [ "${force:-0}" = 1 ]; then
        has_allow force_push "$seg_allow" "$EXP_ALLOW" "$HOOK_ALLOW" && return 0
        block_cmd "force push (--force, -f or a +refspec) overwrites remote history. Use \`git push --force-with-lease\` instead. If the user explicitly asked for a force push, re-run it prefixed with \`EPG_ALLOW=force_push\`."
      fi ;;
  esac
  return 0
}

check_bash_pre() {
  local cmd segments seg
  cmd=$(printf '%s' "$ARGS" | jq -r '.command // empty | strings' 2>/dev/null)
  [ -n "$cmd" ] || exit 0
  find_project_root "$CWD" >/dev/null || exit 0

  # One segment per output line. Inside quotes, whitespace and shell
  # metacharacters become "_" so quoted text stays a single inert word.
  segments=$(printf '%s' "$cmd" | awk '
{ s = (NR > 1) ? s "\n" $0 : $0 }
END {
  L = length(s); out = ""; st = 0; nhd = 0
  for (i = 1; i <= L; i++) {
    c = substr(s, i, 1)
    if (st == 1) {
      if (c == "\047") st = 0
      else out = out ((c ~ /[[:space:];&|()<>`$]/) ? "_" : c)
      continue
    }
    if (st == 2) {
      if (c == "\\") { i++; out = out "_"; continue }
      if (c == "\"") st = 0
      else out = out ((c ~ /[[:space:];&|()<>`$]/) ? "_" : c)
      continue
    }
    if (c == "\\") {
      i++; n2 = substr(s, i, 1)
      out = out ((n2 == "\n") ? " " : ((n2 ~ /[[:space:]]/) ? "_" : n2))
      continue
    }
    if (c == "\047") { st = 1; continue }
    if (c == "\"") { st = 2; continue }
    if (c == "#" && (i == 1 || substr(s, i - 1, 1) ~ /[[:space:];&|()]/)) {
      while (i <= L && substr(s, i + 1, 1) != "\n") i++
      continue
    }
    if (c == "<" && substr(s, i + 1, 1) == "<" && substr(s, i + 2, 1) != "<") {
      j = i + 2
      if (substr(s, j, 1) == "-") j++
      while (substr(s, j, 1) ~ /[ \t]/) j++
      w = ""
      while (j <= L && substr(s, j, 1) !~ /[[:space:];&|()<>]/) { w = w substr(s, j, 1); j++ }
      gsub(/[\047"\\]/, "", w)
      if (w != "") hd[++nhd] = w
      i = j - 1
      out = out " "
      continue
    }
    if (c == "\n") {
      out = out "\n"
      if (nhd > 0) {
        pos = i + 1
        for (h = 1; h <= nhd; h++) {
          while (pos <= L) {
            rest = substr(s, pos); e = index(rest, "\n")
            if (e == 0) { t = rest; pos = L + 1 } else { t = substr(rest, 1, e - 1); pos += e }
            sub(/^[[:space:]]+/, "", t); sub(/[[:space:]]+$/, "", t)
            if (t == hd[h]) break
          }
        }
        nhd = 0; i = pos - 1
      }
      continue
    }
    if (c == "&") {
      p = substr(s, i - 1, 1); q = substr(s, i + 1, 1)
      if (p == ">" || p == "<" || q == ">") { out = out c; continue }
      out = out "\n"; continue
    }
    if (c == "$" && substr(s, i + 1, 1) == "(") { out = out "\n"; i++; continue }
    if (c == ";" || c == "|" || c == "(" || c == ")" || c == "`") { out = out "\n"; continue }
    out = out c
  }
  print out
}') || exit 0

  EXP_MIX_ENV=""; EXP_ALLOW=""
  HOOK_MIX_ENV="${MIX_ENV:-}"; HOOK_ALLOW="${EPG_ALLOW:-}"
  while IFS= read -r seg; do
    force=0
    set -f
    # shellcheck disable=SC2086 # word splitting is the point
    set -- $seg
    set +f
    check_segment "$@"
  done <<EOF
$segments
EOF
  exit 0
}

# ============================================================================
# pre/post edit - file checks
# Two tiers, same as the Claude Code plugin:
#   block  - near-certain bugs. pre edit denies the write.
#   review - heuristics. post edit returns them as additionalContext.
# Only lines this tool call writes are reported, evaluated with whole-file
# context (multi-clause @impl, per-table migration indexes):
#   pre edit   the edit is applied to a copy of the file; reported lines are
#              where new text lands (whole-file write: lines not already in
#              the file). If the edit can't be applied (old text not found,
#              no file yet), the new text alone is scanned.
#   post edit  edit: the lines where the new text now sits in the file;
#              whole-file write: lines added vs the git index if tracked,
#              else the whole file.
# Comments, @doc/@moduledoc/@typedoc text and HEEx comments are ignored.
# Skipped: tests, deps/, _build/, node_modules/, .elixir_ls/.
# ============================================================================

# Lines of $1 (a file) where any string of the JSON array $2 occurs, as
# "a-b a-b ..."; if none occurs verbatim (a formatter may have run), lines
# whose trimmed text equals a trimmed line of the new text; "ALL" when that
# finds nothing either; "NONE" when every new string is empty.
locate_lines() {
  jq -rn --rawfile content "$1" --argjson news "$2" '
    def nl: split("\n") | length - 1;
    def trim_: gsub("^\\s+|\\s+$"; "");
    ($news | map(select(length > 0))) as $news
    | if ($news | length) == 0 then "NONE"
      else
        ([ $news[] as $s
           | ($content | split($s)) as $parts
           | ($s | nl) as $snl
           | (if ($s | endswith("\n")) and $snl > 0 then $snl - 1 else $snl end) as $span
           | select(($parts | length) > 1)
           | foreach range(0; ($parts | length) - 1) as $i (
               {line: 1, start: 1};
               .line += ($parts[$i] | nl) | .start = .line | .line += $snl;
               "\(.start)-\(.start + $span)")
         ]) as $exact
        | if ($exact | length) > 0 then $exact | join(" ")
          else
            ([ $news[] | split("\n")[] | trim_ | select(length > 0) ]
             | map({(.): true}) | add // {}) as $want
            | [ $content | split("\n") | to_entries[]
                | select($want[.value | trim_]) | "\(.key + 1)-\(.key + 1)" ]
            | if length > 0 then join(" ") else "ALL" end
          end
      end' 2>/dev/null || echo ALL
}

# Lines of $2 not present in $1 (multiset match on exact line text), as
# "a-b ..."; "NONE" when every line already existed.
new_lines() {
  awk -v old="$1" '
    { sub(/\r$/, "") }
    FILENAME == old { have[$0]++; next }
    { if (have[$0] > 0) have[$0]--; else { printf "%s%d-%d", sep, FNR, FNR; sep = " "; any = 1 } }
    END { if (!any) print "NONE"; else print "" }' "$1" "$2" 2>/dev/null || echo ALL
}

# Added lines of tracked file $1 vs the git index; "ALL" when untracked or no
# git; "NONE" when nothing was added.
git_added_lines() {
  local dir base out
  dir=$(dirname "$1"); base=$(basename "$1")
  command -v git >/dev/null 2>&1 || { echo ALL; return; }
  (cd "$dir" && git ls-files --error-unmatch -- "$base") >/dev/null 2>&1 || { echo ALL; return; }
  out=$( (cd "$dir" && git diff -U0 --no-color --no-ext-diff -- "$base") 2>/dev/null | awk '
    /^@@/ {
      if (match($0, /\+[0-9]+(,[0-9]+)?/)) {
        s = substr($0, RSTART + 1, RLENGTH - 1); n = split(s, p, ",")
        start = p[1] + 0; cnt = (n > 1) ? p[2] + 0 : 1
        if (cnt > 0) { printf "%s%d-%d", sep, start, start + cnt - 1; sep = " " }
      }
    }
    END { if (sep == "") print "NONE"; else print "" }') || out=ALL
  [ -n "$out" ] || out=ALL
  echo "$out"
}

# Phoenix 1.8 scopes are a code fact: a Scope module, or current_scope in
# *user_auth.ex, under lib/ or apps/*/lib of the project containing $1.
project_has_scope() {
  local root d
  root=$(find_project_root "$(dirname "$1")") || return 1
  for d in "$root/lib" "$root"/apps/*/lib; do
    [ -d "$d" ] || continue
    grep -rlsE --include='*.ex' 'defmodule[[:space:]]+[A-Za-z0-9_.]+\.Scope([[:space:],]|$)' "$d" | grep -q . && return 0
    find "$d" -name '*user_auth.ex' -exec grep -l 'current_scope' {} + 2>/dev/null | grep -q . && return 0
  done
  return 1
}

# run_checks FILE RANGES -> "<block|review>\t<message> (line N, M)" lines.
# Uses KIND, IS_MIGRATION, SKIP_INSPECT, IS_LIVE, HAS_SCOPE.
run_checks() {
  awk -v ranges="$2" -v kind="$KIND" -v is_mig="$IS_MIGRATION" \
    -v skip_inspect="$SKIP_INSPECT" -v is_live="$IS_LIVE" -v has_scope="$HAS_SCOPE" '
function strip_comment(s,   i, c, q, L) {
  if (index(s, "#") == 0) return s
  q = 0; L = length(s)
  for (i = 1; i <= L; i++) {
    c = substr(s, i, 1)
    if (c == "\\") { i++; continue }
    if (c == "\"") q = !q
    else if (c == "#" && !q && substr(s, i + 1, 1) != "{") return substr(s, 1, i - 1)
  }
  return s
}
function dyn_interp(s,   t) {
  t = s
  gsub(/#[{]@[A-Za-z_][A-Za-z0-9_]*[}]/, "", t)   # #{@module_attr} is static
  return t ~ /#[{]/
}
function flag(id, ln) {
  if (!(all || chg[ln])) return
  if (seen[id, ln]) return
  seen[id, ln] = 1
  where[id] = (where[id] == "") ? ln : where[id] ", " ln
  if (!(id in order)) { order[id] = ++norder; ids[norder] = id }
}
# def name and arity (-1 when the head spans lines) of a def line
function def_head(s,   rest, name, i, c, depth, commas, q, L, sawarg) {
  rest = s
  sub(/^[[:space:]]*def(p|macro|macrop)?[[:space:]]+/, "", rest)
  if (!match(rest, /^[a-z_][A-Za-z0-9_]*[?!]?/)) { dh_name = ""; dh_arity = -1; return }
  name = substr(rest, 1, RLENGTH); rest = substr(rest, RLENGTH + 1)
  dh_name = name
  if (substr(rest, 1, 1) != "(") { dh_arity = (rest ~ /^[[:space:]]+[^,d]/) ? -1 : 0; return }
  depth = 0; commas = 0; q = 0; sawarg = 0; L = length(rest)
  for (i = 1; i <= L; i++) {
    c = substr(rest, i, 1)
    if (q) { if (c == "\\") i++; else if (c == "\"") q = 0; continue }
    if (c == "\"") { q = 1; sawarg = 1; continue }
    if (c == "(" || c == "[" || c == "{") { depth++; if (depth > 1) sawarg = 1; continue }
    if (c == ")" || c == "]" || c == "}") {
      depth--
      if (depth == 0) { dh_arity = sawarg ? commas + 1 : 0; return }
      continue
    }
    if (c == "," && depth == 1) commas++
    else if (c !~ /[[:space:]]/) sawarg = 1
  }
  dh_arity = -1
}
# regexes are passed as strings: a bare /re/ argument would be matched against $0
function capture(s, re, prefix_re,   t) {
  if (!match(s, re)) return ""
  t = substr(s, RSTART, RLENGTH)
  sub(prefix_re, "", t)
  return t
}
BEGIN {
  all = (ranges == "ALL")
  if (!all) {
    nr = split(ranges, rr, " ")
    for (k = 1; k <= nr; k++) {
      split(rr[k], ab, "-")
      for (x = ab[1] + 0; x <= ab[2] + 0; x++) chg[x] = 1
    }
  }
  is_ex = (kind == "ex" || kind == "exs")
  tier["sql"] = "block";       msg["sql"] = "SQL built by string interpolation in Repo.query/SQL.query - SQL injection. Pass values as parameters: Repo.query(\"... WHERE id = $1\", [id])."
  tier["fragment"] = "block";  msg["fragment"] = "Interpolation inside fragment() - Ecto rejects this at compile time and it would be SQL injection. Use ? placeholders: fragment(\"lower(?)\", field)."
  tier["extredir"] = "block";  msg["extredir"] = "redirect(external: params...) - open redirect to a user-supplied URL. Use redirect(to: ~p\"...\") or check the host against an allowlist first."
  tier["formfor"] = "block";   msg["formfor"] = "form_for was removed in phoenix_html 4 - use <.form for={@form} ...> with to_form/1."
  tier["livenav"] = "block";   msg["livenav"] = "live_redirect/live_patch/push_redirect are deprecated - use <.link navigate={...}>/<.link patch={...}> or push_navigate/push_patch."
  tier["toatom"] = "review";   msg["toatom"] = "String.to_atom/1 - atoms are never garbage-collected; on user input this can exhaust the atom table. Map known strings explicitly or use String.to_existing_atom/1."
  tier["raw"] = "review";      msg["raw"] = "raw/1 bypasses HTML escaping - XSS if the content can contain user input. Make sure it is sanitized or trusted."
  tier["logger"] = "review";   msg["logger"] = "Logger message interpolates a sensitive value (password/token/secret/key) - redact it or log an identifier instead."
  tier["inspect"] = "review";  msg["inspect"] = "IO.inspect/dbg left in lib code - remove before committing (use Logger for intentional output)."
  tier["timing"] = "review";   msg["timing"] = "Secret/token compared with == - not constant-time. Use Plug.Crypto.secure_compare/2."
  tier["impl"] = "review";     msg["impl"] = "Callback without @impl true on its first clause - add @impl true above it."
  tier["migidx"] = "review";   msg["migidx"] = "references() column with no index on that table in this migration - add create index(:table, [:column]) (Postgres does not index foreign keys automatically)."
  tier["ondelete"] = "review"; msg["ondelete"] = "references() without on_delete: - the default is :nothing; choose :delete_all, :nilify_all or :restrict explicitly."
  tier["curuser"] = "review";  msg["curuser"] = "This project uses Phoenix 1.8 scopes - use @current_scope (and @current_scope.user) rather than @current_user."
  tier["repolive"] = "review"; msg["repolive"] = "Repo called directly in a LiveView module - move the query into a context function (scoped to @current_scope where the project uses scopes)."
}
{ sub(/\r$/, ""); raw[NR] = $0 }
END {
  n = NR
  # ---- pass 1: blank out comments and @doc/@moduledoc/@typedoc text ----
  indoc = ""; inhc = 0
  for (i = 1; i <= n; i++) {
    line = raw[i]
    if (indoc != "") { if (index(line, indoc)) indoc = ""; code[i] = ""; continue }
    if (inhc) {
      if (index(line, "--%>")) { inhc = 0; line = substr(line, index(line, "--%>") + 4) }
      else { code[i] = ""; continue }
    }
    if (is_ex && line ~ /^[[:space:]]*@(moduledoc|doc|typedoc|shortdoc)([[:space:]]|$)/) {
      code[i] = "@doc"
      if (line ~ /"""/) indoc = "\"\"\""
      else if (line ~ /'\'''\'''\''/) indoc = "'\'''\'''\''"
      continue
    }
    if (is_ex && line ~ /^[[:space:]]*#/) { code[i] = ""; continue }
    while (match(line, /<%!--/)) {
      rest = substr(line, RSTART + 5)
      if (index(rest, "--%>")) line = substr(line, 1, RSTART - 1) substr(rest, index(rest, "--%>") + 4)
      else { line = substr(line, 1, RSTART - 1); inhc = 1; break }
    }
    gsub(/<!--.*-->/, "", line)
    code[i] = is_ex ? strip_comment(line) : line
  }

  # ---- pass 2: line checks ----
  impl_pending = 0; last_name = ""; last_arity = -2
  cur_table = ""
  for (i = 1; i <= n; i++) {
    c = code[i]
    if (c ~ /^[[:space:]]*$/) continue
    isdef = (c ~ /^[[:space:]]*def(p|macro|macrop)?[[:space:]]+[a-z_]/)

    if (is_ex) {
      # SQL interpolation: single-line string or a """ heredoc argument
      if (match(c, /(Repo|SQL)[.]query!?[(]/)) {
        rest = substr(c, RSTART + RLENGTH - 1)
        if (rest ~ /^[(]([A-Za-z_][A-Za-z0-9_.]*,[[:space:]]*)?~?[sS]?"""/) {
          for (j = i + 1; j <= n && j <= i + 200; j++) {
            if (index(raw[j], "\"\"\"")) break
            if (dyn_interp(raw[j])) { if (all || chg[j]) flag("sql", j); else flag("sql", i) }
          }
        } else if (match(rest, /^[(]([A-Za-z_][A-Za-z0-9_.]*,[[:space:]]*)?"([^"\\]|\\.)*"/)) {
          if (dyn_interp(substr(rest, 1, RLENGTH))) flag("sql", i)
        } else if (rest ~ /^[(]([A-Za-z_][A-Za-z0-9_.]*,[[:space:]]*)?"/ && dyn_interp(rest)) {
          flag("sql", i)
        }
      }
      if (c ~ /fragment[(]"[^"]*#[{]/) flag("fragment", i)
      if (c ~ /external:[[:space:]]*(conn[.])?(query_|body_|path_)?params([^A-Za-z0-9_]|$)/) flag("extredir", i)
      if (c ~ /String[.]to_atom([^A-Za-z0-9_?!]|$)/) flag("toatom", i)
      lc = tolower(c)
      if (lc ~ /logger[.][a-z_]+[(]/ && lc ~ /#[{][^}]*(password|passwd|secret|token|api_key|apikey|private_key|credential|authorization)/) flag("logger", i)
      if (kind == "ex" && !skip_inspect && (c ~ /IO[.]inspect([^A-Za-z0-9_]|$)/ || c ~ /(^|[^A-Za-z0-9_.:])dbg[(]/)) flag("inspect", i)
      if (c ~ /(token|secret|api_key|signature)[[:space:]]*==[[:space:]]*[a-z_]/ || c ~ /[a-z_][[:space:]]*==[[:space:]]*(token|secret|api_key|signature)([^A-Za-z0-9_]|$)/) {
        if (c !~ /==[[:space:]]*(nil|true|false)([^A-Za-z0-9_]|$)/ && c !~ /(^|[^A-Za-z0-9_.])(nil|true|false)[[:space:]]*==/) flag("timing", i)
      }
      if (kind == "ex" && is_live == 1 && c ~ /(^|[^A-Za-z0-9_])Repo[.](all|one|get|get_by|insert|insert_all|update|update_all|delete|delete_all|aggregate|exists[?]|preload|transact|transaction)(!?)[(]/) flag("repolive", i)
    }

    # deprecated/removed APIs and XSS (also .heex); a project defining its
    # own helper of that name is not flagged on the def line itself
    defines = ""
    if (isdef) defines = capture(c, "def(p|macro|macrop)?[[:space:]]+[a-z_]+", "^def(p|macro|macrop)?[[:space:]]+")
    if (defines != "form_for" && c ~ /(^|[^A-Za-z0-9_:])form_for([(]|[[:space:]]+[@a-z])/) flag("formfor", i)
    if (defines !~ /^(live_redirect|live_patch|push_redirect)$/ && c ~ /(^|[^A-Za-z0-9_:])(live_redirect|live_patch|push_redirect)([^A-Za-z0-9_]|$)/) flag("livenav", i)
    if (defines != "raw" && (c ~ /(^|[^A-Za-z0-9_.:])raw([(]|[[:space:]]+@)/ || c ~ /HTML[.]raw[(]/)) flag("raw", i)
    if (has_scope == "true" && c ~ /(@|assigns[.])current_user([^A-Za-z0-9_]|$)/) flag("curuser", i)

    # @impl: first clause of a callback needs it; later clauses of the same
    # name/arity do not. Blank lines, comments and attributes may intervene.
    if (kind == "ex") {
      if (c ~ /^[[:space:]]*defmodule[[:space:]]/) { last_name = ""; impl_pending = 0 }
      else if (isdef) {
        def_head(c)
        same = (dh_name == last_name && (dh_arity == last_arity || dh_arity < 0 || last_arity < 0))
        if (c ~ /^[[:space:]]*def[[:space:]]+(mount|handle_params|handle_event|handle_info|handle_call|handle_cast|handle_continue|handle_async|terminate)[(]/ && !same && !impl_pending) flag("impl", i)
        last_name = dh_name; last_arity = dh_arity; impl_pending = 0
      }
      else if (c ~ /^[[:space:]]*@impl([[:space:]]|$)/) impl_pending = 1
      else if (c ~ /^[[:space:]]*@/) { }
      else impl_pending = 0
    }

    # migrations: collect references and indexes per table
    if (is_mig == 1) {
      if (c ~ /(create|create_if_not_exists|alter)[[:space:]]*[(]?[[:space:]]*table[(]/) {
        cur_table = capture(c, "table[(][[:space:]]*:?\"?[A-Za-z0-9_]+", "^table[(][[:space:]]*:?\"?")
      }
      if (c ~ /(add|add_if_not_exists|modify)[[:space:]]+:?[A-Za-z0-9_]+,[[:space:]]*references[(]/) {
        nref++
        refcol[nref] = capture(c, "(add|add_if_not_exists|modify)[[:space:]]+:?[A-Za-z0-9_]+", "^(add|add_if_not_exists|modify)[[:space:]]+:?")
        reftab[nref] = cur_table; refline[nref] = i
        # on_delete may sit on a continuation line of the same call
        buf = c; depth = gsub(/[(]/, "(", buf) - gsub(/[)]/, ")", buf)
        for (j = i + 1; depth > 0 && j <= n && j <= i + 6; j++) {
          buf = buf " " code[j]; t = code[j]; depth += gsub(/[(]/, "(", t) - gsub(/[)]/, ")", t)
        }
        if (buf !~ /on_delete:/) flag("ondelete", i)
      }
      if (c ~ /(unique_)?index[(][[:space:]]*:?"?[A-Za-z0-9_]+"?[[:space:]]*,[[:space:]]*[[]?[[:space:]]*:?"?[A-Za-z0-9_]+/) {
        t = capture(c, "index[(][[:space:]]*:?\"?[A-Za-z0-9_]+\"?[[:space:]]*,[[:space:]]*[[]?[[:space:]]*:?\"?[A-Za-z0-9_]+", "^index[(][[:space:]]*:?\"?")
        split(t, parts, /"?[[:space:]]*,[[:space:]]*[[]?[[:space:]]*:?"?/)
        idx[parts[1], parts[2]] = 1
      }
    }
  }
  if (is_mig == 1) {
    for (k = 1; k <= nref; k++) if (!((reftab[k], refcol[k]) in idx)) flag("migidx", refline[k])
  }

  for (k = 1; k <= norder; k++) {
    id = ids[k]
    printf "%s\t%s (%s %s)\n", tier[id], msg[id], (index(where[id], ",") ? "lines" : "line"), where[id]
  }
}' "$1" 2>/dev/null
}

check_edit() {
  local file spec mode news ranges scan findings block review snippet note
  file=$(printf '%s' "$ARGS" | jq -r '(.file_path // .filePath // .path // empty) | strings' 2>/dev/null)
  [ -n "$file" ] || exit 0
  case "$file" in /*) ;; *) file="$CWD/$file" ;; esac
  local nfile="$file"
  case "$nfile" in
    */deps/*|*/_build/*|*/node_modules/*|*/.elixir_ls/*) exit 0 ;;
    *_test.exs|*/test/*) exit 0 ;;
  esac
  case "$nfile" in
    *.ex) KIND="ex" ;;
    *.exs) KIND="exs" ;;
    *.heex) KIND="heex" ;;
    *) exit 0 ;;
  esac
  IS_MIGRATION=0; case "$nfile" in */migrations/*.exs) IS_MIGRATION=1 ;; esac
  SKIP_INSPECT=0; case "$nfile" in */mix/tasks/*) SKIP_INSPECT=1 ;; esac
  IS_LIVE=0; case "$nfile" in *_live.ex|*/live/*) IS_LIVE=1 ;; esac

  # edit: list of {old, new, all}; write: whole new content
  spec=$(printf '%s' "$ARGS" | jq -c '
    def s: if type == "string" then . else "" end;
    if (.edits | type) == "array" then
      {mode: "edit", edits: [.edits[] | {old: ((.old_string // .oldString // .old_str) | s), new: ((.new_string // .newString // .new_str) | s), all: (.replace_all == true)}]}
    elif has("new_string") or has("newString") or has("new_str") then
      {mode: "edit", edits: [{old: ((.old_string // .oldString // .old_str) | s), new: ((.new_string // .newString // .new_str) | s), all: (.replace_all == true)}]}
    elif has("content") or has("file_text") then
      {mode: "write", content: ((.content // .file_text) | s)}
    else empty end' 2>/dev/null)
  [ -n "$spec" ] || exit 0
  mode=$(printf '%s' "$spec" | jq -r '.mode')
  news=$(printf '%s' "$spec" | jq -c '[.edits[]?.new]')

  TMPD=$(mktemp -d 2>/dev/null) || exit 0
  note=""
  if [ "$PHASE" = pre ]; then
    scan="$TMPD/scan"
    if [ "$mode" = write ]; then
      printf '%s' "$spec" | jq -j '.content' > "$scan" 2>/dev/null || exit 0
      [ -s "$scan" ] || exit 0
      if [ -f "$file" ]; then ranges=$(new_lines "$file" "$scan"); else ranges=ALL; fi
    else
      ranges=NONE
      if [ -f "$file" ] && printf '%s' "$spec" | jq -j --rawfile f "$file" '
          reduce .edits[] as $e ($f;
            if . == null or ($e.old | length) == 0 then null
            else (split($e.old)) as $p
              | if ($p | length) < 2 then null
                elif $e.all then $p | join($e.new)
                else $p[0] + $e.new + ($p[1:] | join($e.old)) end
            end)
          | if . == null then error("unapplied") else . end' > "$scan" 2>/dev/null; then
        ranges=$(locate_lines "$scan" "$news")
      else
        # can't reproduce the edit: scan the new text on its own
        printf '%s' "$news" | jq -j 'map(select(length > 0)) | join("\n")' > "$scan" 2>/dev/null || exit 0
        [ -s "$scan" ] && ranges=ALL
        note=" (line numbers count from the start of the new text)"
      fi
    fi
  else
    [ -f "$file" ] || exit 0
    scan="$file"
    if [ "$mode" = write ]; then ranges=$(git_added_lines "$file")
    else ranges=$(locate_lines "$file" "$news"); fi
  fi
  [ -n "$ranges" ] || ranges=ALL
  [ "$ranges" = NONE ] && exit 0

  HAS_SCOPE=false
  if grep -q 'current_user' "$scan" 2>/dev/null && project_has_scope "$file"; then HAS_SCOPE=true; fi

  findings=$(run_checks "$scan" "$ranges") || exit 0
  [ -n "$findings" ] || exit 0
  block=$(printf '%s\n' "$findings" | awk -F'\t' '$1 == "block" { print "- " $2 }')
  review=$(printf '%s\n' "$findings" | awk -F'\t' '$1 == "review" { print "- " $2 }')

  if [ "$PHASE" = pre ]; then
    [ -n "$block" ] || exit 0
    snippet="elixir-phoenix-guide blocked this write to $file$note:
$block"
    [ -n "$review" ] && snippet="$snippet
Also review (may be intentional):
$review"
    deny "$snippet
Fix these and write the file again."
  fi

  snippet="elixir-phoenix-guide review notes for $file (lines just written; fix or confirm they are intentional):"
  if [ -n "$block" ]; then
    snippet="$snippet
Must fix:
$block"
    [ -n "$review" ] && snippet="$snippet
Also review (may be intentional):
$review"
  else
    snippet="$snippet
$review"
  fi
  advise "$snippet"
}

case "${PHASE}_${TYPE}" in
  pre_bash)  check_bash_pre ;;
  pre_edit|post_edit) check_edit ;;
esac
exit 0
