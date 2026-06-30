#!/usr/bin/env bash
# lib/domain-plugins.sh — declarative management of plugins + marketplaces.
#
# Reads the user's manifest and reconciles against `claude plugin list --json`
# and `claude plugin marketplace list --json`. Adds missing entries, removes
# extras, toggles enabled flags. This is what gives harmony its uninstall
# propagation — the killer feature vs the old additive-only system.
#
# Self-uninstall guard: even if a user's manifest omits the harmony plugin
# entirely, this domain MUST NOT uninstall harmony itself (that would kill
# the running reconciler mid-execution). Hardcoded in NEVER_UNINSTALL.
#
# Manifest shape:
#   "marketplaces": [ { "name": "x", "source": "owner/repo" }, ... ]
#   "plugins":      [ { "id": "name@marketplace", "enabled": true }, ... ]
#
# Source field on a marketplace entry is either:
#   - A GitHub repo "owner/repo"
#   - A full URL "https://..."
#   - A local path "/absolute/path" or "./relative/path"
# (passed verbatim to `claude plugin marketplace add`)
#
# CLI overrides (for testing — set in env to swap in a mock):
#   HARMONY_CLAUDE_CMD   default: "claude"

: "${HARMONY_CLAUDE_CMD:=claude}"

# Plugins that must never be auto-uninstalled, regardless of manifest.
# Currently just the harmony plugin itself. Adding to this list is a hard
# decision — these plugins are no longer fully manageable by harmony.
HARMONY_NEVER_UNINSTALL=( "harmony" )

# ---------- Helpers ----------

# Run `claude` with the given args and capture stdout. Returns the exit code
# of the underlying command. On error, prints the captured stderr to ours.
_plugins_claude() {
    local out err rc
    err="$(mktemp -t harmony-plugins-err.XXXXXX)"
    if out="$("$HARMONY_CLAUDE_CMD" "$@" 2>"$err")"; then
        rm -f "$err"
        printf "%s" "$out"
        return 0
    else
        rc=$?
        harmony_warn "claude $* failed (exit $rc): $(cat "$err")"
        rm -f "$err"
        return $rc
    fi
}

# Extract the plugin's "short name" from a fully-qualified id "name@marketplace".
_plugins_short_name() {
    printf "%s\n" "${1%%@*}"
}

# Check if a plugin id is on the NEVER_UNINSTALL list.
_plugins_is_protected() {
    local id="$1"
    local short
    short="$(_plugins_short_name "$id")"
    local p
    for p in "${HARMONY_NEVER_UNINSTALL[@]}"; do
        [[ "$short" == "$p" ]] && return 0
    done
    return 1
}

