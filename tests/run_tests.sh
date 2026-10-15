#!/usr/bin/env bash
# Test harness for hooks/elixir-hook.sh and hooks/elixir-hook.ps1.
# Feeds Copilot-shaped hook JSON on stdin and asserts the decision:
#   deny     exit 2, stdout {"permissionDecision":"deny","permissionDecisionReason":...}
#   advise   exit 0, stdout {"additionalContext":...}
#   clean    exit 0, no stdout
# and never anything on stderr.
#
#   /bin/bash tests/run_tests.sh            # bash hook (also exercises bash 3.2)
#   PWSH=/path/to/pwsh /bin/bash tests/run_tests.sh ps1   # PowerShell hook
#
# Needs jq (the harness builds payloads with it) and git.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIXSRC="$ROOT/tests/fixtures"
TARGET="${1:-sh}"
SH="${BASH:-bash}"
PASS=0; FAIL=0

case "$TARGET" in
  sh) HOOK=("$SH" "$ROOT/hooks/elixir-hook.sh") ;;
  ps1)
    PWSH="${PWSH:-$(command -v pwsh 2>/dev/null)}"
    [ -n "$PWSH" ] && [ -x "$PWSH" ] || { echo "pwsh not found: set PWSH=/path/to/pwsh"; exit 1; }
    HOOK=("$PWSH" -NoProfile -NonInteractive -File "$ROOT/hooks/elixir-hook.ps1") ;;
  *) echo "usage: $0 [sh|ps1]"; exit 1 ;;
esac

TMP="$(mktemp -d)"
TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT
unset EPG_ALLOW MIX_ENV 2>/dev/null || true

ok()  { PASS=$((PASS+1)); }
bad() { echo "FAIL $1: $2"; FAIL=$((FAIL+1)); }

# run PHASE TYPE JSON -> OUT ERR RC
run() {
  OUT=$(printf '%s' "$3" | "${HOOK[@]}" "$1" "$2" 2>"$TMP/stderr"); RC=$?
  ERR=$(cat "$TMP/stderr")
}

expect_deny() { # name phase type json pattern
  run "$2" "$3" "$4"
  [ "$RC" -eq 2 ] || { bad "$1" "exit $RC (want 2) stdout=[$OUT] stderr=[$ERR]"; return; }
  [ -z "$ERR" ] || { bad "$1" "unexpected stderr: $ERR"; return; }
  local r
  r=$(printf '%s' "$OUT" | jq -er 'select(.permissionDecision == "deny") | .permissionDecisionReason' 2>/dev/null) ||
    { bad "$1" "stdout is not deny JSON: $OUT"; return; }
  printf '%s' "$r" | grep -qF -- "$5" || { bad "$1" "reason missing '$5': $r"; return; }
  ok
}

expect_advise() { # name json pattern  (post edit)
  run post edit "$2"
  [ "$RC" -eq 0 ] || { bad "$1" "exit $RC (want 0) stdout=[$OUT] stderr=[$ERR]"; return; }
  [ -z "$ERR" ] || { bad "$1" "unexpected stderr: $ERR"; return; }
  local c
  c=$(printf '%s' "$OUT" | jq -er '.additionalContext | strings' 2>/dev/null) ||
    { bad "$1" "stdout is not additionalContext JSON: $OUT"; return; }
  printf '%s' "$c" | grep -qF -- "$3" || { bad "$1" "additionalContext missing '$3': $c"; return; }
  ok
}

expect_clean() { # name phase type json
  run "$2" "$3" "$4"
  [ "$RC" -eq 0 ] && [ -z "$OUT" ] && [ -z "$ERR" ] || { bad "$1" "exit $RC stdout=[$OUT] stderr=[$ERR] (want silent exit 0)"; return; }
  ok
}

expect_absent() { # name phase type json pattern
  run "$2" "$3" "$4"
  if printf '%s\n%s' "$OUT" "$ERR" | grep -qF -- "$5"; then bad "$1" "unexpected '$5' in: $OUT $ERR"; return; fi
  ok
}

