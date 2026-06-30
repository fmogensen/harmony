# harmony

**Declarative config for Claude Code.** One manifest, full lifecycle (install *and* uninstall), reconciled on every session start. Like `home-manager`, but built for Claude Code.

> Status: **v1 in alpha** — works end-to-end on macOS. Built and dogfooded by one user; not yet announced. Star the repo if the idea resonates and you want updates.

```sh
# 1. Install
claude plugin marketplace add fmogensen/harmony-marketplace
claude plugin install harmony@harmony-marketplace

# 2. Restart Claude Code

# 3. Create your config directory from a starter template
harmony init

# 4. Edit ~/code/harmony-config/harmony.json to taste, then:
harmony apply       # reconcile your Mac to the manifest
harmony verify      # 7/7 green = your Mac matches your config
```

That's the whole loop.

## Why you might want this

You've probably noticed:
- `~/.claude/settings.json` becomes a mystery file. What did you change? When? Why?
- `claude plugin install/uninstall` works, but there's no "remove this everywhere" — you have to remember every machine you installed something on.
- Your skills shell out to `jq`, `rg`, `ffmpeg`, `pdftotext`, … and break silently on a new Mac because a brew dep is missing.
- macOS LaunchAgents pile up. Plists you forgot you installed years ago still run on Sundays.
- Setting up Claude Code on a new machine is undocumented ritual.

`harmony` makes all of that declarative. You write a manifest; harmony reconciles the Mac to it. Add a plugin → next `harmony apply` installs it. Remove the line → next `harmony apply` uninstalls it. Same for marketplaces, hooks, MCP servers, brew deps, LaunchAgents, keybindings.

## What you get

- **Single source of truth.** One `harmony.json` describes what your machine should look like.
- **Real uninstall propagation.** Remove a plugin from the manifest → it's actually uninstalled. The Claude Code CLI gives you install/uninstall; harmony gives you state-sync.
- **Brewfile reconciliation with tier policy.** `safe` tier auto-installs silently; `ask` tier nudges you. Never auto-uninstalls (brew formulas have side-effects — that's a footgun we explicitly opted out of).
- **Declarative LaunchAgents with prune.** Add a launchd entry to the manifest → installed. Remove it → uninstalled. Orphan plists from old setups get pruned automatically, scoped to a configurable label prefix so Apple/Homebrew agents stay untouched.
- **Hand-edit escape hatch.** Only keys you declare in the manifest are owned by harmony. Anything else in your `~/.claude/settings.json` is preserved. Want a one-off setting for this Mac only? Just edit settings.json — harmony won't fight you.
- **`harmony verify`** — 7-domain smoke test. Green means your Mac matches your manifest. Use it on a fresh laptop to confirm setup is complete.
- **Self-protection.** harmony refuses to uninstall itself even if you forget to list it in your manifest.

## What harmony does NOT do

Honest scope (set expectations before you adopt):

- **Doesn't sync your shell dotfiles.** Use `chezmoi`, `yadm`, or Nix `home-manager` for `.zshrc`, `.gitconfig`, etc.
- **Doesn't manage OS preferences, TCC permissions, Keychain, or Mail.app accounts.** Those are per-machine grants you do manually once.
- **Doesn't store or manage secrets.** harmony refuses to write API keys / tokens into your manifest (sanitiser detects common patterns and aborts). Real secrets live in shell env vars, referenced from manifest entries.
- **Doesn't sync your Claude Code memory, knowledge-base content, or anything in `~/Documents/`.** Memory has different lifecycle from config — out of scope.
- **Doesn't replace `brew` itself.** It reconciles your Brewfile (which `brew bundle` already understands).
- **Multi-Mac git sync** (v2, now shipped). Add a `sync` block to your manifest and harmony keeps the `harmony-config` repo in step across machines: `git pull --ff-only` before each apply (warns, never blocks, if the local repo has diverged or uncommitted changes), and — if `mode: "pull-push"` — pushes your local config commits after. A per-host `overrides/<hostname>.json` is deep-merged over the base manifest so one Mac can differ without forking. See **Multi-Mac sync** below.

## Multi-Mac sync (v2)

Keep all your Macs in step from one git-backed `harmony-config` repo. Add to your manifest:

```json
"sync": {
  "enabled": true,
  "mode": "pull",          // "pull" (default, safe) or "pull-push"
  "remote": "origin",
  "branch": "",             // "" = current branch
  "autoCommit": false       // pull-push: commit local edits before pushing
}
```

**Sync states.** harmony classifies the config repo before acting and reports it
in `verify` (a `sync` row) and `status`: `in sync` · `behind` (apply pulls) ·
`ahead` (local commits not pushed) · `diverged` (resolve manually) · `dirty`
(uncommitted — won't pull) · `no upstream` · `offline` (can't reach the remote —
distinct from diverged). Only `behind` triggers an actual fast-forward; every
other state is reported and left alone.

**autoCommit.** With `mode: "pull-push"` and `autoCommit: true`, harmony commits
your uncommitted config edits (message: `harmony: auto-commit config from <host>`)
before pushing — so "edit the manifest, next apply propagates it" works without
manual `git commit`.

- **`pull`** — before every apply, harmony runs `git pull --ff-only`. If the repo
  has diverged or has uncommitted changes, it **warns and skips** the pull, then
  applies your current local state. It never blocks a session.
- **`pull-push`** — additionally pushes local commits (commits ahead of upstream)
  after a successful apply. Opt-in, because auto-push is higher-risk. A failed push
  warns, never aborts.
- **On demand:** `harmony sync` (pull, +push if `pull-push`) or `harmony sync --push`
  (force the push once).

**Per-host overrides.** Drop `overrides/<hostname>.json` in your config repo to make
one machine differ. It's deep-merged over the base `harmony.json` (objects merge
recursively; scalars and arrays are replaced). Example — give just the iMac an extra
launchd agent, or flip one setting on the laptop — without forking the manifest.

