#!/usr/bin/env bash
# Test: domain-settings replaces managed keys + preserves unmanaged keys.
#
# This is the fix-for-the-additive-merge-bug test. Sets up a settings.json
# with: (a) a managed key that disagrees with the manifest, (b) a managed
# key that should be uninstalled, (c) an unmanaged key that must survive.
# After apply, all three should be in the expected state.

set -e
source "$(dirname "$0")/helpers.sh"

t_setup

# Manifest: set permissions + voice; declare hooks/enabledPlugins as derived;
# omit "tui" (so it should be deleted from settings.json).
t_write_manifest '{
  "_schema_version": 1,
  "marketplaces": [],
  "plugins": [],
  "hooks": {
    "SessionStart": [
      { "command": "${CLAUDE_PLUGIN_ROOT}/hooks/session-start.sh" }
    ]
  },
  "settings": {
    "values": {
      "permissions": { "defaultMode": "bypassPermissions" },
      "voice": { "enabled": true, "mode": "hold" },
      "tui": null
    },
    "derived": ["hooks", "enabledPlugins", "extraKnownMarketplaces"]
  }
}'

# Initial settings.json:
#   - permissions: WRONG mode (should be overwritten)
#   - tui: present, manifest explicitly nulls it (should be deleted)
#   - hooks: stale (should be rewritten from manifest.hooks)
#   - someUserKey: unmanaged (must survive)
#   - voiceEnabled: unmanaged scalar (must survive)
#   - extraKnownMarketplaces: stale (derived; should be cleared since manifest.marketplaces=[])
t_write_settings '{
  "permissions": { "defaultMode": "default" },
  "tui": "fullscreen",
  "hooks": {
    "SessionStart": [
      { "hooks": [ { "type": "command", "command": "/old/path/legacy.sh" } ] }
    ]
  },
  "someUserKey": "preserve-me",
  "voiceEnabled": true,
  "extraKnownMarketplaces": {
    "legacy-marketplace": { "source": { "source": "github", "repo": "old/repo" } }
  }
}'

# Run apply.
"$HARMONY" apply >/dev/null 2>&1 || t_fail "harmony apply exited non-zero"

# Assertions:

# 1. permissions overwritten to manifest value.
t_assert_json_eq "$T_FAKE_SETTINGS" '.permissions.defaultMode' '"bypassPermissions"' \
    "permissions.defaultMode overwritten"

# 2. voice written from manifest.
t_assert_json_eq "$T_FAKE_SETTINGS" '.voice.enabled' 'true' "voice.enabled set"
t_assert_json_eq "$T_FAKE_SETTINGS" '.voice.mode' '"hold"' "voice.mode set"

# 3. tui DELETED (manifest omits it from values).
t_assert_json_eq "$T_FAKE_SETTINGS" '.tui' 'null' "tui removed (not in manifest)"

# 4. hooks rewritten from manifest.hooks (derived).
t_assert_json_eq "$T_FAKE_SETTINGS" '.hooks.SessionStart[0].hooks[0].type' '"command"' \
    "hooks shape preserved"
expected_cmd="\"${HARMONY_TEST_REPO_ROOT}/hooks/session-start.sh\""
actual_cmd="$(jq -c '.hooks.SessionStart[0].hooks[0].command' "$T_FAKE_SETTINGS")"
t_assert_eq "$actual_cmd" "$expected_cmd" "hook command path expanded"

# 5. extraKnownMarketplaces wiped (manifest has empty marketplaces[]).
t_assert_json_eq "$T_FAKE_SETTINGS" '.extraKnownMarketplaces' '{}' \
    "extraKnownMarketplaces cleared"

# 6. enabledPlugins becomes empty object (manifest has empty plugins[]).
t_assert_json_eq "$T_FAKE_SETTINGS" '.enabledPlugins' '{}' \
    "enabledPlugins cleared"

# 7. UNMANAGED keys preserved.
t_assert_json_eq "$T_FAKE_SETTINGS" '.someUserKey' '"preserve-me"' \
    "unmanaged string key preserved"
t_assert_json_eq "$T_FAKE_SETTINGS" '.voiceEnabled' 'true' \
    "unmanaged scalar key preserved"

# 8. Backup file was created.
backup_count="$(ls "${T_FAKE_SETTINGS}".backup.* 2>/dev/null | wc -l | tr -d ' ')"
t_assert_eq "$backup_count" "1" "exactly one backup file created"

# 9. Re-run apply: should be a no-op (idempotent).
"$HARMONY" apply >/dev/null 2>&1 || t_fail "harmony apply (2nd run) exited non-zero"
backup_count_after="$(ls "${T_FAKE_SETTINGS}".backup.* 2>/dev/null | wc -l | tr -d ' ')"
t_assert_eq "$backup_count_after" "1" "no new backup on idempotent run"

# 10. verify reports green.
"$HARMONY" verify >/dev/null 2>&1 || t_fail "harmony verify reported drift after apply"

t_pass
