#!/usr/bin/env bash
# lib/domain-settings.sh — declarative management of ~/.claude/settings.json.
#
# This is the domain that fixes the additive-merge bug in the previous
# claude-config system. The contract:
#
#   - Keys in `manifest.settings.values` are written verbatim. To remove a
#     key, set its value to `null` explicitly — harmony deletes null values.
#     Simply omitting a key from `values` preserves whatever is already in
#     settings.json (harmony only touches keys it sees in your manifest).
#   - Keys in `manifest.settings.derived[]` are computed by harmony from
#     other manifest sections (e.g. `hooks` derives from manifest.hooks{},
#     `enabledPlugins` from manifest.plugins[], `extraKnownMarketplaces`
#     from manifest.marketplaces[]). These are always overwritten when
#     listed, even with empty values.
#   - Any other key in the user's existing settings.json is preserved. This
#     is the escape hatch for hand-edits.
#
# Path target: ~/.claude/settings.json (override via HARMONY_SETTINGS_PATH).

: "${HARMONY_SETTINGS_PATH:=${HOME}/.claude/settings.json}"

# ---------- Helpers ----------

# Build a jq expression that constructs the desired settings.json from the
# current settings.json + the manifest. Used by both plan (diff) and apply.
#
# Args: manifest_path
# Stdin: current settings.json contents
# Stdout: desired settings.json contents
_settings_compute_desired() {
    local manifest="$1"

    # Pull the various manifest sections.
    # We let jq do the merging in a single pass so semantics are auditable.
    jq \
        --slurpfile manifest "$manifest" \
        --arg config_dir "$HARMONY_CONFIG_DIR" \
        --arg plugin_root "$CLAUDE_PLUGIN_ROOT" \
        --arg home "$HOME" '
        # --- Helpers ---
        def expand_vars:
            gsub("\\$\\{HARMONY_CONFIG_DIR\\}"; $config_dir)
            | gsub("\\$\\{CLAUDE_PLUGIN_ROOT\\}"; $plugin_root)
            | gsub("\\$\\{HOME\\}"; $home);

        # Recursively expand ${VAR} placeholders in every string leaf of a
        # JSON value. Numbers/bools/null pass through unchanged. Used on
        # whatever the user puts in `values` so they can reference
        # ${HARMONY_CONFIG_DIR} et al. in any setting (statusLine command,
        # etc.) without hardcoding per-Mac paths.
        def deep_expand:
            walk(if type == "string" then expand_vars else . end);

        # Convert manifest hook entries -> Claude Code nested shape.
        # Manifest: { "SessionStart": [ { "command": "..." } ] }
        # Output:   { "SessionStart": [ { "hooks": [ { "type": "command", "command": "..." } ] } ] }
        # Optional per-entry fields "matcher" (entry-level) and "timeout"
        # (hook-level) are carried through when present, so hooks written by
        # external tools (the cux matcher/timeout entries) round-trip
        # faithfully instead of being stripped on apply. Entries without them
        # emit the same bare shape as before.
        def to_cc_hooks(h):
            h
            | to_entries
            | map({
                key: .key,
                value: ( .value | map(
                    (if has("matcher") then { matcher: .matcher } else {} end)
                    + { hooks: [
                        ( { type: "command", command: (.command | expand_vars) }
                          + (if has("timeout") then { timeout: .timeout } else {} end) )
                      ] }
                ) )
              })
            | from_entries;

        # Build enabledPlugins from manifest.plugins[].
        # Note: cannot use `.enabled // true` because `false // true` = true (jq gotcha).
        def to_enabled_plugins(plugins):
            plugins
            | map({ key: .id, value: (if has("enabled") then .enabled else true end) })
            | from_entries;

        # Build extraKnownMarketplaces from manifest.marketplaces[].
        def to_extra_marketplaces(marketplaces):
            marketplaces
            | map(select(.source))
            | map({
                key: .name,
                value: {
                    source: (
                        if (.source | type) == "string"
                            and (.source | contains("/"))
                            and (.source | startswith("http") | not)
                        then { source: "github", repo: .source }
                        else (if (.source | type) == "object" then .source else { source: "github", repo: .source } end)
                        end
                    )
                }
              })
            | from_entries;

        # The current settings.json (this stdin).
        . as $current

        # The manifest (slurpfile yields a 1-element array).
        | ($manifest[0]) as $m
        | ($m.settings // {}) as $msettings
        | ($msettings.values // {}) as $values
        | ($msettings.derived // []) as $derived_keys

        # Compute derived values.
        | (if ($m.hooks // null) != null
              then to_cc_hooks($m.hooks)
              else null end) as $derived_hooks
        | (if ($m.plugins // null) != null
              then to_enabled_plugins($m.plugins)
              else null end) as $derived_enabledPlugins
        | (if ($m.marketplaces // null) != null
              then to_extra_marketplaces($m.marketplaces)
              else null end) as $derived_extraMarketplaces

        # Apply: start from current; remove all managed keys; then re-add
        # whatever the manifest says.
        | ($values | keys) as $value_keys
        | $current
        # Delete all derived keys so they get fully recomputed below.
        | reduce $derived_keys[] as $k (.; del(.[$k]))
        # Apply values: for each key in values, either set it (non-null)
        # or delete it from settings.json (null = explicit removal).
        # String leaves go through deep_expand so ${HARMONY_CONFIG_DIR} etc.
        # resolve to actual paths on this Mac.
        | reduce ($values | to_entries)[] as $kv (.;
              if $kv.value == null then del(.[$kv.key]) else .[$kv.key] = ($kv.value | deep_expand) end
          )
        # Write back the derived values (only if computable + listed in derived).
        | (if (($derived_keys | index("hooks")) != null and $derived_hooks != null)
              then .hooks = $derived_hooks else . end)
        | (if (($derived_keys | index("enabledPlugins")) != null and $derived_enabledPlugins != null)
              then .enabledPlugins = $derived_enabledPlugins else . end)
        | (if (($derived_keys | index("extraKnownMarketplaces")) != null and $derived_extraMarketplaces != null)
              then .extraKnownMarketplaces = $derived_extraMarketplaces else . end)
    '
}

# Return tab-separated diff lines: <action>\t<key>\t<detail>
# Used by both plan and verify. Empty output means in sync.
_settings_compute_diff() {
    local manifest="$1"
    local current

    # Load current settings.json (or empty object if missing).
    if [[ -f "$HARMONY_SETTINGS_PATH" ]]; then
        current="$(cat "$HARMONY_SETTINGS_PATH")"
    else
        current="{}"
    fi

    local desired
    desired="$(printf "%s" "$current" | _settings_compute_desired "$manifest")"

    # Walk every key in either current or desired. For each, classify:
    #   - present in both, equal -> noop (don't emit)
    #   - present only in desired -> install
    #   - present only in current AND key is managed -> uninstall
    #   - present in both but different -> update
    #
    # "Managed" = key is in manifest.settings.values OR in manifest.settings.derived.
    # Unmanaged keys present in current are preserved (don't emit anything for them).

    local managed_keys
    managed_keys="$(jq -r '
        ((.settings.values // {}) | keys) + (.settings.derived // [])
        | unique | .[]
    ' "$manifest")"

    # Compare with -S (sort object keys) so a pure key-reorder is NOT seen as
    # drift — object key order is not semantically meaningful, but array order
    # is preserved by -S (hook execution order still matters). Without this,
    # tools that write settings.json keys in their own order (e.g. cux) would
    # register perpetual phantom drift even when values are identical.
    local key cur_val des_val managed
    while IFS= read -r key; do
        [[ -z "$key" ]] && continue
        cur_val="$(printf "%s" "$current" | jq -cS --arg k "$key" '.[$k] // null')"
        des_val="$(printf "%s" "$desired" | jq -cS --arg k "$key" '.[$k] // null')"
        managed=0
        if printf "%s\n" "$managed_keys" | grep -qx "$key"; then
            managed=1
        fi

        if [[ "$cur_val" == "$des_val" ]]; then
            continue  # in sync, no line
        fi

        if [[ "$cur_val" == "null" ]]; then
            harmony_plan_line install "settings.${key}" "set"
        elif [[ "$des_val" == "null" ]]; then
            if [[ "$managed" == "1" ]]; then
                harmony_plan_line uninstall "settings.${key}" "remove"
            fi
            # else: unmanaged + not desired = preserve, no action
        else
            if [[ "$managed" == "1" ]]; then
                harmony_plan_line update "settings.${key}" "change"
            fi
            # else: unmanaged + has different value than what desired-would-be:
            # but desired only sets managed keys, so this branch shouldn't fire
            # for unmanaged keys. Defensive.
        fi
    done < <(printf "%s\n%s\n" "$current" "$desired" | jq -r 'keys | .[]' | sort -u)
}

# ---------- Public API ----------

harmony_domain_settings_plan() {
    local manifest="$1"
    _settings_compute_diff "$manifest"
}

harmony_domain_settings_apply() {
    local manifest="$1"
    local current desired

    if [[ -f "$HARMONY_SETTINGS_PATH" ]]; then
        current="$(cat "$HARMONY_SETTINGS_PATH")"
    else
        current="{}"
    fi

    desired="$(printf "%s" "$current" | _settings_compute_desired "$manifest")"

    # Only write if different.
    if [[ "$current" == "$desired" ]]; then
        harmony_debug "settings.json already in sync"
        return 0
    fi

    # Validate desired output before writing.
    if ! printf "%s" "$desired" | jq empty 2>/dev/null; then
        harmony_error "computed desired settings.json is not valid JSON; refusing to write"
        return 1
    fi

    # Pretty-print on write so the file stays human-editable.
    printf "%s" "$desired" | jq '.' | harmony_jq_write_atomic "$HARMONY_SETTINGS_PATH"
    harmony_info "wrote $HARMONY_SETTINGS_PATH"
}

harmony_domain_settings_verify() {
    local manifest="$1"
    local diff
    diff="$(_settings_compute_diff "$manifest")"
    [[ -z "$diff" ]]
}
