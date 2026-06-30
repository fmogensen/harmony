#!/usr/bin/env bash
# lib/domain-keybindings.sh — declarative ~/.claude/keybindings.json.
#
# Trivial domain: if manifest.keybindings is non-null, write the file.
# If null, leave the file alone (don't create or delete).
#
# Test override:
#   HARMONY_KEYBINDINGS_PATH  default: ~/.claude/keybindings.json

: "${HARMONY_KEYBINDINGS_PATH:=${HOME}/.claude/keybindings.json}"

_kb_desired() {
    jq -c '.keybindings' "$1"
}

_kb_current() {
    if [[ -f "$HARMONY_KEYBINDINGS_PATH" ]]; then
        jq -c '.' "$HARMONY_KEYBINDINGS_PATH" 2>/dev/null || printf "{}\n"
    else
        printf "null\n"
    fi
}

harmony_domain_keybindings_plan() {
    local manifest="$1"
    local desired current
    desired="$(_kb_desired "$manifest")"
    current="$(_kb_current)"

    # If desired is null, harmony does not touch keybindings — even if a file exists.
    if [[ "$desired" == "null" ]]; then
        return 0
    fi

    if [[ "$desired" == "$current" ]]; then
        return 0
    fi

    if [[ "$current" == "null" ]]; then
        harmony_plan_line install "keybindings" "create"
    else
        harmony_plan_line update "keybindings" "rewrite"
    fi
}

harmony_domain_keybindings_apply() {
    local manifest="$1"
    local desired current
    desired="$(_kb_desired "$manifest")"
    current="$(_kb_current)"

    if [[ "$desired" == "null" ]]; then
        return 0
    fi
    if [[ "$desired" == "$current" ]]; then
        return 0
    fi

    mkdir -p "$(dirname "$HARMONY_KEYBINDINGS_PATH")"
    printf "%s\n" "$desired" | jq '.' | harmony_jq_write_atomic "$HARMONY_KEYBINDINGS_PATH"
    harmony_info "wrote $HARMONY_KEYBINDINGS_PATH"
    return 0
}

harmony_domain_keybindings_verify() {
    local manifest="$1"
    local diff
    diff="$(harmony_domain_keybindings_plan "$manifest")"
    [[ -z "$diff" ]]
}
