# Changelog

All notable changes to `harmony` will be documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **`harmony capture` — reverse reconcile.** Adds plugins/MCP servers installed
  on this machine but missing from the manifest (the inverse of `apply`'s prune),
  then commits and pushes if sync mode is `pull-push`. `--dry-run` reports without
  writing. The protected `harmony` plugin is never captured; MCP servers with
  secret-looking env values are skipped (never committed to git) and reported for
  manual handling.
- **Stop hook (`hooks/session-stop.sh`).** On session end, runs `harmony status`
  (read-only) and, if plugins/MCP servers were installed this session but aren't
  in the manifest, prints a non-blocking nudge to run `harmony capture` (so the
  config syncs to other Macs instead of being pruned next start). Fail-open,
  honors `stop_hook_active`, never auto-captures. Known v1 gap: hand-authored
  skills/agents dropped outside a plugin and outside `content/` are not detected.
- **v2.1 sync hardening**:
  - `harmony_sync_state` state machine classifies the config repo as
    in-sync / behind / ahead / diverged / dirty / no-upstream / offline / detached
    — distinguishing offline (can't reach remote) from a real divergence, and
    handling first-run no-upstream.
  - `verify` gains a `sync` row and `status` reports sync state (visible health,
    not just silent side-effects).
  - State-aware pull messages: only `behind` fast-forwards; `ahead` in pull-mode
    warns that local commits aren't pushed; `diverged`/`offline`/`dirty` each get
    a distinct, actionable message.
  - `sync.autoCommit` (pull-push): auto-commit uncommitted config edits before
    pushing, with a hostname-stamped message.
  - `is_dirty` now also counts untracked files (via `git status --porcelain`).
  - Test: `test/test-sync-hardening.sh` (state classification incl.
    behind/ahead/diverged/dirty, autoCommit→push, verify sync row). Suite 7/7.
- **v2 multi-Mac git-sync layer** (`lib/sync.sh`): optional `sync` block in the
  manifest. `apply` runs `git pull --ff-only` on the config repo before reconciling
  (warns and skips on divergence / uncommitted changes — never blocks a session),
  and pushes local commits afterward when `mode: "pull-push"`. New `harmony sync`
  verb for on-demand pull/push (`--push` forces the push once).
- **Per-host overrides** (`lib/overrides.sh`): `overrides/<hostname>.json` is
  deep-merged over the base manifest to produce the effective manifest, so one
  machine can differ without forking. Objects merge recursively; scalars/arrays
  replace.
- `sync` block added to the JSON schema and the `single-mac.json` example.
- Test: `test/test-sync-and-overrides.sh` (ff-pull picks up a remote change; dirty
  repo skips pull + warns; per-host override merges).
- `lib/common.sh`: an EXIT-cleanup registry (`harmony_on_exit`) so the lock and the
  overrides temp-file cleanups no longer clobber each other's `trap`.
- Initial scaffold: repo layout, MIT license, README front door.
- Plan: see `/Users/Frank/.claude/plans/dazzling-humming-star.md` (private; not shipped with the repo).
