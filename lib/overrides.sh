#!/usr/bin/env bash
# lib/overrides.sh — v2 per-host manifest overrides.
#
# Lets one machine differ from the shared base manifest without forking it.
# If HARMONY_CONFIG_DIR/overrides/<hostname>.json exists, it is deep-merged
# OVER the base harmony.json to produce the "effective" manifest that all
# domains then reconcile against.
#
# Merge semantics (jq `*` recursive merge):
#   - Objects merge key-by-key, recursively (e.g. settings.values.voice can be
#     overridden without restating the whole settings block).
#   - Scalars and ARRAYS are REPLACED wholesale by the override (so an override
#     that sets "plugins" replaces the base plugins list — by design: arrays are
#     identity-less, merging them is ambiguous). Override only what you mean to.
#
# The effective manifest is written to a temp file; callers use its path in
# place of the base manifest. The base harmony.json on disk is never mutated.
#
# Sourced by bin/harmony. Depends on common.sh (logging, hostname, jq).

# Path to this host's override file (may not exist).
harmony_overrides_path() {
    printf "%s/overrides/%s.json\n" "$HARMONY_CONFIG_DIR" "$(harmony_hostname)"
}

# Produce the effective manifest for this host.
# Usage: harmony_effective_manifest <base-manifest>
# Echoes the path to the manifest to use (either the base itself if no override,
# or a temp merged file). The temp file is registered for cleanup by the caller's
# EXIT trap via HARMONY_EFFECTIVE_TMP.
harmony_effective_manifest() {
    local base="$1"
    local ovr
    ovr="$(harmony_overrides_path)"

    if [[ ! -f "$ovr" ]]; then
        harmony_debug "overrides: none for host $(harmony_hostname) — using base manifest"
        printf "%s\n" "$base"
        return 0
    fi

    if ! jq empty "$ovr" 2>/dev/null; then
        harmony_warn "overrides: $ovr is not valid JSON — ignoring it, using base manifest"
        printf "%s\n" "$base"
        return 0
    fi

    local merged="${TMPDIR:-/tmp}/harmony-effective.$$.json"
    if jq -s '.[0] * .[1]' "$base" "$ovr" > "$merged" 2>/dev/null && jq empty "$merged" 2>/dev/null; then
        HARMONY_EFFECTIVE_TMP="$merged"
        export HARMONY_EFFECTIVE_TMP
        harmony_info "overrides: applied overrides/$(harmony_hostname).json over base manifest"
        printf "%s\n" "$merged"
        return 0
    fi

    harmony_warn "overrides: failed to merge $ovr — using base manifest"
    rm -f "$merged" 2>/dev/null || true
    printf "%s\n" "$base"
    return 0
}

# Remove the temp effective manifest, if one was created.
harmony_overrides_cleanup() {
    [[ -n "${HARMONY_EFFECTIVE_TMP:-}" && -f "${HARMONY_EFFECTIVE_TMP}" ]] && rm -f "$HARMONY_EFFECTIVE_TMP"
    return 0
}
