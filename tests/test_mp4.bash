#!/usr/bin/env bash
#
# End-to-end tests confirming that MP4 files behave identically to MKV: the
# script detects E-AC-3, adds a default AAC companion, verifies integrity, and
# replaces the file in place.
#
set -u

# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.bash"

export PATH="$(dirname "$REAL_FFPROBE"):$(dirname "$REAL_FFMPEG"):$PATH"

# shellcheck disable=SC1090
source "$SCRIPT_UNDER_TEST"

if ! have_real_tools; then
    printf 'SKIP: no real ffprobe/ffmpeg available\n' >&2
    exit 0
fi

# ---------------------------------------------------------------------------
# Case 1: no E-AC-3 -> main is a no-op, MP4 left untouched
# ---------------------------------------------------------------------------

begin_test "main leaves a non-E-AC-3 MP4 file untouched"
make_aac_mp4_file "$TEMP_DIR/aac.mp4"
before="$(sha1sum "$TEMP_DIR/aac.mp4" | cut -d' ' -f1)"
(
    main "$TEMP_DIR/aac.mp4"
)
assert_status 0 "$?" "main exit status"
after="$(sha1sum "$TEMP_DIR/aac.mp4" | cut -d' ' -f1)"
assert_equal "$before" "$after" "MP4 bytes unchanged"

# ---------------------------------------------------------------------------
# Case 2: E-AC-3 -> transcoded in place, now has E-AC-3 + default AAC
# ---------------------------------------------------------------------------

begin_test "main transcodes an E-AC-3 MP4 in place, adding AAC and AC-3 5.1"
make_eac3_mp4_file "$TEMP_DIR/eac3.mp4"

(
    main "$TEMP_DIR/eac3.mp4"
)
assert_status 0 "$?" "main exit status"
assert_file_exists "$TEMP_DIR/eac3.mp4" "MP4 still present"

assert_transcoded_with_compat_streams "$TEMP_DIR/eac3.mp4"

# ---------------------------------------------------------------------------
# Case 3: the output container is still MP4 (faststart moved the moov atom)
# ---------------------------------------------------------------------------

begin_test "transcoded MP4 remains a valid MP4 container"
format="$("$REAL_FFPROBE" -v error -show_entries format=format_name -of default=noprint_wrappers=1:nokey=1 "$TEMP_DIR/eac3.mp4" | tr -d '\r')"
assert_contains "$format" "mp4" "container format is MP4"

# ---------------------------------------------------------------------------
# Case 4: temporary transcoding artifact is cleaned up
# ---------------------------------------------------------------------------

begin_test "no leftover transcoding temp files remain"
assert_no_temp_artifacts "$TEMP_DIR"

run_test_file_summary "test_mp4"
