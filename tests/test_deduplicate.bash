#!/usr/bin/env bash
#
# Tests for the audio-stream deduplication step: collapsing accidental
# duplicates that share codec, channel count, language, and content checksum,
# while leaving distinct streams intact.
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

# find_duplicate_audio_indices ------------------------------------------------

begin_test "identical AAC streams are reported as duplicates"
make_duplicate_aac_media_file "$TEMP_DIR/dup.mkv"
actual="$(find_duplicate_audio_indices "$TEMP_DIR/dup.mkv")"
assert_equal "2" "$actual" "second identical stream index reported"

begin_test "streams with different channel counts are not duplicates"
make_channel_distinct_aac_media_file "$TEMP_DIR/diffch.mkv"
actual="$(find_duplicate_audio_indices "$TEMP_DIR/diffch.mkv")"
assert_equal "" "$actual" "no duplicates across channel counts"

begin_test "streams with different languages are not duplicates"
make_language_distinct_aac_media_file "$TEMP_DIR/difflang.mkv"
actual="$(find_duplicate_audio_indices "$TEMP_DIR/difflang.mkv")"
assert_equal "" "$actual" "no duplicates across languages"

# deduplicate_audio_streams -----------------------------------------------------

begin_test "deduplicate collapses identical streams, leaving one"
make_duplicate_aac_media_file "$TEMP_DIR/dup.mkv"
deduplicate_audio_streams "$TEMP_DIR/dup.mkv" >/dev/null 2>&1

# After dedup there should be exactly one audio stream.
streams="$(ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 -- "$TEMP_DIR/dup.mkv" | tr -d '\r' | wc -l)"
assert_equal "1" "$streams" "exactly one audio stream remains"

begin_test "deduplicate leaves distinct streams untouched"
make_channel_distinct_aac_media_file "$TEMP_DIR/diffch.mkv"
before="$(probe_audio_stream_metadata "$TEMP_DIR/diffch.mkv")"
deduplicate_audio_streams "$TEMP_DIR/diffch.mkv" >/dev/null 2>&1
after="$(probe_audio_stream_metadata "$TEMP_DIR/diffch.mkv")"
assert_equal "$before" "$after" "distinct streams unchanged"

run_test_file_summary "test_deduplicate"
