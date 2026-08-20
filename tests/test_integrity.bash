#!/usr/bin/env bash
#
# Tests for integrity verification and file replacement.
#
set -u

# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.bash"

setup_fake_toolchain
# shellcheck disable=SC1090
source "$SCRIPT_UNDER_TEST"

# verify_decode_clean ---------------------------------------------------------

begin_test "verify_decode_clean succeeds when ffmpeg reports no errors"
: > "$TEMP_DIR/ctrl/ffmpeg_stderr"
rm -f "$TEMP_DIR/ctrl/ffmpeg_rc"
make_fake_media_file "$TEMP_DIR/out.mkv"
if verify_decode_clean "$TEMP_DIR/out.mkv"; then
    ok "decode clean passes on no errors"
else
    fail "decode clean should pass on no errors"
fi

begin_test "verify_decode_clean fails when ffmpeg reports errors"
make_fake_media_file "$TEMP_DIR/out.mkv"
set_ffmpeg_stderr "Invalid data found when processing input"
if verify_decode_clean "$TEMP_DIR/out.mkv"; then
    fail "decode clean should fail on decoder errors"
else
    ok "decode clean fails on decoder errors"
fi
: > "$TEMP_DIR/ctrl/ffmpeg_stderr"

# verify_duration_matches -----------------------------------------------------

begin_test "verify_duration_matches passes within tolerance"
# Override probe_duration deterministically per file.
probe_duration() {
    if [[ "$1" == *"a.mkv" ]]; then printf '120.0'; else printf '120.4'; fi
}
make_fake_media_file "$TEMP_DIR/a.mkv"
make_fake_media_file "$TEMP_DIR/b.mkv"
if verify_duration_matches "$TEMP_DIR/a.mkv" "$TEMP_DIR/b.mkv"; then
    ok "duration matches within 1s tolerance"
else
    fail "0.4s difference should be within tolerance"
fi

begin_test "verify_duration_matches fails outside tolerance"
probe_duration() {
    if [[ "$1" == *"a.mkv" ]]; then printf '100.0'; else printf '105.0'; fi
}
make_fake_media_file "$TEMP_DIR/a.mkv"
make_fake_media_file "$TEMP_DIR/b.mkv"
if verify_duration_matches "$TEMP_DIR/a.mkv" "$TEMP_DIR/b.mkv"; then
    fail "5s difference should be outside tolerance"
else
    ok "duration mismatch detected"
fi

# verify_integrity (composition) ---------------------------------------------

begin_test "verify_integrity succeeds when both checks pass"
: > "$TEMP_DIR/ctrl/ffmpeg_stderr"
rm -f "$TEMP_DIR/ctrl/ffmpeg_rc"
probe_duration() { printf '100.0'; }
make_fake_media_file "$TEMP_DIR/a.mkv"
make_fake_media_file "$TEMP_DIR/b.mkv"
if verify_integrity "$TEMP_DIR/a.mkv" "$TEMP_DIR/b.mkv"; then
    ok "verify_integrity passes"
else
    fail "verify_integrity should pass on clean decode and matching duration"
fi

# replace_original_in_place ---------------------------------------------------

begin_test "replace_original_in_place moves output over source"
make_fake_media_file "$TEMP_DIR/new.mkv"
make_fake_media_file "$TEMP_DIR/orig.mkv"
printf 'NEW-CONTENT' > "$TEMP_DIR/new.mkv"
replace_original_in_place "$TEMP_DIR/new.mkv" "$TEMP_DIR/orig.mkv"
assert_file_contents "$TEMP_DIR/orig.mkv" "NEW-CONTENT" "original has new content"
assert_file_absent "$TEMP_DIR/new.mkv" "temp file removed after mv"

# clean_up --------------------------------------------------------------------

begin_test "clean_up removes an existing temp file"
make_fake_media_file "$TEMP_DIR/tmpfile"
clean_up "$TEMP_DIR/tmpfile"
assert_file_absent "$TEMP_DIR/tmpfile" "file removed"

begin_test "clean_up is a no-op for a missing file"
clean_up "$TEMP_DIR/does-not-exist"
ok "clean_up tolerates missing file"

run_test_file_summary "test_integrity"
