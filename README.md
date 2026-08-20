# eac3-transcode-script

Detect media files containing E-AC-3 audio and add Windows 11 / Plex
compatible audio tracks while preserving the original E-AC-3 stream. For each
E-AC-3 stream the script adds:

- an **AAC** track (set as the default), and
- a separate **5.1 AC-3** track.

Integrity is verified before replacing the original file in place.

Supported containers: MKV and MP4.

## Usage

Transcode a single file:

```bash
./transcode-eac3.sh /path/to/media/file.mkv
```

Transcode every E-AC-3 file in a directory (recursively), inside a
named `screen` session:

```bash
./transcode-directory.sh /path/to/media/directory
```

The directory script recurses through all subdirectories under the given
path, scanning for `.mp4`/`.mkv` files containing E-AC-3 audio, then runs
`transcode-eac3.sh` on each. All work runs inside a `screen` session named
`eac3-conversion-screen`, so you can detach (`Ctrl-A` `D`) and re-attach later
(`screen -r eac3-conversion-screen`) without interrupting the batch.

Requirements: `ffmpeg` and `ffprobe` on the `PATH` (available from the
AlmaLinux base/extras repositories via `dnf install ffmpeg`), plus `screen`
for the directory batch script.

## Performance & progress

- **Audio-only transcoding** — video and the original E-AC-3 stream are copied
  bit-for-bit. Only the AAC and 5.1 AC-3 companion tracks are encoded (CPU audio
  encode, typically 50–150× realtime).
- **Multi-threaded** — both transcode and verification use `-threads 0` to use
  all available cores.
- **Live progress** — the transcode shows ffmpeg's `-stats` line
  (`frame=... speed=...`), and the integrity check streams a machine-readable
  `-progress` meter (`out_time`, `speed`, `progress=end`).

## Testing

The test suite is dependency-free and runs on any Bash 4.3+. It locates a real
`ffmpeg`/`ffprobe` automatically — either downloaded under `vendor/bin/` (for
Windows) or installed on the system (Linux/AlmaLinux) — and generates real media
fixtures on the fly.

```bash
./tests/run_tests.sh
```

### Test layout

| File | What it covers |
| --- | --- |
| `tests/test_pure_functions.bash` | Channel-count clamping, bitrate math, temp-path construction |
| `tests/test_detection.bash` | E-AC-3 stream detection against real media |
| `tests/test_arguments.bash` | ffmpeg `-map`/`-c`/`-disposition` argument construction |
| `tests/test_integrity.bash` | Decode verification, duration comparison, file replacement, cleanup |
| `tests/test_main.bash` | Full end-to-end transcodes with real ffmpeg/ffprobe (MKV) |
| `tests/test_mp4.bash` | End-to-end transcodes confirming MP4 behaves like MKV |
| `tests/test_directory.bash` | Directory batch script: detection, manifest, worker generation |
| `tests/test_helper.bash` | Shared minimal test framework + fixtures |
