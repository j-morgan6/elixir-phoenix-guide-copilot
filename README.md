# Elixir Phoenix Guide — GitHub Copilot Edition

A GitHub Copilot-native instruction set that brings opinionated, production-ready Elixir and Phoenix guidance directly into your editor. It ships 19 context-aware instructions covering the full Phoenix stack, 27 hooks that automatically enforce code quality and security rules on every file write, agent docs for deep-dive assistance, and 4 analysis scripts that detect duplication, complexity, and project configuration.

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
│   ├── detect_template_duplication.sh   # HEEx duplication detection
│   ├── detect_project.sh                # Project capability detection
│   └── run_analysis.sh                  # Full analysis suite
└── AGENTS.md                            # Agent guidance for Ecto, LiveView, structure, testing
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

### 27 Hooks (21 PreToolUse + 6 PostToolUse)

Hooks run automatically via `.github/hooks/elixir-guard.json` and enforce rules on every tool call.

| Category | What Gets Blocked | What Gets Warned |
|----------|-------------------|------------------|
| **Dangerous commands** | `mix ecto.reset`, force push, `MIX_ENV=prod` | -- |
| **Security** | `String.to_atom/1`, SQL injection in `fragment`, open redirect, raw SQL with interpolation | `raw/1` (XSS), sensitive data in Logger, timing-unsafe token comparison |
| **Deprecated APIs** | `.flash_group`, `form_for`, `live_redirect`/`live_patch`, `@current_user` on Phoenix 1.8+ scope projects | -- |
| **Upload / config** | Hardcoded file paths, hardcoded file size limits | `auto_upload: true` without handle_progress |
| **OTP / LiveView** | Missing `@impl true` before callbacks, `static_paths` mismatch | Repo called directly in LiveView, missing preload |
| **Code style** | -- | Nested if/else, chained Enum.map/filter, string concat in loops |
| **Migrations** | -- | Missing FK index, missing on_delete, unsafe column removal, NOT NULL without default |
| **Post-write reminders** | -- | Skill invocation reminder, mix.exs security audit, template duplication, code quality analysis, `with` missing else, context boundary violations |

### Agent Docs (AGENTS.md)

Consolidated guidance covering:
- **Ecto Conventions** -- schema design, query optimization, database conventions
- **LiveView Checklist** -- implementation patterns, component design, common pitfalls
- **Project Structure** -- directory layout, context organization, file naming
- **Testing Guide** -- ExUnit patterns, DataCase/ConnCase, test organization

### 4 Analysis Scripts

| Script | Purpose |
|--------|---------|
| `code_quality.exs` | Elixir static analysis -- complexity, duplication, and unused function detection |
| `detect_template_duplication.sh` | Finds repeated HEEx template blocks that could be extracted into components |
| `detect_project.sh` | Detects project capabilities (LiveView, Oban, Scope, etc.) and writes a cache file for context-aware hooks |
| `run_analysis.sh` | Runs the full suite of analysis scripts against the current project |

## Requirements

Works with any Elixir/Phoenix project. Elixir is optional -- it is only required for the `code_quality.exs` script (code quality analysis). All other hooks and instructions function without a local Elixir installation.

## Claude Code Version

The Claude Code version of this guide (with CLAUDE.md, hooks, and skills for the Claude Code CLI) is available at:
https://github.com/j-morgan6/elixir-phoenix-guide

## License

MIT
