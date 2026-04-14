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

PreToolUse and PostToolUse hooks enforce these rules automatically:
- **Blocking hooks** prevent dangerous operations (ecto.reset, force push, SQL injection, atom exhaustion)
- **Warning hooks** flag code smells (nested if/else, inefficient Enum chains, missing preloads)

See AGENTS.md for specialized agent guidance on Ecto, LiveView, project structure, and testing.
