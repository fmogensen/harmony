#!/usr/bin/env bash
# hooks/session-stop.sh — nudge to capture session-installed config on session end.
#
# Invoked by Claude Code via the plugin's hooks.json `Stop` declaration. Runs
# `harmony status` (read-only) and, if it finds plugins/MCP servers installed on
# this machine but absent from the manifest, prints a one-line nudge telling the
# user to `harmony capture` (so the config syncs to their other Macs) — or it'll
# be pruned next session start.
#
# It NEVER mutates anything (no apply, no capture) and NEVER blocks session end:
# this is a Stop hook, so a non-zero exit / exit-2 could trap the session. We
# always exit 0, fail-open, log to $TMPDIR/harmony.log, and honor stop_hook_active
# so we never re-trigger ourselves.

# Read the hook payload from stdin (Claude Code passes JSON). Bail out cleanly if
# this is a re-entrant Stop (stop_hook_active) so we never loop.
payload="$(cat 2>/dev/null || true)"
if printf "%s" "$payload" | grep -q '"stop_hook_active"[[:space:]]*:[[:space:]]*true'; then
    exit 0
fi

SELF_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
HARMONY_BIN="${SELF_DIR}/../bin/harmony"
LOG="${TMPDIR:-/tmp}/harmony.log"

# CLI missing → log and exit cleanly.
if [[ ! -x "$HARMONY_BIN" ]]; then
    printf "%s WARN session-stop: harmony binary not executable at %s\n" \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$HARMONY_BIN" >> "$LOG" 2>/dev/null
    exit 0
fi

: "${HARMONY_CONFIG_DIR:=${HOME}/code/harmony-config}"
if [[ ! -f "$HARMONY_CONFIG_DIR/harmony.json" ]]; then
    exit 0
fi

# Read-only status. harmony writes its plan lines to STDERR (via harmony_info),
# so capture both streams. Never let a failure escape.
status_out="$("$HARMONY_BIN" status 2>&1 || true)"

# Drift we care about = things installed here but missing from the manifest,
# which `status` renders as `uninstall` actions on plugin.* / mcp.* resources.
# (Format: "harmony: [<domain>] uninstall <resource> — ...".)
drift="$(printf "%s\n" "$status_out" \
    | grep -E 'uninstall (plugin|mcp)\.' || true)"

if [[ -z "$drift" ]]; then
    exit 0
fi

# Extract a short, friendly name list (the resource ids).
names="$(printf "%s\n" "$drift" \
    | sed -E 's/.*uninstall (plugin|mcp)\.([^ ]+).*/\2/' \
    | paste -sd ', ' - 2>/dev/null)"
count="$(printf "%s\n" "$drift" | grep -c . || true)"

# Non-blocking nudge to stdout. (Hand-authored skills/agents dropped outside a
# plugin aren't detected here — a known v1 gap.)
printf 'harmony: %s item(s) installed this session are not in your config%s.\n' \
    "$count" "${names:+ ($names)}"
printf '         They will be removed next session start and will not sync to your other Macs.\n'
printf '         Run `harmony capture` to keep them, or `harmony status` for details.\n'

exit 0
