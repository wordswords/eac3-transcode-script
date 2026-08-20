#!/usr/bin/env bash
#
# Tests for transcode-directory.sh, focusing on the pieces that can run without
# a real `screen` (E-AC-3 detection, manifest building, worker generation) and
# using a fake `screen` shim for session-management logic.
#
set -u

# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/test_helper.bash"

export PATH="$(dirname "$REAL_FFPROBE"):$(dirname "$REAL_FFMPEG"):$PATH"

# Source the directory script (it has a source guard, so main() won't run).
# shellcheck disable=SC1090
source "$SCRIPT_UNDER_TEST_DIR"

if ! have_real_tools; then
    printf 'SKIP: no real ffprobe/ffmpeg available\n' >&2
    exit 0
fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Build a directory tree containing a mix of E-AC-3 and non-E-AC-3 media.
make_mixed_media_tree() {
    local root="$1"
    mkdir -p "$root/subdir"
    make_eac3_media_file "$root/a.mkv" >/dev/null 2>&1
    make_aac_media_file "$root/b.mkv" >/dev/null 2>&1
    make_eac3_mp4_file "$root/subdir/c.mp4" >/dev/null 2>&1
    make_aac_mp4_file "$root/subdir/d.mp4" >/dev/null 2>&1
    printf 'not-a-video' > "$root/note.txt"
}

# Read a NUL-delimited manifest into newline-delimited stdout.
read_manifest() {
    local manifest="$1"
    tr '\0' '\n' < "$manifest"
}

# ---------------------------------------------------------------------------
# has_eac3_audio
# ---------------------------------------------------------------------------

begin_test "has_eac3_audio detects E-AC-3 in MKV"
make_eac3_media_file "$TEMP_DIR/eac3.mkv" >/dev/null 2>&1
if has_eac3_audio "$TEMP_DIR/eac3.mkv"; then
    ok "MKV E-AC-3 detected"
else
    fail "MKV E-AC-3 not detected"
fi

begin_test "has_eac3_audio detects E-AC-3 in MP4"
make_eac3_mp4_file "$TEMP_DIR/eac3.mp4" >/dev/null 2>&1
if has_eac3_audio "$TEMP_DIR/eac3.mp4"; then
    ok "MP4 E-AC-3 detected"
else
    fail "MP4 E-AC-3 not detected"
fi

begin_test "has_eac3_audio rejects AAC-only files"
make_aac_media_file "$TEMP_DIR/aac.mkv" >/dev/null 2>&1
if has_eac3_audio "$TEMP_DIR/aac.mkv"; then
    fail "AAC-only file should not be detected as E-AC-3"
else
    ok "AAC-only file correctly rejected"
fi

begin_test "has_eac3_audio rejects non-media files"
make_fake_media_file "$TEMP_DIR/note.txt"
if has_eac3_audio "$TEMP_DIR/note.txt"; then
    fail "non-media file should not be detected"
else
    ok "non-media file correctly rejected"
fi

# ---------------------------------------------------------------------------
# build_eac3_manifest
# ---------------------------------------------------------------------------

begin_test "manifest includes only E-AC-3 files, recursively"
make_mixed_media_tree "$TEMP_DIR/media"
manifest="$TEMP_DIR/manifest"
build_eac3_manifest "$TEMP_DIR/media" "$manifest"

content="$(read_manifest "$manifest")"

# Expect exactly two entries: a.mkv and subdir/c.mp4.
assert_contains "$content" "a.mkv" "E-AC-3 MKV included"
assert_contains "$content" "c.mp4" "E-AC-3 MP4 included (recursive)"
if [[ "$content" == *"b.mkv"* || "$content" == *"d.mp4"* || "$content" == *"note.txt"* ]]; then
    fail "manifest should exclude AAC-only and non-media files"
else
    ok "AAC-only and non-media files excluded"
fi

begin_test "manifest count matches expected E-AC-3 file count"
count="$(tr -cd '\0' < "$manifest" | wc -c)"
assert_equal "2" "$count" "exactly two E-AC-3 files"

begin_test "empty directory yields an empty manifest"
mkdir -p "$TEMP_DIR/empty"
empty_manifest="$TEMP_DIR/empty_manifest"
build_eac3_manifest "$TEMP_DIR/empty" "$empty_manifest"
count="$(tr -cd '\0' < "$empty_manifest" | wc -c)"
assert_equal "0" "$count" "no files"

begin_test "manifest recurses into arbitrary depth"
deep_root="$TEMP_DIR/deep"
mkdir -p "$deep_root/level1/level2/level3/level4"
make_eac3_media_file "$deep_root/top.mkv" >/dev/null 2>&1
make_eac3_mp4_file "$deep_root/level1/level2/level3/level4/deepest.mp4" >/dev/null 2>&1
make_aac_media_file "$deep_root/level1/skip.mkv" >/dev/null 2>&1

deep_manifest="$TEMP_DIR/deep_manifest"
build_eac3_manifest "$deep_root" "$deep_manifest"

deep_content="$(read_manifest "$deep_manifest")"
assert_contains "$deep_content" "top.mkv" "top-level E-AC-3 found"
assert_contains "$deep_content" "deepest.mp4" "deeply-nested E-AC-3 found"
if [[ "$deep_content" == *"skip.mkv"* ]]; then
    fail "non-E-AC-3 file should be excluded even when nested"
else
    ok "nested non-E-AC-3 file excluded"
fi
deep_count="$(tr -cd '\0' < "$deep_manifest" | wc -c)"
assert_equal "2" "$deep_count" "two E-AC-3 files across tree"

# ---------------------------------------------------------------------------
# worker script generation
# ---------------------------------------------------------------------------

begin_test "worker script is written, executable, and references the manifest"
worker_path="$TEMP_DIR/worker.sh"
manifest_abs="$TEMP_DIR/manifest"
summary_log="$TEMP_DIR/eac3-conversion.log"
write_worker_script "$worker_path" "$manifest_abs" "$summary_log"

assert_file_exists "$worker_path" "worker script created"
assert_file_contents "$worker_path" "$(cat "$worker_path")" "worker content round-trips"
if [[ -x "$worker_path" ]]; then
    ok "worker script is executable"
else
    fail "worker script should be executable"
fi
worker_content="$(cat "$worker_path")"
assert_contains "$worker_content" "$manifest_abs" "worker references manifest"
assert_contains "$worker_content" "transcode-eac3.sh" "worker references transcode script"

# ---------------------------------------------------------------------------
# screen session detection (with a fake screen)
# ---------------------------------------------------------------------------

# Install a fake `screen` that records invocations to a log file.
setup_fake_screen() {
    local bin_dir="$TEMP_DIR/fakebin"
    mkdir -p "$bin_dir"
    cat > "$bin_dir/screen" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TEMP_DIR/screen_calls"
# `screen -ls` should print a session list; otherwise behave like the real one.
if [[ "${1:-}" == "-ls" ]]; then
    # No sessions listed by default (session absent).
    exit 0
fi
exit 0
EOF
    chmod +x "$bin_dir/screen"
    export PATH="$bin_dir:$PATH"
}

begin_test "screen_session_exists returns false when no session present"
setup_fake_screen
: > "$TEMP_DIR/screen_calls"
if screen_session_exists; then
    fail "session should not exist when screen -ls lists none"
else
    ok "session correctly reported as absent"
fi

run_test_file_summary "test_directory"
