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
    HARMONY_SYNC_AUTOCOMMIT="$(harmony_jq_read "$manifest" '.sync.autoCommit')"

    # Defaults.
    [[ "$HARMONY_SYNC_ENABLED" == "true" ]] || HARMONY_SYNC_ENABLED="false"
    [[ -n "$HARMONY_SYNC_MODE" ]]   || HARMONY_SYNC_MODE="pull"
    [[ -n "$HARMONY_SYNC_REMOTE" ]] || HARMONY_SYNC_REMOTE="origin"
    [[ "$HARMONY_SYNC_AUTOCOMMIT" == "true" ]] || HARMONY_SYNC_AUTOCOMMIT="false"
    # branch may legitimately be empty → means "current branch"
    export HARMONY_SYNC_ENABLED HARMONY_SYNC_MODE HARMONY_SYNC_REMOTE HARMONY_SYNC_BRANCH HARMONY_SYNC_AUTOCOMMIT
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

# True if the work tree has uncommitted changes (tracked or staged) OR untracked files.
harmony_sync_is_dirty() {
    [[ -n "$(git -C "$HARMONY_CONFIG_DIR" status --porcelain 2>/dev/null)" ]]
}

# Does the current branch have an upstream tracking ref?
harmony_sync_has_upstream() {
    git -C "$HARMONY_CONFIG_DIR" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' >/dev/null 2>&1
}

# Classify the config repo's sync state. Echoes ONE word:
#   disabled | not-repo | dirty | detached | no-upstream | offline
#   | in-sync | behind | ahead | diverged
# This is the keystone the pull logic and verify/status reporting both consume.
# It does a `git fetch` (network) to learn behind/ahead unless told not to.
# Usage: harmony_sync_state [--no-fetch]
harmony_sync_state() {
    local do_fetch=1
    [[ "${1:-}" == "--no-fetch" ]] && do_fetch=0

    [[ "${HARMONY_SYNC_ENABLED:-false}" == "true" ]] || { printf "disabled\n"; return 0; }
    harmony_have_cmd git || { printf "not-repo\n"; return 0; }
    harmony_sync_is_repo || { printf "not-repo\n"; return 0; }

    local branch="${HARMONY_SYNC_BRANCH:-}"
    [[ -n "$branch" ]] || branch="$(harmony_sync_current_branch)"
    [[ -n "$branch" ]] || { printf "detached\n"; return 0; }

    harmony_sync_is_dirty && { printf "dirty\n"; return 0; }
    harmony_sync_has_upstream || { printf "no-upstream\n"; return 0; }

    # Refresh remote-tracking refs so behind/ahead is accurate. Distinguish a
    # network failure (offline) from a real divergence.
    if [[ "$do_fetch" == "1" ]]; then
        if ! git -C "$HARMONY_CONFIG_DIR" fetch --quiet "$HARMONY_SYNC_REMOTE" "$branch" 2>/dev/null; then
            printf "offline\n"; return 0
        fi
    fi

    # Counts relative to upstream: behind = remote-only, ahead = local-only.
    local counts behind ahead
    counts="$(git -C "$HARMONY_CONFIG_DIR" rev-list --left-right --count "@{upstream}...HEAD" 2>/dev/null || printf "0\t0")"
    behind="$(printf "%s" "$counts" | awk '{print $1}')"
    ahead="$(printf "%s" "$counts" | awk '{print $2}')"
    behind="${behind:-0}"; ahead="${ahead:-0}"

    if   [[ "$behind" -eq 0 && "$ahead" -eq 0 ]]; then printf "in-sync\n"
    elif [[ "$behind" -gt 0 && "$ahead" -eq 0 ]]; then printf "behind\n"
    elif [[ "$behind" -eq 0 && "$ahead" -gt 0 ]]; then printf "ahead\n"
    else printf "diverged\n"; fi
    return 0
}

# Auto-commit uncommitted manifest/config changes before a push, when enabled
# (sync.autoCommit = true). Generates a hostname+timestamp message. Returns 0
# always; only commits if dirty and autoCommit is on.
harmony_sync_autocommit() {
    [[ "${HARMONY_SYNC_AUTOCOMMIT:-false}" == "true" ]] || return 0
    harmony_sync_is_repo || return 0
    harmony_sync_is_dirty || return 0

    git -C "$HARMONY_CONFIG_DIR" add -A 2>/dev/null || return 0
    local msg
    msg="harmony: auto-commit config from $(harmony_hostname)"
    if git -C "$HARMONY_CONFIG_DIR" commit -q -m "$msg" 2>/dev/null; then
        harmony_info "sync: auto-committed local config changes ($(harmony_hostname))"
    fi
    return 0
}

