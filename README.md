# Elixir Phoenix Guide — Copilot Plugin

A GitHub Copilot plugin that brings opinionated, production-ready Elixir and Phoenix guidance directly into your editor. It ships 19 skills covering the full Phoenix stack, 27 hooks that automatically enforce code quality and security rules on every file write, 4 specialized agent docs for deep-dive assistance, and 4 analysis scripts that detect duplication, complexity, and project configuration — so you spend less time remembering conventions and more time shipping features.

## Installation

```
copilot plugin install https://github.com/j-morgan6/elixir-phoenix-guide-copilot
```

## What's Included

### 19 Skills

| Skill | Description |
|-------|-------------|
| `elixir-essentials` | MANDATORY for ALL Elixir code changes. Invoke before writing any .ex or .exs file. |
| `ecto-essentials` | MANDATORY for ALL database work. Invoke before modifying schemas, queries, or migrations. |
| `ecto-changeset-patterns` | MANDATORY for ALL changeset work beyond basic CRUD. Invoke before writing multiple changesets, cast_assoc, or conditional validation. |
| `ecto-nested-associations` | MANDATORY for ALL nested association and multi-table work. Invoke before writing cast_assoc, cast_embed, Ecto.Multi, or cascade operations. |
| `phoenix-liveview-essentials` | MANDATORY for ALL LiveView work. Invoke before writing LiveView modules or .heex templates. |
| `phoenix-liveview-auth` | MANDATORY for ALL LiveView authentication work. Invoke before writing on_mount hooks, auth plugs for LiveViews, or session handling in LiveView modules. |
| `phoenix-auth-customization` | MANDATORY when extending phx.gen.auth with custom fields. Invoke before adding usernames, profiles, or custom registration fields. |
| `phoenix-authorization-patterns` | MANDATORY for ALL authorization and access control work. Invoke before writing permission checks, policy modules, or role-based access. |
| `phoenix-channels-essentials` | MANDATORY for ALL Phoenix Channels work. Invoke before writing socket, channel, or Presence modules. |
| `phoenix-json-api` | MANDATORY for ALL JSON API work. Invoke before writing API controllers, pipelines, or JSON responses. |
| `phoenix-pubsub-patterns` | MANDATORY for ALL PubSub and real-time broadcast work. Invoke before writing PubSub.subscribe, broadcast, or handle_info for real-time updates. |
| `phoenix-uploads` | MANDATORY for file upload features. Invoke before implementing upload or file serving functionality. |
| `otp-essentials` | MANDATORY for ALL OTP work. Invoke before writing GenServer, Supervisor, Task, or Agent modules. |
| `oban-essentials` | MANDATORY for ALL Oban work. Invoke before writing workers or enqueuing jobs. |
| `security-essentials` | MANDATORY for ALL security-sensitive code. Invoke before writing auth, token handling, redirects, or user input processing. |
| `telemetry-essentials` | MANDATORY for ALL telemetry, logging, and observability work. Invoke before writing telemetry handlers, Logger calls, or metrics code. |
| `testing-essentials` | MANDATORY for ALL test files. Invoke before writing any _test.exs file. |
| `deployment-gotchas` | MANDATORY for deployment and release configuration. Invoke before modifying config/, rel/, or Dockerfile. |
| `code-quality` | Automated code quality detection — duplication, complexity, unused functions. Invoke when analyzing or refactoring Elixir code. |

### 27 Hooks (21 PreToolUse + 6 PostToolUse)

| Category | What Gets Blocked | What Gets Warned |
|----------|-------------------|------------------|
| **Dangerous commands** | `mix ecto.reset`, force push, `MIX_ENV=prod` | — |
| **Security** | `String.to_atom/1`, SQL injection in `fragment`, open redirect, raw SQL with interpolation | `raw/1` (XSS), sensitive data in Logger, timing-unsafe token comparison |
| **Deprecated APIs** | `.flash_group`, `form_for`, `live_redirect`/`live_patch`, `@current_user` on Phoenix 1.8+ scope projects | — |
| **Upload / config** | Hardcoded file paths, hardcoded file size limits | `auto_upload: true` without handle_progress |
| **OTP / LiveView** | Missing `@impl true` before callbacks, `static_paths` mismatch | Repo called directly in LiveView, missing preload |
| **Code style** | — | Nested if/else, chained Enum.map/filter, string concat in loops |
| **Migrations** | — | Missing FK index, missing on_delete, unsafe column removal, NOT NULL without default |
| **Post-write reminders** | — | Skill invocation reminder, mix.exs security audit, template duplication, code quality analysis, `with` missing else, context boundary violations |

### 4 Agent Docs

| Agent | Description |
|-------|-------------|
| `ecto-conventions` | Ecto schema design, query optimization, and database convention guidance. |
| `liveview-checklist` | LiveView implementation patterns, component design, and common pitfall guidance. |
| `project-structure` | Phoenix project directory layout, context organization, and file naming conventions. |
| `testing-guide` | ExUnit testing patterns, DataCase/ConnCase usage, and test organization guidance. |

### 4 Analysis Scripts

| Script | Purpose |
|--------|---------|
| `code_quality.exs` | Elixir static analysis — complexity, duplication, and unused function detection. |
| `detect_template_duplication.sh` | Finds repeated HEEx template blocks that could be extracted into components. |
| `detect_project.sh` | Detects project capabilities (LiveView, Oban, Scope, etc.) and writes a cache file for context-aware hooks. |
| `run_analysis.sh` | Runs the full suite of analysis scripts against the current project. |

## Requirements

Works with any Elixir/Phoenix project. Elixir is optional — it is only required for the `code_quality.exs` script (code quality analysis). All other hooks and skills function without a local Elixir installation.

## Claude Code Version

The Claude Code version of this guide (with CLAUDE.md, hooks, and skills for the Claude Code CLI) is available at:
https://github.com/j-morgan6/elixir-phoenix-guide

## License

MIT
