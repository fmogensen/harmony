#!/usr/bin/env bash
# lib/domain-mcp.sh — declarative MCP server management.
#
# Reconciles ~/.claude.json's projects[$HOME].mcpServers against the manifest.
# Scope-limited to global (project = $HOME) in v1; the schema reserves
# manifest.mcpServers._scope for future per-project extension.
#
# Manifest shape:
#   "mcpServers": {
#     "_scope": "global",
#     "servers": {
#       "my-mcp": { "command": "uv", "args": ["run","my-mcp"], "env": {} }
#     }
#   }
#
# Sanitiser: refuses to write entries whose env values look like secrets
# (long random strings, anything matching common token patterns). Real
# secrets must live in shell env vars and be referenced via "$ENV_VAR_NAME"
# in args, not embedded in the manifest.
#
# Test overrides:
#   HARMONY_CLAUDE_JSON  default: ~/.claude.json

: "${HARMONY_CLAUDE_JSON:=${HOME}/.claude.json}"

# Sanitiser: if any env value matches one of these patterns, abort with error.
_HARMONY_SECRET_PATTERNS=(
    'sk-[A-Za-z0-9_-]{20,}'    # OpenAI/Anthropic
    'ghp_[A-Za-z0-9]{36,}'     # GitHub PAT
    'gho_[A-Za-z0-9]{36,}'     # GitHub OAuth
    'xoxb-[0-9-]{10,}'         # Slack bot tokens
    'AKIA[0-9A-Z]{16,}'        # AWS access keys
)

_mcp_looks_like_secret() {
    local val="$1"
    local pat
    for pat in "${_HARMONY_SECRET_PATTERNS[@]}"; do
        if printf "%s" "$val" | grep -Eq "$pat"; then
            return 0
        fi
    done
    return 1
}

# Validate manifest mcpServers contains no embedded secrets. Returns 0 if clean.
_mcp_validate_no_secrets() {
    local manifest="$1"
    local entries env_pairs server val
    entries="$(jq -r '.mcpServers.servers // {} | to_entries[] | .key' "$manifest")"
    while IFS= read -r server; do
        [[ -z "$server" ]] && continue
        # Iterate env vars, check each value.
        while IFS=$'\t' read -r k v; do
            if _mcp_looks_like_secret "$v"; then
                harmony_error "mcp.${server}.env.${k} looks like a secret; refusing to apply"
                return 1
            fi
        done < <(jq -r --arg s "$server" '.mcpServers.servers[$s].env // {} | to_entries[] | "\(.key)\t\(.value)"' "$manifest")
    done <<< "$entries"
    return 0
}

# Read current mcpServers for the global scope ($HOME project).
_mcp_current_json() {
    if [[ ! -f "$HARMONY_CLAUDE_JSON" ]]; then
        printf "{}\n"
        return 0
    fi
    jq -c --arg h "$HOME" '.projects[$h].mcpServers // {}' "$HARMONY_CLAUDE_JSON" 2>/dev/null || printf "{}\n"
}

# ---------- Public API ----------

harmony_domain_mcp_plan() {
    local manifest="$1"
    local desired current
    desired="$(jq -c '.mcpServers.servers // {}' "$manifest")"
    current="$(_mcp_current_json)"

    if [[ "$desired" == "$current" ]]; then
        return 0
    fi

    # Per-server diff for readable plan lines.
    local key
    while IFS= read -r key; do
        [[ -z "$key" ]] && continue
        local d c
        d="$(printf "%s" "$desired" | jq -c --arg k "$key" '.[$k] // null')"
        c="$(printf "%s" "$current" | jq -c --arg k "$key" '.[$k] // null')"
        if [[ "$d" == "$c" ]]; then
            continue
        fi
        if [[ "$c" == "null" ]]; then
            harmony_plan_line install "mcp.${key}" "add server"
        elif [[ "$d" == "null" ]]; then
            harmony_plan_line uninstall "mcp.${key}" "remove server"
        else
            harmony_plan_line update "mcp.${key}" "config changed"
        fi
    done < <(printf "%s\n%s\n" "$desired" "$current" | jq -r 'keys | .[]' | sort -u)
}

harmony_domain_mcp_apply() {
    local manifest="$1"

    _mcp_validate_no_secrets "$manifest" || return 1

    local desired current
    desired="$(jq -c '.mcpServers.servers // {}' "$manifest")"
    current="$(_mcp_current_json)"

    if [[ "$desired" == "$current" ]]; then
        return 0
    fi

    if [[ ! -f "$HARMONY_CLAUDE_JSON" ]]; then
        # No .claude.json at all — leave it alone unless desired is non-empty.
        if [[ "$desired" == "{}" ]]; then
            return 0
        fi
        # Create minimal structure.
        jq -n --arg h "$HOME" --argjson s "$desired" '{ projects: { ($h): { mcpServers: $s } } }' \
            | harmony_jq_write_atomic "$HARMONY_CLAUDE_JSON"
        harmony_info "wrote mcpServers to $HARMONY_CLAUDE_JSON"
        return 0
    fi

    # Update in place.
    jq --arg h "$HOME" --argjson s "$desired" '
        .projects = (.projects // {})
        | .projects[$h] = (.projects[$h] // {})
        | .projects[$h].mcpServers = $s
    ' "$HARMONY_CLAUDE_JSON" | harmony_jq_write_atomic "$HARMONY_CLAUDE_JSON"
    harmony_info "updated mcpServers in $HARMONY_CLAUDE_JSON"
    return 0
}

harmony_domain_mcp_verify() {
    local manifest="$1"
    local desired current
    desired="$(jq -c '.mcpServers.servers // {}' "$manifest")"
    current="$(_mcp_current_json)"
    [[ "$desired" == "$current" ]]
}

# Reverse reconcile: report MCP servers present on the machine but absent from
# the manifest, so `harmony capture` can ADD them. CRITICAL: a server whose
# config contains a secret-looking env value is NOT captured — writing it into
# the manifest would commit a secret to git and sync it to other Macs. Such
# servers are reported on the SKIP channel instead, so the caller can nudge the
# user to add them by hand.
#
# Args:    <manifest>
# Stdout:  one line per capturable server: "<key>\t<config-json>"
#          one line per skipped (secret) server: "SKIP\t<key>\t<reason>"
harmony_domain_mcp_capture() {
    local manifest="$1"
    local desired current
    desired="$(jq -c '.mcpServers.servers // {}' "$manifest")"
    current="$(_mcp_current_json)"

    [[ "$desired" == "$current" ]] && return 0

    local key d c
    while IFS= read -r key; do
        [[ -z "$key" ]] && continue
        d="$(printf "%s" "$desired" | jq -c --arg k "$key" '.[$k] // null')"
        c="$(printf "%s" "$current" | jq -c --arg k "$key" '.[$k] // null')"
        # Only capture servers present on the machine but missing from manifest.
        [[ "$d" == "null" && "$c" != "null" ]] || continue

        # Secret guard: refuse to capture a server with secret-looking env values.
        local has_secret=0 v
        while IFS= read -r v; do
            [[ -z "$v" ]] && continue
            if _mcp_looks_like_secret "$v"; then has_secret=1; break; fi
        done < <(printf "%s" "$c" | jq -r '.env // {} | to_entries[] | .value')

        if [[ "$has_secret" == "1" ]]; then
            printf "SKIP\t%s\tcontains a secret-looking env value; add it to the manifest by hand\n" "$key"
        else
            printf "%s\t%s\n" "$key" "$c"
        fi
    done < <(printf "%s\n%s\n" "$desired" "$current" | jq -r 'keys | .[]' | sort -u)
}
