# Elixir Phoenix Guide — GitHub Copilot Edition

A GitHub Copilot-native instruction set that brings opinionated, production-ready Elixir and Phoenix guidance directly into your editor. It ships 19 context-aware instructions covering the full Phoenix stack, 17 hook checks that block destructive commands and catch security bugs and removed APIs as Copilot writes code, agent docs for deep-dive assistance, and analysis scripts for duplication, branch complexity and project detection.

## Installation

Copy the following directories into your Elixir project root:

```bash
# Clone or download this repo
git clone https://github.com/j-morgan6/elixir-phoenix-guide-copilot.git

# Copy into your project
cp -r elixir-phoenix-guide-copilot/.github your-project/.github
cp -r elixir-phoenix-guide-copilot/hooks your-project/hooks
cp -r elixir-phoenix-guide-copilot/scripts your-project/scripts
cp elixir-phoenix-guide-copilot/AGENTS.md your-project/AGENTS.md
```

That's it. Copilot will automatically load the relevant instructions when you edit matching files.

## File Structure

```
your-project/
├── .github/
│   ├── copilot-instructions.md          # Project-wide overview (always loaded)
│   ├── instructions/
│   │   ├── elixir-essentials.instructions.md
│   │   ├── ecto-essentials.instructions.md
│   │   ├── ecto-changeset-patterns.instructions.md
│   │   ├── ecto-nested-associations.instructions.md
│   │   ├── phoenix-liveview-essentials.instructions.md
│   │   ├── phoenix-liveview-auth.instructions.md
│   │   ├── phoenix-uploads.instructions.md
│   │   ├── phoenix-auth-customization.instructions.md
│   │   ├── phoenix-pubsub-patterns.instructions.md
│   │   ├── phoenix-authorization-patterns.instructions.md
│   │   ├── phoenix-channels-essentials.instructions.md
│   │   ├── phoenix-json-api.instructions.md
│   │   ├── testing-essentials.instructions.md
│   │   ├── otp-essentials.instructions.md
│   │   ├── oban-essentials.instructions.md
│   │   ├── code-quality.instructions.md
│   │   ├── security-essentials.instructions.md
│   │   ├── deployment-gotchas.instructions.md
│   │   └── telemetry-essentials.instructions.md
│   └── hooks/
│       └── elixir-guard.json            # Hook configuration
├── hooks/
│   ├── elixir-hook.sh                   # Hook script (bash)
│   └── elixir-hook.ps1                  # Hook script (PowerShell)
├── scripts/
│   ├── code_quality.exs                 # Elixir static analysis
│   ├── detect_project.sh                # One-line project summary
│   ├── run_analysis.sh                  # Full analysis suite
│   └── lib/
│       └── common.sh                    # Shared shell helpers for the scripts
└── AGENTS.md                            # Agent reference: Ecto, project structure, LiveView, testing
```

## What's Included

### 19 Instructions

Each instruction is automatically loaded by Copilot when you edit files matching its `applyTo` pattern.

| Instruction | Applies To |
|-------------|-----------|
| `elixir-essentials` | `**/*.ex,**/*.exs` |
| `ecto-essentials` | `**/*.ex,**/*.exs` |
| `ecto-changeset-patterns` | `**/*.ex,**/*.exs` |
| `ecto-nested-associations` | `**/*.ex,**/*.exs` |
| `phoenix-liveview-essentials` | `**/live/**/*.ex,**/*_live.ex,**/*.html.heex,**/live/**/*.html.heex` |
| `phoenix-liveview-auth` | `**/live/**/*.ex,**/*_live.ex` |
| `phoenix-uploads` | `**/live/**/*.ex,**/*_live.ex` |
| `phoenix-auth-customization` | `**/*.ex,**/*.exs` |
| `phoenix-pubsub-patterns` | `**/*.ex` |
| `phoenix-authorization-patterns` | `**/*.ex` |
| `phoenix-channels-essentials` | `**/*.ex` |
| `phoenix-json-api` | `**/*.ex` |
| `testing-essentials` | `**/*_test.exs,**/test/**/*.exs` |
| `otp-essentials` | `**/*.ex` |
| `oban-essentials` | `**/*.ex` |
| `code-quality` | `**/*.ex,**/*.exs,**/*.html.heex` |
| `security-essentials` | `**/*.ex,**/*.exs` |
| `deployment-gotchas` | `**/config/**/*.exs,**/rel/**/*,**/Dockerfile` |
| `telemetry-essentials` | `**/*.ex` |

### Hooks (7 PreToolUse checks + 10 PostToolUse checks)

Hooks run automatically via `.github/hooks/elixir-guard.json`. `hooks/elixir-hook.sh` (macOS/Linux, needs `jq`) and `hooks/elixir-hook.ps1` (Windows PowerShell 5.1 / PowerShell 7, no extra tools) behave identically.

| When | Check | Result |
|------|-------|--------|
| Before a shell command | `mix ecto.reset` / `mix ecto.drop`, unless `MIX_ENV=test` | **deny** |
| | `git push --force`, `-f`, combined flags such as `-uf`, `+refspec` (allows `--force-with-lease`, `--force-if-includes`) | **deny** |
| Before a file write | SQL built by interpolation in `Repo.query`/`SQL.query` (string or heredoc; `#{@attr}` allowed) | **deny** |
| | Interpolation inside `fragment()` | **deny** |
| | `redirect(external: params…)` (open redirect) | **deny** |
| | `form_for` (removed in phoenix_html 4) | **deny** |
| | `live_redirect`, `live_patch`, `push_redirect` (deprecated) | **deny** |
| After a file write | `String.to_atom/1` | review note |
| | `raw/1`, `Phoenix.HTML.raw/1` | review note |
| | Logger message interpolating a sensitive name (`#{…password…}`, token, secret, api_key, private_key, credential, authorization) | review note |
| | `IO.inspect` / `dbg` in `.ex` files (not in `mix/tasks/`) | review note |
| | `==` on token/secret/api_key/signature (use `Plug.Crypto.secure_compare/2`) | review note |
| | Callback (`mount`, `handle_*`, `terminate`) without `@impl true` on its first clause | review note |
| | Migration `references()` column with no index on that table in the same migration | review note |
| | Migration `references()` without `on_delete:` | review note |
| | `@current_user` in a project that uses Phoenix 1.8 scopes (a `Scope` module, or `current_scope` in `user_auth.ex`) | review note |
| | `Repo` called directly in a LiveView module (`*_live.ex`, `live/`) | review note |

