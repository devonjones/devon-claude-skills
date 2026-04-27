#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["yt-dlp", "imagehash>=4.3", "Pillow>=10"]
# ///
"""Unified screenshotter extract command.

Given a YouTube URL + a list of timestamps, download the video (if not
already cached), extract frames at those timestamps, compute pHashes, and
emit a single manifest JSON. Designed to be called multiple times during
the synthesizer's bisection loop — repeated invocations on the same video
hit the download cache, and repeated timestamps hit the frame cache.

CLI:
    extract.py <url-or-id> -t 1.0 -t 5.0 -t 10.0 [-o DIR]

The output dir holds the merged video file (named '<video_id>.mp4') and
a 'frames/' subdir of 't<ms>.png' frame caches.
"""

import argparse
import json
import sys
from dataclasses import asdict
from pathlib import Path

# Allow sibling imports when run via 'uv run --script' from any cwd.
sys.path.insert(0, str(Path(__file__).parent))

import yt_dlp  # noqa: E402

from frames import extract_frames  # noqa: E402
from phash import compute as phash_compute  # noqa: E402
from video import download  # noqa: E402


def extract(url: str, timestamps: list[float], output_dir: Path) -> dict:
    """Download (or reuse) video, extract frames, compute pHashes; return manifest.

    yt-dlp's `nooverwrites=True` (set in video.py) makes a re-invocation a
    metadata-extract call only — the actual file isn't re-downloaded. So this
    function makes one network round-trip whether or not the video is cached.
    """
    timestamps = sorted(set(timestamps))
    output_dir.mkdir(parents=True, exist_ok=True)
    result = download(url, output_dir, skip_download=False)

    frames_dir = output_dir / "frames"
    frames = extract_frames(result.video_path, timestamps, frames_dir)

    entries = [
        {
            "timestamp": f.timestamp,
            "frame_path": str(f.path),
            "phash": str(phash_compute(f.path)),
        }
        for f in frames
    ]

    return {
        "video_path": str(result.video_path),
        "metadata": asdict(result.metadata),
        "entries": entries,
    }


def main() -> int:
    p = argparse.ArgumentParser(
        description="Download a YouTube video and extract frames + pHashes at given timestamps."
    )
    p.add_argument("url", help="YouTube video URL or 11-char video ID")
    p.add_argument(
        "-t", "--timestamp",
        type=float,
        action="append",
        required=True,
        help="Timestamp in seconds (repeatable: -t 0 -t 1 -t 5)",
    )
    p.add_argument(
        "-o", "--output-dir",
        type=Path,
        default=Path("./screenshotter-output"),
        help="Working directory for the cached video + frame dir (default: ./screenshotter-output)",
    )
    args = p.parse_args()

    try:
        manifest = extract(args.url, args.timestamp, args.output_dir)
    except (yt_dlp.utils.DownloadError, RuntimeError, OSError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1

    print(json.dumps(manifest, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
