---
name: youtube-screenshotter
description: Download a YouTube video and extract frames at specified timestamps with perceptual hashes; also discovers candidate timestamps via ffmpeg scene-detect + per-second pHash run-grouping; analyses optical flow over a sub-range and composes a sprite strip showing a motion arc. Use when capturing specific moments from a video as PNG images, or when a downstream skill (e.g. youtube-synthesizer) needs a high-recall list of where things change in the video. Mechanical only — no LLM calls.
---

# YouTube Screenshotter

Mechanical primitives for video analysis. Downloads a YouTube video at 720p via `yt-dlp`, extracts PNG frames at requested timestamps via `ffmpeg`, computes perceptual hashes (pHash) per frame, and discovers candidate timestamps from the video itself using ffmpeg primitives. Emits JSON manifests.

This skill is deliberately narrow: it does not classify content kinds and makes no LLM calls. The caller decides what to do with the discovered candidates and extracted frames. See `youtube-synthesizer` for the smart kind-classification loop that drives this skill.

## Usage

```bash
# Discover candidate timestamps (ffmpeg scene-detect + per-second pHash runs)
scripts/discover.py "<URL_OR_VIDEO_ID>" -o ./out

# Extract frames at specific timestamps
scripts/extract.py "<URL_OR_VIDEO_ID>" -t 1 -t 30 -t 500 -o ./out
```

`extract.py` output is a JSON manifest printed to stdout. The output dir holds the cached video file (`<video_id>.mp4`) and a `frames/` subdir of `t<ms>.png` extracted frames. Repeated calls with the same URL skip the download; repeated timestamps hit the per-frame cache.

`discover.py` returns a manifest with two source signals (`scene_detect` and `phash_runs`) plus a unioned `candidates` list. Typical pipeline: `discover.py` → pick candidates from the manifest → `extract.py -t <ts1> -t <ts2> ...` → classify the extracted frames.

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

`scripts/discover.py` is a separate entrypoint that produces a candidate-timestamp manifest:

- Runs `ffmpeg select='gt(scene,N)'` over the video for sharp-cut transitions (configurable via `--threshold-scene`, default 0.2).
- Runs `ffmpeg fps=1,scale=320:180` for a single-pass per-second thumbnail set, then computes pHash per thumbnail and groups consecutive thumbnails into runs by Hamming distance ≤ `--threshold-phash` (default 12 — merges talking-head microexpressions into single runs).
- Filters runs to ≥ `--min-run` seconds (default 3).
- Unions both signals, dedups within 1s.

The two signals complement each other: scene-detect catches sharp cuts (including 1–2s content stretches that the run-duration filter would drop) but misses slow fade-ins; pHash run-grouping catches every sustained content stretch ≥ `--min-run` seconds (including fade-in diagrams).

`scripts/motion.py` is a third entrypoint for the case discover.py can't catch on its own — a small object moving across an otherwise-static background, where the global pHash stays within threshold and run-grouping merges the whole animation into one start frame. Given a sub-range, it densely re-samples (default 4 fps), computes Farneback optical flow per consecutive pair, picks the largest moving connected component, and scores each frame by `area * centeredness * edge_penalty`. With `--sprite-out PATH`, it also re-extracts N evenly-spaced timestamps across the motion-active span at full source resolution and composites a horizontal sprite strip — useful for animations whose meaning lives in the *arc*, not in any single frame.

```bash
scripts/motion.py <video> --start S --end E [--fps 4] [-o DIR]
                          [--sprite-out PATH] [--sprite-frames 4]
```

The primitive is content-agnostic: a talking-head with hand gestures generates motion comparable to a sliding boat. The decision *whether* a motion-active span is worth sprite-sheeting (vs. a single frame, vs. an `--allow-no-screenshot` text annotation) lives in the caller — typically `youtube-synthesizer` Phase A.5, where the keep-kind has already been confirmed via vision.

### Discover manifest shape

```json
{
  "video_path": "...", "duration_seconds": 1119,
  "thresholds": {"scene": 0.2, "phash": 12, "min_run": 3.0},
  "sources": {
    "scene_detect": [4.8, 6.9, 18.6, ...],
    "phash_runs": [
      {"start_t": 88.0, "end_t": 90.0, "duration": 3.0, "phash": "..."},
      ...
    ]
  },
  "candidates": [
    {"timestamp": 4.8,  "source": "scene_detect", "run_duration": null},
    {"timestamp": 88.0, "source": "phash_run",    "run_duration": 3.0},
    ...
  ]
}
```

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
