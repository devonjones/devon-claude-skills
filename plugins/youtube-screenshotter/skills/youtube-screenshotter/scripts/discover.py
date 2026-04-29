#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["yt-dlp", "imagehash>=4.3", "Pillow>=10"]
# ///
"""Discover candidate timestamps for the synthesizer.

Combines two ffmpeg-based discovery primitives over the cached video:

1. **Scene-detect.** Single-pass `select='gt(scene,N)'`. Catches sharp cuts,
   including brief content stretches (a 1–2s diagram between talking-head
   shots) that a duration filter would otherwise drop. Misses slow fade-ins
   on its own, but it's cheap (~10s for an 18-min video).

2. **Per-second pHash run-grouping.** Single-pass `fps=1,scale=320:180`
   thumbnail extraction, then pHash per thumbnail, then collapse consecutive
   thumbnails whose Hamming distance to the run's start frame stays below
   `--threshold-phash` (default 12, which merges talking-head microexpressions
   into a single run). Catches every sustained content stretch ≥ `--min-run`
   seconds — including the fade-in diagrams scene-detect misses.

The two timestamp sets are unioned and dedup'd by proximity (within 1s).
The synthesizer's Phase A consumes the resulting `candidates` list, calls
`extract.py` to fetch the chosen frames at full res, and classifies each
by kind.

CLI:
    discover.py <URL-or-file> [-o WORK_DIR]
                              [--threshold-scene 0.2]
                              [--threshold-phash 12]
                              [--min-run 3]
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

# Allow sibling imports when run via `uv run --script` from any cwd.
sys.path.insert(0, str(Path(__file__).parent))

import yt_dlp  # noqa: E402

from phash import compute as phash_compute  # noqa: E402
from video import download  # noqa: E402


DEFAULT_SCENE_THRESHOLD = 0.2
DEFAULT_PHASH_THRESHOLD = 12  # Hamming; ~12 merges talking-head microexpressions
DEFAULT_MIN_RUN = 3.0  # seconds a run must hold to count as sustained content
DEDUP_PROXIMITY = 1.0  # seconds — entries within this window are deduped


# --- ffmpeg discovery primitives -----------------------------------------


def probe_duration(video_path: Path) -> float | None:
    """Return the video's duration in seconds via ffprobe, or None on failure."""
    cmd = [
        "ffprobe",
        "-v", "error",
        "-show_entries", "format=duration",
        "-of", "default=noprint_wrappers=1:nokey=1",
        str(video_path),
    ]
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, check=True)
        return float(proc.stdout.strip())
    except (subprocess.CalledProcessError, FileNotFoundError, ValueError):
        return None


def scene_detect(video_path: Path, threshold: float) -> list[float]:
    """Return ffmpeg scene-change timestamps in seconds."""
    cmd = [
        "ffmpeg",
        "-hide_banner",
        "-nostats",
        "-nostdin",
        "-i", str(video_path),
        "-vf", f"select='gt(scene,{threshold})',showinfo",
        "-vsync", "vfr",
        "-an",
        "-f", "null",
        "-",
    ]
    proc = subprocess.run(cmd, capture_output=True, text=True, check=True)
    # showinfo emits to stderr at default loglevel; pts_time:N.NNN is the field.
    return [float(m) for m in re.findall(r"pts_time:([0-9.]+)", proc.stderr)]


def extract_thumbnails(video_path: Path, out_dir: Path) -> list[tuple[float, Path]]:
    """Extract one low-res thumbnail per second using a single ffmpeg pass.

    Returns sorted (timestamp_seconds, file_path) pairs. The thumbnails are
    320×180 JPEG (~quality 5 / mid range) so the directory stays small.
    """
    out_dir.mkdir(parents=True, exist_ok=True)
    pattern = str(out_dir / "thumb_%05d.jpg")
    cmd = [
        "ffmpeg",
        "-hide_banner",
        "-loglevel", "error",
        "-nostdin",
        "-i", str(video_path),
        "-vf", "fps=1,scale=320:180",
        "-q:v", "5",
        "-y",
        pattern,
    ]
    subprocess.run(cmd, check=True)
    # ffmpeg numbers from 1; the Nth thumbnail covers second (N-1) of the
    # video's playback timeline (roughly mid-second since fps=1 samples one
    # frame per second).
    files = sorted(out_dir.glob("thumb_*.jpg"))
    return [(float(i), p) for i, p in enumerate(files)]


# --- run-grouping --------------------------------------------------------


@dataclass
class Run:
    start_t: float
    end_t: float          # inclusive; duration = end_t - start_t + 1
    phash: str            # pHash of the run's first thumbnail
    representative: Path  # path to that first thumbnail

    @property
    def duration(self) -> float:
        return self.end_t - self.start_t + 1.0