# --- payload builders ------------------------------------------------------
b()  { jq -n --arg c "$1" --arg d "${2:-$PROJ}" '{timestamp: 1, cwd: $d, toolName: "bash", toolArgs: {command: $c}}'; }
# Copilot create: whole-file write
cr() { jq -n --arg f "$1" --rawfile c "$2" --arg d "$APP" '{cwd: $d, toolName: "create", toolArgs: {path: $f, file_text: $c}}'; }
crs() { jq -n --arg f "$1" --arg c "$2" --arg d "$APP" '{cwd: $d, toolName: "create", toolArgs: {path: $f, file_text: $c}}'; }
# Copilot edit: replace old_str with new_str
ed() { jq -n --arg f "$1" --arg o "$2" --arg n "$3" --arg d "$APP" '{cwd: $d, toolName: "edit", toolArgs: {path: $f, old_str: $o, new_str: $n}}'; }

# --- projects ---------------------------------------------------------------
PROJ="$TMP/elixir_proj"; mkdir -p "$PROJ/lib/sub"; : > "$PROJ/mix.exs"
UMB="$TMP/umbrella_proj"; mkdir -p "$UMB/apps/web"; : > "$UMB/mix.exs"; : > "$UMB/apps/web/mix.exs"
NONE="$TMP/not_elixir"; mkdir -p "$NONE"
APP="$TMP/app"; mkdir -p "$APP/lib"; : > "$APP/mix.exs"

# fixture case: pre-edit on a new file (create), then post-edit on the
# written file. fcase NAME FIXTURE RELPATH PRE(deny|clean) POST(advise|clean) PATTERN
fcase() {
  local name="$1" fix="$FIXSRC/$2" dest="$APP/$3"
  rm -f "$dest"; mkdir -p "$(dirname "$dest")"
  if [ "$4" = deny ]; then expect_deny "${name}_pre" pre edit "$(cr "$dest" "$fix")" "$6"
  else expect_clean "${name}_pre" pre edit "$(cr "$dest" "$fix")"; fi
  cp "$fix" "$dest"
  if [ "$5" = advise ]; then expect_advise "${name}_post" "$(cr "$dest" "$fix")" "$6"
  else expect_clean "${name}_post" post edit "$(cr "$dest" "$fix")"; fi
}

# =============================================================== fail-open
expect_clean empty_stdin_bash   pre bash ''
expect_clean garbage_stdin_bash pre bash 'not json'
expect_clean empty_stdin_edit   pre edit ''
expect_clean garbage_stdin_edit post edit 'not json'
expect_clean no_args_object     pre bash '{"cwd":"/"}'
expect_clean unknown_phase      foo bash "$(b 'mix ecto.reset')"
run pre "" "$(b 'mix ecto.reset')"
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then ok; else bad missing_type "exit $RC $OUT"; fi
expect_clean bash_hook_on_edit_tool pre bash "$(ed "$APP/lib/x.ex" a b)"
expect_clean edit_hook_on_bash_tool pre edit "$(b 'mix ecto.reset')"
expect_clean view_tool_ignored  pre edit "$(jq -n --arg f "$FIXSRC/bad_mixed.ex" '{toolName: "view", toolArgs: {path: $f}}')"
expect_clean missing_file_post  post edit "$(ed "$APP/lib/does_not_exist.ex" a 'String.to_atom(x)')"

