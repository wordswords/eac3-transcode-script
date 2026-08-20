#!/usr/bin/env bash
#
# transcode-eac3.sh
#
# Detect whether a media file contains E-AC-3 audio. If it does, add an AAC
# track (broadly compatible with Windows 11 and Plex) as the default audio
# track, while preserving the original E-AC-3 stream. After transcoding, the
# new file's integrity is verified. If it passes, the original file is
# replaced in place (retaining the original filename).
#
# Usage:
#   ./transcode-eac3.sh /path/to/media/file.mkv
#
# Requirements:
#   - ffmpeg and ffprobe available on the PATH
#   - Bash 4+ (present on AlmaLinux by default)
#
set -euo pipefail

readonly AAC_BITRATE_PER_CHANNEL=96k   # bits per channel for the AAC track
readonly MAX_AAC_CHANNELS=8            # upper bound on compatible-track channels
readonly DURATION_TOLERANCE_SECONDS=1  # acceptable duration drift for the check

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
# Argument & environment validation
# ----------------------------------------------------------------------------

resolve_input_file() {
    if [[ $# -ne 1 ]]; then
        die "Usage: $0 <path-to-media-file>"
    fi

    local requested="$1"
    if [[ ! -f "$requested" ]]; then
        die "File not found or not a regular file: $requested"
    fi

    readlink -f -- "$requested"
}

require_dependencies() {
    command -v ffmpeg >/dev/null 2>&1 \
        || die "ffmpeg is not installed or not on the PATH"
    command -v ffprobe >/dev/null 2>&1 \
        || die "ffprobe is not installed or not on the PATH"
}

# ----------------------------------------------------------------------------
# ffprobe helpers (single responsibility: extract data)
# ----------------------------------------------------------------------------

# Emit audio streams as "index,codec_name,channels" lines.
probe_audio_streams() {
    local file="$1"
    ffprobe -v error \
        -select_streams a \
        -show_entries stream=index,codec_name,channels \
        -of csv=p=0 \
        -- "$file" 2>/dev/null
}

# Emit every stream as "index,codec_type,codec_name,channels" lines.
probe_all_streams() {
    local file="$1"
    ffprobe -v error \
        -show_entries stream=index,codec_type,codec_name,channels \
        -of csv=p=0 \
        -- "$file" 2>/dev/null
}

# Print the container duration in seconds.
probe_duration() {
    local file="$1"
    ffprobe -v error \
        -show_entries format=duration \
        -of default=noprint_wrappers=1:nokey=1 \
        -- "$file" 2>/dev/null
}

# ----------------------------------------------------------------------------
# E-AC-3 detection
# ----------------------------------------------------------------------------

# Print the indices of all E-AC-3 ("eac3") audio streams, one per line.
find_eac3_stream_indices() {
    local file="$1"
    local line index codec channels

    while IFS=',' read -r index codec channels; do
        if [[ "$codec" == "eac3" ]]; then
            log "Found E-AC-3 audio stream: index=$index channels=$channels"
            printf '%s\n' "$index"
        fi
    done < <(probe_audio_streams "$file")
}

# ----------------------------------------------------------------------------
# AAC options
# ----------------------------------------------------------------------------

# Compute the AAC channel count, clamped to a supported maximum.
resolve_channel_count() {
    local detected_channel_count="${1:-2}"
    local channel_count="${detected_channel_count%%.*}"

    (( channel_count > 0 )) || channel_count=2
    (( channel_count > MAX_AAC_CHANNELS )) && channel_count=$MAX_AAC_CHANNELS

    printf '%s\n' "$channel_count"
}

# Compute the total AAC bitrate from the channel count. The per-channel
# constant carries a trailing 'k', so strip it before the arithmetic and
# re-append it to the result.
resolve_bitrate() {
    local channel_count="$1"
    local per_channel_bits="${AAC_BITRATE_PER_CHANNEL%k}"
    printf '%sk\n' "$(( channel_count * per_channel_bits ))"
}

# ----------------------------------------------------------------------------
# ffmpeg argument construction
# ----------------------------------------------------------------------------

# Given the set of E-AC-3 indices, build the -map and per-stream -c/-disposition
# arguments needed to copy every stream and add a default AAC track per E-AC-3
# stream. Results are stored in the caller-provided array names.
build_ffmpeg_stream_arguments() {
    local file="$1"
    local -n map_args_ref="$2"
    local -n codec_args_ref="$3"

    local eac3_indices=()
    mapfile -t eac3_indices < <(find_eac3_stream_indices "$file")

    local -A eac3_lookup=()
    local index
    for index in "${eac3_indices[@]}"; do
        eac3_lookup[$index]=1
    done

    local output_index=0
    local line stream_index stream_type codec_name channels channel_count output_bitrate

    while IFS=',' read -r stream_index stream_type codec_name channels; do
        map_args_ref+=("-map" "0:$stream_index")

        if [[ "$stream_type" == "audio" && -n "${eac3_lookup[$stream_index]:-}" ]]; then
            append_eac3_copy_args codec_args_ref "$output_index"
            (( output_index += 1 ))

            # Append an AAC rendering of the same input stream.
            map_args_ref+=("-map" "0:$stream_index")
            channel_count="$(resolve_channel_count "$channels")"
            output_bitrate="$(resolve_bitrate "$channel_count")"
            append_aac_args codec_args_ref "$output_index" "$channel_count" "$output_bitrate"
            (( output_index += 1 ))
        else
            codec_args_ref+=("-c:$output_index" "copy")
            (( output_index += 1 ))
        fi
    done < <(probe_all_streams "$file")
}

# Copy an E-AC-3 stream and clear its default disposition.
append_eac3_copy_args() {
    local -n codec_args_ref="$1"
    local output_index="$2"

    codec_args_ref+=(
        "-c:$output_index" "copy"
        "-disposition:$output_index" "0"
    )
}

# Encode an AAC stream and mark it as the default track.
append_aac_args() {
    local -n codec_args_ref="$1"
    local output_index="$2"
    local channel_count="$3"
    local output_bitrate="$4"

    codec_args_ref+=(
        "-c:$output_index" "aac"
        "-b:$output_index" "$output_bitrate"
        "-ac:$output_index" "$channel_count"
        "-metadata:s:$output_index" "title=Compatible AAC"
        "-disposition:$output_index" "default"
    )
}

# ----------------------------------------------------------------------------
# Transcoding
# ----------------------------------------------------------------------------

# Build a temporary output path alongside the source file.
make_temporary_output_path() {
    local input_file="$1"
    local input_dir input_basename file_extension

    input_dir="$(dirname -- "$input_file")"
    input_basename="$(basename -- "$input_file")"
    file_extension="${input_basename##*.}"

    printf '%s/.%s.transcoding.%s.%s\n' \
        "$input_dir" "$input_basename" "$$" "$file_extension"
}

transcode_file() {
    local input_file="$1"
    local output_file="$2"
    local -n map_args_ref="$3"
    local -n codec_args_ref="$4"

    ffmpeg -hide_banner -loglevel warning -y \
        -i "$input_file" \
        "${map_args_ref[@]}" \
        "${codec_args_ref[@]}" \
        -map_metadata 0 \
        -map_chapters 0 \
        -movflags +faststart \
        -- "$output_file" 2>&1 \
        || die "ffmpeg transcoding failed"
}

# ----------------------------------------------------------------------------
# Integrity verification
# ----------------------------------------------------------------------------

# Decode the whole file; return 0 if no decoder errors were reported.
verify_decode_clean() {
    local output_file="$1"
    local decode_errors

    decode_errors="$(ffmpeg -hide_banner -v error \
        -i "$output_file" \
        -f null - 2>&1 || true)"

    if [[ -n "$decode_errors" ]]; then
        printf '%s\n' "$decode_errors" >&2
        return 1
    fi

    return 0
}

# Compare the durations of two files within a tolerance; return 0 on success.
verify_duration_matches() {
    local original_file="$1"
    local output_file="$2"

    local original_duration output_duration
    original_duration="$(probe_duration "$original_file" || echo 0)"
    output_duration="$(probe_duration "$output_file" || echo 0)"

    log "Original duration: ${original_duration}s, new duration: ${output_duration}s"

    awk -v original="$original_duration" \
        -v output="$output_duration" \
        -v tolerance="$DURATION_TOLERANCE_SECONDS" \
        'BEGIN { diff = original - output; if (diff < 0) diff = -diff; exit (diff > tolerance) }'
}

verify_integrity() {
    local original_file="$1"
    local output_file="$2"

    log "Verifying integrity of the transcoded file..."

    if ! verify_decode_clean "$output_file"; then
        die "Integrity check failed: decoder reported errors"
    fi
    log "Full decode completed without errors."

    if ! verify_duration_matches "$original_file" "$output_file"; then
        die "Integrity check failed: duration mismatch"
    fi
    log "Duration matches within tolerance."
}

# ----------------------------------------------------------------------------
# File replacement
# ----------------------------------------------------------------------------

replace_original_in_place() {
    local output_file="$1"
    local input_file="$2"

    log "Replacing original file with the transcoded version..."

    # mv is atomic on the same filesystem and keeps the exact original name.
    if mv -f -- "$output_file" "$input_file"; then
        return 0
    fi

    log "mv failed; falling back to copy+remove."
    cp -f -- "$output_file" "$input_file" \
        || die "Failed to copy over original"
    rm -f -- "$output_file"
}

# ----------------------------------------------------------------------------
# Orchestration
# ----------------------------------------------------------------------------

# Remove a leftover temporary file, if any.
clean_up() {
    local temp_file="$1"

    if [[ -n "$temp_file" && -e "$temp_file" ]]; then
        log "Cleaning up temporary file: $temp_file"
        rm -f -- "$temp_file"
    fi
}

main() {
    require_dependencies

    local input_file
    input_file="$(resolve_input_file "$@")"
    log "Processing: $input_file"

    local eac3_stream_count
    eac3_stream_count="$(find_eac3_stream_indices "$input_file" | wc -l)"

    if (( eac3_stream_count == 0 )); then
        log "No E-AC-3 audio streams detected. Nothing to do: $input_file"
        return 0
    fi
    log "Found $eac3_stream_count E-AC-3 stream(s); adding a default AAC track."

    local map_args=()
    local codec_args=()
    build_ffmpeg_stream_arguments "$input_file" map_args codec_args

    local temp_file
    temp_file="$(make_temporary_output_path "$input_file")"
    log "Temporary output: $temp_file"

    # Guarantee cleanup of the temp file on failure or interruption.
    trap 'clean_up "$temp_file"' EXIT INT TERM

    transcode_file "$input_file" "$temp_file" map_args codec_args
    log "Transcode completed successfully."

    verify_integrity "$input_file" "$temp_file"

    replace_original_in_place "$temp_file" "$input_file"
    local replaced_file="$input_file"   # capture before temp_file goes away

    # Temp file has been consumed; disarm cleanup.
    trap - EXIT INT TERM

    log "Operation complete: $replaced_file"
}

main "$@"
