#!/usr/bin/env bash
# lib/common.sh — foundation library for harmony.
#
# Sourced by bin/harmony and every lib/domain-*.sh. Provides logging, jq
# helpers, lockfile + backup utilities, environment resolution, and a small
# diff/plan/report format that all domains share.
#
# Sourcing contract:
#   - HARMONY_LIB_DIR is set to the absolute path of this file's directory.
#   - HARMONY_REPO_ROOT is set to the absolute path of this repo (one up from lib/).
#   - HARMONY_CONFIG_DIR is resolved from the env (default: ~/code/harmony-config).
#   - HARMONY_VERBOSE / HARMONY_QUIET reflect CLI flags.
#
# All functions are namespaced harmony_* to avoid polluting subshells.

set -o errexit
set -o nounset
set -o pipefail

# ---------- Path resolution ----------

# Resolve our own directory regardless of how we were sourced.
HARMONY_LIB_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
HARMONY_REPO_ROOT="$( cd "${HARMONY_LIB_DIR}/.." && pwd )"
export HARMONY_LIB_DIR HARMONY_REPO_ROOT

# User data directory. Default follows the convention; user can override.
: "${HARMONY_CONFIG_DIR:=${HOME}/code/harmony-config}"
export HARMONY_CONFIG_DIR

# Manifest filename inside the user data dir.
: "${HARMONY_MANIFEST_FILE:=harmony.json}"
export HARMONY_MANIFEST_FILE

# CLAUDE_PLUGIN_ROOT is set by the Claude Code runtime when invoking plugin
# hooks. When running from a user terminal it won't be set; fall back to repo
# root (developing-locally case) or HARMONY_REPO_ROOT.
: "${CLAUDE_PLUGIN_ROOT:=${HARMONY_REPO_ROOT}}"
export CLAUDE_PLUGIN_ROOT

# Logging verbosity. Mutually exclusive: verbose wins.
: "${HARMONY_VERBOSE:=0}"
: "${HARMONY_QUIET:=0}"

# Log file lives in $TMPDIR so it's per-Mac and auto-cleaned.
: "${HARMONY_LOG_FILE:=${TMPDIR:-/tmp}/harmony.log}"
export HARMONY_LOG_FILE

# Lock file for SessionStart race prevention.
: "${HARMONY_LOCK_FILE:=${TMPDIR:-/tmp}/harmony.lock}"
export HARMONY_LOCK_FILE

# ---------- Logging ----------
# Convention: stderr for human messages, stdout for machine-readable output.

harmony_log() {
    # harmony_log <level> <message>
    # Levels: info, warn, error, debug
    local level="$1"; shift
    local msg="$*"
    local ts
    ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

    # Always append to log file.
    printf "%s %-5s %s\n" "$ts" "$level" "$msg" >> "$HARMONY_LOG_FILE" 2>/dev/null || true

    # Stderr behaviour depends on flags.
    case "$level" in
        error)
            printf "harmony: error: %s\n" "$msg" >&2
            ;;
        warn)
            [[ "$HARMONY_QUIET" == "1" ]] || printf "harmony: warning: %s\n" "$msg" >&2
            ;;
        info)
            [[ "$HARMONY_QUIET" == "1" ]] || printf "harmony: %s\n" "$msg" >&2
            ;;
        debug)
            [[ "$HARMONY_VERBOSE" == "1" ]] && printf "harmony: debug: %s\n" "$msg" >&2
            ;;
    esac
    # Always return 0 — errexit in callers must not trip on a guard short-circuit.
    return 0
}

harmony_info()  { harmony_log info  "$@"; }
harmony_warn()  { harmony_log warn  "$@"; }
harmony_error() { harmony_log error "$@"; }
harmony_debug() { harmony_log debug "$@"; }

harmony_die() {
    harmony_error "$@"
    exit 1
}

# ---------- Dependency checks ----------

harmony_require_cmd() {
    # harmony_require_cmd <cmd> [<install hint>]
    local cmd="$1"
    local hint="${2:-install it}"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        harmony_die "required command not found: $cmd ($hint)"
    fi
}

harmony_have_cmd() {
    command -v "$1" >/dev/null 2>&1
}

# ---------- Environment resolution ----------

harmony_hostname() {
    # Short hostname, lowercase, with anything weird stripped. Used as the
    # overlay key in v2.
    hostname -s 2>/dev/null | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-' | sed 's/-*$//'
}

harmony_manifest_path() {
    printf "%s/%s\n" "$HARMONY_CONFIG_DIR" "$HARMONY_MANIFEST_FILE"
}

harmony_config_exists() {
    [[ -d "$HARMONY_CONFIG_DIR" && -f "$(harmony_manifest_path)" ]]
}