# =============================================================== pre bash
# review 2.2 "blocked but harmless" -> allowed
expect_clean test_env_reset_allowed    pre bash "$(b 'MIX_ENV=test mix ecto.reset')"
expect_clean commit_msg_mentions_reset pre bash "$(b 'git commit -m "docs: never run mix ecto.reset in prod"')"
expect_clean grep_for_reset            pre bash "$(b 'grep -rn "mix ecto.reset" docs/')"
# review 2.2 "allowed but dangerous" -> blocked
expect_deny ecto_drop_blocked          pre bash "$(b 'mix ecto.drop')"                     'ecto.drop'
expect_deny plus_refspec_blocked       pre bash "$(b 'git push origin +main')"             'force-with-lease'
expect_deny combined_uf_blocked        pre bash "$(b 'git push -uf origin main')"          'force-with-lease'
expect_deny combined_fu_blocked        pre bash "$(b 'git push -fu origin main')"          'force-with-lease'
expect_deny git_C_push_force_blocked   pre bash "$(b 'git -C dir push --force')"           'force-with-lease'
expect_deny lease_then_force_blocked   pre bash "$(b 'git push --force-with-lease x && git push --force y')" 'force-with-lease'
# still blocked / still allowed
expect_deny ecto_reset_blocked         pre bash "$(b 'mix ecto.reset')"                    'ecto.rollback'
expect_deny force_push_blocked         pre bash "$(b 'git push --force origin main')"      'force-with-lease'
expect_deny force_after_args           pre bash "$(b 'git push origin main --force')"      'force-with-lease'
expect_deny short_f_blocked            pre bash "$(b 'git push -f')"                       'force-with-lease'
expect_deny git_c_config_push_f        pre bash "$(b 'git -c push.default=current push -f')" 'force-with-lease'
expect_deny force_and_lease_blocked    pre bash "$(b 'git push --force-with-lease --force origin main')" 'force-with-lease'
expect_deny mix_do_drop_blocked        pre bash "$(b 'mix do ecto.drop + ecto.create')"    'ecto.drop'
expect_deny subshell_drop_blocked      pre bash "$(b '(cd apps/core; mix ecto.drop)')"     'ecto.drop'
expect_deny pipe_reset_blocked         pre bash "$(b 'yes 2>&1 | mix ecto.reset')"         'ecto.reset'
expect_deny dev_env_reset_blocked      pre bash "$(b 'MIX_ENV=dev mix ecto.reset')"        'dev database'
expect_deny newline_segment_blocked    pre bash "$(b "$(printf 'echo start\nmix ecto.reset')")" 'ecto.reset'
expect_clean force_lease_allowed       pre bash "$(b 'git push --force-with-lease origin main')"
expect_clean force_if_includes_allowed pre bash "$(b 'git push --force-with-lease --force-if-includes origin main')"
expect_clean plain_push_allowed        pre bash "$(b 'git push origin main')"
expect_clean push_option_allowed       pre bash "$(b 'git push -o ci.skip origin main')"
expect_clean prod_env_allowed          pre bash "$(b 'MIX_ENV=prod mix assets.deploy')"
expect_clean prod_release_allowed      pre bash "$(b 'MIX_ENV=prod mix release')"
expect_clean exported_test_env         pre bash "$(b 'export MIX_ENV=test; mix ecto.reset')"
expect_clean env_cmd_test_env          pre bash "$(b 'env MIX_ENV=test mix ecto.drop')"
expect_clean quoted_test_env           pre bash "$(b "cd apps/core && MIX_ENV='test' mix ecto.drop")"
expect_clean mix_help_reset            pre bash "$(b 'mix help ecto.reset')"
expect_clean shell_comment             pre bash "$(b 'mix test # then maybe mix ecto.reset')"
expect_clean heredoc_body              pre bash "$(b "$(printf 'cat <<EOF > notes.md\nmix ecto.reset\nEOF')")"
# shellcheck disable=SC2016 # literal $(cat <<EOF) is the input under test
expect_clean heredoc_commit_msg        pre bash "$(b "$(printf 'git commit -m "$(cat <<'"'"'EOF'"'"'\nfix: stop calling mix ecto.reset\n\nalso no git push --force\nEOF\n)"')")"
expect_clean echo_force_text           pre bash "$(b 'echo "git push --force is blocked"')"
# opt-out: command prefix, export, hook environment
expect_clean optout_prefix_force       pre bash "$(b 'EPG_ALLOW=force_push git push --force origin release')"
expect_clean optout_export_reset       pre bash "$(b 'export EPG_ALLOW=ecto_reset && mix ecto.reset')"
expect_deny  optout_wrong_token        pre bash "$(b 'EPG_ALLOW=ecto_reset git push -f')" 'force-with-lease'
OUT=$(b 'mix ecto.drop' | EPG_ALLOW=ecto_drop "${HOOK[@]}" pre bash 2>&1); RC=$?
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then ok; else bad optout_hook_env "exit $RC $OUT"; fi
OUT=$(b 'git push -f' | EPG_ALLOW=ecto_reset,force_push "${HOOK[@]}" pre bash 2>&1); RC=$?
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then ok; else bad optout_hook_env_list "exit $RC $OUT"; fi
OUT=$(b 'mix ecto.reset' | MIX_ENV="test" "${HOOK[@]}" pre bash 2>&1); RC=$?
if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then ok; else bad hook_env_mix_env_test "exit $RC $OUT"; fi
# Elixir projects only: walk up from cwd; umbrella root counts
expect_clean non_elixir_project_skip   pre bash "$(b 'git push --force origin main' "$NONE")"
expect_deny  umbrella_project_guarded  pre bash "$(b 'mix ecto.reset' "$UMB")"       'ecto.reset'
expect_deny  umbrella_child_guarded    pre bash "$(b 'mix ecto.reset' "$UMB/apps/web")" 'ecto.reset'
expect_deny  project_subdir_guarded    pre bash "$(b 'mix ecto.drop' "$PROJ/lib/sub")" 'ecto.drop'
# payload shapes: toolArgs as a JSON string; VS Code-compatible tool_input
expect_deny  toolargs_string           pre bash "$(jq -n --arg d "$PROJ" '{cwd: $d, toolName: "bash", toolArgs: ({command: "git push -f"} | tojson)}')" 'force-with-lease'
expect_deny  vscode_tool_input         pre bash "$(jq -n --arg d "$PROJ" '{hook_event_name: "PreToolUse", cwd: $d, tool_name: "Bash", tool_input: {command: "mix ecto.drop"}}')" 'ecto.drop'

