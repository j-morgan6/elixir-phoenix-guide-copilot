# Changelog

## [2.4.0] - 2026-07-03

### Fixed
- **Advisory hook output** — `elixir-hook.sh` and `elixir-hook.ps1` previously wrote advisory/warning messages to stderr, which Copilot's hook runner discards entirely on exit 0. All advisories are now emitted as `{"additionalContext": "..."}` JSON on stdout via a new `emit_context` (bash) / `Emit-Context` (PowerShell) helper, matching Copilot's hook-output contract. Deny paths (`{"permissionDecision":"deny",...}`) were already correct and are unchanged.
- **Post-write check ordering** — in both hook scripts, the generic "did you invoke the skill" reminder previously ran first and (since only one JSON object can be emitted per invocation) silently prevented every other post-write advisory — mix.exs audit reminder, missing-preload warning, `with` missing-else warning, and LiveView/Repo boundary-violation warning — from ever being seen. Reordered so specific, actionable warnings run first and the generic reminder is a fallback.
- **`code_quality.exs` stdout leak** — its plain-text analysis output was being interleaved with the hook's own JSON on stdout, corrupting the JSON contract; stdout is now suppressed for that invocation.
- Header comments in both hook scripts corrected: hooks are configured in `elixir-guard.json`, not `hooks.json`.
- **`security-essentials.instructions.md`** — `applyTo` now includes `**/*.html.heex` (previously `.ex`/`.exs` only), so security guidance also loads for HEEx templates.

### Changed
- All 19 instruction files resynced from the corrected canonical skills in `elixir-phoenix-guide` (skills were substantially revised there since this port was first generated; this is the first resync). `deployment-gotchas`, `elixir-essentials`, `phoenix-liveview-essentials`, `ecto-nested-associations`, and `phoenix-liveview-auth` changed the most.
- `scripts/code_quality.exs`, `scripts/detect_project.sh`, and `scripts/run_analysis.sh` recopied from canonical sources.
- Added `scripts/sync_copilot.sh` upstream (in the `elixir-phoenix-guide` repo) to regenerate this port mechanically going forward.

### Removed
- **`detect_template_duplication.sh`** and all references to it (hook call sites, `run_analysis.sh`, `README.md`) — removed upstream from `elixir-phoenix-guide` and no longer shipped here.

### Known gaps
- `elixir-hook.ps1`'s deny paths still use `Write-Error` + `exit 2` instead of a `{"permissionDecision":"deny",...}` JSON object on stdout (unlike `elixir-hook.sh`, whose deny paths are already correct). Reworking every PowerShell deny site is a larger follow-up.

## [2.3.1] - 2026-04-13

### Added
- Initial Copilot plugin port from elixir-phoenix-guide Claude Code plugin v2.3.1
- 19 skills covering Elixir, Phoenix, LiveView, Ecto, OTP, Oban, security, and more
- 27 hooks (21 PreToolUse + 6 PostToolUse) for code quality enforcement
- 4 agent docs for specialized guidance
- 4 analysis scripts (code quality, template duplication, project detection)
- Cross-platform support (macOS/Linux via bash, Windows via PowerShell)
