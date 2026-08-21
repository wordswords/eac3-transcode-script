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
readonly EAC3_CODEC="eac3"             # ffmpeg codec name for Dolby Digital Plus
readonly DEFAULT_CHANNEL_COUNT=2       # fallback when a stream omits channel info
readonly AC3_BITRATE="640k"            # bitrate for the 5.1 AC-3 compatibility track
readonly AC3_CHANNEL_COUNT=6           # 5.1 surround = 6 channels
readonly AC3_CHANNEL_LAYOUT="5.1"      # explicit surround layout for the AC-3 track

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

# Emit audio streams as "index,codec_name,channels" lines. Carriage returns
# are stripped so the script behaves identically on Windows (CRLF ffprobe) and
# Linux.
probe_audio_streams() {
    local file="$1"
    ffprobe -v error \
        -select_streams a \
        -show_entries stream=index,codec_name,channels \
        -of csv=p=0 \
        -- "$file" 2>/dev/null \
        | tr -d '\r'
}

# Emit every stream as "index,codec_name,codec_type,channels" lines.
# Note: ffmpeg emits fields in this fixed order regardless of the
# -show_entries request order. Carriage returns are stripped for
# cross-platform consistency.
probe_all_streams() {
    local file="$1"
    ffprobe -v error \
        -show_entries stream=index,codec_type,codec_name,channels \
        -of csv=p=0 \
        -- "$file" 2>/dev/null \
        | tr -d '\r'
}

# Print the container duration in seconds.
probe_duration() {
    local file="$1"
    ffprobe -v error \
        -show_entries format=duration \
        -of default=noprint_wrappers=1:nokey=1 \
        -- "$file" 2>/dev/null \
        | tr -d '\r'
}

# Emit audio streams as "index,codec_name,channels,language" lines. Carriage
# returns are stripped for cross-platform consistency; an empty language field
# is emitted as an empty string so columns stay aligned.
probe_audio_stream_metadata() {
    local file="$1"
    ffprobe -v error \
        -select_streams a \
        -show_entries stream=index,codec_name,channels \
        -show_entries stream_tags=language \
        -of csv=p=0 \
        -- "$file" 2>/dev/null \
        | tr -d '\r'
}

# ----------------------------------------------------------------------------
# E-AC-3 detection
# ----------------------------------------------------------------------------

# Return 0 if the given codec name is E-AC-3.
is_eac3_codec() {
    [[ "$1" == "$EAC3_CODEC" ]]
}