# =============================================================== edit: fixtures
# block tier: pre denies; post (if the write happened anyway) says "Must fix"
fcase sql_adapter_interp   bad_sql_adapter.ex          lib/app/a.ex deny  advise 'SQL injection'
fcase repo_query_interp    bad_repo_query.ex           lib/app/a.ex deny  advise 'SQL injection'
fcase repo_query_heredoc   bad_repo_query_heredoc.ex   lib/app/a.ex deny  advise 'line 7'
fcase fragment_interp      bad_fragment.ex             lib/app/a.ex deny  advise 'fragment'
fcase redirect_external    bad_redirect_external.ex    lib/app/a.ex deny  advise 'open redirect'
fcase redirect_external_lv bad_redirect_external_live.ex lib/app/a.ex deny advise 'open redirect'
fcase form_for_removed     bad_form_for.ex             lib/app/a.ex deny  advise 'form_for'
fcase live_redirect_dep    bad_live_redirect.ex        lib/app/a.ex deny  advise 'live_redirect'
fcase live_patch_heex      bad_live_patch.heex         lib/app/a.html.heex deny advise 'live_patch'
fcase mixed_tiers          bad_mixed.ex                lib/app/a.ex deny  advise 'Also review'
fcase mixed_tiers_both     bad_mixed.ex                lib/app/a.ex deny  advise 'String.to_atom'
fcase param_query_ok       good_repo_query.ex          lib/app/a.ex clean clean
fcase redirect_to_params_ok good_redirect_to.ex        lib/app/a.ex clean clean
fcase simple_form_for_ok   good_simple_form_for.ex     lib/app/a.ex clean clean
# review tier: pre allows, post advises
fcase to_atom              bad_to_atom.ex              lib/app/a.ex clean advise 'String.to_atom'
fcase raw_heex             bad_raw.heex                lib/app/a.html.heex clean advise 'raw/1'
fcase phoenix_html_raw     bad_phoenix_html_raw.ex     lib/app/a.ex clean advise 'raw/1'
fcase logger_password      bad_logger.ex               lib/app/a.ex clean advise 'Logger'
fcase logger_warning       bad_logger_warning.ex       lib/app/a.ex clean advise 'Logger'
fcase io_inspect           bad_inspect.ex              lib/app/a.ex clean advise 'IO.inspect'
fcase dbg_call             bad_dbg.ex                  lib/app/a.ex clean advise 'dbg'
fcase timing_compare       bad_timing.ex               lib/app/a.ex clean advise 'secure_compare'
fcase impl_missing         bad_impl.ex                 lib/app/a.ex clean advise '@impl'
fcase impl_second_callback bad_impl_second_callback.ex lib/app/a.ex clean advise 'line 7'
fcase migration_on_delete  migrations/20260101000000_bad_migration.exs priv/repo/migrations/1_a.exs clean advise 'on_delete'
fcase migration_noindex    migrations/20260102000000_bad_migration_noindex.exs priv/repo/migrations/1_a.exs clean advise 'no index'
fcase migration_two_refs   migrations/20260103000000_two_refs_one_index.exs priv/repo/migrations/1_a.exs clean advise 'automatically). (line 7)'
fcase repo_in_liveview     bad_repo_live.ex            lib/app_web/live/post_live/index.ex clean advise 'Repo called directly'
fcase logger_no_secret     good_logger.ex              lib/app/a.ex clean clean
fcase nil_check_ok         good_nil_check.ex           lib/app/a.ex clean clean
fcase impl_ok              good_impl.ex                lib/app/a.ex clean clean
fcase impl_multiclause_ok  good_impl_multiclause.ex    lib/app/a.ex clean clean
fcase plug_init_ok         good_plug.ex                lib/app/a.ex clean clean
fcase migration_good       migrations/20260104000000_good.exs priv/repo/migrations/1_a.exs clean clean
fcase clean_file           good_clean.ex               lib/app/a.ex clean clean
fcase repo_outside_live_ok bad_repo_live.ex            lib/app/blog.ex clean clean
# false positives, removed Copilot-only checks, exclusions
fcase comments_and_docs    good_comments.ex            lib/app/a.ex clean clean
fcase heex_comments        good_comments.heex          lib/app/a.html.heex clean clean
fcase removed_checks_quiet good_removed_checks.ex      lib/app_web/components/layouts.ex clean clean
fcase deps_excluded        deps/some_dep/lib/bad.ex    deps/some_dep/lib/bad.ex clean clean
fcase build_excluded       bad_mixed.ex                _build/dev/lib/x/bad.ex clean clean
fcase node_modules_excluded bad_mixed.ex               assets/node_modules/x/bad.ex clean clean
fcase mix_task_inspect_ok  lib/mix/tasks/report.ex     lib/mix/tasks/report.ex clean clean
fcase test_file_skipped    skip_test.exs               test/app/skip_test.exs clean clean
fcase form_for_test_skipped form_for_test.exs          test/form_for_test.exs clean clean
fcase non_elixir_skipped   readme.md                   README.md clean clean
fcase mix_exs_quiet        good_clean.ex               mix2.exs clean clean

