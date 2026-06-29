#!/usr/bin/env bash
# test/helpers.sh — shared test scaffolding.
#
# Usage in each test/test-*.sh:
#   #!/usr/bin/env bash
#   set -e
#   source "$(dirname "$0")/helpers.sh"
#   t_setup
#   ... assertions ...
#   t_pass

set -o errexit
set -o nounset
set -o pipefail

HARMONY_TEST_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
HARMONY_TEST_REPO_ROOT="$( cd "${HARMONY_TEST_DIR}/.." && pwd )"

t_setup() {
    # Create a per-test sandbox: fake $HOME + fake HARMONY_CONFIG_DIR.
    T_TMPDIR="$(mktemp -d -t harmony-test.XXXXXXXX)"
    T_FAKE_HOME="${T_TMPDIR}/home"
    T_FAKE_CONFIG="${T_FAKE_HOME}/code/harmony-config"
    T_FAKE_SETTINGS="${T_FAKE_HOME}/.claude/settings.json"

    mkdir -p "${T_FAKE_HOME}/.claude" "${T_FAKE_CONFIG}"

    # Point harmony at the sandbox via env.
    export HOME="$T_FAKE_HOME"
    export HARMONY_CONFIG_DIR="$T_FAKE_CONFIG"
    export HARMONY_SETTINGS_PATH="$T_FAKE_SETTINGS"
    export HARMONY_LOG_FILE="${T_TMPDIR}/harmony.log"
    export HARMONY_LOCK_FILE="${T_TMPDIR}/harmony.lock"

    # Quiet output by default in tests.
    export HARMONY_QUIET=1

    # Add cleanup trap.
    trap 't_cleanup' EXIT

    # Expose paths.
    export T_TMPDIR T_FAKE_HOME T_FAKE_CONFIG T_FAKE_SETTINGS
    export HARMONY="${HARMONY_TEST_REPO_ROOT}/bin/harmony"
    chmod +x "$HARMONY" 2>/dev/null || true
}

t_cleanup() {
    # Cleanup is best-effort. Comment out to debug a test.
    if [[ -n "${T_TMPDIR:-}" && -d "$T_TMPDIR" && "$T_TMPDIR" == /tmp/* || "$T_TMPDIR" == /var/folders/* ]]; then
        rm -rf "$T_TMPDIR"
    fi
}

t_assert_eq() {
    local actual="$1" expected="$2" name="${3:-assertion}"
    if [[ "$actual" == "$expected" ]]; then
        return 0
    fi
    printf "ASSERTION FAILED: %s\n  expected: %s\n  actual:   %s\n" "$name" "$expected" "$actual" >&2
    return 1
}

t_assert_contains() {
    local haystack="$1" needle="$2" name="${3:-contains}"
    if [[ "$haystack" == *"$needle"* ]]; then
        return 0
    fi
    printf "ASSERTION FAILED: %s\n  haystack: %s\n  needle:   %s\n" "$name" "$haystack" "$needle" >&2
    return 1
}

t_assert_json_eq() {
    local file="$1" jq_path="$2" expected="$3" name="${4:-json-eq}"
    local actual
    actual="$(jq -c "$jq_path" "$file")"
    if [[ "$actual" == "$expected" ]]; then
        return 0
    fi
    printf "ASSERTION FAILED: %s (file=%s path=%s)\n  expected: %s\n  actual:   %s\n" \
        "$name" "$file" "$jq_path" "$expected" "$actual" >&2
    return 1
}

t_pass() {
    printf "PASS  %s\n" "$(basename "$0")"
    exit 0
}

t_fail() {
    printf "FAIL  %s — %s\n" "$(basename "$0")" "${1:-}" >&2
    exit 1
}

t_write_manifest() {
    # t_write_manifest <json-string>
    printf "%s\n" "$1" > "${T_FAKE_CONFIG}/harmony.json"
}

t_write_settings() {
    # t_write_settings <json-string>
    printf "%s\n" "$1" > "${T_FAKE_SETTINGS}"
}

t_read_settings() {
    cat "${T_FAKE_SETTINGS}"
}
