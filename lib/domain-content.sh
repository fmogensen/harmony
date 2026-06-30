#!/usr/bin/env bash
# lib/domain-content.sh — manage symlinks from ~/.claude/ to user content.
#
# The user's skills, agents, commands, and global CLAUDE.md live in their
# config repo (default ~/code/harmony-config/). harmony makes them available
# to Claude Code via symlinks under ~/.claude/.
#
# Why symlinks (not copies):
#   - Editing a skill in the config repo is immediately live.
#   - Removing a skill = rm -rf content/skills/<name> + git commit. The
#     symlink to the directory transparently reflects the change. No
#     per-skill manifest entry needed; the filesystem IS the manifest for
#     content.
#
# Manifest shape (under .content):
#   {
#     "skills":          "content/skills",        # path relative to HARMONY_CONFIG_DIR
#     "agents":          "content/agents",
#     "commands":        "content/commands",
#     "globalClaudeMd":  "settings/global-CLAUDE.md"
#   }
# Each value is either a relative path (resolved against HARMONY_CONFIG_DIR)
# or null/absent (= leave that link alone).
#
# Targets in ~/.claude/:
#   skills          -> directory symlink
#   agents          -> directory symlink
#   commands        -> directory symlink
#   CLAUDE.md       -> file symlink (target is settings/global-CLAUDE.md)

: "${HARMONY_CLAUDE_DIR:=${HOME}/.claude}"

# Map of manifest-key -> target-path-in-~/.claude/
_CONTENT_TARGETS_KEYS=(skills      agents      commands    globalClaudeMd)
_CONTENT_TARGETS_PATHS=(skills     agents      commands    CLAUDE.md)

# ---------- Helpers ----------

# Resolve a content source from the manifest. Returns empty string if missing.
_content_source_for() {
    local manifest="$1" key="$2"
    local rel
    rel="$(harmony_jq_read "$manifest" ".content.${key}")"
    [[ -z "$rel" ]] && return 0
    # Already absolute? Use as-is. Otherwise join with HARMONY_CONFIG_DIR.
    if [[ "$rel" = /* ]]; then
        printf "%s\n" "$rel"
    else
        printf "%s/%s\n" "$HARMONY_CONFIG_DIR" "$rel"
    fi
}

_content_target_for() {
    # Map manifest key -> ~/.claude/<name>
    local key="$1"
    local i
    for i in "${!_CONTENT_TARGETS_KEYS[@]}"; do
        if [[ "${_CONTENT_TARGETS_KEYS[$i]}" == "$key" ]]; then
            printf "%s/%s\n" "$HARMONY_CLAUDE_DIR" "${_CONTENT_TARGETS_PATHS[$i]}"
            return 0
        fi
    done
}

# What's the current state of a symlink target? Outputs one of:
#   missing               nothing exists at the target path
#   correct               symlink, points at expected
#   wrong-link            symlink, points at something else (prints actual after \t)
#   not-a-symlink         a real file or directory is sitting in the target spot
_content_inspect_link() {
    local target="$1" expected="$2"
    if [[ ! -e "$target" && ! -L "$target" ]]; then
        printf "missing\n"
    elif [[ -L "$target" ]]; then
        local actual
        actual="$(readlink "$target")"
        if [[ "$actual" == "$expected" ]]; then
            printf "correct\n"
        else
            printf "wrong-link\t%s\n" "$actual"
        fi
    else
        printf "not-a-symlink\n"
    fi
}

# ---------- Public API ----------

harmony_domain_content_plan() {
    local manifest="$1"
    local key
    for key in "${_CONTENT_TARGETS_KEYS[@]}"; do
        local src
        src="$(_content_source_for "$manifest" "$key")"
        # Skip if manifest doesn't declare this link.
        [[ -z "$src" ]] && continue

        local target
        target="$(_content_target_for "$key")"

        # The source must exist; if it doesn't, that's a planning error
        # (we can't symlink to a nonexistent file). Emit an error line so
        # the apply phase will skip it.
        if [[ ! -e "$src" ]]; then
            harmony_plan_line error "content.${key}" "source missing: $src"
            continue
        fi

        local result actual
        result="$(_content_inspect_link "$target" "$src")"
        case "$result" in
            correct)
                # No line emitted = in sync.
                ;;
            missing)
                harmony_plan_line install "content.${key}" "ln -s $src -> $target"
                ;;
            wrong-link*)
                actual="${result#wrong-link	}"
                harmony_plan_line update "content.${key}" "relink (was -> $actual)"
                ;;
            not-a-symlink)
                harmony_plan_line update "content.${key}" "replace existing file/dir with symlink (will back up)"
                ;;
        esac
    done
}

harmony_domain_content_apply() {
    local manifest="$1"
    local key
    mkdir -p "$HARMONY_CLAUDE_DIR"

    for key in "${_CONTENT_TARGETS_KEYS[@]}"; do
        local src
        src="$(_content_source_for "$manifest" "$key")"
        [[ -z "$src" ]] && continue

        local target
        target="$(_content_target_for "$key")"

        if [[ ! -e "$src" ]]; then
            harmony_warn "content.${key}: source missing, skipping: $src"
            continue
        fi

        # Make sure the parent directory exists.
        mkdir -p "$(dirname "$target")"

        # If a non-symlink exists in the way, back it up.
        if [[ -e "$target" && ! -L "$target" ]]; then
            local ts backup
            ts="$(date +"%Y%m%d-%H%M%S")"
            backup="${target}.backup.${ts}"
            mv "$target" "$backup"
            harmony_info "moved aside non-symlink at $target -> $backup"
        fi

        # If a wrong symlink is there, just remove it; ln -sf below will
        # overwrite a symlink but not a missing path - we want a clean state.
        if [[ -L "$target" ]]; then
            rm -f "$target"
        fi

        ln -s "$src" "$target"
        harmony_debug "linked $target -> $src"
    done
    return 0
}

harmony_domain_content_verify() {
    local manifest="$1"
    local key fail=0
    for key in "${_CONTENT_TARGETS_KEYS[@]}"; do
        local src
        src="$(_content_source_for "$manifest" "$key")"
        [[ -z "$src" ]] && continue

        local target
        target="$(_content_target_for "$key")"

        # Source missing in repo = drift.
        if [[ ! -e "$src" ]]; then
            fail=$(( fail + 1 ))
            continue
        fi

        local result
        result="$(_content_inspect_link "$target" "$src")"
        [[ "$result" == "correct" ]] || fail=$(( fail + 1 ))
    done
    [[ "$fail" -eq 0 ]]
}
