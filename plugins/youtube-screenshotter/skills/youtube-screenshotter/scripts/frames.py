#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = []
# ///
"""Extract frames from a video at given timestamps via ffmpeg.

Importable as `from frames import extract_frames` or runnable as a CLI:
    frames.py <video> -t 1.0 -t 5.0 -t 10.0 [-o DIR]

Filenames are 't<ms>.png' so the same timestamp re-extracted hits a cache.
"""

import argparse
import json
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path


@dataclass
class Frame:
    timestamp: float
    path: Path


def extract_one(video_path: Path, timestamp: float, output_path: Path) -> Frame:
    """Extract a single frame at the given timestamp; raises on ffmpeg failure."""
    cmd = [
        "ffmpeg",
        "-ss", f"{timestamp}",
        "-i", str(video_path),
        "-frames:v", "1",
        "-update", "1",
        "-y",
        "-loglevel", "error",
        str(output_path),
    ]
    result = subprocess.run(cmd, capture_output=True, text=True, check=False)
    if result.returncode != 0:
        raise RuntimeError(
            f"ffmpeg failed (code {result.returncode}) at t={timestamp}: {result.stderr.strip()}"
        )
    return Frame(timestamp=timestamp, path=output_path)


def extract_frames(
    video_path: Path,
    timestamps: list[float],
    output_dir: Path,
) -> list[Frame]:
    """Extract one frame per timestamp into output_dir; cached by timestamp."""
    output_dir.mkdir(parents=True, exist_ok=True)
    frames = []
    for ts in timestamps:
        ms = int(round(ts * 1000))
        out = output_dir / f"t{ms:08d}.png"
        if out.exists():
            frames.append(Frame(timestamp=ts, path=out))
            continue
        frames.append(extract_one(video_path, ts, out))
    return frames


def main() -> int:
    p = argparse.ArgumentParser(description="Extract video frames at given timestamps.")
    p.add_argument("video", type=Path, help="Path to the video file")
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
        default=Path("./frames"),
        help="Directory to write frames into (default: ./frames)",
    )
    args = p.parse_args()

    if not args.video.exists():
        print(f"video not found: {args.video}", file=sys.stderr)
        return 1

    try:
        frames = extract_frames(args.video, args.timestamp, args.output_dir)
    except (RuntimeError, OSError) as exc:
        print(str(exc), file=sys.stderr)
        return 1

    print(json.dumps(
        [{"timestamp": f.timestamp, "path": str(f.path)} for f in frames],
        indent=2,
    ))
    return 0


if __name__ == "__main__":
    sys.exit(main())
