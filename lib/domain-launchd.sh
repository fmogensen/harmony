#!/usr/bin/env bash
# lib/domain-launchd.sh — declarative management of macOS LaunchAgents.
#
# Renders plist templates from the user config repo, installs them into
# ~/Library/LaunchAgents/, loads them via launchctl. Critically, PRUNES any
# `dk.fmogensen.*` plist (or whatever prefix the user configures) that isn't
# in the manifest — this is what makes orphaned plists clean up automatically.
#
# Manifest shape:
#   "launchd": [
#     {
#       "label":  "dk.fmogensen.dream",
#       "plist":  "launchd/dk.fmogensen.dream.plist.template",
#       "runner": "launchd/dk.fmogensen.dream.run.sh.template",
#       "vars":   { "DREAM_HOUR": "9" }
#     }
#   ]
#
# Templates may reference ${HOME}, ${HARMONY_CONFIG_DIR}, ${CLAUDE_PLUGIN_ROOT}
# and any keys in the entry's `vars` object. Expansion happens at apply time.
#
# Safety boundary: harmony only manages plists whose label matches the user's
# label prefix (default: dk.fmogensen.*). Apple system agents, Homebrew
# services, and anything outside this prefix are NEVER touched.
#
# Test overrides:
#   HARMONY_LAUNCHD_DIR     default: ~/Library/LaunchAgents
#   HARMONY_LAUNCHCTL_CMD   default: launchctl
#   HARMONY_LABEL_PREFIX    default: dk.fmogensen
#   HARMONY_LAUNCHD_RUNNERS_DIR  default: ~/Library/Application Support

: "${HARMONY_LAUNCHD_DIR:=${HOME}/Library/LaunchAgents}"
: "${HARMONY_LAUNCHCTL_CMD:=launchctl}"
: "${HARMONY_LABEL_PREFIX:=dk.fmogensen}"
: "${HARMONY_LAUNCHD_RUNNERS_DIR:=${HOME}/Library/Application Support}"

# ---------- Helpers ----------

