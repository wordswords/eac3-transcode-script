#!/usr/bin/env bash
#
# run_tests.sh
#
# Run every test file under tests/ and print an aggregate summary.
# No third-party dependencies: a minimal framework lives in test_helper.bash.
#
# Usage:
#   ./tests/run_tests.sh
#
set -u

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export TESTS_DIR

TOTAL_PASS=0
TOTAL_FAIL=0
FAILED_FILES=()

for test_file in "$TESTS_DIR"/test_*.bash; do
    [[ -e "$test_file" ]] || continue
    case "$(basename "$test_file")" in
        test_helper.bash) continue ;;
    esac
    label="$(basename "$test_file")"

    output="$(bash "$test_file" 2>&1)"
    status=$?

    printf '===== %s =====\n' "$label"
    printf '%s\n' "$output"

    # Extract "N passed, M failed" from the framework summary at the end.
    pass="$(printf '%s\n' "$output" | grep -oE '[0-9]+ passed' | grep -oE '[0-9]+' | tail -1)"
    fail="$(printf '%s\n' "$output" | grep -oE '[0-9]+ failed' | grep -oE '[0-9]+' | tail -1)"
    pass="${pass:-0}"
    fail="${fail:-0}"

    TOTAL_PASS=$(( TOTAL_PASS + pass ))
    TOTAL_FAIL=$(( TOTAL_FAIL + fail ))

    if [[ "$fail" -gt 0 ]]; then
        FAILED_FILES+=("$label")
    fi
    printf '\n'
done

printf '========================================\n'
printf 'TOTAL: %d passed, %d failed\n' "$TOTAL_PASS" "$TOTAL_FAIL"

if [[ ${#FAILED_FILES[@]} -gt 0 ]]; then
    printf 'Failed test files:\n'
    for f in "${FAILED_FILES[@]}"; do
        printf '  - %s\n' "$f"
    done
    exit 1
fi

exit 0