# =============================================================== edit: changed lines
EF="$APP/lib/app/edit_target.ex"
# pre: the edit is applied to a copy; only the replaced text is judged
cat > "$EF" <<'EOF'
defmodule EditTarget do
  def old(conn), do: live_redirect(conn, to: "/")

  def added(x) do
    x + 1
  end
end
EOF
expect_clean pre_edit_ignores_old_block pre edit "$(ed "$EF" '    x + 1' '    x + 2')"
expect_deny  pre_edit_new_block         pre edit "$(ed "$EF" '    x + 1' '    redirect(x, external: params["u"])')" 'line 5'
expect_absent pre_edit_new_block_only   pre edit "$(ed "$EF" '    x + 1' '    redirect(x, external: params["u"])')" 'live_redirect'
expect_clean pre_edit_review_tier_allowed pre edit "$(ed "$EF" '    x + 1' '    String.to_atom(x)')"
expect_clean pre_edit_deletion_only     pre edit "$(ed "$EF" '    x + 1' '')"
# old text not found: the new text is judged on its own
expect_deny  pre_edit_unapplied_fallback pre edit "$(ed "$EF" 'NOT THERE' 'form_for(@changeset, "/x", fn f -> f end)')" 'form_for'
# doc context: new text inside a @moduledoc is not code
cat > "$EF" <<'EOF'
defmodule EditTarget do
  @moduledoc """
  Helpers.
  """
