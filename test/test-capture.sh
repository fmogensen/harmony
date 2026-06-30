#!/usr/bin/env bash
# Test: `harmony capture` (reverse reconcile) + the Stop-hook nudge.
#
# Covers:
#   1. plugins capture detects installed-but-unmanifested plugins (and skips
#      the protected harmony plugin).
#   2. `harmony capture` writes the right manifest entry; `--dry-run` writes nothing.
#   3. MCP capture refuses to capture a server with a secret-looking env value.
#   4. session-stop.sh is fail-open (exit 0) and nudges only when there's drift.
#
# `claude` is mocked via HARMONY_CLAUDE_CMD so no real plugin commands run.

set -e
source "$(dirname "$0")/helpers.sh"
t_setup

# --- Mock `claude` ---------------------------------------------------------
# Emits canned `plugin list --json` / `marketplace list --json`. One plugin
# (playwright) is installed but will be absent from the manifest; harmony is
# installed and protected.
MOCK_CLAUDE="${T_TMPDIR}/claude-mock"
cat > "$MOCK_CLAUDE" <<'MOCK'
#!/usr/bin/env bash
case "$*" in
  *"marketplace list --json"*)
    echo '[{"name":"official","source":"github","repo":"anthropics/claude-plugins-official"}]' ;;
  *"plugin list --json"*)
    echo '[
      {"id":"frontend-design@official","enabled":true,"scope":"user"},
      {"id":"playwright@official","enabled":true,"scope":"user"},
      {"id":"harmony@harmony-mp","enabled":true,"scope":"user"}
    ]' ;;
  *) exit 0 ;;
esac
MOCK
chmod +x "$MOCK_CLAUDE"
export HARMONY_CLAUDE_CMD="$MOCK_CLAUDE"

source "${HARMONY_TEST_REPO_ROOT}/lib/common.sh"
source "${HARMONY_TEST_REPO_ROOT}/lib/domain-plugins.sh"

# ---- 1. plugins capture detects the undeclared plugin, skips protected ----
t_write_manifest '{
  "marketplaces": [{ "name": "official", "source": "anthropics/claude-plugins-official" }],
  "plugins": [ { "id": "frontend-design@official", "enabled": true } ]
}'

caps="$(harmony_domain_plugins_capture "${T_FAKE_CONFIG}/harmony.json")"
t_assert_contains "$caps" "playwright@official" "capture should list the undeclared plugin"
if printf "%s\n" "$caps" | grep -q "harmony@"; then
    t_fail "capture must NOT list the protected harmony plugin"
fi
if printf "%s\n" "$caps" | grep -q "frontend-design@"; then
    t_fail "capture must NOT list an already-managed plugin"
fi

# ---- 2. `harmony capture` writes manifest; --dry-run writes nothing -------
before="$(cat "${T_FAKE_CONFIG}/harmony.json")"
HARMONY_QUIET=1 "$HARMONY" capture --dry-run >/dev/null 2>&1 || true
after_dry="$(cat "${T_FAKE_CONFIG}/harmony.json")"
t_assert_eq "$after_dry" "$before" "dry-run must not modify the manifest"

HARMONY_QUIET=1 "$HARMONY" capture >/dev/null 2>&1 || true
t_assert_json_eq "${T_FAKE_CONFIG}/harmony.json" \
    '[.plugins[].id] | any(. == "playwright@official")' 'true' \
    "capture must add playwright to manifest.plugins"
# harmony must NOT have been captured.
t_assert_json_eq "${T_FAKE_CONFIG}/harmony.json" \
    '[.plugins[].id] | any(startswith("harmony@"))' 'false' \
    "capture must not add the protected harmony plugin"

# ---- 3. MCP capture refuses secret-looking servers -----------------------
source "${HARMONY_TEST_REPO_ROOT}/lib/domain-mcp.sh"
# Fake ~/.claude.json with two servers: one safe, one with a secret env value.
export HARMONY_CLAUDE_JSON="${T_TMPDIR}/claude.json"
cat > "$HARMONY_CLAUDE_JSON" <<JSON
{ "projects": { "${HOME}": { "mcpServers": {
  "safe":   { "command": "node", "args": ["x.js"] },
  "secret": { "command": "node", "env": { "TOKEN": "sk-abcdef0123456789abcdef0123456789" } }
} } } }
JSON
# Manifest has no MCP servers, so both are "present but unmanifested".
t_write_manifest '{ "plugins": [], "mcpServers": { "servers": {} } }'
mcaps="$(harmony_domain_mcp_capture "${T_FAKE_CONFIG}/harmony.json")"
t_assert_contains "$mcaps" "safe" "mcp capture should include the safe server"
printf "%s\n" "$mcaps" | grep -qE '^SKIP\b.*secret' \
    || t_fail "mcp capture must SKIP the secret-bearing server"
if printf "%s\n" "$mcaps" | grep -vE '^SKIP' | grep -q '"TOKEN"'; then
    t_fail "FATAL: a secret value was emitted as capturable"
fi

# ---- 4. Stop hook is fail-open + nudges only on drift --------------------
HOOK="${HARMONY_TEST_REPO_ROOT}/hooks/session-stop.sh"

# stop_hook_active → silent, exit 0
out="$(echo '{"stop_hook_active": true}' | "$HOOK" 2>/dev/null)"; rc=$?
t_assert_eq "$rc" "0" "hook must exit 0 on stop_hook_active"
t_assert_eq "$out" "" "hook must be silent on stop_hook_active"

# missing config dir → silent, exit 0
out="$(HARMONY_CONFIG_DIR=/nonexistent-xyz "$HOOK" </dev/null 2>/dev/null)"; rc=$?
t_assert_eq "$rc" "0" "hook must exit 0 when no config exists"

t_pass
