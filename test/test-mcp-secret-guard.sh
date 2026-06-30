#!/usr/bin/env bash
# Test: domain-mcp writes mcpServers to ~/.claude.json AND refuses to write
# anything that looks like an embedded secret.

set -e
source "$(dirname "$0")/helpers.sh"

t_setup

export HARMONY_CLAUDE_JSON="${T_FAKE_HOME}/.claude.json"

# ---- Scenario 1: clean mcpServers writes successfully ----

t_write_manifest '{
  "_schema_version": 1,
  "marketplaces": [],
  "plugins": [],
  "settings": { "values": {}, "derived": [] },
  "mcpServers": {
    "_scope": "global",
    "servers": {
      "my-mcp": {
        "command": "uv",
        "args": ["run", "my-mcp"],
        "env": { "MY_ENV": "$MY_REAL_TOKEN_FROM_SHELL" }
      }
    }
  }
}'

"$HARMONY" apply >/dev/null 2>&1 || t_fail "harmony apply exited non-zero (clean scenario)"

# Assertion: mcpServers landed under projects[$HOME].
actual_cmd="$(jq -r --arg h "$HOME" '.projects[$h].mcpServers["my-mcp"].command' "$HARMONY_CLAUDE_JSON")"
t_assert_eq "$actual_cmd" "uv" "my-mcp command written"

# ---- Scenario 2: manifest contains a real-looking secret → refused ----

t_write_manifest '{
  "_schema_version": 1,
  "marketplaces": [],
  "plugins": [],
  "settings": { "values": {}, "derived": [] },
  "mcpServers": {
    "_scope": "global",
    "servers": {
      "bad-mcp": {
        "command": "node",
        "args": ["x.js"],
        "env": { "OPENAI_API_KEY": "sk-abcdefghij1234567890ABCDEFGH1234567890" }
      }
    }
  }
}'

# Capture stderr to verify the error message.
err_output="$( "$HARMONY" apply 2>&1 >/dev/null )" || true
t_assert_contains "$err_output" "looks like a secret" "harmony refused secret-looking value"

# Assertion: bad-mcp was NOT written to .claude.json (still only my-mcp).
has_bad="$(jq -r --arg h "$HOME" '.projects[$h].mcpServers | has("bad-mcp")' "$HARMONY_CLAUDE_JSON")"
t_assert_eq "$has_bad" "false" "bad-mcp was NOT written"

# Still has my-mcp from scenario 1.
still_has_my="$(jq -r --arg h "$HOME" '.projects[$h].mcpServers | has("my-mcp")' "$HARMONY_CLAUDE_JSON")"
t_assert_eq "$still_has_my" "true" "my-mcp preserved from previous apply"

t_pass