end
EOF
expect_clean pre_edit_inside_moduledoc  pre edit "$(ed "$EF" '  Helpers.' '  Never use form_for(@cs, ...) or live_redirect.')"
# whole-file write over an existing file: only lines not already there
cat > "$EF" <<'EOF'
defmodule EditTarget do
  def old(conn), do: live_redirect(conn, to: "/")
end
EOF
expect_clean pre_write_keeps_old_block  pre edit "$(crs "$EF" "$(printf 'defmodule EditTarget do\n  def old(conn), do: live_redirect(conn, to: "/")\n  def new(x), do: x\nend\n')")"
expect_deny  pre_write_new_block        pre edit "$(crs "$EF" "$(printf 'defmodule EditTarget do\n  def old(conn), do: live_redirect(conn, to: "/")\n  def q(id), do: Repo.query!("SELECT #{id}")\nend\n')")" 'line 3'
expect_clean pre_write_identical        pre edit "$(cr "$EF" "$EF")"
: > "$EF"
expect_deny  pre_write_over_empty_file  pre edit "$(crs "$EF" "$(printf 'defmodule E do\n  def f(c), do: live_redirect(c, to: "/")\nend\n')")" 'line 2'
# CRLF content and non-ASCII text before the change: same line numbers
printf 'defmodule W do\r\n  # caf\303\251 \360\237\230\200\r\n  def ok(x), do: x\r\nend\r\n' > "$EF"
expect_deny  pre_edit_crlf_unicode      pre edit "$(ed "$EF" '  def ok(x), do: x' '  def q(id), do: Repo.query("SELECT #{id}")')" 'line 3'
cp "$EF" "$EF.orig"
printf 'defmodule W do\r\n  # caf\303\251 \360\237\230\200\r\n  def q(id), do: Repo.query("SELECT #{id}")\r\nend\r\n' > "$EF"
expect_advise post_edit_crlf_unicode    "$(ed "$EF" '  def ok(x), do: x' '  def q(id), do: Repo.query("SELECT #{id}")')" 'line 3'
cp "$EF" "$EF.new"; cp "$EF.orig" "$EF"
expect_deny  pre_write_crlf_unicode     pre edit "$(cr "$EF" "$EF.new")" 'line 3'
expect_deny  pre_write_crlf_vs_lf       pre edit "$(crs "$EF" "$(printf 'defmodule W do\n  # caf\303\251 \360\237\230\200\n  def ok(x), do: x\n  def r(c), do: live_patch(c, to: "/")\nend\n')")" 'line 4'

# post: Edit / MultiEdit lines located in the written file
cat > "$EF" <<'EOF'
defmodule EditTarget do
  def old(x), do: String.to_atom(x)

  def added(x) do
    x + 1
  end
end
EOF
expect_clean post_edit_clean_new_string post edit "$(ed "$EF" 'x' "$(printf '  def added(x) do\n    x + 1\n  end')")"
cat > "$EF" <<'EOF'
defmodule EditTarget do
  def old(x), do: String.to_atom(x)

  def added(x) do
    IO.inspect(x)
  end
end
EOF
expect_advise post_edit_bad_new_string "$(ed "$EF" 'x' "$(printf '  def added(x) do\n    IO.inspect(x)\n  end')")" 'line 5'
expect_absent post_edit_ignores_old_line post edit "$(ed "$EF" 'x' "$(printf '  def added(x) do\n    IO.inspect(x)\n  end')")" 'String.to_atom'
expect_advise post_edit_reindented     "$(ed "$EF" 'x' "$(printf 'def added(x) do\nIO.inspect(x)\nend')")" 'line 5'
expect_clean  post_edit_deletion_only  post edit "$(ed "$EF" 'x' '')"
cat > "$EF" <<'EOF'
defmodule EditTarget do
  def a(x), do: dbg(x)
  def b(x), do: x
  def c(x), do: dbg(x)
