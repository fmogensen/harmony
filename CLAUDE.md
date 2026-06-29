# CLAUDE.md — harmony repo

This file guides Claude Code when working inside this repo.

## What this repo is

`harmony` is a Claude Code plugin (MIT, OSS) that declaratively manages a user's Claude Code config. See `README.md` for the user-facing pitch.

This repo contains the **engine only** — generic, reusable, with zero user-specific content.

## Hard rules

- **Zero personal/Frank-specific content in this repo.** Frank's hooks/skills/Brewfile/global-CLAUDE.md live in his private `~/code/harmony-config/`, not here. If you find yourself writing anything Frank-specific in this repo, stop and put it in the data repo instead.
- **Bash + jq only.** No Python, no Node. Match macOS bash 3.2.
- **Idempotent.** Every reconciler operation must be safe to re-run.
- **Fail-open.** Per-domain failures log + warn but never abort the pipeline. SessionStart hook must never block a session.
- **`${CLAUDE_PLUGIN_ROOT}`** — the official env var the runtime sets when invoking plugin hooks. Use it; do not invent your own.
- **`${HARMONY_CONFIG_DIR}`** — the harmony-specific env var pointing at the user's data repo. Default: `~/code/harmony-config/`. Can be overridden.
- **Self-uninstall guard.** `domain-plugins.sh` must never uninstall the `harmony` plugin itself, even if absent from the user's manifest.

## File map

| Path | What |
|---|---|
| `bin/harmony` | The CLI dispatcher. Routes to subcommands. |
| `lib/common.sh` | Logging, jq helpers, flock, host detection. Sourced by everything. |
| `lib/domain-*.sh` | One per managed domain. Each exposes `domain_X_plan`, `domain_X_apply`, `domain_X_verify`. |
| `hooks/hooks.json` | Plugin-declared hooks (SessionStart points at `hooks/session-start.sh`). |
| `hooks/session-start.sh` | Minimal wrapper that calls `harmony apply --quiet`. |
| `.claude-plugin/plugin.json` | Plugin metadata (name, version, components). |
| `commands/*.md` | Slash commands: `/harmony-apply`, `/harmony-status`, `/harmony-verify`. |
| `schema/manifest.schema.json` | JSON Schema for the user's `harmony.json` manifest. |
| `examples/single-mac.json` | Minimal starter manifest. |
| `test/*.sh` | End-to-end tests in tmpdir. |
| `docs/*.md` | Architecture, manifest reference, FAQ. |

## Apply order

```
content → settings → plugins → mcp → brew → launchd → keybindings
```

(See `bin/harmony` and the plan file for why.)

## Testing

```sh
test/run-all.sh    # runs all test/test-*.sh in sequence inside a tmpdir
```

Each test:
1. Creates a fresh tmpdir as a fake `${HARMONY_CONFIG_DIR}`.
2. Writes a fake manifest.
3. Runs `harmony apply` (or whatever verb).
4. Asserts side-effects.
5. Cleans up.

## What this repo does NOT contain

- Frank's personal config (skills, hooks, agents, Brewfile, etc.) — those live in `~/code/harmony-config/`.
- A SaaS layer — `harmony` is a single-user tool. The multi-user/team story is users sharing a git repo of their data.
- Memory management — out of scope. See `clonelab` for Frank's broader digital-twin work.

## When in doubt

Refer to the original plan at `/Users/Frank/.claude/plans/dazzling-humming-star.md` (Frank-local, not in this repo). It's the source of truth for design decisions until that content migrates into `docs/`.
