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

TOTAL_PASS=0
TOTAL_FAIL=0
FAILED_FILES=()

# Parse the final "label: N passed, M failed" summary line, setting the
# globals TEST_FILE_PASS and TEST_FILE_FAIL.
extract_counts() {
    local summary="$1"
    local summary_line
    summary_line="$(printf '%s\n' "$summary" | grep -E '^[^:]+: [0-9]+ passed, [0-9]+ failed' | tail -1)"
    TEST_FILE_PASS="$(printf '%s\n' "$summary_line" | sed -E 's/.* ([0-9]+) passed,.*/\1/')"
    TEST_FILE_FAIL="$(printf '%s\n' "$summary_line" | sed -E 's/.* ([0-9]+) failed/\1/')"
    TEST_FILE_PASS="${TEST_FILE_PASS:-0}"
    TEST_FILE_FAIL="${TEST_FILE_FAIL:-0}"
}

for test_file in "$TESTS_DIR"/test_*.bash; do
    [[ -e "$test_file" ]] || continue
    [[ "$(basename "$test_file")" == "test_helper.bash" ]] && continue
    label="$(basename "$test_file")"

    output="$(bash "$test_file" 2>&1)"

    printf '===== %s =====\n' "$label"
    printf '%s\n' "$output"

    TEST_FILE_PASS=0
    TEST_FILE_FAIL=0
    extract_counts "$output"

    TOTAL_PASS=$(( TOTAL_PASS + TEST_FILE_PASS ))
    TOTAL_FAIL=$(( TOTAL_FAIL + TEST_FILE_FAIL ))

    if [[ "$TEST_FILE_FAIL" -gt 0 ]]; then
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
