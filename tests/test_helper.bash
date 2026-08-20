# ----------------------------------------------------------------------------
# test_helper.bash
#
# Minimal, dependency-free test framework and fixtures for the E-AC-3
# transcode script. Source this from any test_*.bash file.
#
# It locates a real ffmpeg/ffprobe (vendored on Windows, or system-installed on
# Linux such as AlmaLinux) and exposes helpers to generate test media and to
# build a fake-toolchain PATH for testing failure branches.
#
# ----------------------------------------------------------------------------
# State (global; test files run at the top level)
# ----------------------------------------------------------------------------

TEST_PASS=0
TEST_FAIL=0

# Directory containing this helper (== tests/).
TEST_ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Path to the script under test.
SCRIPT_UNDER_TEST="${TEST_ROOT_DIR}/../transcode-eac3.sh"

# A writable scratch directory for the current run.
TEMP_DIR="$(mktemp -d)"
export TEMP_DIR

# ----------------------------------------------------------------------------
# Assertion library
# ----------------------------------------------------------------------------

begin_test() {
    printf '\n  -- %s --\n' "$*"
}

ok() {
    TEST_PASS=$(( TEST_PASS + 1 ))
    printf '  ok: %s\n' "$*"
}

fail() {
    TEST_FAIL=$(( TEST_FAIL + 1 ))
    printf '  FAIL: %s\n' "$*" >&2
}

assert_equal() {
    local expected="$1"
    local actual="$2"
    local description="${3:-assert_equal}"
    if [[ "$actual" == "$expected" ]]; then
        ok "$description"
        return 0
    fi
    fail "$description: expected [$expected] got [$actual]"
    return 1
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local description="${3:-assert_contains}"
    if [[ "$haystack" == *"$needle"* ]]; then
        ok "$description"
        return 0
    fi
    fail "$description: expected to find [$needle] in: $haystack"
    return 1
}

assert_status() {
    local expected="$1"
    local actual="$2"
    local description="${3:-assert_status}"
    if [[ "$actual" -eq "$expected" ]]; then
        ok "$description"
        return 0
    fi
    fail "$description: expected status $expected got $actual"
    return 1
}

assert_file_exists() {
    local path="$1"
    local description="${2:-assert_file_exists}"
    if [[ -e "$path" ]]; then
        ok "$description"
        return 0
    fi
    fail "$description: file not found: $path"
    return 1
}

assert_file_absent() {
    local path="$1"
    local description="${2:-assert_file_absent}"
    if [[ ! -e "$path" ]]; then
        ok "$description"
        return 0
    fi
    fail "$description: file should not exist: $path"
    return 1
}

assert_file_contents() {
    local path="$1"
    local expected="$2"
    local description="${3:-assert_file_contents}"
    local actual
    actual="$(cat "$path" 2>/dev/null)"
    assert_equal "$expected" "$actual" "$description"
}

run_test_file_summary() {
    local label="$1"
    printf '%s: %d passed, %d failed\n' "$label" "$TEST_PASS" "$TEST_FAIL"
}

# ----------------------------------------------------------------------------
# Locate real ffmpeg / ffprobe
# ----------------------------------------------------------------------------

# Prefer a vendored build (tests/vendor/bin), then anything on the PATH.
resolve_real_ffprobe() {
    local vendored="${TEST_ROOT_DIR}/../vendor/bin/ffprobe"
    if [[ -x "$vendored" || -f "$vendored" ]]; then
        printf '%s' "$vendored"
        return 0
    fi
    command -v ffprobe
}

resolve_real_ffmpeg() {
    local vendored="${TEST_ROOT_DIR}/../vendor/bin/ffmpeg"
    if [[ -x "$vendored" || -f "$vendored" ]]; then
        printf '%s' "$vendored"
        return 0
    fi
    command -v ffmpeg
}

REAL_FFPROBE="$(resolve_real_ffprobe)"
REAL_FFMPEG="$(resolve_real_ffmpeg)"

have_real_tools() {
    [[ -n "$REAL_FFPROBE" && -n "$REAL_FFMPEG" ]]
}

# ----------------------------------------------------------------------------
# Fixture generation (real media)
# ----------------------------------------------------------------------------

# Generate a 1-second MKV containing an E-AC-3 audio stream (plus a video
# stream). Prints the path.
make_eac3_media_file() {
    local path="$1"
    mkdir -p "$(dirname "$path")"
    "$REAL_FFMPEG" -hide_banner -loglevel error -y \
        -f lavfi -i "testsrc2=size=64x64:rate=10:duration=1" \
        -f lavfi -i "sine=frequency=1000:duration=1" \
        -c:v libx264 -c:a eac3 -shortest "$path" 2>&1
    printf '%s' "$path"
}

# Generate a 1-second MKV with a non-E-AC-3 (AAC) audio stream.
make_aac_media_file() {
    local path="$1"
    mkdir -p "$(dirname "$path")"
    "$REAL_FFMPEG" -hide_banner -loglevel error -y \
        -f lavfi -i "testsrc2=size=64x64:rate=10:duration=1" \
        -f lavfi -i "sine=frequency=1000:duration=1" \
        -c:v libx264 -c:a aac -shortest "$path" 2>&1
    printf '%s' "$path"
}

