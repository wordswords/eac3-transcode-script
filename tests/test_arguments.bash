#!/usr/bin/env bash
#
# Tests for build_ffmpeg_stream_arguments against real media files. These
# verify that the generated -map/-c/-disposition arguments correctly express
# "copy everything + add a default AAC companion + a 5.1 AC-3 companion per
# E-AC-3 stream".
#
set -u

# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.bash"

export PATH="$(dirname "$REAL_FFPROBE"):$PATH"

# shellcheck disable=SC1090
source "$SCRIPT_UNDER_TEST"

if ! have_real_tools; then
    printf 'SKIP: no real ffprobe/ffmpeg available\n' >&2
    exit 0
fi

# Helper: build the arguments for a given file and return them joined.
build_args() {
    map_args=()
    codec_args=()
    build_ffmpeg_stream_arguments "$1" map_args codec_args
    printf '%s\n' "${map_args[*]}"
    printf '%s\n' "${codec_args[*]}"
}

begin_test "E-AC-3 file produces copy + AAC + AC-3 with AAC as default"
make_eac3_media_file "$TEMP_DIR/eac3.mkv"
args="$(build_args "$TEMP_DIR/eac3.mkv")"

# The E-AC-3 audio stream (index 1, video is 0) is mapped three times: once for
# the copy, once for the AAC companion, once for the 5.1 AC-3 companion.
assert_contains "$args" "-map 0:1 -map 0:1 -map 0:1" "E-AC-3 stream mapped three times"

# The copied stream clears default; the AAC companion is the new default; the
# AC-3 companion is non-default.
assert_contains "$args" "-disposition:1 0" "E-AC-3 default cleared"
assert_contains "$args" "-disposition:2 default" "AAC companion is default"
assert_contains "$args" "-disposition:3 0" "AC-3 companion is non-default"

# The codec arguments: copy the original, encode AAC (default) and AC-3 5.1.
assert_contains "$args" "-c:1 copy" "E-AC-3 codec copied"
assert_contains "$args" "-c:2 aac" "AAC companion encoded"
assert_contains "$args" "-c:3 ac3" "AC-3 companion encoded"
assert_contains "$args" "-ac:3 6" "AC-3 companion is 5.1"

begin_test "AAC file produces only copies and no companions"
make_aac_media_file "$TEMP_DIR/aac.mkv"
args="$(build_args "$TEMP_DIR/aac.mkv")"

# No E-AC-3 means no companion track: both streams are copied, none encoded.
assert_contains "$args" "-c:0 copy" "video copied"
assert_contains "$args" "-c:1 copy" "AAC audio copied"
if [[ "$args" == *"-c:"*" aac"* || "$args" == *"-c:"*" ac3"* ]]; then
    fail "no AAC/AC-3 companion should be added for a non-E-AC-3 file"
else
    ok "no companion tracks added"
fi

begin_test "MP4 E-AC-3 file produces the same copy + AAC + AC-3 arguments"
make_eac3_mp4_file "$TEMP_DIR/eac3.mp4"
args="$(build_args "$TEMP_DIR/eac3.mp4")"

assert_contains "$args" "-map 0:1 -map 0:1 -map 0:1" "MP4 E-AC-3 stream mapped three times"
assert_contains "$args" "-disposition:1 0" "MP4 E-AC-3 default cleared"
assert_contains "$args" "-disposition:2 default" "MP4 AAC companion is default"
assert_contains "$args" "-disposition:3 0" "MP4 AC-3 companion is non-default"
assert_contains "$args" "-c:1 copy" "MP4 E-AC-3 codec copied"
assert_contains "$args" "-c:2 aac" "MP4 AAC companion encoded"
assert_contains "$args" "-c:3 ac3" "MP4 AC-3 companion encoded"
assert_contains "$args" "-ac:3 6" "MP4 AC-3 companion is 5.1"

run_test_file_summary "test_arguments"
