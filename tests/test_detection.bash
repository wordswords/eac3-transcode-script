#!/usr/bin/env bash
#
# Tests for E-AC-3 stream detection, using real ffprobe against real media.
#
set -u

# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.bash"

# Make the real vendored/system ffprobe available on PATH for the functions.
export PATH="$(dirname "$REAL_FFPROBE"):$PATH"

# shellcheck disable=SC1090
source "$SCRIPT_UNDER_TEST"

# Skip gracefully if no real tools are available (e.g. unsupported environment).
if ! have_real_tools; then
    printf 'SKIP: no real ffprobe/ffmpeg available\n' >&2
    exit 0
fi

begin_test "finds the E-AC-3 stream index in a real file"
make_eac3_media_file "$TEMP_DIR/eac3.mkv"
actual="$(find_eac3_stream_indices "$TEMP_DIR/eac3.mkv")"
assert_equal "1" "$actual" "E-AC-3 stream index detected"

begin_test "returns nothing for a file with no E-AC-3 (AAC only)"
make_aac_media_file "$TEMP_DIR/aac.mkv"
actual="$(find_eac3_stream_indices "$TEMP_DIR/aac.mkv")"
assert_equal "" "$actual" "no E-AC-3 stream detected"

begin_test "detects E-AC-3 in an MP4 container"
make_eac3_mp4_file "$TEMP_DIR/eac3.mp4"
actual="$(find_eac3_stream_indices "$TEMP_DIR/eac3.mp4")"
assert_equal "1" "$actual" "E-AC-3 stream index detected in MP4"

begin_test "returns nothing for an MP4 with no E-AC-3 (AAC only)"
make_aac_mp4_file "$TEMP_DIR/aac.mp4"
actual="$(find_eac3_stream_indices "$TEMP_DIR/aac.mp4")"
assert_equal "" "$actual" "no E-AC-3 stream detected in MP4"

run_test_file_summary "test_detection"
