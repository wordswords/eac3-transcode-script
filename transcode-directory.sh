#!/usr/bin/env bash
#
# transcode-directory.sh
#
# Scan a directory (recursively) for .mp4 and .mkv files that contain E-AC-3
# audio, then transcode each one using the sibling transcode-eac3.sh script.
# All conversion work runs inside a named `screen` session so it can survive a
# disconnect and be monitored/re-attached later.
#
# Usage:
#   ./transcode-directory.sh /path/to/media/directory
#
# Requirements:
#   - screen, ffmpeg, ffprobe available on the PATH
#   - transcode-eac3.sh located in the same directory as this script
#   - Bash 4+ (present on AlmaLinux by default)
#
set -euo pipefail

readonly SCREEN_SESSION="eac3-conversion-screen"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly TRANSCODE_SCRIPT="${SCRIPT_DIR}/transcode-eac3.sh"
readonly EAC3_CODEC="eac3"           # ffmpeg codec name for Dolby Digital Plus
readonly WORKER_FILENAME=".eac3-batch-worker.sh"
readonly MANIFEST_FILENAME=".eac3-batch-manifest"
readonly SUMMARY_LOG_FILENAME="eac3-conversion.log"

# ----------------------------------------------------------------------------
# Logging
# ----------------------------------------------------------------------------

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2
}

die() {
    log "ERROR: $*"
    exit 1
}

# ----------------------------------------------------------------------------
# Validation
# ----------------------------------------------------------------------------

require_directory() {
    local requested="${1:-}"

    if [[ -z "$requested" ]]; then
        die "Usage: $0 <directory>"
    fi

    if [[ ! -d "$requested" ]]; then
        die "Not a directory: $requested"
    fi

    readlink -f -- "$requested"
}

require_dependencies() {
    require_command screen
    require_command ffprobe
    require_command ffmpeg

    if [[ ! -x "$TRANSCODE_SCRIPT" ]]; then
        die "transcode script not found or not executable: $TRANSCODE_SCRIPT"
    fi
}

# Ensure a command is available on the PATH.
require_command() {
    local command_name="$1"
    command -v "$command_name" >/dev/null 2>&1 \
        || die "$command_name is not installed or not on the PATH"
}

# ----------------------------------------------------------------------------
# E-AC-3 detection across the directory tree
# ----------------------------------------------------------------------------

# Return 0 if the file contains an E-AC-3 audio stream.
has_eac3_audio() {
    local file="$1"

    ffprobe -v error \
        -select_streams a \
        -show_entries stream=codec_name \
        -of default=noprint_wrappers=1:nokey=1 \
        -- "$file" 2>/dev/null \
        | tr -d '\r' \
        | grep -qx "$EAC3_CODEC"
}

# Write the NUL-delimited list of E-AC-3 files to <output_file>.
build_eac3_manifest() {
    local directory="$1"
    local output_file="$2"
    local file

    # shellcheck disable=SC2312
    : > "$output_file"

    while IFS= read -r -d '' file; do
        if has_eac3_audio "$file"; then
            printf '%s\0' "$file" >> "$output_file"
        fi
    done < <(find "$directory" -type f \( -iname '*.mp4' -o -iname '*.mkv' \) -print0)
}

# ----------------------------------------------------------------------------
# Worker script generation (runs inside the screen session)
# ----------------------------------------------------------------------------

# Print the path to the worker script and manifest.
make_worker_path() {
    local directory="$1"
    printf '%s/%s\n' "$directory" "$WORKER_FILENAME"
}

make_manifest_path() {
    local directory="$1"
    printf '%s/%s\n' "$directory" "$MANIFEST_FILENAME"
}

# Write the worker script. It reads the manifest and transcodes each file,
# appending results to a summary log.
write_worker_script() {
    local worker_path="$1"
    local manifest_path="$2"
    local summary_log="$3"

    cat > "$worker_path" <<EOF
#!/usr/bin/env bash
set -uo pipefail

TRANSCODE_SCRIPT="$TRANSCODE_SCRIPT"
MANIFEST="$manifest_path"
SUMMARY_LOG="$summary_log"

log() {
    printf '[%s] %s\n' "\$(date '+%Y-%m-%d %H:%M:%S')" "\$*"
}

log "Worker started."

COUNT=0
FAILED=0

while IFS= read -r -d '' file; do
    COUNT=\$(( COUNT + 1 ))
    log "Processing (\$COUNT): \$file"
    if "\$TRANSCODE_SCRIPT" "\$file"; then
        log "OK: \$file" | tee -a "\$SUMMARY_LOG"
    else
        FAILED=\$(( FAILED + 1 ))
        log "FAILED: \$file" | tee -a "\$SUMMARY_LOG"
    fi
done < "\$MANIFEST"

log "Done. Processed \$COUNT file(s), \$FAILED failure(s)." | tee -a "\$SUMMARY_LOG"
EOF

    chmod +x "$worker_path"
}

# ----------------------------------------------------------------------------
# screen session management
# ----------------------------------------------------------------------------

# Return 0 if a screen session named $SCREEN_SESSION already exists.
# screen -ls lists sessions as "<pid>.<session-name>", so match the name
# following a dot.
screen_session_exists() {
    screen -ls 2>/dev/null | grep -q "\.${SCREEN_SESSION}[[:space:]]"
}

# ----------------------------------------------------------------------------
# Orchestration
# ----------------------------------------------------------------------------

main() {
    local directory worker_path manifest_path summary_log

    directory="$(require_directory "$@")"
    require_dependencies

    worker_path="$(make_worker_path "$directory")"
    manifest_path="$(make_manifest_path "$directory")"
    summary_log="${directory}/${SUMMARY_LOG_FILENAME}"

    log "Scanning for E-AC-3 files under: $directory"
    build_eac3_manifest "$directory" "$manifest_path"

    local count
    count="$(tr -cd '\0' < "$manifest_path" | wc -c)"
    log "Found $count media file(s) with E-AC-3 audio."

    if (( count == 0 )); then
        log "Nothing to transcode."
        rm -f "$manifest_path"
        return 0
    fi

    write_worker_script "$worker_path" "$manifest_path" "$summary_log"
    log "Worker script written: $worker_path"

    if screen_session_exists; then
        log "screen session '$SCREEN_SESSION' already exists"
    else
        log "Starting detached screen session '$SCREEN_SESSION'"
        # Run the worker detached with its stdin disconnected from the terminal
        # so ffmpeg (and screen) never read stray keystrokes.
        screen -dmS "$SCREEN_SESSION" bash "$worker_path" < /dev/null
    fi

    log "Attaching to screen session '$SCREEN_SESSION' (detach with Ctrl-A, D)."
    screen -R "$SCREEN_SESSION"
}

# Only run when executed directly, not when sourced (e.g. by the test suite).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