# Pull the config repo fast-forward-only, with state-aware, distinct messages.
# No-op unless sync is enabled. Always returns 0 (fail-open).
harmony_sync_pull() {
    [[ "${HARMONY_SYNC_ENABLED:-false}" == "true" ]] || { harmony_debug "sync disabled — skipping pull"; return 0; }

    local branch="${HARMONY_SYNC_BRANCH:-}"
    [[ -n "$branch" ]] || branch="$(harmony_sync_current_branch)"

    # Classify once (this fetches), then act + message per state.
    local state
    state="$(harmony_sync_state)"
    case "$state" in
        not-repo)
            harmony_warn "sync: $HARMONY_CONFIG_DIR is not a git repo (or git missing) — skipping pull" ;;
        detached)
            harmony_warn "sync: config repo is in detached HEAD — skipping pull" ;;
        dirty)
            harmony_warn "sync: config repo has uncommitted changes — skipping pull (commit, stash, or set sync.autoCommit). Applying current local state." ;;
        no-upstream)
            harmony_warn "sync: branch '$branch' has no upstream — skipping pull (set one: git -C $HARMONY_CONFIG_DIR push -u $HARMONY_SYNC_REMOTE $branch)" ;;
        offline)
            harmony_warn "sync: can't reach $HARMONY_SYNC_REMOTE (offline?) — skipping pull, applying current local state" ;;
        in-sync)
            harmony_debug "sync: already up to date" ;;
        ahead)
            harmony_debug "sync: local is ahead of $HARMONY_SYNC_REMOTE/$branch — nothing to pull"
            [[ "$HARMONY_SYNC_MODE" == "pull-push" ]] || harmony_warn "sync: you have local commits not on $HARMONY_SYNC_REMOTE/$branch — they won't reach other Macs until pushed (mode=pull-push or 'harmony sync --push')" ;;
        diverged)
            harmony_warn "sync: $HARMONY_SYNC_REMOTE/$branch has diverged from local — can't fast-forward; resolve manually (git -C $HARMONY_CONFIG_DIR log --oneline --left-right @{upstream}...HEAD). Applying current local state." ;;
        behind)
            # The one case we actually pull.
            if git -C "$HARMONY_CONFIG_DIR" merge --ff-only "@{upstream}" >/dev/null 2>&1; then
                harmony_info "sync: pulled latest config from $HARMONY_SYNC_REMOTE/$branch"
            else
                harmony_warn "sync: fast-forward to $HARMONY_SYNC_REMOTE/$branch failed unexpectedly — applying current local state"
            fi ;;
        *)
            harmony_debug "sync: state=$state — no pull action" ;;
    esac
    return 0
}

# Push the config repo after a successful local apply. Opt-in (mode=pull-push).
# Auto-commits first if sync.autoCommit is on. Pushes only if strictly ahead.
# Always returns 0.
harmony_sync_push() {
    [[ "${HARMONY_SYNC_ENABLED:-false}" == "true" ]] || return 0
    [[ "$HARMONY_SYNC_MODE" == "pull-push" ]] || { harmony_debug "sync: mode=$HARMONY_SYNC_MODE — not pushing"; return 0; }

    harmony_have_cmd git || return 0
    harmony_sync_is_repo || return 0

    local branch="${HARMONY_SYNC_BRANCH:-}"
    [[ -n "$branch" ]] || branch="$(harmony_sync_current_branch)"
    [[ -n "$branch" ]] || return 0

    # Capture uncommitted edits into a commit first, if autoCommit is enabled.
    harmony_sync_autocommit

    if ! harmony_sync_has_upstream; then
        harmony_warn "sync: branch '$branch' has no upstream — can't push (git -C $HARMONY_CONFIG_DIR push -u $HARMONY_SYNC_REMOTE $branch)"
        return 0
    fi

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

# One-line human-readable sync status, for verify/status. Echoes a label like
#   "sync: in sync with origin/main"  or  "sync: 2 behind origin/main"
# Usage: harmony_sync_report [--no-fetch]
harmony_sync_report() {
    local state branch
    state="$(harmony_sync_state "${1:-}")"
    branch="${HARMONY_SYNC_BRANCH:-}"; [[ -n "$branch" ]] || branch="$(harmony_sync_current_branch)"
    local ref="$HARMONY_SYNC_REMOTE/$branch"
    case "$state" in
        disabled)    printf "sync: disabled\n" ;;
        not-repo)    printf "sync: config dir is not a git repo\n" ;;
        detached)    printf "sync: detached HEAD (no branch to sync)\n" ;;
        dirty)       printf "sync: uncommitted local changes (won't pull)\n" ;;
        no-upstream) printf "sync: branch '%s' has no upstream set\n" "$branch" ;;
        offline)     printf "sync: can't reach %s (offline?)\n" "$HARMONY_SYNC_REMOTE" ;;
        in-sync)     printf "sync: in sync with %s\n" "$ref" ;;
        behind)      printf "sync: behind %s (apply will pull)\n" "$ref" ;;
        ahead)       printf "sync: ahead of %s (local commits not pushed)\n" "$ref" ;;
        diverged)    printf "sync: DIVERGED from %s — resolve manually\n" "$ref" ;;
        *)           printf "sync: %s\n" "$state" ;;
    esac
    # Exit status: healthy states 0, attention-needed states 1 (for verify).
    case "$state" in
        disabled|in-sync|behind|ahead) return 0 ;;
        *) return 1 ;;
    esac
}
