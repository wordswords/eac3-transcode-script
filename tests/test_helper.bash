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

# Path to the directory-batch script.
SCRIPT_UNDER_TEST_DIR="${TEST_ROOT_DIR}/../transcode-directory.sh"

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
resolve_real_tool() {
    local tool_name="$1"
    local vendored="${TEST_ROOT_DIR}/../vendor/bin/${tool_name}"
    if [[ -x "$vendored" || -f "$vendored" ]]; then
        printf '%s' "$vendored"
        return 0
    fi
    command -v "$tool_name"
}

REAL_FFPROBE="$(resolve_real_tool ffprobe)"
REAL_FFMPEG="$(resolve_real_tool ffmpeg)"

have_real_tools() {
    [[ -n "$REAL_FFPROBE" && -n "$REAL_FFMPEG" ]]
}

# ----------------------------------------------------------------------------
# Fixture generation (real media)
# ----------------------------------------------------------------------------

# Generate a 1-second media file with a single audio stream of the given codec
# (eac3 or aac) in a given container (mkv or mp4). Prints the path.
make_media_file() {
    local path="$1"
    local audio_codec="$2"
    mkdir -p "$(dirname "$path")"
    "$REAL_FFMPEG" -hide_banner -loglevel error -y \
        -f lavfi -i "testsrc2=size=64x64:rate=10:duration=1" \
        -f lavfi -i "sine=frequency=1000:duration=1" \
        -c:v libx264 -c:a "$audio_codec" -shortest "$path" 2>&1
    printf '%s' "$path"
}

# MKV / MP4, E-AC-3 / AAC convenience wrappers.
make_eac3_media_file() { make_media_file "$1" eac3; }
make_aac_media_file()  { make_media_file "$1" aac; }
make_eac3_mp4_file()   { make_media_file "$1" eac3; }
make_aac_mp4_file()    { make_media_file "$1" aac; }

# Generate a 1-second MKV whose single E-AC-3 stream is 5.1 surround.
make_eac3_51_media_file() {
    local path="$1"
    mkdir -p "$(dirname "$path")"
    "$REAL_FFMPEG" -hide_banner -loglevel error -y \
        -f lavfi -i "testsrc2=size=64x64:rate=10:duration=1" \
        -f lavfi -i "sine=frequency=1000:duration=1:sample_rate=48000" \
        -af "aformat=channel_layouts=5.1" \
        -c:v libx264 -c:a eac3 -shortest "$path" 2>&1
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

set_fake_control() {
    local control_file="$1"
    local content="$2"
    printf '%s' "$content" > "$TEMP_DIR/ctrl/$control_file"
}

set_ffprobe_output() { set_fake_control ffprobe_stdout "$1"; }
set_ffprobe_rc()     { set_fake_control ffprobe_rc "$1"; }
set_ffmpeg_rc()      { set_fake_control ffmpeg_rc "$1"; }
set_ffmpeg_stderr()  { set_fake_control ffmpeg_stderr "$1"; }

make_fake_media_file() {
    local path="$1"
    mkdir -p "$(dirname "$path")"
    printf 'fake-media-data' > "$path"
}

# ----------------------------------------------------------------------------
# End-to-end assertion helpers (shared by MKV and MP4 test suites)
# ----------------------------------------------------------------------------

# Assert that <path> now contains an E-AC-3 stream, a default AAC track, and a
# separate 5.1 AC-3 compatibility track.
assert_transcoded_with_compat_streams() {
    local path="$1"
    local audio_info default_index default_codec ac3_channels

    # Print index, codec_name, disposition.default, and channels per audio
    # stream as CSV.
    audio_info="$("$REAL_FFPROBE" -v error \
        -select_streams a \
        -show_entries stream=index,codec_name,channels \
        -show_entries stream_disposition=default \
        -of csv=p=0 \
        "$path")"

    assert_contains "$audio_info" "eac3" "E-AC-3 stream preserved"
    assert_contains "$audio_info" "aac" "AAC companion added"
    assert_contains "$audio_info" "ac3" "AC-3 companion added"

    # The default track must be AAC. Extract the index of the stream whose
    # default disposition is 1, then confirm its codec is aac.
    default_index="$(
        printf '%s\n' "$audio_info" \
            | awk -F, '$4 == 1 { print $1; exit }'
    )"
    default_codec="$(
        printf '%s\n' "$audio_info" \
            | awk -F, -v idx="$default_index" '$1 == idx { print $2 }'
    )"
    assert_equal "aac" "$default_codec" "default track is AAC"

    # The AC-3 track must be 5.1 (6 channels).
    ac3_channels="$(
        printf '%s\n' "$audio_info" \
            | awk -F, '$2 == "ac3" { print $3; exit }'
    )"
    assert_equal "6" "$ac3_channels" "AC-3 track is 5.1"
}

# Assert that <path> contains no leftover transcode temp files beside it.
assert_no_temp_artifacts() {
    local dir="$1"
    local leftover
    leftover="$(find "$dir" -name '.*.transcoding.*' 2>/dev/null)"
    assert_equal "" "$leftover" "no temp files"
}
