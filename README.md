# harmony

**Declarative config for Claude Code.**

`harmony` is a Claude Code plugin that turns your `~/.claude/` setup into a single declarative manifest. You describe what you want; `harmony` makes it so — installs and **uninstalls** plugins, marketplaces, hooks, MCP servers, brew dependencies, and macOS LaunchAgents. No more drift. No more "what did I change?". No more skills that break silently because a brew dep is missing on this Mac.

> Status: **early development**. v1 (solo single-Mac use) is being built. Multi-Mac sync is v2.

## What you get

- **A single source of truth** for your Claude Code config — one JSON file.
- **Reversible plugin lifecycle** — remove a plugin from the manifest, run `harmony apply`, and it's actually uninstalled. The Claude Code CLI gives you install/uninstall; `harmony` gives you declarative propagation.
- **Brewfile + dependency reconciliation** — declare what your skills need, `harmony` installs missing tools (safe-tier auto-installs, ask-tier prompts).
- **Declarative LaunchAgents** — your local cron jobs live in the manifest. Add one, it's installed. Remove one, it's uninstalled. Orphan plists are pruned.
- **`harmony verify`** — a smoke test for your environment. Green means your machine matches your config.
- **Hand-edit escape hatch** — only manifest-owned settings.json keys are overwritten; anything you edit by hand is preserved.

## What `harmony` does NOT do

Honest scope:
- Doesn't sync your shell dotfiles (use `chezmoi`/`yadm`/Nix for that).
- Doesn't manage OS preferences, TCC permissions, Keychain, or Mail.app accounts.
- Doesn't store or manage secrets.
- Doesn't sync your Claude Code memory or knowledge-base content.
- Doesn't replace `brew` itself — it reconciles your Brewfile.

## Quick start

```sh
# 1. Install the plugin
claude plugin marketplace add fmogensen/harmony-marketplace
claude plugin install harmony@harmony-marketplace

# 2. Restart Claude Code

# 3. Create your config directory from a starter template
harmony init

# 4. Edit ~/code/harmony-config/harmony.json to taste

# 5. Apply + verify
harmony apply
harmony verify
```

## Architecture

- **The plugin (this repo)** is the *engine* — reconciler, schema, CLI, slash commands. Generic. Ships with no user-specific content.
- **Your config repo (`~/code/harmony-config/`)** is your *data* — your manifest, your skills, your hooks, your Brewfile, your overrides. Private to you.

Clean separation: the plugin updates via the marketplace; your config evolves in your own git repo.

## Comparison

| | harmony | hand-editing settings.json | chezmoi / yadm | Nix home-manager |
|---|---|---|---|---|
| Knows Claude Code's settings.json shape | ✓ | — | — | — |
| Manages plugins + marketplaces | ✓ | partial | — | — |
| Manages MCP servers | ✓ | — | — | — |
| Brewfile reconciliation | ✓ | — | partial | ✓ |
| LaunchAgent management | ✓ | — | partial | partial |
| Declarative (state-sync) | ✓ | — | ✓ | ✓ |
| Reversible (uninstalls propagate) | ✓ | — | partial | ✓ |
| Cross-machine git sync | v2 | — | ✓ | ✓ |
| macOS only | ✓ | — | — | ✓ |

## Roadmap

- **v1** (in progress): solo single-Mac declarative manager.
- **v2**: multi-Mac git-sync layer, per-host overrides (`overrides/<hostname>.json`), conflict handling.
- **v3** (maybe): generic dependency managers beyond brew (npm/pip/cargo).

## License

MIT. See [LICENSE](LICENSE).

## Contributing

Early days; not yet open to external contributions. Watch the repo for the v1 release announcement.
