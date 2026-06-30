# Changelog

All notable changes to `harmony` will be documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
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
