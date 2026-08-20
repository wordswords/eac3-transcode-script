#!/usr/bin/env bash
#
# Tests for the pure computational functions that require no I/O or mocks.
#
set -u

# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.bash"
# shellcheck disable=SC1090
source "$SCRIPT_UNDER_TEST"

# resolve_channel_count --------------------------------------------------------

begin_test "resolve_channel_count keeps normal channel counts"
assert_equal "2" "$(resolve_channel_count 2)" "2 channels"
assert_equal "6" "$(resolve_channel_count 6)" "6 channels"

begin_test "resolve_channel_count clamps channels above the maximum"
assert_equal "8" "$(resolve_channel_count 12)" "12 channels -> 8"
assert_equal "8" "$(resolve_channel_count 8)" "8 channels stays at max"

begin_test "resolve_channel_count handles fractional channel values"
assert_equal "7" "$(resolve_channel_count 7.1)" "7.1 -> 7"

begin_test "resolve_channel_count falls back to 2 for empty or zero"
assert_equal "2" "$(resolve_channel_count '')" "empty -> 2"
assert_equal "2" "$(resolve_channel_count 0)" "0 -> 2"

# resolve_bitrate -------------------------------------------------------------

begin_test "resolve_bitrate scales by channel count"
assert_equal "192k" "$(resolve_bitrate 2)" "2 x 96k"
assert_equal "576k" "$(resolve_bitrate 6)" "6 x 96k"

begin_test "resolve_bitrate handles a single channel"
assert_equal "96k" "$(resolve_bitrate 1)" "1 x 96k"

# make_temporary_output_path --------------------------------------------------

begin_test "make_temporary_output_path nests beside source with full name"
result="$(make_temporary_output_path "/videos/movie.mkv")"
assert_contains "$result" "/videos/.movie.mkv.transcoding." "temp path keeps dir and name"
assert_contains "$result" ".mkv" "temp path keeps extension"

begin_test "make_temporary_output_path is not the source itself"
result="$(make_temporary_output_path "/videos/movie.mkv")"
if [[ "$result" == "/videos/movie.mkv" ]]; then
    report_fail "temp path must differ from source"
fi

run_test_file_summary "test_pure_functions"
