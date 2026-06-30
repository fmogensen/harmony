#!/usr/bin/env bash
# lib/domain-brew.sh — reconcile a Brewfile against the local brew install.
#
# Asymmetric vs other domains: ADDITIVE ONLY. harmony never auto-uninstalls
# a brew formula — they often have side-effects (services, taps, kexts) and
# users install things ad-hoc. To remove a formula, delete it from the
# Brewfile + `brew uninstall <formula>` by hand.
#
# Manifest shape:
#   "brew": {
#     "brewfile": "settings/Brewfile",       # path relative to HARMONY_CONFIG_DIR
#     "auto_install_tier": "safe",           # "safe" | "ask" | "none"
#     "tiers": {
#       "safe": ["jq", "gh", "ripgrep"],     # auto-install silently
#       "ask":  ["reminders-cli"]            # warn but don't install
#     }
#   }
#
# Formulas not listed in any tier default to "safe" (install).
#
# CLI override (for tests):
#   HARMONY_BREW_CMD  default: "brew"

: "${HARMONY_BREW_CMD:=brew}"

# ---------- Helpers ----------

# Extract formula names from a Brewfile. Standard format:
#   brew "name"               -> "name"
#   brew "name", args: ...    -> "name"
# Casks, taps, mas entries are ignored for tier classification but
# `brew bundle install` still handles them.
_brew_formula_names() {
    local brewfile="$1"
    [[ -f "$brewfile" ]] || return 0
    grep -E '^[[:space:]]*brew[[:space:]]+"' "$brewfile" \
        | sed -E 's/^[[:space:]]*brew[[:space:]]+"([^"]+)".*/\1/'
}

_brew_tier_for() {
    # Print the tier name for a formula. Defaults to "safe".
    local manifest="$1" formula="$2"
    local tier
    tier="$(jq -r --arg f "$formula" '
        .brew.tiers // {} as $t
        | if ($t.safe // [] | index($f)) != null then "safe"
          elif ($t.ask // [] | index($f)) != null then "ask"
          else "safe"
          end
    ' "$manifest")"
    printf "%s\n" "$tier"
}

_brew_have() {
    "$HARMONY_BREW_CMD" list --formula --versions "$1" >/dev/null 2>&1
}

_brew_brewfile_path() {
    local manifest="$1"
    local rel
    rel="$(harmony_jq_read "$manifest" '.brew.brewfile')"
    [[ -z "$rel" ]] && return 0
    if [[ "$rel" = /* ]]; then
        printf "%s\n" "$rel"
    else
        printf "%s/%s\n" "$HARMONY_CONFIG_DIR" "$rel"
    fi
}

# ---------- Public API ----------

harmony_domain_brew_plan() {
    local manifest="$1"
    local brewfile
    brewfile="$(_brew_brewfile_path "$manifest")"

    if [[ -z "$brewfile" || ! -f "$brewfile" ]]; then
        # Manifest doesn't declare a Brewfile, or it doesn't exist. Nothing to do.
        return 0
    fi

    if ! harmony_have_cmd "$HARMONY_BREW_CMD"; then
        harmony_warn "brew not found; skipping brew domain"
        return 0
    fi

    local auto_tier
    auto_tier="$(harmony_jq_read "$manifest" '.brew.auto_install_tier')"
    [[ -z "$auto_tier" ]] && auto_tier="safe"

    local formula tier
    while IFS= read -r formula; do
        [[ -z "$formula" ]] && continue
        if _brew_have "$formula"; then
            continue  # already installed, no action
        fi
        tier="$(_brew_tier_for "$manifest" "$formula")"
        case "$tier" in
            safe)
                if [[ "$auto_tier" == "safe" || "$auto_tier" == "ask" ]]; then
                    harmony_plan_line install "brew.${formula}" "tier=safe (auto-install)"
                else
                    harmony_plan_line noop "brew.${formula}" "tier=safe, but auto_install_tier=$auto_tier"
                fi
                ;;
            ask)
                if [[ "$auto_tier" == "ask" ]]; then
                    harmony_plan_line install "brew.${formula}" "tier=ask (--install-ask)"
                else
                    harmony_plan_line noop "brew.${formula}" "tier=ask — install manually: brew install $formula"
                fi
                ;;
            *)
                harmony_plan_line install "brew.${formula}" "tier=unknown -> default safe"
                ;;
        esac
    done < <(_brew_formula_names "$brewfile")
}

harmony_domain_brew_apply() {
    local manifest="$1"
    local brewfile
    brewfile="$(_brew_brewfile_path "$manifest")"

    if [[ -z "$brewfile" || ! -f "$brewfile" ]]; then
        return 0
    fi

    if ! harmony_have_cmd "$HARMONY_BREW_CMD"; then
        harmony_warn "brew not found; skipping brew domain"
        return 0
    fi

    local auto_tier
    auto_tier="$(harmony_jq_read "$manifest" '.brew.auto_install_tier')"
    [[ -z "$auto_tier" ]] && auto_tier="safe"

    local formula tier ok=0 skipped=0 failed=0
    while IFS= read -r formula; do
        [[ -z "$formula" ]] && continue
        if _brew_have "$formula"; then
            continue
        fi
        tier="$(_brew_tier_for "$manifest" "$formula")"
        local install=0
        case "$tier" in
            safe)
                [[ "$auto_tier" == "safe" || "$auto_tier" == "ask" ]] && install=1
                ;;
            ask)
                [[ "$auto_tier" == "ask" ]] && install=1
                ;;
            *)
                install=1
                ;;
        esac

        if [[ "$install" == "1" ]]; then
            harmony_info "brew install $formula (tier=$tier)"
            if "$HARMONY_BREW_CMD" install "$formula" >/dev/null 2>&1; then
                ok=$(( ok + 1 ))
            else
                harmony_warn "brew install $formula failed; continuing"
                failed=$(( failed + 1 ))
            fi
        else
            harmony_info "skipping $formula (tier=$tier, auto_install_tier=$auto_tier) — install manually: brew install $formula"
            skipped=$(( skipped + 1 ))
        fi
    done < <(_brew_formula_names "$brewfile")

    harmony_debug "brew: ok=$ok skipped=$skipped failed=$failed"
    return 0
}

harmony_domain_brew_verify() {
    local manifest="$1"
    local brewfile
    brewfile="$(_brew_brewfile_path "$manifest")"

    if [[ -z "$brewfile" || ! -f "$brewfile" ]]; then
        return 0  # nothing to verify
    fi

    if ! harmony_have_cmd "$HARMONY_BREW_CMD"; then
        return 0
    fi

    # All safe-tier formulae must be present. ask-tier missing is not a verify failure
    # (user opted into manual install). unknown-tier counts as safe (default).
    local formula tier fail=0
    while IFS= read -r formula; do
        [[ -z "$formula" ]] && continue
        tier="$(_brew_tier_for "$manifest" "$formula")"
        if [[ "$tier" == "safe" ]] && ! _brew_have "$formula"; then
            fail=$(( fail + 1 ))
        fi
    done < <(_brew_formula_names "$brewfile")
    [[ "$fail" -eq 0 ]]
}