end
EOF
expect_advise post_edit_replace_all "$(jq -n --arg f "$EF" '{toolName: "edit", toolArgs: {file_path: $f, old_string: "x", new_string: "dbg(x)", replace_all: true}}')" 'lines 2, 4'
expect_advise post_multiedit_union  "$(jq -n --arg f "$EF" '{tool_name: "MultiEdit", tool_input: {file_path: $f, edits: [{old_string: "a", new_string: "def b(x), do: x"}, {old_string: "b", new_string: "def c(x), do: dbg(x)"}]}}')" 'line 4'
expect_absent post_multiedit_skips_unchanged post edit "$(jq -n --arg f "$EF" '{tool_name: "MultiEdit", tool_input: {file_path: $f, edits: [{old_string: "a", new_string: "def b(x), do: x"}, {old_string: "b", new_string: "def c(x), do: dbg(x)"}]}}')" 'line 2'
cat > "$EF" <<'EOF'
defmodule EditLive do
  use Phoenix.LiveView

  @impl true
  def handle_event("a", _p, s), do: {:noreply, s}

  def handle_event("b", _p, s), do: {:noreply, s}
end
EOF
expect_clean post_edit_new_clause_no_impl post edit "$(ed "$EF" 'x' '  def handle_event("b", _p, s), do: {:noreply, s}')"
# pre with whole-file context: same new clause under an @impl'd one
cat > "$EF" <<'EOF'
defmodule EditLive do
  use Phoenix.LiveView

  @impl true
  def handle_event("a", _p, s), do: {:noreply, s}
end
EOF
expect_clean pre_edit_new_clause_no_impl pre edit "$(ed "$EF" '  def handle_event("a", _p, s), do: {:noreply, s}' "$(printf '  def handle_event("a", _p, s), do: {:noreply, s}\n\n  def handle_event("b", _p, s), do: {:noreply, s}')")"

# multi-edit pre: both edits applied, second introduces a block finding
cat > "$EF" <<'EOF'
defmodule M do
  def a, do: 1
  def b, do: 2
end
EOF
expect_deny pre_multiedit_applied pre edit "$(jq -n --arg f "$EF" '{tool_name: "MultiEdit", tool_input: {file_path: $f, edits: [{old_string: "def a, do: 1", new_string: "def a, do: 10"}, {old_string: "def b, do: 2", new_string: "def b(c), do: push_redirect(c, to: \"/\")"}]}}')" 'line 3'

# payload shapes for edits: toolArgs JSON string; VS Code Write with file_path/content
expect_deny toolargs_string_edit pre edit "$(jq -n --arg f "$APP/lib/app/new1.ex" '{toolName: "create", toolArgs: ({path: $f, file_text: "defmodule N do\n  def f(c), do: live_patch(c, to: \"/\")\nend\n"} | tojson)}')" 'live_patch'
expect_deny vscode_write_shape   pre edit "$(jq -n --arg f "$APP/lib/app/new2.ex" '{tool_name: "Write", tool_input: {file_path: $f, content: "defmodule N do\n  def f(c), do: live_patch(c, to: \"/\")\nend\n"}}')" 'live_patch'
expect_deny relative_path        pre edit "$(jq -n --arg d "$APP" '{cwd: $d, toolName: "create", toolArgs: {path: "lib/app/new3.ex", file_text: "defmodule N do\n  def f(c), do: live_patch(c, to: \"/\")\nend\n"}}')" 'live_patch'
expect_clean relative_test_path  pre edit "$(jq -n --arg d "$APP" '{cwd: $d, toolName: "create", toolArgs: {path: "test/new_test.exs", file_text: "form_for(a, b, c)\n"}}')"

# post write in a git repo: added lines vs the index
REPO="$TMP/repo"; mkdir -p "$REPO/lib"
( cd "$REPO" && git init -q && printf 'defmodule W do\n  def old(x), do: String.to_atom(x)\nend\n' > lib/w.ex &&
  git add lib/w.ex && git -c user.email=t@t -c user.name=t commit -qm init ) >/dev/null 2>&1
