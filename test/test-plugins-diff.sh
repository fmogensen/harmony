#!/usr/bin/env bash
# Test: domain-plugins diff logic — install/uninstall/enable/disable propagation
# and the harmony self-uninstall guard.
#
# Tests the pure diff function _plugins_compute_diff against canned JSON, so
# no real `claude plugin` commands are invoked. The CLI wiring (apply path)
# is exercised by the harmony plugin's own integration tests later.

set -e
source "$(dirname "$0")/helpers.sh"

t_setup

# Source the library directly so we can call _plugins_compute_diff.
# shellcheck source=../lib/common.sh
source "${HARMONY_TEST_REPO_ROOT}/lib/common.sh"
# shellcheck source=../lib/domain-plugins.sh
source "${HARMONY_TEST_REPO_ROOT}/lib/domain-plugins.sh"

# ---- Scenario 1: install + uninstall + enable + disable + self-uninstall guard ----

t_write_manifest '{
  "marketplaces": [
    { "name": "official",   "source": "anthropics/claude-plugins-official" },
    { "name": "harmony-mp", "source": "fmogensen/harmony-marketplace" }
  ],
  "plugins": [
    { "id": "frontend-design@official", "enabled": true  },
    { "id": "notion@official",          "enabled": false },
    { "id": "harmony@harmony-mp",       "enabled": true  }
  ]
}'

# Current state: extra marketplace, extra plugin (not in manifest), one wrong-enabled.
current_markets='[
  { "name": "official",       "source": "github", "repo": "anthropics/claude-plugins-official" },
  { "name": "old-marketplace","source": "github", "repo": "old/repo" }
]'
current_plugins='[
  { "id": "frontend-design@official", "enabled": false },
  { "id": "asana@official",           "enabled": true  },
  { "id": "harmony@harmony-mp",       "enabled": true  }
]'

diff="$(_plugins_compute_diff "${T_FAKE_CONFIG}/harmony.json" "$current_markets" "$current_plugins")"

# Marketplace assertions:
# - install harmony-mp (in manifest, not installed)
# - uninstall old-marketplace (installed, not in manifest, no plugins from it)
# - official: no action (in both)
echo "$diff" | grep -qE "^install	marketplace.harmony-mp	" || t_fail "expected to install harmony-mp marketplace"
echo "$diff" | grep -qE "^uninstall	marketplace.old-marketplace	" || t_fail "expected to uninstall old-marketplace"
echo "$diff" | grep -qE "^(install|uninstall)	marketplace.official	" \
    && t_fail "should NOT touch official marketplace" || true

# Plugin assertions:
# - install notion (in manifest, not installed)
# - uninstall asana (installed, not in manifest, not protected)
# - frontend-design: enable (currently disabled, manifest says enabled=true)
# - harmony: no action (in both, both enabled)
echo "$diff" | grep -qE "^install	plugin.notion@official	" || t_fail "expected to install notion"
echo "$diff" | grep -qE "^uninstall	plugin.asana@official	" || t_fail "expected to uninstall asana"
echo "$diff" | grep -qE "^enable	plugin.frontend-design@official	" || t_fail "expected to enable frontend-design"

# notion is desired-disabled, so install line should record that.
echo "$diff" | grep -E "^install	plugin.notion@official	" | grep -q "enabled=false" \
    || t_fail "install line for notion should mention enabled=false"

# ---- Scenario 2: harmony self-uninstall guard ----
# Manifest OMITS harmony entirely; current state HAS harmony installed.
# Diff must emit a NOOP for harmony, never an uninstall.

t_write_manifest '{
  "marketplaces": [],
  "plugins": []
}'
current_plugins_with_harmony='[
  { "id": "harmony@harmony-mp", "enabled": true }
]'

diff="$(_plugins_compute_diff "${T_FAKE_CONFIG}/harmony.json" "[]" "$current_plugins_with_harmony")"

echo "$diff" | grep -qE "^uninstall	plugin.harmony@" \
    && t_fail "FATAL: harmony plugin was scheduled for uninstall (self-uninstall guard broke)" || true

echo "$diff" | grep -qE "^noop	plugin.harmony@harmony-mp	" || t_fail "expected noop line for protected harmony plugin"

# ---- Scenario 3: marketplace with active plugins must not be removed ----
# Marketplace in current but not in manifest. But plugins from that marketplace
# are still installed. Should noop, not uninstall.

t_write_manifest '{
  "marketplaces": [],
  "plugins": [
    { "id": "still-here@orphan-marketplace", "enabled": true }
  ]
}'
current_markets='[{ "name": "orphan-marketplace", "source": "github", "repo": "x/y" }]'
current_plugins='[{ "id": "still-here@orphan-marketplace", "enabled": true }]'

diff="$(_plugins_compute_diff "${T_FAKE_CONFIG}/harmony.json" "$current_markets" "$current_plugins")"

echo "$diff" | grep -qE "^uninstall	marketplace.orphan-marketplace	" \
    && t_fail "should NOT uninstall a marketplace whose plugins are still installed" || true

echo "$diff" | grep -qE "^noop	marketplace.orphan-marketplace	.*still installed" \
    || t_fail "expected noop line explaining preservation"

t_pass