def group_runs(
    thumbnails: list[tuple[float, Path]],
    threshold: int,
) -> list[Run]:
    """Walk thumbnails in time order; collapse consecutive thumbs whose pHash
    is within Hamming `threshold` of the run's start frame into a single run.
    """
    runs: list[Run] = []
    current: Run | None = None
    current_h = None

    for t, path in thumbnails:
        h = phash_compute(path)
        if current is None:
            current = Run(start_t=t, end_t=t, phash=str(h), representative=path)
            current_h = h
            continue
        dist = h - current_h
        if dist <= threshold:
            current.end_t = t
        else:
            runs.append(current)
            current = Run(start_t=t, end_t=t, phash=str(h), representative=path)
            current_h = h

    if current is not None:
        runs.append(current)
    return runs


# --- merge + dedup -------------------------------------------------------


def union_candidates(
    scene_changes: list[float],
    runs: list[Run],
    min_run: float,
) -> list[dict]:
    """Merge scene-change timestamps and (filtered) run-start timestamps into
    a single ordered candidate list, deduped by `DEDUP_PROXIMITY` seconds.

    Each candidate carries `source` ('scene_detect' / 'phash_run') and, where
    applicable, `run_duration` so the synthesizer knows how long the static
    stretch was — useful as a kind-classification hint.
    """
    raw: list[dict] = []
    for t in scene_changes:
        raw.append({"timestamp": round(t, 3), "source": "scene_detect", "run_duration": None})
    for r in runs:
        if r.duration < min_run:
            continue
        raw.append({
            "timestamp": round(r.start_t, 3),
            "source": "phash_run",
            "run_duration": round(r.duration, 1),
        })

    raw.sort(key=lambda x: x["timestamp"])

    deduped: list[dict] = []
    for c in raw:
        if deduped and c["timestamp"] - deduped[-1]["timestamp"] <= DEDUP_PROXIMITY:
            # Prefer phash_run entries (they carry run_duration metadata).
            if c["source"] == "phash_run" and deduped[-1]["source"] == "scene_detect":
                deduped[-1] = c
            continue
        deduped.append(c)
    return deduped


# --- top-level ------------------------------------------------------------


def discover(
    target: str,
    work_dir: Path,
    *,
    scene_threshold: float = DEFAULT_SCENE_THRESHOLD,
    phash_threshold: int = DEFAULT_PHASH_THRESHOLD,
    min_run: float = DEFAULT_MIN_RUN,
) -> dict:
    """Return a manifest with discovered candidate timestamps for `target`.

    `target` is a YouTube URL/ID (downloaded via video.py) or a path to an
    existing local video file.
    """
    target_path = Path(target)
    if target_path.exists() and target_path.is_file():
        video_path = target_path
        duration = probe_duration(target_path)
    else:
        result = download(target, work_dir, skip_download=False)
        video_path = result.video_path
        duration = result.metadata.duration_seconds if result.metadata else None

    if video_path is None:
        raise RuntimeError(f"no video file resolved for {target!r}")

    scene_changes = scene_detect(video_path, scene_threshold)
    thumbs = extract_thumbnails(video_path, work_dir / "discover-thumbs")
    runs = group_runs(thumbs, phash_threshold)
    candidates = union_candidates(scene_changes, runs, min_run)

    return {
        "video_path": str(video_path),
        "duration_seconds": duration,
        "thresholds": {
            "scene": scene_threshold,
            "phash": phash_threshold,
            "min_run": min_run,
        },
        "sources": {
            "scene_detect": [round(t, 3) for t in scene_changes],
            "phash_runs": [
                {
                    "start_t": round(r.start_t, 3),
                    "end_t": round(r.end_t, 3),
                    "duration": round(r.duration, 1),
                    "phash": r.phash,
                }
                for r in runs
                if r.duration >= min_run
            ],
        },
        "candidates": candidates,
    }


def main() -> int:
    p = argparse.ArgumentParser(
        description="Discover candidate timestamps via ffmpeg scene-detect + per-second pHash runs.",
    )
    p.add_argument("target", help="YouTube URL/ID or path to a local video file")
    p.add_argument(
        "-o", "--output-dir",
        type=Path,
        default=Path("./screenshotter-output"),
        help="Working directory for the cached video + thumbnail dir (default: ./screenshotter-output)",
    )
    p.add_argument(
        "--threshold-scene",
        type=float,
        default=DEFAULT_SCENE_THRESHOLD,
        help=f"ffmpeg scene-change threshold 0..1 (default {DEFAULT_SCENE_THRESHOLD})",
    )
    p.add_argument(
        "--threshold-phash",
        type=int,
        default=DEFAULT_PHASH_THRESHOLD,
        help=f"Hamming distance for pHash run-grouping (default {DEFAULT_PHASH_THRESHOLD})",
    )
    p.add_argument(
        "--min-run",
        type=float,
        default=DEFAULT_MIN_RUN,
        help=f"Minimum run duration in seconds to count as a candidate (default {DEFAULT_MIN_RUN})",
    )
    args = p.parse_args()

    try:
        manifest = discover(
            args.target,
            args.output_dir,
            scene_threshold=args.threshold_scene,
            phash_threshold=args.threshold_phash,
            min_run=args.min_run,
        )
    except (yt_dlp.utils.DownloadError, RuntimeError, OSError, subprocess.CalledProcessError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1

    print(json.dumps(manifest, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
