# Elixir Phoenix Guide

This project uses the Elixir Phoenix Guide for enforced best practices.

## How Skills Work

When working with Elixir (.ex, .exs) or HEEx (.html.heex) files, context-specific instructions are automatically loaded via the `.github/instructions/` directory. These provide rules for:

- **Elixir fundamentals** — pattern matching, pipe operator, error tuples
- **Phoenix LiveView** — two-phase rendering, assigns, callbacks
- **Ecto** — changesets, queries, associations, migrations
- **OTP** — GenServer, Supervisor, Task, Agent
- **Oban** — background jobs, workers, queues
- **Security** — SQL injection, XSS, atom exhaustion, open redirects
- **Testing** — ExUnit, DataCase, ConnCase, async safety
- **Deployment** — runtime config, releases, health checks
- **Channels** — WebSocket auth, Presence, handle_in/push
- **Telemetry** — structured logging, metrics, dashboards
- **JSON API** — pipelines, error rendering, pagination

## Hooks

PreToolUse and PostToolUse hooks enforce these rules automatically, judging only the code you are writing:
- **Blocking hooks** deny destructive commands (`mix ecto.reset`/`mix ecto.drop` outside `MIX_ENV=test`, force pushes) and writes that add near-certain bugs (SQL built by interpolation, interpolation in `fragment`, `redirect(external: params…)`, removed `form_for`, deprecated `live_redirect`/`live_patch`/`push_redirect`). Fix the code and write it again. If the user explicitly asked for a blocked command, re-run it prefixed with the `EPG_ALLOW=…` value the message names.
- **Review notes** after a write flag likely problems (`String.to_atom/1`, `raw/1`, secrets in Logger messages, leftover `IO.inspect`/`dbg`, `==` on tokens, missing `@impl true`, unindexed or `on_delete`-less foreign keys, `@current_user` in scope-based apps, `Repo` calls in LiveViews). Fix them or confirm they are intentional.

See AGENTS.md for reference material on Ecto, project structure, LiveView (checklist and JS interop), and testing.
