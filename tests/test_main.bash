#!/usr/bin/env bash
#
# End-to-end tests for main(), running the full pipeline against real media
# and inspecting the resulting file with real ffprobe.
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
# Case 1: no E-AC-3 -> main is a no-op, file left untouched
# ---------------------------------------------------------------------------

begin_test "main leaves a non-E-AC-3 file untouched"
make_aac_media_file "$TEMP_DIR/aac.mkv"
before="$(sha1sum "$TEMP_DIR/aac.mkv" | cut -d' ' -f1)"
(
    main "$TEMP_DIR/aac.mkv"
)
assert_status 0 "$?" "main exit status"
after="$(sha1sum "$TEMP_DIR/aac.mkv" | cut -d' ' -f1)"
assert_equal "$before" "$after" "file bytes unchanged"

# ---------------------------------------------------------------------------
# Case 2: E-AC-3 -> transcoded in place, now has E-AC-3 + default AAC
# ---------------------------------------------------------------------------

begin_test "main transcodes E-AC-3 in place, adding AAC and AC-3 5.1 streams"
make_eac3_media_file "$TEMP_DIR/eac3.mkv"

(
    main "$TEMP_DIR/eac3.mkv"
)
assert_status 0 "$?" "main exit status"
assert_file_exists "$TEMP_DIR/eac3.mkv" "file still present"

# Verify the resulting streams: E-AC-3 preserved, plus a default AAC track and
# a separate 5.1 AC-3 track.
assert_transcoded_with_compat_streams "$TEMP_DIR/eac3.mkv"

# ---------------------------------------------------------------------------
# Case 2b: 5.1 E-AC-3 -> all six channels reproduced in the AC-3 stream
# ---------------------------------------------------------------------------

begin_test "5.1 E-AC-3 source reproduces all six channels in the AC-3 stream"
make_eac3_51_media_file "$TEMP_DIR/surround.mkv"

(
    main "$TEMP_DIR/surround.mkv"
)
assert_status 0 "$?" "main exit status"

# The AC-3 stream must be 5.1 and carry a surround channel layout.
ac3_layout="$("$REAL_FFPROBE" -v error \
    -select_streams a:2 \
    -show_entries stream=codec_name,channels,channel_layout \
    -of csv=p=0 \
    "$TEMP_DIR/surround.mkv" | tr -d '\r')"
assert_contains "$ac3_layout" "ac3,6" "AC-3 stream is 5.1 (6 channels)"
assert_contains "$ac3_layout" "5.1" "AC-3 stream uses a surround layout"

# ---------------------------------------------------------------------------
# Case 3: temporary transcoding artifact is cleaned up
# ---------------------------------------------------------------------------

begin_test "no leftover transcoding temp files remain"
assert_no_temp_artifacts "$TEMP_DIR"

run_test_file_summary "test_main"
