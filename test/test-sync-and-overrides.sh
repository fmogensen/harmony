#!/usr/bin/env bash
# test/test-sync-and-overrides.sh — v2 git-sync + per-host overrides.
#
# Covers:
#   1. apply with sync.enabled pulls a remote-side config change (ff-only).
#   2. a dirty config repo skips the pull and warns (never blocks).
#   3. a per-host overrides/<hostname>.json deep-merges over the base manifest.
set -e
source "$(dirname "$0")/helpers.sh"

t_setup

HARMONY="${HARMONY_TEST_REPO_ROOT}/bin/harmony"

# Minimal base manifest with sync enabled (pull mode). Empty domains → apply is a no-op,
# which is what we want: we're testing the sync/override plumbing, not a domain.
BASE='{
  "_schema_version": 1,
  "sync": { "enabled": true, "mode": "pull", "remote": "origin", "branch": "main" },
  "settings": { "values": { "tui": "fullscreen" }, "derived": [] }
}'

# ---- Build a fake "remote": a bare repo + a clone that becomes HARMONY_CONFIG_DIR ----
REMOTE="${T_TMPDIR}/remote.git"
WORKA="${T_TMPDIR}/workA"     # the "other Mac" that pushes a change
git init -q --bare "$REMOTE"

git init -q "$WORKA"
git -C "$WORKA" config user.email t@t; git -C "$WORKA" config user.name t
printf "%s\n" "$BASE" > "$WORKA/harmony.json"
git -C "$WORKA" add -A; git -C "$WORKA" commit -qm init
git -C "$WORKA" branch -M main
git -C "$WORKA" remote add origin "$REMOTE"
git -C "$WORKA" push -q -u origin main

# Clone into the config dir (replacing the empty sandbox config dir).
rm -rf "$T_FAKE_CONFIG"
git clone -q "$REMOTE" "$T_FAKE_CONFIG"
git -C "$T_FAKE_CONFIG" config user.email t@t; git -C "$T_FAKE_CONFIG" config user.name t

# ---- 1. Remote-side change should be pulled by apply ----------------------------
# "Other Mac" edits the manifest (adds a comment marker) and pushes.
jq '._comment = "from-other-mac"' "$WORKA/harmony.json" > "$WORKA/harmony.json.t" && mv "$WORKA/harmony.json.t" "$WORKA/harmony.json"
git -C "$WORKA" commit -qam "remote change"
git -C "$WORKA" push -q origin main

# Run apply on the config-dir clone — it should ff-pull the remote change in.
"$HARMONY" apply --quiet >/dev/null 2>&1 || true
PULLED="$(jq -r '._comment // empty' "$T_FAKE_CONFIG/harmony.json")"
t_assert_eq "$PULLED" "from-other-mac" "sync pull brought in remote change"

# ---- 2. Dirty repo skips the pull and warns -------------------------------------
# Make a fresh remote commit, then dirty the local work tree.
jq '._comment = "second-remote-change"' "$WORKA/harmony.json" > "$WORKA/harmony.json.t" && mv "$WORKA/harmony.json.t" "$WORKA/harmony.json"
git -C "$WORKA" commit -qam "second remote change"; git -C "$WORKA" push -q origin main

# Dirty the local tree with a VALID-JSON edit (realistic: a half-finished manifest change).
jq '._local_wip = "in-progress"' "$T_FAKE_CONFIG/harmony.json" > "$T_FAKE_CONFIG/harmony.json.t" \
    && mv "$T_FAKE_CONFIG/harmony.json.t" "$T_FAKE_CONFIG/harmony.json"
# Run non-quiet for this assertion so the warn-level message is visible on stderr
# (the sandbox defaults HARMONY_QUIET=1, which suppresses warnings).
OUT="$(HARMONY_QUIET=0 "$HARMONY" apply 2>&1 || true)"
t_assert_contains "$OUT" "uncommitted changes" "dirty repo warns and skips pull"
# The dirty local content must NOT have been overwritten by the remote pull.
DIRTY_KEPT="$(jq -r '._local_wip // empty' "$T_FAKE_CONFIG/harmony.json")"
t_assert_eq "$DIRTY_KEPT" "in-progress" "dirty pull skipped — local edit preserved"
# And the second remote change must NOT have landed (pull was skipped).
NOT_PULLED="$(jq -r '._comment // empty' "$T_FAKE_CONFIG/harmony.json")"
t_assert_eq "$NOT_PULLED" "from-other-mac" "dirty pull skipped — second remote change not yet pulled"

# Reset to a clean tree for the next assertion (discard the WIP edit, pull current remote).
git -C "$T_FAKE_CONFIG" checkout -q -- harmony.json 2>/dev/null || true
git -C "$T_FAKE_CONFIG" pull -q --ff-only origin main >/dev/null 2>&1 || true

# ---- 3. Per-host override deep-merges over the base ------------------------------
# Derive this host's override filename exactly as the engine does.
HOST="$(hostname -s 2>/dev/null | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-' | sed 's/-*$//')"
mkdir -p "$T_FAKE_CONFIG/overrides"
# Override flips a nested settings value and adds a new key — base keeps the rest.
printf '%s\n' '{ "settings": { "values": { "tui": "compact" } }, "_host": "'"$HOST"'" }' \
    > "$T_FAKE_CONFIG/overrides/${HOST}.json"

# status prints the effective manifest's override notice; verify via a dry-run apply log line.
OUT2="$(HARMONY_QUIET=0 "$HARMONY" status 2>&1 || true)"
t_assert_contains "$OUT2" "applied overrides/${HOST}.json" "per-host override is detected and merged"

t_pass