## Architecture

```
            ┌─────────────────────────────┐
            │  fmogensen/harmony          │  ← this repo (OSS, MIT)
            │  the engine plugin          │     installed via marketplace
            │  bin/, lib/, hooks.json,    │     ships zero user content
            │  schema, slash commands     │
            └─────────────┬───────────────┘
                          │ reads
                          ▼
            ┌─────────────────────────────┐
            │  ~/code/your-config/        │  ← you maintain this
            │  your data repo (private)   │     plain folder or git
            │  harmony.json + skills/     │     keep it in your own git
            │  agents/, hooks/, Brewfile  │     repo for backup/sync
            └─────────────┬───────────────┘
                          │ apply
                          ▼
            ┌─────────────────────────────┐
            │  ~/.claude/                 │  ← your live config
            │  settings.json, symlinks,   │     fully reconciled
            │  ~/Library/LaunchAgents,    │     to the manifest
            │  installed plugins, …       │
            └─────────────────────────────┘
```

The engine plugin updates via the marketplace (`claude plugin update harmony`). Your data evolves in your own repo at whatever cadence you want.

## Comparison

|                                        | harmony | hand-editing settings.json | chezmoi / yadm | Nix home-manager |
|----------------------------------------|:-------:|:--------------------------:|:--------------:|:----------------:|
| Knows Claude Code's settings.json shape|    ✓    |             —              |       —        |        —         |
| Manages plugins + marketplaces         |    ✓    |          partial           |       —        |        —         |
| Manages MCP servers                    |    ✓    |             —              |       —        |        —         |
| Brewfile reconciliation                |    ✓    |             —              |    partial     |        ✓         |
| LaunchAgent management                 |    ✓    |             —              |    partial     |     partial      |
| Declarative (state-sync)               |    ✓    |             —              |       ✓        |        ✓         |
| Reversible (uninstalls propagate)      |    ✓    |             —              |    partial     |        ✓         |
| One-command install + smoke test       |    ✓    |             —              |    partial     |     partial      |
| Cross-machine git sync                 |    ✓    |             —              |       ✓        |        ✓         |
| macOS only                             |    ✓    |             —              |       —        |        ✓         |
| Zero new runtimes (just bash + jq)     |    ✓    |             ✓              |    partial     |        —         |

## Domains harmony manages

