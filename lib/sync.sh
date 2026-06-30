#!/usr/bin/env bash
# lib/sync.sh — v2 multi-Mac git-sync layer.
#
# Makes harmony keep the user's HARMONY_CONFIG_DIR git repo in step across
# machines: pull before apply (so each Mac picks up pushed config changes), and
# optionally push after a local apply (so the others see your edits).
#
# Behaviour is driven by the manifest's optional "sync" block:
#   "sync": {
#     "enabled": true,           // master switch (default: false)
#     "mode": "pull",            // "pull" | "pull-push"  (push is opt-in)
#     "remote": "origin",        // git remote name      (default: origin)
#     "branch": ""               // branch; ""=current   (default: current)
#   }
#
# Safety contract (matches the SessionStart fail-open philosophy):
#   - Pull is ALWAYS `git pull --ff-only`. If the local repo has diverged or
#     has uncommitted changes, the pull is skipped and a WARNING is surfaced
#     (pull + warn-on-divergence) — the apply still proceeds on local state.
#   - Push is opt-in (mode=pull-push) and also non-fatal: a failed push warns,
#     never aborts.
#   - Every path returns 0 so `set -o errexit` in callers never trips and a
#     session is never blocked by sync.
#
# Sourced by bin/harmony. Depends on common.sh (logging, jq helpers).

# Read the sync config from the manifest into globals. Defaults applied here.
# Usage: harmony_sync_load <manifest>
harmony_sync_load() {
    local manifest="$1"
    HARMONY_SYNC_ENABLED="$(harmony_jq_read "$manifest" '.sync.enabled')"
    HARMONY_SYNC_MODE="$(harmony_jq_read "$manifest" '.sync.mode')"
    HARMONY_SYNC_REMOTE="$(harmony_jq_read "$manifest" '.sync.remote')"
    HARMONY_SYNC_BRANCH="$(harmony_jq_read "$manifest" '.sync.branch')"

    # Defaults.
    [[ "$HARMONY_SYNC_ENABLED" == "true" ]] || HARMONY_SYNC_ENABLED="false"
    [[ -n "$HARMONY_SYNC_MODE" ]]   || HARMONY_SYNC_MODE="pull"
    [[ -n "$HARMONY_SYNC_REMOTE" ]] || HARMONY_SYNC_REMOTE="origin"
    # branch may legitimately be empty → means "current branch"
    export HARMONY_SYNC_ENABLED HARMONY_SYNC_MODE HARMONY_SYNC_REMOTE HARMONY_SYNC_BRANCH
    return 0
}

# Is the config dir a git work tree with the configured remote?
harmony_sync_is_repo() {
    git -C "$HARMONY_CONFIG_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1
}

# Current branch of the config repo (empty if detached/unknown).
harmony_sync_current_branch() {
    git -C "$HARMONY_CONFIG_DIR" symbolic-ref --quiet --short HEAD 2>/dev/null || printf ""
}

# True if the work tree has uncommitted changes (tracked or staged).
harmony_sync_is_dirty() {
    ! git -C "$HARMONY_CONFIG_DIR" diff --quiet 2>/dev/null \
    || ! git -C "$HARMONY_CONFIG_DIR" diff --cached --quiet 2>/dev/null
}

# Pull the config repo fast-forward-only. Warn (don't fail) on any obstacle.
# No-op unless sync is enabled. Always returns 0.
harmony_sync_pull() {
    [[ "${HARMONY_SYNC_ENABLED:-false}" == "true" ]] || { harmony_debug "sync disabled — skipping pull"; return 0; }

    if ! harmony_have_cmd git; then
        harmony_warn "sync: git not found — skipping pull"
        return 0
    fi
    if ! harmony_sync_is_repo; then
        harmony_warn "sync: $HARMONY_CONFIG_DIR is not a git repo — skipping pull"
        return 0
    fi
    if harmony_sync_is_dirty; then
        harmony_warn "sync: config repo has uncommitted changes — skipping pull (commit or stash to sync)"
        return 0
    fi

    local branch="${HARMONY_SYNC_BRANCH:-}"
    [[ -n "$branch" ]] || branch="$(harmony_sync_current_branch)"
    if [[ -z "$branch" ]]; then
        harmony_warn "sync: config repo is in detached HEAD — skipping pull"
        return 0
    fi

    harmony_debug "sync: git pull --ff-only $HARMONY_SYNC_REMOTE $branch"
    local out
    if out="$(git -C "$HARMONY_CONFIG_DIR" pull --ff-only "$HARMONY_SYNC_REMOTE" "$branch" 2>&1)"; then
        if printf "%s" "$out" | grep -q 'Already up to date'; then
            harmony_debug "sync: already up to date"
        else
            harmony_info "sync: pulled latest config from $HARMONY_SYNC_REMOTE/$branch"
        fi
    else
        # Most common cause: local diverged from remote (can't fast-forward).
        harmony_warn "sync: could not fast-forward $HARMONY_SYNC_REMOTE/$branch — local has diverged; resolve manually (git -C $HARMONY_CONFIG_DIR status). Applying current local state."
    fi
    return 0
}

# Push the config repo after a successful local apply. Opt-in (mode=pull-push).
# Only pushes if there is a local commit ahead of the remote. Always returns 0.
harmony_sync_push() {
    [[ "${HARMONY_SYNC_ENABLED:-false}" == "true" ]] || return 0
    [[ "$HARMONY_SYNC_MODE" == "pull-push" ]] || { harmony_debug "sync: mode=$HARMONY_SYNC_MODE — not pushing"; return 0; }

    harmony_have_cmd git || return 0
    harmony_sync_is_repo || return 0

    local branch="${HARMONY_SYNC_BRANCH:-}"
    [[ -n "$branch" ]] || branch="$(harmony_sync_current_branch)"
    [[ -n "$branch" ]] || return 0

    # Only push if we are strictly ahead of the upstream (avoid noisy no-op pushes).
    local ahead
    ahead="$(git -C "$HARMONY_CONFIG_DIR" rev-list --count "@{upstream}..HEAD" 2>/dev/null || printf "0")"
    if [[ "${ahead:-0}" -eq 0 ]]; then
        harmony_debug "sync: nothing to push (0 commits ahead)"
        return 0
    fi

    harmony_debug "sync: git push $HARMONY_SYNC_REMOTE $branch ($ahead ahead)"
    if git -C "$HARMONY_CONFIG_DIR" push "$HARMONY_SYNC_REMOTE" "$branch" >/dev/null 2>&1; then
        harmony_info "sync: pushed $ahead local commit(s) to $HARMONY_SYNC_REMOTE/$branch"
    else
        harmony_warn "sync: push to $HARMONY_SYNC_REMOTE/$branch failed — push manually when ready"
    fi
    return 0
}
