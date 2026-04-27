---
name: youtube-screenshotter
description: Download a YouTube video and extract frames at specified timestamps with perceptual hashes. Use when capturing specific moments from a video as PNG images, or when a downstream skill (e.g. youtube-synthesizer) needs frames + pHashes for diffing. Mechanical only — no LLM calls, no scene detection.
---

# YouTube Screenshotter

Mechanical primitives for video frame extraction. Downloads a YouTube video at 720p via `yt-dlp`, extracts PNG frames at requested timestamps via `ffmpeg`, and computes perceptual hashes (pHash) for each frame. Emits a single manifest JSON.

This skill is deliberately narrow: it does not pick timestamps, does not classify visual differences, and makes no LLM calls. The caller decides what to sample and what to do with the output. See `youtube-synthesizer` for the smart bisection + judgment loop that drives this skill.

## Usage

```bash
scripts/extract.py "<URL_OR_VIDEO_ID>" -t 1 -t 30 -t 500 -o ./out
```

Output is a JSON manifest printed to stdout. The output dir holds the cached video file (`<video_id>.mp4`) and a `frames/` subdir of `t<ms>.png` extracted frames. Repeated calls with the same URL skip the download; repeated timestamps hit the per-frame cache.

## Manifest shape

```json
{
  "video_path": "/abs/path/to/<video_id>.mp4",
  "metadata": {
    "video_id": "...", "source_url": "...", "source_title": "...",
    "source_author": "...", "source_published_date": "YYYY-MM-DD",
    "channel": "...", "channel_id": "...",
    "duration_seconds": 1119,
    "chapter_markers": [{"title": "...", "start_time": 0.0, "end_time": 153.0}, ...],
    "playlist_id": null, "playlist_title": null
  },
  "entries": [
    {"timestamp": 1.0, "frame_path": "/abs/.../frames/t00001000.png", "phash": "b230d3532d4b8de9"},
    ...
  ]
}
```

## Sub-scripts

`scripts/extract.py` composes three primitives that can also be invoked independently:

- `scripts/video.py <url> [-o DIR] [--no-download]` — yt-dlp wrapper for download + metadata. `--no-download` for cheap metadata-only probes.
- `scripts/frames.py <video> -t <ts> [-t <ts> ...] [-o DIR]` — ffmpeg frame extraction.
- `scripts/phash.py compute <image>` / `scripts/phash.py compare <a> <b>` — perceptual-hash compute + Hamming-distance pair classifier (`same` / `ambiguous` / `different` bands).

## pHash interpretation

For 64-bit pHash with default thresholds (`SAME_MAX=5`, `DIFFERENT_MIN=20`):

- Hamming distance ≤ 5 → `same` (no meaningful change)
- Hamming distance ≥ 20 → `different` (clear scene/content change)
- 6–19 → `ambiguous` — pHash can't disambiguate; needs visual judgment

Disambiguating the ambiguous band into `same` / `different` / `additive` is the caller's job — typically the `youtube-synthesizer` skill, which does it with the parent agent's native vision capability.

## Supported URL formats

Same as `youtube-transcript`:
- `https://www.youtube.com/watch?v=VIDEO_ID`
- `https://youtu.be/VIDEO_ID`
- `https://youtube.com/embed/VIDEO_ID`
- `https://youtube.com/shorts/VIDEO_ID`
- Raw 11-character video ID

## Prerequisites

- `uv` — installs Python deps in an ephemeral venv per invocation. `curl -LsSf https://astral.sh/uv/install.sh | sh` or `pip install uv`.
- `ffmpeg` — required for frame extraction and yt-dlp's video+audio merge. `sudo apt install ffmpeg` (Linux), `brew install ffmpeg` (macOS).
- Network access to `youtube.com` and `googlevideo.com` for downloads.