printf 'defmodule W do\n  def old(x), do: String.to_atom(x)\n  def clean(x), do: x\nend\n' > "$REPO/lib/w.ex"
expect_clean post_write_clean_line_ok post edit "$(cr "$REPO/lib/w.ex" "$REPO/lib/w.ex")"
printf 'defmodule W do\n  def old(x), do: String.to_atom(x)\n  def clean(x), do: x\n  def debug(x), do: IO.inspect(x)\nend\n' > "$REPO/lib/w.ex"
expect_advise post_write_bad_line     "$(cr "$REPO/lib/w.ex" "$REPO/lib/w.ex")" 'line 4'
expect_absent post_write_ignores_old  post edit "$(cr "$REPO/lib/w.ex" "$REPO/lib/w.ex")" 'String.to_atom'
printf 'defmodule N do\n  def n(x), do: String.to_atom(x)\nend\n' > "$REPO/lib/new.ex"
expect_advise post_write_untracked    "$(cr "$REPO/lib/new.ex" "$REPO/lib/new.ex")" 'String.to_atom'

# =============================================================== @current_user vs scopes
SC="$TMP/scoped"; mkdir -p "$SC/lib/app/accounts" "$SC/lib/app_web/live"; : > "$SC/mix.exs"
printf 'defmodule App.Accounts.Scope do\n  defstruct user: nil\nend\n' > "$SC/lib/app/accounts/scope.ex"
cp "$FIXSRC/bad_current_user.ex" "$SC/lib/app_web/live/greeting.ex"
expect_advise scope_current_user "$(cr "$SC/lib/app_web/live/greeting.ex" "$FIXSRC/bad_current_user.ex")" 'current_scope'
NS="$TMP/unscoped"; mkdir -p "$NS/lib/app_web"; : > "$NS/mix.exs"
printf 'defmodule UWeb.UserAuth do\n  def fetch_current_user(conn, _), do: assign(conn, :current_user, nil)\nend\n' > "$NS/lib/app_web/user_auth.ex"
cp "$FIXSRC/bad_current_user.ex" "$NS/lib/app_web/greeting.ex"
expect_clean scope_absent_ok post edit "$(cr "$NS/lib/app_web/greeting.ex" "$FIXSRC/bad_current_user.ex")"
printf 'defmodule UWeb.UserAuth do\n  def on_mount(_, _, _, s), do: {:cont, assign(s, :current_scope, nil)}\nend\n' > "$NS/lib/app_web/user_auth.ex"
expect_advise scope_via_user_auth "$(cr "$NS/lib/app_web/greeting.ex" "$FIXSRC/bad_current_user.ex")" 'current_scope'
UM="$TMP/umbrella_scoped"; mkdir -p "$UM/apps/core/lib/core" "$UM/apps/web/lib/web"; : > "$UM/mix.exs"; : > "$UM/apps/core/mix.exs"; : > "$UM/apps/web/mix.exs"
printf 'defmodule Core.Scope do\nend\n' > "$UM/apps/core/lib/core/scope.ex"
cp "$FIXSRC/bad_current_user.ex" "$UM/apps/web/lib/web/greeting.ex"
expect_advise scope_umbrella "$(cr "$UM/apps/web/lib/web/greeting.ex" "$FIXSRC/bad_current_user.ex")" 'current_scope'

# =============================================================== no jq (bash only)
if [ "$TARGET" = sh ]; then
  NOJQ="$TMP/nojq_bin"; mkdir -p "$NOJQ"
  for t in cat dirname basename awk grep find mktemp rm tr; do
    p=$(command -v "$t" 2>/dev/null) && ln -s "$p" "$NOJQ/$t"
  done
  OUT=$(b 'mix ecto.reset' | PATH="$NOJQ" "$SH" "$ROOT/hooks/elixir-hook.sh" pre bash 2>&1); RC=$?
  if [ "$RC" -eq 0 ] && [ -z "$OUT" ]; then ok; else bad no_jq_fails_open "exit $RC $OUT"; fi
fi

echo "[$TARGET] pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