# Expand ${HARMONY_*} and ${HOME}/${CLAUDE_PLUGIN_ROOT} in a string.
# Used for hook commands, plist templates, etc.
harmony_expand_vars() {
    local s="$1"
    s="${s//\$\{HARMONY_REPO_ROOT\}/$HARMONY_REPO_ROOT}"
    s="${s//\$\{HARMONY_CONFIG_DIR\}/$HARMONY_CONFIG_DIR}"
    s="${s//\$\{CLAUDE_PLUGIN_ROOT\}/$CLAUDE_PLUGIN_ROOT}"
    s="${s//\$\{HOME\}/$HOME}"
    s="${s//\$HOME/$HOME}"
    printf "%s\n" "$s"
}

# ---------- jq helpers ----------

# Read a JSON value from a file. Returns empty string if missing.
# Usage: harmony_jq_read <file> <jq-expr>
harmony_jq_read() {
    local file="$1" expr="$2"
    [[ -f "$file" ]] || { printf "\n"; return 0; }
    jq -r "$expr // empty" "$file" 2>/dev/null || printf "\n"
}

# Validate that a file is valid JSON. Exit non-zero with a friendly message if not.
harmony_jq_validate() {
    local file="$1" name="${2:-$file}"
    if ! jq empty "$file" 2>/dev/null; then
        harmony_die "$name is not valid JSON: $file"
    fi
}

# Write a JSON object to a file atomically. Creates a timestamped backup of
# the existing file first if it exists.
# Usage: harmony_jq_write <file> <json-string-on-stdin>
harmony_jq_write_atomic() {
    local file="$1"
    local tmp="${file}.tmp.$$"
    local dir
    dir="$(dirname "$file")"
    mkdir -p "$dir"
    cat > "$tmp"
    # Validate before swapping.
    if ! jq empty "$tmp" 2>/dev/null; then
        rm -f "$tmp"
        harmony_die "refused to write invalid JSON to $file"
    fi
    [[ -f "$file" ]] && harmony_backup_file "$file"
    mv "$tmp" "$file"
}

# ---------- Backups ----------

# Create a timestamped backup of a file. Logs the backup path; does not write
# it to stdout (so this is safe to call from within a jq pipe).
harmony_backup_file() {
    local file="$1"
    [[ -f "$file" ]] || return 0
    local ts backup
    ts="$(date +"%Y%m%d-%H%M%S")"
    backup="${file}.backup.${ts}"
    cp -p "$file" "$backup"
    harmony_debug "backed up $file -> $backup"
    return 0
}

# ---------- Locking ----------

# Try to acquire the global harmony lock. Exits with code 75 (EX_TEMPFAIL)
# if --no-wait and the lock is held. Otherwise blocks.
harmony_acquire_lock() {
    local wait_mode="${1:-wait}"  # wait | no-wait
    # macOS bash 3.2 doesn't have a built-in flock; use shlock via mkdir.
    # Note: this is best-effort. Concurrent SessionStart fires are rare;
    # if both proceed, the worst case is duplicated no-op writes.
    local lockdir="${HARMONY_LOCK_FILE}.d"
    if mkdir "$lockdir" 2>/dev/null; then
        # We own it. Set up cleanup.
        # shellcheck disable=SC2064
        trap "rmdir '$lockdir' 2>/dev/null || true" EXIT
        return 0
    fi
    if [[ "$wait_mode" == "no-wait" ]]; then
        harmony_debug "lock held; --no-wait, exiting"
        exit 75
    fi
    # Wait up to 30s for the lock.
    local i
    for i in $(seq 1 30); do
        sleep 1
        if mkdir "$lockdir" 2>/dev/null; then
            # shellcheck disable=SC2064
            trap "rmdir '$lockdir' 2>/dev/null || true" EXIT
            return 0
        fi
    done
    harmony_die "could not acquire lock at $lockdir after 30s"
}

# ---------- Plan/diff format ----------
# Domains emit lines on stdout in this tab-separated format:
#   <action>\t<resource>\t<details>
# Actions: install, uninstall, update, noop, error
#
# bin/harmony collates these to print a human-readable summary.

harmony_plan_line() {
    # harmony_plan_line <action> <resource> [<details>]
    printf "%s\t%s\t%s\n" "$1" "$2" "${3:-}"
}

# ---------- Domain dispatch ----------
# Each domain library defines functions named:
#   harmony_domain_<name>_plan
#   harmony_domain_<name>_apply
#   harmony_domain_<name>_verify
# Each takes the manifest file as its first arg.

# The official order of domains for apply.
HARMONY_DOMAINS=(content settings plugins mcp brew launchd keybindings)

harmony_source_domains() {
    local d
    for d in "${HARMONY_DOMAINS[@]}"; do
        local f="$HARMONY_LIB_DIR/domain-${d}.sh"
        if [[ -f "$f" ]]; then
            # shellcheck source=/dev/null
            source "$f"
        else
            harmony_debug "domain library missing (not yet implemented): $f"
        fi
    done
}