# Compute the diff between desired (manifest) and current state. Pure
# function — takes JSON on stdin so it's testable without running `claude`.
#
# Args:    <manifest> <current-marketplaces-json> <current-plugins-json>
# Stdout:  plan lines (tab-separated): <action>\t<resource>\t<details>
#   Marketplace actions: install/uninstall/noop (resource: marketplace.<name>)
#   Plugin actions:      install/uninstall/enable/disable/noop (resource: plugin.<id>)
_plugins_compute_diff() {
    local manifest="$1"
    local current_markets_json="$2"
    local current_plugins_json="$3"

    # --- Marketplaces ---
    # Desired set.
    local desired_market_names
    desired_market_names="$(jq -r '.marketplaces // [] | .[] | .name' "$manifest" | sort -u)"

    # Current set.
    local current_market_names
    current_market_names="$(printf "%s" "$current_markets_json" | jq -r '.[] | .name' | sort -u)"

    # Install missing.
    local name source
    while IFS= read -r name; do
        [[ -z "$name" ]] && continue
        if ! printf "%s\n" "$current_market_names" | grep -qx "$name"; then
            source="$(jq -r --arg n "$name" '.marketplaces[] | select(.name == $n) | .source' "$manifest")"
            harmony_plan_line install "marketplace.${name}" "add $source"
        fi
    done <<< "$desired_market_names"

    # Uninstall extras (only if no plugins in that marketplace are installed,
    # to avoid orphaning plugins).
    while IFS= read -r name; do
        [[ -z "$name" ]] && continue
        if ! printf "%s\n" "$desired_market_names" | grep -qx "$name"; then
            # How many installed plugins are from this marketplace?
            local in_use
            in_use="$(printf "%s" "$current_plugins_json" \
                | jq -r --arg m "$name" '.[] | select(.id | endswith("@" + $m)) | .id' | wc -l | tr -d ' ')"
            if [[ "$in_use" -gt 0 ]]; then
                harmony_plan_line noop "marketplace.${name}" "would remove, but $in_use plugin(s) still installed from it; keeping"
            else
                harmony_plan_line uninstall "marketplace.${name}" "remove"
            fi
        fi
    done <<< "$current_market_names"

    # --- Plugins ---
    # Desired { id -> enabled }.
    local desired_plugin_ids
    desired_plugin_ids="$(jq -r '.plugins // [] | .[] | .id' "$manifest" | sort -u)"

    # Current { id -> enabled }.
    local current_plugin_ids
    current_plugin_ids="$(printf "%s" "$current_plugins_json" | jq -r '.[] | .id' | sort -u)"

    # Install missing.
    local id desired_enabled current_enabled
    while IFS= read -r id; do
        [[ -z "$id" ]] && continue
        if ! printf "%s\n" "$current_plugin_ids" | grep -qx "$id"; then
            desired_enabled="$(jq -r --arg i "$id" '.plugins[] | select(.id == $i) | (if has("enabled") then .enabled else true end)' "$manifest")"
            harmony_plan_line install "plugin.${id}" "install (enabled=$desired_enabled)"
        fi
    done <<< "$desired_plugin_ids"

    # Uninstall extras (with NEVER_UNINSTALL guard).
    while IFS= read -r id; do
        [[ -z "$id" ]] && continue
        if ! printf "%s\n" "$desired_plugin_ids" | grep -qx "$id"; then
            if _plugins_is_protected "$id"; then
                harmony_plan_line noop "plugin.${id}" "absent from manifest but on NEVER_UNINSTALL list; preserving"
            else
                harmony_plan_line uninstall "plugin.${id}" "uninstall"
            fi
        fi
    done <<< "$current_plugin_ids"

    # Enable/disable mismatches for plugins present on both sides.
    while IFS= read -r id; do
        [[ -z "$id" ]] && continue
        if printf "%s\n" "$current_plugin_ids" | grep -qx "$id"; then
            desired_enabled="$(jq -r --arg i "$id" '.plugins[] | select(.id == $i) | (if has("enabled") then .enabled else true end)' "$manifest")"
            current_enabled="$(printf "%s" "$current_plugins_json" \
                | jq -r --arg i "$id" '.[] | select(.id == $i) | .enabled')"
            if [[ "$desired_enabled" != "$current_enabled" ]]; then
                if [[ "$desired_enabled" == "true" ]]; then
                    harmony_plan_line enable "plugin.${id}" "enable (was disabled)"
                else
                    harmony_plan_line disable "plugin.${id}" "disable (was enabled)"
                fi
            fi
        fi
    done <<< "$desired_plugin_ids"
}

# Wrapper that fetches live state from `claude` and computes the diff.
# Filters current plugin list to scope=="user" — harmony does not manage
# project-scoped plugins (those are owned per-project, not globally).
_plugins_diff_live() {
    local manifest="$1"
    local markets plugins
    if ! markets="$(_plugins_claude plugin marketplace list --json)"; then
        markets="[]"
    fi
    if ! plugins="$(_plugins_claude plugin list --json)"; then
        plugins="[]"
    fi
    # Keep only user-scoped plugins.
    plugins="$(printf "%s" "$plugins" | jq -c '[ .[] | select(.scope == "user") ]')"
    _plugins_compute_diff "$manifest" "$markets" "$plugins"
}

# ---------- Public API ----------

harmony_domain_plugins_plan() {
    local manifest="$1"

    # If `claude` is unavailable, we can't plan against live state. Warn and
    # emit nothing (treated as "in sync"). The plan/apply contract is to
    # tolerate missing prerequisites, not fail.
    if ! harmony_have_cmd "$HARMONY_CLAUDE_CMD"; then
        harmony_warn "claude CLI not found; skipping plugins domain"
        return 0
    fi

    _plugins_diff_live "$manifest"
}