_launchd_resolve_path() {
    # Resolve a path under HARMONY_CONFIG_DIR (or pass through if absolute).
    local rel="$1"
    [[ -z "$rel" ]] && return 0
    if [[ "$rel" = /* ]]; then
        printf "%s\n" "$rel"
    else
        printf "%s/%s\n" "$HARMONY_CONFIG_DIR" "$rel"
    fi
}

# Expand a template file's ${VARS} into the output. Uses simple bash
# parameter expansion via envsubst-style sed. Predefined variables:
#   HOME, HARMONY_CONFIG_DIR, CLAUDE_PLUGIN_ROOT.
# Per-entry vars (from manifest .vars) are passed via env.
_launchd_render_template() {
    local template="$1"
    [[ -f "$template" ]] || { harmony_error "template not found: $template"; return 1; }
    # Read template, expand ${...} placeholders against the current env.
    # We use perl rather than envsubst (not on every macOS) for portability.
    perl -pe 's/\$\{([A-Za-z_][A-Za-z0-9_]*)\}/exists $ENV{$1} ? $ENV{$1} : "\$\{$1\}"/ge' "$template"
}

# Iterate launchd entries from the manifest. Each iteration sets the
# variables: L_LABEL, L_PLIST_SRC, L_RUNNER_SRC, L_VARS_JSON.
_launchd_each_entry() {
    local manifest="$1"
    jq -c '.launchd // [] | .[]' "$manifest"
}

# Compute the path on disk where a label's plist lives.
_launchd_installed_plist_path() {
    printf "%s/%s.plist\n" "$HARMONY_LAUNCHD_DIR" "$1"
}

# Compute the runner directory for a label.
_launchd_runner_dir() {
    printf "%s/%s\n" "$HARMONY_LAUNCHD_RUNNERS_DIR" "$1"
}

# Is this label already loaded in launchctl?
_launchd_is_loaded() {
    local label="$1"
    "$HARMONY_LAUNCHCTL_CMD" print "gui/$(id -u)/${label}" >/dev/null 2>&1
}

# List all installed plists matching the label prefix.
_launchd_installed_labels_with_prefix() {
    [[ -d "$HARMONY_LAUNCHD_DIR" ]] || return 0
    local f
    for f in "$HARMONY_LAUNCHD_DIR/${HARMONY_LABEL_PREFIX}."*.plist; do
        [[ -f "$f" ]] || continue
        local b
        b="$(basename "$f" .plist)"
        printf "%s\n" "$b"
    done
}

# Build the expanded environment for rendering a single entry's templates.
# Exports HOME, HARMONY_CONFIG_DIR, CLAUDE_PLUGIN_ROOT, and any per-entry vars.
_launchd_export_vars_for() {
    local vars_json="$1"
    [[ -z "$vars_json" || "$vars_json" == "null" ]] && return 0
    # Iterate keys; export each.
    local key val
    while IFS=$'\t' read -r key val; do
        export "$key=$val"
    done < <(printf "%s" "$vars_json" | jq -r 'to_entries | .[] | "\(.key)\t\(.value)"')
}

# ---------- Public API ----------

harmony_domain_launchd_plan() {
    local manifest="$1"

    # Desired labels.
    local desired_labels
    desired_labels="$(jq -r '.launchd // [] | .[] | .label' "$manifest" | sort -u)"

    # Compute install/update lines.
    local entry label plist_src runner_src vars
    while IFS= read -r entry; do
        [[ -z "$entry" ]] && continue
        label="$(printf "%s" "$entry" | jq -r '.label')"

        # Safety: refuse to manage labels outside the prefix.
        if [[ "$label" != "${HARMONY_LABEL_PREFIX}".* ]]; then
            harmony_plan_line error "launchd.${label}" "label outside managed prefix '${HARMONY_LABEL_PREFIX}.*' — skipping"
            continue
        fi

        plist_src="$(_launchd_resolve_path "$(printf "%s" "$entry" | jq -r '.plist')")"
        if [[ ! -f "$plist_src" ]]; then
            harmony_plan_line error "launchd.${label}" "plist template missing: $plist_src"
            continue
        fi

        local installed_plist
        installed_plist="$(_launchd_installed_plist_path "$label")"
        local loaded=0
        _launchd_is_loaded "$label" && loaded=1

        if [[ ! -f "$installed_plist" ]]; then
            harmony_plan_line install "launchd.${label}" "install plist + bootstrap"
        else
            # Compare rendered template to installed file.
            local rendered
            (
                _launchd_export_vars_for "$(printf "%s" "$entry" | jq -c '.vars // {}')"
                _launchd_render_template "$plist_src"
            ) > "${installed_plist}.harmony-tmp" 2>/dev/null
            if diff -q "$installed_plist" "${installed_plist}.harmony-tmp" >/dev/null 2>&1; then
                if [[ "$loaded" != "1" ]]; then
                    harmony_plan_line update "launchd.${label}" "plist in sync but not loaded; bootstrap"
                fi
                # else fully in sync, no line
            else
                harmony_plan_line update "launchd.${label}" "re-render + reload"
            fi
            rm -f "${installed_plist}.harmony-tmp"
        fi
    done < <(_launchd_each_entry "$manifest")

    # Prune: any installed plist with our prefix not in desired_labels.
    local installed_label
    while IFS= read -r installed_label; do
        [[ -z "$installed_label" ]] && continue
        if ! printf "%s\n" "$desired_labels" | grep -qx "$installed_label"; then
            harmony_plan_line uninstall "launchd.${installed_label}" "prune (not in manifest)"
        fi
    done < <(_launchd_installed_labels_with_prefix)
}

harmony_domain_launchd_apply() {
    local manifest="$1"

    mkdir -p "$HARMONY_LAUNCHD_DIR"

    local desired_labels
    desired_labels="$(jq -r '.launchd // [] | .[] | .label' "$manifest" | sort -u)"

    # Install / update.
    local entry label plist_src runner_src vars_json
    while IFS= read -r entry; do
        [[ -z "$entry" ]] && continue
        label="$(printf "%s" "$entry" | jq -r '.label')"

        if [[ "$label" != "${HARMONY_LABEL_PREFIX}".* ]]; then
            harmony_warn "launchd: skipping label outside prefix: $label"
            continue
        fi

        plist_src="$(_launchd_resolve_path "$(printf "%s" "$entry" | jq -r '.plist')")"
        runner_src="$(_launchd_resolve_path "$(printf "%s" "$entry" | jq -r '.runner // empty')")"
        vars_json="$(printf "%s" "$entry" | jq -c '.vars // {}')"

        if [[ ! -f "$plist_src" ]]; then
            harmony_warn "launchd: template missing, skipping: $plist_src"
            continue
        fi

        local installed_plist
        installed_plist="$(_launchd_installed_plist_path "$label")"

        # Render to a temp file.
        local rendered_tmp
        rendered_tmp="$(mktemp -t harmony-launchd.XXXXXX).plist"
        (
            _launchd_export_vars_for "$vars_json"
            _launchd_render_template "$plist_src"
        ) > "$rendered_tmp"

        # If in sync and loaded, skip.
        if [[ -f "$installed_plist" ]] && diff -q "$installed_plist" "$rendered_tmp" >/dev/null 2>&1 \
           && _launchd_is_loaded "$label"; then
            rm -f "$rendered_tmp"
            continue
        fi

        # Bootout if loaded.
        if _launchd_is_loaded "$label"; then
            "$HARMONY_LAUNCHCTL_CMD" bootout "gui/$(id -u)/${label}" >/dev/null 2>&1 || true
        fi

        # Write the plist.
        mv "$rendered_tmp" "$installed_plist"

        # Write the runner if declared.
        if [[ -n "$runner_src" && -f "$runner_src" ]]; then
            local runner_dir runner_dst
            runner_dir="$(_launchd_runner_dir "$label")"
            runner_dst="${runner_dir}/run.sh"
            mkdir -p "$runner_dir"
            (
                _launchd_export_vars_for "$vars_json"
                _launchd_render_template "$runner_src"
            ) > "$runner_dst"
            chmod +x "$runner_dst"
        fi

        # Bootstrap.
        if ! "$HARMONY_LAUNCHCTL_CMD" bootstrap "gui/$(id -u)" "$installed_plist" >/dev/null 2>&1; then
            harmony_warn "launchctl bootstrap failed for $label; continuing"
        fi
        harmony_info "launchd: installed $label"
    done < <(_launchd_each_entry "$manifest")

    # Prune.
    local installed_label
    while IFS= read -r installed_label; do
        [[ -z "$installed_label" ]] && continue
        if ! printf "%s\n" "$desired_labels" | grep -qx "$installed_label"; then
            harmony_info "launchd: pruning $installed_label"
            "$HARMONY_LAUNCHCTL_CMD" bootout "gui/$(id -u)/${installed_label}" >/dev/null 2>&1 || true
            rm -f "$(_launchd_installed_plist_path "$installed_label")"
            local runner_dir
            runner_dir="$(_launchd_runner_dir "$installed_label")"
            [[ -d "$runner_dir" ]] && rm -rf "$runner_dir"
        fi
    done < <(_launchd_installed_labels_with_prefix)

    return 0
}

harmony_domain_launchd_verify() {
    local manifest="$1"
    local diff
    diff="$(harmony_domain_launchd_plan "$manifest")"
    [[ -z "$diff" ]]
}
