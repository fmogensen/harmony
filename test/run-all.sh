#!/usr/bin/env bash
# test/run-all.sh — run every test/test-*.sh in sequence, report summary.

set -u
TEST_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

shopt -s nullglob
tests=( "$TEST_DIR"/test-*.sh )
shopt -u nullglob

if [[ ${#tests[@]} -eq 0 ]]; then
    printf "no tests found in %s/test-*.sh\n" "$TEST_DIR"
    exit 1
fi

pass=0
fail=0
failures=()

for t in "${tests[@]}"; do
    chmod +x "$t" 2>/dev/null || true
    if "$t"; then
        pass=$(( pass + 1 ))
    else
        fail=$(( fail + 1 ))
        failures+=( "$(basename "$t")" )
    fi
done

printf "\n%d passed, %d failed (of %d)\n" "$pass" "$fail" "${#tests[@]}"
if [[ $fail -gt 0 ]]; then
    printf "Failed tests:\n"
    for f in "${failures[@]}"; do
        printf "  - %s\n" "$f"
    done
    exit 1
fi