# Generate a 1-second MP4 containing an E-AC-3 audio stream.
make_eac3_mp4_file() {
    local path="$1"
    mkdir -p "$(dirname "$path")"
    "$REAL_FFMPEG" -hide_banner -loglevel error -y \
        -f lavfi -i "testsrc2=size=64x64:rate=10:duration=1" \
        -f lavfi -i "sine=frequency=1000:duration=1" \
        -c:v libx264 -c:a eac3 -shortest "$path" 2>&1
    printf '%s' "$path"
}

# Generate a 1-second MP4 with a non-E-AC-3 (AAC) audio stream.
make_aac_mp4_file() {
    local path="$1"
    mkdir -p "$(dirname "$path")"
    "$REAL_FFMPEG" -hide_banner -loglevel error -y \
        -f lavfi -i "testsrc2=size=64x64:rate=10:duration=1" \
        -f lavfi -i "sine=frequency=1000:duration=1" \
        -c:v libx264 -c:a aac -shortest "$path" 2>&1
    printf '%s' "$path"
}

# ----------------------------------------------------------------------------
# Fake toolchain (for failure-branch tests)
# ----------------------------------------------------------------------------

# Install fake ffmpeg/ffprobe shims at the front of PATH, driven by control
# files under $TEMP_DIR/ctrl.
setup_fake_toolchain() {
    local bin_dir="${TEMP_DIR}/bin"
    mkdir -p "$bin_dir"

    cat > "$bin_dir/ffprobe" <<'EOF'
#!/usr/bin/env bash
out_file="$TEMP_DIR/ctrl/ffprobe_stdout"
err_file="$TEMP_DIR/ctrl/ffprobe_stderr"
rc_file="$TEMP_DIR/ctrl/ffprobe_rc"
[[ -f "$out_file" ]] && cat "$out_file"
[[ -f "$err_file" ]] && cat "$err_file" >&2
[[ -f "$rc_file" ]] && exit "$(cat "$rc_file")"
exit 0
EOF

    cat > "$bin_dir/ffmpeg" <<'EOF'
#!/usr/bin/env bash
err_file="$TEMP_DIR/ctrl/ffmpeg_stderr"
rc_file="$TEMP_DIR/ctrl/ffmpeg_rc"
prev=""
for a in "$@"; do
    if [[ "$prev" == "--" ]]; then
        dir="$(dirname "$a")"
        mkdir -p "$dir"
        printf 'transcoded-data' > "$a"
        break
    fi
    prev="$a"
done
[[ -f "$err_file" ]] && cat "$err_file" >&2
[[ -f "$rc_file" ]] && exit "$(cat "$rc_file")"
exit 0
EOF

    chmod +x "$bin_dir/ffprobe" "$bin_dir/ffmpeg"

    mkdir -p "$TEMP_DIR/ctrl"
    : > "$TEMP_DIR/ctrl/ffprobe_stdout"
    : > "$TEMP_DIR/ctrl/ffprobe_stderr"
    : > "$TEMP_DIR/ctrl/ffmpeg_stderr"
    rm -f "$TEMP_DIR/ctrl/ffprobe_rc" "$TEMP_DIR/ctrl/ffmpeg_rc"

    export PATH="$bin_dir:$PATH"
}

set_ffprobe_output() {
    printf '%s' "$1" > "$TEMP_DIR/ctrl/ffprobe_stdout"
}

set_ffprobe_rc() {
    printf '%s' "$1" > "$TEMP_DIR/ctrl/ffprobe_rc"
}

set_ffmpeg_rc() {
    printf '%s' "$1" > "$TEMP_DIR/ctrl/ffmpeg_rc"
}

set_ffmpeg_stderr() {
    printf '%s' "$1" > "$TEMP_DIR/ctrl/ffmpeg_stderr"
}

make_fake_media_file() {
    local path="$1"
    mkdir -p "$(dirname "$path")"
    printf 'fake-media-data' > "$path"
}

# ----------------------------------------------------------------------------
# End-to-end assertion helpers (shared by MKV and MP4 test suites)
# ----------------------------------------------------------------------------

# Assert that <path> now contains an E-AC-3 stream and a default AAC track.
assert_transcoded_with_default_aac() {
    local path="$1"
    local audio_info default_index default_codec

    audio_info="$("$REAL_FFPROBE" -v error \
        -select_streams a \
        -show_entries stream=index,codec_name \
        -show_entries stream_disposition=default \
        -of csv=p=0 \
        "$path")"

    assert_contains "$audio_info" "eac3" "E-AC-3 stream preserved"
    assert_contains "$audio_info" "aac" "AAC companion added"

    default_index="$(
        printf '%s\n' "$audio_info" \
            | awk -F, '$3 == 1 { print $1; exit }'
    )"
    default_codec="$(
        printf '%s\n' "$audio_info" \
            | awk -F, -v idx="$default_index" '$1 == idx { print $2 }'
    )"
    assert_equal "aac" "$default_codec" "default track is AAC"
}

# Assert that <path> contains no leftover transcode temp files beside it.
assert_no_temp_artifacts() {
    local dir="$1"
    local leftover
    leftover="$(find "$dir" -name '.*.transcoding.*' 2>/dev/null)"
    assert_equal "" "$leftover" "no temp files"
}
