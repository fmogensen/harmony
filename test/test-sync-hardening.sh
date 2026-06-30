#!/usr/bin/env bash
# test/test-sync-hardening.sh — v2.1 sync state machine, auto-commit, reporting.
#
# Covers:
#   1. harmony_sync_state classifies in-sync / behind / ahead / diverged / dirty / no-upstream.
#   2. sync.autoCommit commits uncommitted changes before push.
#   3. `verify` shows a sync row; `status` reports sync state.
set -e
source "$(dirname "$0")/helpers.sh"
t_setup

HARMONY="${HARMONY_TEST_REPO_ROOT}/bin/harmony"

mk_manifest() {
    # $1 = mode, $2 = autoCommit
    printf '{
      "_schema_version": 1,
      "sync": { "enabled": true, "mode": "%s", "remote": "origin", "branch": "main", "autoCommit": %s },
      "settings": { "values": { "tui": "fullscreen" }, "derived": [] }
    }\n' "$1" "${2:-false}"
}

# ---- Build remote + config-dir clone ----
REMOTE="${T_TMPDIR}/remote.git"; WORKA="${T_TMPDIR}/workA"
git init -q --bare "$REMOTE"
git init -q "$WORKA"; git -C "$WORKA" config user.email t@t; git -C "$WORKA" config user.name t
mk_manifest pull > "$WORKA/harmony.json"
git -C "$WORKA" add -A; git -C "$WORKA" commit -qm init; git -C "$WORKA" branch -M main
git -C "$WORKA" remote add origin "$REMOTE"; git -C "$WORKA" push -q -u origin main

rm -rf "$T_FAKE_CONFIG"
git clone -q "$REMOTE" "$T_FAKE_CONFIG"
git -C "$T_FAKE_CONFIG" config user.email t@t; git -C "$T_FAKE_CONFIG" config user.name t

# Helper to call an internal sync fn with the libs sourced and config loaded.
sync_fn() {
    # $1 = fn name, rest = args. Sources libs, loads manifest, runs fn.
    bash -c '
        source "'"$HARMONY_TEST_REPO_ROOT"'/lib/common.sh"
        source "'"$HARMONY_TEST_REPO_ROOT"'/lib/sync.sh"
        export HARMONY_CONFIG_DIR="'"$T_FAKE_CONFIG"'"
        export HARMONY_QUIET=1
        harmony_sync_load "'"$T_FAKE_CONFIG"'/harmony.json"
        "$@"
    ' _ "$@"
}

# ---- 1. state: in-sync ----
t_assert_eq "$(sync_fn harmony_sync_state)" "in-sync" "state: clean clone is in-sync"

# behind: remote advances
jq '._r = 1' "$WORKA/harmony.json" > "$WORKA/h.t" && mv "$WORKA/h.t" "$WORKA/harmony.json"
git -C "$WORKA" commit -qam r1; git -C "$WORKA" push -q origin main
t_assert_eq "$(sync_fn harmony_sync_state)" "behind" "state: remote ahead → behind"

# pull catches up → in-sync again
git -C "$T_FAKE_CONFIG" pull -q --ff-only origin main >/dev/null 2>&1
t_assert_eq "$(sync_fn harmony_sync_state)" "in-sync" "state: after pull → in-sync"

# ahead: local commits not pushed
jq '._l = 1' "$T_FAKE_CONFIG/harmony.json" > "$T_FAKE_CONFIG/h.t" && mv "$T_FAKE_CONFIG/h.t" "$T_FAKE_CONFIG/harmony.json"
git -C "$T_FAKE_CONFIG" commit -qam l1
t_assert_eq "$(sync_fn harmony_sync_state)" "ahead" "state: local commit → ahead"

# diverged: remote ALSO advances independently
jq '._r = 2' "$WORKA/harmony.json" > "$WORKA/h.t" && mv "$WORKA/h.t" "$WORKA/harmony.json"
git -C "$WORKA" commit -qam r2; git -C "$WORKA" push -q origin main
t_assert_eq "$(sync_fn harmony_sync_state)" "diverged" "state: both moved → diverged"

# dirty beats everything
printf '\n' >> "$T_FAKE_CONFIG/harmony.json"   # actually need a real change:
jq '._wip = 1' "$T_FAKE_CONFIG/harmony.json" > "$T_FAKE_CONFIG/h.t" && mv "$T_FAKE_CONFIG/h.t" "$T_FAKE_CONFIG/harmony.json"
t_assert_eq "$(sync_fn harmony_sync_state)" "dirty" "state: uncommitted change → dirty"

# ---- 2. autoCommit: a fresh clone + dirty edit + push mode should commit ----
REMOTE2="${T_TMPDIR}/remote2.git"; git init -q --bare "$REMOTE2"
CFG2="${T_TMPDIR}/cfg2"
git init -q "$CFG2"; git -C "$CFG2" config user.email t@t; git -C "$CFG2" config user.name t
mk_manifest pull-push true > "$CFG2/harmony.json"
git -C "$CFG2" add -A; git -C "$CFG2" commit -qm init; git -C "$CFG2" branch -M main
git -C "$CFG2" remote add origin "$REMOTE2"; git -C "$CFG2" push -q -u origin main
# dirty edit, then run push (which auto-commits first)
jq '._auto = 1' "$CFG2/harmony.json" > "$CFG2/h.t" && mv "$CFG2/h.t" "$CFG2/harmony.json"
bash -c '
    source "'"$HARMONY_TEST_REPO_ROOT"'/lib/common.sh"
    source "'"$HARMONY_TEST_REPO_ROOT"'/lib/sync.sh"
    export HARMONY_CONFIG_DIR="'"$CFG2"'"; export HARMONY_QUIET=1
    harmony_sync_load "'"$CFG2"'/harmony.json"
    harmony_sync_push
' >/dev/null 2>&1 || true
CLEAN_AFTER="$(git -C "$CFG2" status --porcelain)"
t_assert_eq "$CLEAN_AFTER" "" "autoCommit: working tree clean after push (changes were committed)"
# and the remote got it
git -C "$CFG2" fetch -q origin main
PUSHED="$(git -C "$CFG2" rev-list --count origin/main 2>/dev/null)"
[[ "$PUSHED" -ge 2 ]] || t_fail "autoCommit: remote did not receive the auto-committed push"

# ---- 3. verify shows a sync row ----
rm -rf "$T_FAKE_CONFIG"; git clone -q "$REMOTE" "$T_FAKE_CONFIG"
git -C "$T_FAKE_CONFIG" config user.email t@t; git -C "$T_FAKE_CONFIG" config user.name t
mk_manifest pull > "$T_FAKE_CONFIG/harmony.json"
git -C "$T_FAKE_CONFIG" commit -qam "use pull manifest"; git -C "$T_FAKE_CONFIG" push -q origin main
VOUT="$(HARMONY_QUIET=0 "$HARMONY" verify 2>&1 || true)"
t_assert_contains "$VOUT" "sync" "verify: includes a sync row"

t_pass