harmony_domain_plugins_apply() {
    local manifest="$1"

    if ! harmony_have_cmd "$HARMONY_CLAUDE_CMD"; then
        harmony_warn "claude CLI not found; skipping plugins domain"
        return 0
    fi

    local plan
    plan="$(_plugins_diff_live "$manifest")"
    [[ -z "$plan" ]] && return 0

    local action resource details
    while IFS=$'\t' read -r action resource details; do
        [[ -z "$action" ]] && continue
        case "$action" in
            noop)
                harmony_debug "[plugins] noop: $resource — $details"
                ;;
            install)
                case "$resource" in
                    marketplace.*)
                        local mname="${resource#marketplace.}"
                        local source
                        source="$(jq -r --arg n "$mname" '.marketplaces[] | select(.name == $n) | .source' "$manifest")"
                        if ! _plugins_claude plugin marketplace add "$source" >/dev/null; then
                            harmony_warn "failed to add marketplace $mname; continuing"
                        fi
                        ;;
                    plugin.*)
                        local pid="${resource#plugin.}"
                        local desired_enabled
                        desired_enabled="$(jq -r --arg i "$pid" '.plugins[] | select(.id == $i) | (.enabled // true)' "$manifest")"
                        if ! _plugins_claude plugin install "$pid" >/dev/null; then
                            harmony_warn "failed to install $pid; continuing"
                            continue
                        fi
                        # If desired disabled, immediately disable.
                        if [[ "$desired_enabled" == "false" ]]; then
                            _plugins_claude plugin disable "$pid" >/dev/null || true
                        fi
                        ;;
                esac
                ;;
            uninstall)
                case "$resource" in
                    marketplace.*)
                        local mname="${resource#marketplace.}"
                        _plugins_claude plugin marketplace remove "$mname" >/dev/null \
                            || harmony_warn "failed to remove marketplace $mname; continuing"
                        ;;
                    plugin.*)
                        local pid="${resource#plugin.}"
                        if _plugins_is_protected "$pid"; then
                            harmony_warn "refusing to uninstall protected plugin: $pid"
                            continue
                        fi
                        _plugins_claude plugin uninstall "$pid" >/dev/null \
                            || harmony_warn "failed to uninstall $pid; continuing"
                        ;;
                esac
                ;;
            enable)
                local pid="${resource#plugin.}"
                _plugins_claude plugin enable "$pid" >/dev/null \
                    || harmony_warn "failed to enable $pid; continuing"
                ;;
            disable)
                local pid="${resource#plugin.}"
                _plugins_claude plugin disable "$pid" >/dev/null \
                    || harmony_warn "failed to disable $pid; continuing"
                ;;
        esac
    done <<< "$plan"
    return 0
}

harmony_domain_plugins_verify() {
    local manifest="$1"
    if ! harmony_have_cmd "$HARMONY_CLAUDE_CMD"; then
        # Can't verify without claude. Treat as not-applicable (pass).
        return 0
    fi
    local diff
    diff="$(_plugins_diff_live "$manifest")"
    # Only fail on real drift; noop lines mean "we noticed something but didn't act."
    local actionable
    actionable="$(printf "%s\n" "$diff" | grep -v '^noop' || true)"
    [[ -z "$actionable" ]]
}

# Reverse reconcile: report plugin ids that are installed but absent from the
# manifest (i.e. what `plan` would uninstall) so `harmony capture` can ADD them
# instead of removing them. Pure-ish — relies on the same live plan path.
#
# Args:    <manifest>
# Stdout:  one plugin id per line (e.g. "playwright@claude-plugins-official").
#          Protected plugins (NEVER_UNINSTALL) are excluded — they're already
#          preserved, not captured.
harmony_domain_plugins_capture() {
    local manifest="$1"

    if ! harmony_have_cmd "$HARMONY_CLAUDE_CMD"; then
        harmony_warn "claude CLI not found; skipping plugins capture"
        return 0
    fi

    local plan
    plan="$(_plugins_diff_live "$manifest")"
    [[ -z "$plan" ]] && return 0

    # An `uninstall plugin.<id>` line == installed-but-not-in-manifest. That is
    # exactly the session-installed plugin we want to capture. (Protected ones
    # surface as `noop`, so they're naturally skipped by the grep.)
    local action resource details
    while IFS=$'\t' read -r action resource details; do
        [[ "$action" == "uninstall" ]] || continue
        case "$resource" in
            plugin.*) printf "%s\n" "${resource#plugin.}" ;;
        esac
    done <<< "$plan"
}