**deny**: the tool call is refused with `{"permissionDecision":"deny","permissionDecisionReason":"…"}` and the reason is shown to Copilot. **review note**: returned as `additionalContext` after the write; Copilot sees it and decides, nothing is blocked. (Copilot accepts `additionalContext` only from postToolUse hooks, which is why the heuristic checks run after the write.)

How the file checks decide what to report:

- **Only the text this tool call writes is judged**, so code Copilot didn't touch is never re-flagged. Before a write, the edit is applied to a copy of the file and only the replaced text counts (a whole-file write counts lines that weren't already in the file). After a write, the reported lines are where the new text now sits; for a whole-file write, lines added since the git index (the whole file when it is new or untracked).
- **Findings use the whole file as context**: a later clause of a callback whose first clause has `@impl true` is fine, and a migration index further down the file counts for its table.
- `#` comments, `@moduledoc`/`@doc`/`@typedoc` text and HEEx comments are ignored.
- Skipped: test files (`*_test.exs`, `test/`), `deps/`, `_build/`, `node_modules/`, `.elixir_ls/`.

The command guard:

- Runs only in Elixir projects (a `mix.exs` in the working directory or a parent; umbrella roots count).
- Splits the command on `;`, `&&`, `||`, `|`, `&`, newlines, subshells and `$(…)` and checks each part's command words. Quoted text, `#` comments and heredoc bodies are ignored, so `git commit -m "… mix ecto.reset …"` and `grep "mix ecto.reset" docs/` pass. Leading `VAR=value`, `env`, `git -C dir` and `git -c key=value` are understood; `mix do ecto.drop + ecto.create` is checked task by task.
- `MIX_ENV=test` counts when it prefixes the command, was exported earlier in the same command line, or is set in Copilot's environment.
- **Opt-out**: set `EPG_ALLOW` to a comma-separated list of `force_push`, `ecto_reset`, `ecto_drop` — as a command prefix (`EPG_ALLOW=force_push git push --force origin release`), or in the environment Copilot runs with (or the hook entry's `env` in `elixir-guard.json`) for every session. The deny message tells Copilot it may use the prefix only when you asked for the destructive command explicitly.
- Known limits: commands inside `bash -c "…"`/`eval` strings, aliases, shell functions and `$(…)` inside double quotes are not inspected.

The hooks fail open: bad input, a missing `jq` (bash script) or an internal error lets the tool call through rather than blocking it. Nothing runs `mix` or compiles code.

### Agent Docs (AGENTS.md)

Reference material Copilot can read on demand, generated from the canonical plugin's skill reference files:
- **Ecto Reference** -- field types, associations, validators and constraints, query syntax, Repo return shapes, migration operations, soft delete
- **Phoenix Project Structure** -- directory layout, context boundaries, file organization, configuration, static files and uploads
- **LiveView Checklist** -- review checklist for LiveView modules and templates
- **LiveView JS Interop** -- hooks, colocated hooks/JS/CSS, `push_event`, replies, `JS` commands
- **Testing Reference** -- fixtures, context/schema/LiveView/upload tests, async tests and the SQL sandbox

### Analysis Scripts

Run these yourself (or ask Copilot to); the hooks don't call them.

| Script | Purpose |
|--------|---------|
| `code_quality.exs` | On-demand analysis: duplicated function bodies and branch complexity (`elixir scripts/code_quality.exs scan lib/`). For unused functions use `mix compile --warnings-as-errors` and `mix xref` |
| `detect_project.sh` | Prints a one-line project summary: locked Phoenix/LiveView versions, whether the app uses Phoenix 1.8 scopes, Ecto adapter, Oban, umbrella apps |
| `run_analysis.sh` | Runs `code_quality.exs` over `lib/` (or every `apps/*/lib` in an umbrella) |
| `lib/common.sh` | Shell helpers shared by the scripts above |

## Requirements

Works with any Elixir/Phoenix project.

- **`jq`** for `hooks/elixir-hook.sh` (macOS/Linux): `brew install jq`, `apt-get install jq`. Without it the bash hooks do nothing. The PowerShell hook needs nothing extra.
- `git` (optional) lets the post-write check limit whole-file writes to the lines that changed.
- Elixir only for the on-demand `code_quality.exs` analysis; hooks and instructions don't need it.

## Testing the hooks

```bash
/bin/bash tests/run_tests.sh                       # bash hook (macOS bash 3.2 compatible)
PWSH=/path/to/pwsh /bin/bash tests/run_tests.sh ps1  # same cases against the PowerShell hook
```

The suite feeds Copilot-shaped hook JSON to the scripts and checks every hook check in both directions, every command-guard case, changed-lines behaviour for edits and whole-file writes, and the accepted payload shapes.

## Claude Code Version

The Claude Code version of this guide (with CLAUDE.md, hooks, and skills for the Claude Code CLI) is available at:
https://github.com/j-morgan6/elixir-phoenix-guide

## License

MIT