# Print the indices of all E-AC-3 audio streams, one per line.
find_eac3_stream_indices() {
    local file="$1"
    local index codec_name channels

    while IFS=',' read -r index codec_name channels; do
        if is_eac3_codec "$codec_name"; then
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
    local detected_channel_count="${1:-$DEFAULT_CHANNEL_COUNT}"
    local channel_count="${detected_channel_count%%.*}"

    (( channel_count > 0 )) || channel_count=$DEFAULT_CHANNEL_COUNT
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
# arguments needed to copy every stream and, per E-AC-3 stream, add an AAC track
# plus a separate 5.1 AC-3 compatibility track. The AAC companion of the English
# audio stream (falling back to the first E-AC-3 stream) is marked default.
# Results are stored in the caller-provided array names.
build_ffmpeg_stream_arguments() {
    local file="$1"
    local map_args_name="$2"
    local codec_args_name="$3"
    local -n map_args_ref="$map_args_name"
    local -n codec_args_ref="$codec_args_name"

    local eac3_indices=()
    mapfile -t eac3_indices < <(find_eac3_stream_indices "$file")

    local -A eac3_lookup=()
    local index
    for index in "${eac3_indices[@]}"; do
        eac3_lookup[$index]=1
    done

    local default_source_index
    default_source_index="$(find_english_audio_index "$file")"
    if [[ -z "$default_source_index" ]]; then
        # Fall back to the first E-AC-3 stream when no English audio exists.
        default_source_index="${eac3_indices[0]:-}"
    fi

    local output_index=0
    local stream_index codec_name stream_type channels channel_count output_bitrate is_default

    while IFS=',' read -r stream_index codec_name stream_type channels; do
        map_args_ref+=("-map" "0:$stream_index")

        if is_eac3_audio_stream "$stream_type" "${eac3_lookup[$stream_index]:-}"; then
            append_copied_eac3 "$codec_args_name" "$output_index"
            (( output_index += 1 ))

            channel_count="$(resolve_channel_count "$channels")"
            output_bitrate="$(resolve_bitrate "$channel_count")"

            if [[ "$stream_index" == "$default_source_index" ]]; then
                is_default=1
            else
                is_default=0
            fi

            # AAC compatibility track.
            map_args_ref+=("-map" "0:$stream_index")
            append_compat_aac "$codec_args_name" "$output_index" "$channel_count" "$output_bitrate" "$is_default"
            (( output_index += 1 ))

            # Separate 5.1 AC-3 compatibility track.
            map_args_ref+=("-map" "0:$stream_index")
            append_compat_ac3 "$codec_args_name" "$output_index"
            (( output_index += 1 ))
        else
            codec_args_ref+=("-c:$output_index" "copy")
            (( output_index += 1 ))
        fi
    done < <(probe_all_streams "$file")
}

# Print the absolute index of the audio stream tagged with language "eng", or
# nothing if none is tagged as English.
find_english_audio_index() {
    local file="$1"
    local index codec_name channels language

    while IFS=',' read -r index codec_name channels language; do
        if [[ "$language" == "eng" ]]; then
            printf '%s\n' "$index"
            return 0
        fi
    done < <(probe_audio_stream_metadata "$file")
}

# Return 0 if the stream is an audio stream present in the E-AC-3 lookup.
is_eac3_audio_stream() {
    local stream_type="$1"
    local in_eac3_lookup="$2"

    [[ "$stream_type" == "audio" && -n "$in_eac3_lookup" ]]
}

# Copy an E-AC-3 stream and clear its default disposition.
append_copied_eac3() {
    local -n target_array="$1"
    local output_index="$2"

    target_array+=(
        "-c:$output_index" "copy"
        "-disposition:$output_index" "0"
    )
}

# Encode an AAC stream. <is_default> is 1 for the single track that should be
# the default, 0 otherwise.
append_compat_aac() {
    local -n target_array="$1"
    local output_index="$2"
    local channel_count="$3"
    local output_bitrate="$4"
    local is_default="$5"
    local disposition

    if [[ "$is_default" == "1" ]]; then
        disposition="default"
    else
        disposition="0"
    fi

    target_array+=(
        "-c:$output_index" "aac"
        "-b:$output_index" "$output_bitrate"
        "-ac:$output_index" "$channel_count"
        "-metadata:s:$output_index" "title=Compatible AAC"
        "-disposition:$output_index" "$disposition"
    )
}

# Encode a fixed 5.1 AC-3 compatibility stream (not the default track). The
# explicit channel layout guarantees all six source channels are reproduced in
# the surround mix rather than being lost to an automatic downmix.
append_compat_ac3() {
    local -n target_array="$1"
    local output_index="$2"

    target_array+=(
        "-c:$output_index" "ac3"
        "-b:$output_index" "$AC3_BITRATE"
        "-ac:$output_index" "$AC3_CHANNEL_COUNT"
        "-channel_layout:$output_index" "$AC3_CHANNEL_LAYOUT"
        "-metadata:s:$output_index" "title=Compatible AC3 5.1"
        "-disposition:$output_index" "0"
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

# Build a second temporary path (for the deduplication pass) alongside the
# source file, distinct from the transcode temp so the two never collide.
make_dedup_output_path() {
    local input_file="$1"
    local input_dir input_basename file_extension

    input_dir="$(dirname -- "$input_file")"
    input_basename="$(basename -- "$input_file")"
    file_extension="${input_basename##*.}"

    printf '%s/.%s.dedup.%s.%s\n' \
        "$input_dir" "$input_basename" "$$" "$file_extension"
}

transcode_file() {
    local input_file="$1"
    local output_file="$2"
    local -n map_args_ref="$3"
    local -n codec_args_ref="$4"

    # Video and the original E-AC-3 stream are copied bit-for-bit, so the only
    # encode is audio->AAC. `-threads 0` uses all cores, and `-stats` renders a
    # live progress line at a reduced log level so we don't dump the full
    # stream mapping.
    ffmpeg -hide_banner -loglevel warning -y \
        -nostdin \
        -threads 0 \
        -i "$input_file" \
        "${map_args_ref[@]}" \
        "${codec_args_ref[@]}" \
        -map_metadata 0 \
        -map_chapters 0 \
        -movflags +faststart \
        -stats \
        -- "$output_file" 2>&1 \
        || die "ffmpeg transcoding failed"
}

# ----------------------------------------------------------------------------
# Integrity verification
# ----------------------------------------------------------------------------

# Decode the whole file; return 0 on a clean decode. Success is determined by
# ffmpeg's exit code, not by stderr output: the null muxer emits benign DTS
# warnings (e.g. for x265 sources) that do not indicate corruption. Progress is
# streamed to stdout; genuine failures surface ffmpeg's stderr and a non-zero
# exit code.
verify_decode_clean() {
    local output_file="$1"
    local stderr_log
    local ffmpeg_status
    stderr_log="$(mktemp)"

    # `-progress pipe:1` emits a machine-readable progress meter on stdout,
    # while stderr is captured separately so we can inspect it on failure.
    ffmpeg_status=0
    ffmpeg -hide_banner -v error \
        -nostdin \
        -threads 0 \
        -i "$output_file" \
        -f null - \
        -progress pipe:1 \
        2>"$stderr_log" || ffmpeg_status=$?

    # A non-zero exit code means the decode failed; report captured diagnostics.
    if [[ "$ffmpeg_status" -ne 0 ]]; then
        cat "$stderr_log" >&2
        rm -f -- "$stderr_log"
        return 1
    fi

    rm -f -- "$stderr_log"
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
# Audio stream deduplication
# ----------------------------------------------------------------------------

# Print the MD5 checksum (as "MD5=<hex>") of a single audio stream's encoded
# packets. <audio_index> is 0-based relative to the audio streams.
checksum_audio_stream() {
    local file="$1"
    local audio_index="$2"
    ffmpeg -hide_banner -v error \
        -nostdin \
        -i "$file" \
        -map "0:a:${audio_index}" \
        -c copy \
        -f md5 - 2>&1 \
        | grep -oE 'MD5=[0-9a-fA-F]+' \
        | head -1
}

# Print the absolute stream index of every audio stream that duplicates an
# earlier stream, as "<index>" lines. Two streams are duplicates when their
# codec, channel count, language, and encoded-packet checksum all match.
find_duplicate_audio_indices() {
    local file="$1"
    local -A seen=()
    local audio_relative=0
    local index codec_name channels language dedup_key checksum

    while IFS=',' read -r index codec_name channels language; do
        checksum="$(checksum_audio_stream "$file" "$audio_relative")"
        dedup_key="${codec_name}|${channels}|${language}|${checksum}"

        if [[ -n "${seen[$dedup_key]:-}" ]]; then
            printf '%s\n' "$index"
        else
            seen[$dedup_key]=1
        fi

        audio_relative=$(( audio_relative + 1 ))
    done < <(probe_audio_stream_metadata "$file")
}

# Remove any duplicate audio streams from <file>, producing a new file in
# place. Only runs when duplicates are found; otherwise leaves the file
# untouched. Video, subtitles, chapters, and metadata are preserved by copying
# every non-duplicate stream.
deduplicate_audio_streams() {
    local file="$1"
    local -a duplicate_indices=()
    mapfile -t duplicate_indices < <(find_duplicate_audio_indices "$file")

    if [[ ${#duplicate_indices[@]} -eq 0 ]]; then
        log "No duplicate audio streams found."
        return 0
    fi

    log "Removing ${#duplicate_indices[@]} duplicate audio stream(s)."

    # Build a lookup so we can skip duplicate streams when mapping.
    local -A drop_lookup=()
    local dup
    for dup in "${duplicate_indices[@]}"; do
        drop_lookup[$dup]=1
    done

    # Map every stream except the duplicates; copy them all bit-for-bit.
    local -a map_args=()
    local output_stream_index=0
    local stream_index
    while IFS=',' read -r stream_index _rest; do
        if [[ -n "${drop_lookup[$stream_index]:-}" ]]; then
            continue
        fi
        map_args+=("-map" "0:$stream_index")
        map_args+=("-c:$output_stream_index" "copy")
        output_stream_index=$(( output_stream_index + 1 ))
    done < <(probe_all_streams "$file")

    local deduped
    deduped="$(make_dedup_output_path "$file")"

    ffmpeg -hide_banner -loglevel warning -y \
        -nostdin \
        -i "$file" \
        "${map_args[@]}" \
        -map_metadata 0 \
        -map_chapters 0 \
        -movflags +faststart \
        -- "$deduped" 2>&1 \
        || die "ffmpeg deduplication failed"

    mv -f -- "$deduped" "$file"
    log "Deduplication complete."
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

# Transcode <input_file> into a temporary file, verify it, and replace the
# original in place. On failure or interruption the temp file is cleaned up.
# <map_args_name> and <codec_args_name> are the names of caller-owned arrays.
transcode_and_replace() {
    local input_file="$1"
    local map_args_name="$2"
    local codec_args_name="$3"
    local temp_file

    temp_file="$(make_temporary_output_path "$input_file")"
    log "Temporary output: $temp_file"

    # Guarantee cleanup of the temp file on failure or interruption.
    trap 'clean_up "$temp_file"' EXIT INT TERM

    transcode_file "$input_file" "$temp_file" "$map_args_name" "$codec_args_name"
    log "Transcode completed successfully."

    verify_integrity "$input_file" "$temp_file"

    deduplicate_audio_streams "$temp_file"

    replace_original_in_place "$temp_file" "$input_file"

    # Temp file has been consumed; disarm cleanup.
    trap - EXIT INT TERM
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

    transcode_and_replace "$input_file" map_args codec_args

    log "Operation complete: $input_file"
}

# Only run when executed directly, not when sourced (e.g. by the test suite).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
