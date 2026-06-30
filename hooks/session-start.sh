#!/usr/bin/env bash
# hooks/session-start.sh — auto-reconcile on Claude Code session start.
#
# Invoked by Claude Code via the plugin's hooks.json declaration. Resolves
# the user's config directory (HARMONY_CONFIG_DIR, default ~/code/harmony-config/)
# and runs `harmony apply --quiet --no-wait`.
#
# Failure mode is FAIL-OPEN: this hook MUST NOT block a session under any
# circumstance. Errors log to $TMPDIR/harmony.log and exit silently.

# Resolve our own location to find the harmony CLI.
SELF_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
HARMONY_BIN="${SELF_DIR}/../bin/harmony"

# If for some reason the CLI is missing, log and exit cleanly.
if [[ ! -x "$HARMONY_BIN" ]]; then
    printf "%s WARN harmony binary not executable at %s\n" \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$HARMONY_BIN" \
        >> "${TMPDIR:-/tmp}/harmony.log" 2>/dev/null
    exit 0
fi

# Default config dir. User can override via HARMONY_CONFIG_DIR in their shell env.
: "${HARMONY_CONFIG_DIR:=${HOME}/code/harmony-config}"

# If there's no config yet (fresh install before `harmony init`), exit cleanly.
if [[ ! -d "$HARMONY_CONFIG_DIR" || ! -f "$HARMONY_CONFIG_DIR/harmony.json" ]]; then
    printf "%s INFO no harmony config at %s — run 'harmony init' to set up\n" \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$HARMONY_CONFIG_DIR" \
        >> "${TMPDIR:-/tmp}/harmony.log" 2>/dev/null
    exit 0
fi

# Run apply in quiet+no-wait mode. Output to log file only.
"$HARMONY_BIN" apply --quiet --no-wait >>"${TMPDIR:-/tmp}/harmony.log" 2>&1 || true

exit 0