| Domain         | What                                                  | Asymmetric?                  |
|----------------|-------------------------------------------------------|------------------------------|
| `content`      | Symlinks `~/.claude/{skills,agents,commands}`         | —                            |
| `settings`     | Owned keys in `~/.claude/settings.json`               | unmanaged keys preserved     |
| `plugins`      | `claude plugin {install,uninstall,enable,disable}`    | never uninstalls harmony itself; ignores local-scope plugins |
| `mcp`          | `~/.claude.json` `mcpServers`                         | refuses to write secret-looking values |
| `brew`         | Brewfile reconciliation with safe/ask tiers           | additive only — never auto-uninstalls |
| `launchd`      | `~/Library/LaunchAgents/<prefix>.*`                   | scoped to your label prefix only |
| `keybindings`  | `~/.claude/keybindings.json`                          | null in manifest = leave alone |

## Manifest snippet

```json
{
  "_schema_version": 1,

  "marketplaces": [
    { "name": "official", "source": "anthropics/claude-plugins-official" }
  ],

  "plugins": [
    { "id": "frontend-design@official", "enabled": true }
  ],

  "content": {
    "skills":   "content/skills",
    "agents":   "content/agents",
    "commands": "content/commands"
  },

  "settings": {
    "values": {
      "permissions": { "defaultMode": "default" },
      "statusLine":  { "type": "command", "command": "${HARMONY_CONFIG_DIR}/helpers/statusline.sh" }
    },
    "derived": ["hooks", "enabledPlugins", "extraKnownMarketplaces"]
  },

  "hooks": {
    "SessionStart": [
      { "command": "${HARMONY_CONFIG_DIR}/hooks/my-session-start.sh" }
    ]
  },

  "brew": {
    "brewfile": "settings/Brewfile",
    "auto_install_tier": "safe",
    "tiers": { "safe": ["jq","gh","ripgrep"], "ask": ["reminders-cli"] }
  },

  "launchd": [
    { "label": "com.you.nightly", "plist": "launchd/nightly.plist.template" }
  ]
}
```

Full schema: [`schema/manifest.schema.json`](schema/manifest.schema.json). More examples in [`examples/`](examples/).

## CLI

| Command                  | What                                                       |
|--------------------------|------------------------------------------------------------|
| `harmony apply`          | Reconcile to manifest                                      |
| `harmony apply --dry-run`| Show what would change without doing it                    |
| `harmony status`         | Drift summary (read-only)                                  |
| `harmony verify`         | 7-domain smoke test; exit 0 green, 1 red                   |
| `harmony capture`        | Add plugins/MCP installed here but missing from manifest   |
| `harmony capture --dry-run`| Show what would be captured without writing               |
| `harmony init`           | Create `~/code/harmony-config/` from a starter template    |
| `harmony help`           | Show help                                                  |

Slash commands inside Claude Code: `/harmony-apply`, `/harmony-status`, `/harmony-verify`.

### `harmony capture` — reverse reconcile

`apply` flows manifest → machine. `capture` is the inverse: it adds config you
installed on *this* machine but never wrote into the manifest — the plugins and
MCP servers that would otherwise be pruned next session start (and never reach
your other Macs). It appends them to the manifest, commits, and pushes if your
sync mode is `pull-push`.

A **Stop hook** nudges you automatically: when a session ends with undeclared
plugins/MCP servers installed, harmony prints a one-line reminder to run
`harmony capture` (it never captures automatically — you decide). Secret-bearing
MCP servers are never auto-captured; harmony tells you to add those by hand so a
secret is never committed to git.

## Roadmap

- **v1**: solo single-Mac declarative manager. Stable.
- **v2** (current): multi-Mac git-sync layer (pull-ff-only + warn, opt-in push), per-host overrides (`overrides/<hostname>.json`). See **Multi-Mac sync** above. *(Still open: richer conflict handling beyond ff-only/warn, and integration tests against real plugin marketplaces.)*
- **v3** *(maybe)*: generic dependency managers beyond brew (npm/pip/cargo), best-practices linter ("you don't have `statusLine` configured — recommended setting:"), GUI for editing the manifest.

## Requirements

- macOS (tested on Apple Silicon; should work on Intel).
- `bash` ≥ 3.2 (macOS default).
- `jq` (will be auto-installed via the brew domain on first apply if listed in your Brewfile).
- `claude` CLI (Claude Code).

## License

[MIT](LICENSE).

## Contributing

Pre-1.0 — APIs and schemas may change. Open an issue before sending a PR so we can sanity-check direction. Tests live in [`test/`](test/); run with `test/run-all.sh`.

---

Built because the alternative was hand-editing settings.json every time a new Mac joined the household.
