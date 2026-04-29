#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["opencv-python-headless>=4.9", "numpy>=1.26", "Pillow>=10"]
# ///
"""Motion-bisection primitive: detect progressive animation and score frames by subject-centeredness.

Per-second pHash run-grouping (in `discover.py`) merges sequences where only a
small object moves across an otherwise-static background — the global pHash
stays within threshold because most pixels don't change. This script complements
that by analysing the optical flow inside a sub-range and:

1. Flagging whether the range contains *sustained* directional motion (vs. a
   static reveal where pHash would also drift).
2. Scoring each densely-sampled frame by how centered+complete the moving
   subject is, so a downstream picker can prefer the moment where the boat is
   in the middle of the river over the moment it's at the edge.

The score formula follows the design in bd 7h0:

    mag        = ||flow||_2  per pixel
    mask       = mag > threshold
    largest CC = single biggest connected component of mask
    score      = area * (1 - centre_distance_norm) * edge_penalty

`edge_penalty` is 0.2 if the component bbox touches the frame edge, else 1.0.

CLI:
    motion.py <video> --start S --end E [-o DIR] [--fps 4] [--flow-threshold 1.0]

Output: JSON manifest to stdout with per-sample scores and a best-candidate.
"""

from __future__ import annotations

import argparse
import json
import math
import subprocess
import sys
import tempfile
from dataclasses import asdict, dataclass
from pathlib import Path

import cv2  # type: ignore
import numpy as np
from PIL import Image

# Allow sibling imports when run via `uv run --script` from any cwd.
sys.path.insert(0, str(Path(__file__).parent))
from frames import extract_frames as _extract_full_res  # noqa: E402


DEFAULT_FPS = 4
DEFAULT_FLOW_THRESHOLD = 1.0
DEFAULT_MIN_AREA = 200  # pixels at the working resolution
DEFAULT_PROGRESSIVE_MIN_SAMPLES = 3
DEFAULT_SPRITE_FRAMES = 4


@dataclass
class Sample:
    timestamp: float
    motion_area: int
    centeredness: float | None  # 1.0 = centroid at frame center, 0.0 = at corner
    bbox: tuple[int, int, int, int] | None  # x, y, w, h (None if no motion)
    touches_edge: bool | None
    score: float


def extract_frames(
    video_path: Path,
    start: float,
    end: float,
    fps: float,
    out_dir: Path,
) -> list[tuple[float, Path]]:
    """Dense-sample the [start, end) range at `fps` frames per second.

    Returns sorted (timestamp, path) pairs. Uses ffmpeg with input-side seeking
    for performance; output is downscaled to width 320 for cheap flow compute.
    """
    out_dir.mkdir(parents=True, exist_ok=True)
    for stale in out_dir.glob("motion_*.png"):
        stale.unlink()
    pattern = str(out_dir / "motion_%05d.png")
    duration = end - start
    cmd = [
        "ffmpeg",
        "-hide_banner",
        "-loglevel", "error",
        "-nostdin",
        "-ss", f"{start:.3f}",
        "-i", str(video_path),
        "-t", f"{duration:.3f}",
        "-vf", f"fps={fps},scale=320:-2",
        "-y",
        pattern,
    ]
    subprocess.run(cmd, check=True)
    files = sorted(out_dir.glob("motion_*.png"))
    return [(start + i / fps, p) for i, p in enumerate(files)]


def score_frame(
    prev_gray: np.ndarray,
    cur_gray: np.ndarray,
    flow_threshold: float,
    min_area: int,
) -> tuple[int, float | None, tuple[int, int, int, int] | None, bool | None, float]:
    """Compute motion area + centeredness + score for a consecutive frame pair.

    Returns (area, centeredness, bbox, touches_edge, score).
    """
    flow = cv2.calcOpticalFlowFarneback(
        prev_gray, cur_gray, None,
        pyr_scale=0.5, levels=3, winsize=15, iterations=3,
        poly_n=5, poly_sigma=1.2, flags=0,
    )
    mag = np.linalg.norm(flow, axis=2)
    mask = (mag > flow_threshold).astype(np.uint8)

    nlabels, _labels, stats, centroids = cv2.connectedComponentsWithStats(mask)
    if nlabels < 2:
        return 0, None, None, None, 0.0

    # Component 0 is background; pick the largest non-background component.
    largest = 1 + int(np.argmax(stats[1:, cv2.CC_STAT_AREA]))
    area = int(stats[largest, cv2.CC_STAT_AREA])
    if area < min_area:
        return 0, None, None, None, 0.0

    x = int(stats[largest, cv2.CC_STAT_LEFT])
    y = int(stats[largest, cv2.CC_STAT_TOP])
    w = int(stats[largest, cv2.CC_STAT_WIDTH])
    h = int(stats[largest, cv2.CC_STAT_HEIGHT])
    cx, cy = centroids[largest]

    h_frame, w_frame = mask.shape
    touches_edge = bool(x <= 0 or y <= 0 or x + w >= w_frame or y + h >= h_frame)

    # Normalised centroid distance: 0 at frame center, 1 at corner.
    half_w, half_h = w_frame / 2, h_frame / 2
    center_dist = math.hypot(cx - half_w, cy - half_h) / math.hypot(half_w, half_h)
    centeredness = 1.0 - center_dist

    edge_penalty = 0.2 if touches_edge else 1.0
    score = area * centeredness * edge_penalty

    return area, centeredness, (x, y, w, h), touches_edge, score


def analyse_range(
    video_path: Path,
    start: float,
    end: float,
    *,
    fps: float = DEFAULT_FPS,
    flow_threshold: float = DEFAULT_FLOW_THRESHOLD,
    min_area: int = DEFAULT_MIN_AREA,
    progressive_min_samples: int = DEFAULT_PROGRESSIVE_MIN_SAMPLES,
    out_dir: Path | None = None,
) -> dict:
    """Run motion analysis over [start, end). Returns a JSON-serialisable manifest."""
    if end <= start:
        raise ValueError(f"end ({end}) must be > start ({start})")

    use_temp = out_dir is None
    if use_temp:
        tmp = tempfile.mkdtemp(prefix="motion-")
        out_dir = Path(tmp)
    else:
        out_dir = Path(out_dir)

    try:
        frame_pairs = extract_frames(video_path, start, end, fps, out_dir)
        if len(frame_pairs) < 2:
            return {
                "video_path": str(video_path),
                "range": {"start": start, "end": end},
                "fps": fps,
                "samples": [],
                "best_candidate": None,
                "has_progressive_motion": False,
                "warning": "fewer than 2 frames extracted",
            }

        samples: list[Sample] = []
        prev_gray: np.ndarray | None = None
        prev_t: float | None = None

        for t, path in frame_pairs:
            img = cv2.imread(str(path), cv2.IMREAD_GRAYSCALE)
            if img is None:
                continue
            if prev_gray is None:
                # First frame — no motion to score yet.
                samples.append(Sample(
                    timestamp=t, motion_area=0, centeredness=None,
                    bbox=None, touches_edge=None, score=0.0,
                ))
            else:
                area, centeredness, bbox, touches_edge, score = score_frame(
                    prev_gray, img, flow_threshold, min_area,
                )
                # Tag motion at the *current* timestamp (motion happens between
                # prev_t and t; we associate it with t since the subject is in
                # the new position there).
                samples.append(Sample(
                    timestamp=t, motion_area=area, centeredness=centeredness,
                    bbox=bbox, touches_edge=touches_edge, score=score,
                ))
            prev_gray, prev_t = img, t

        # Progressive-motion heuristic: ≥ N consecutive samples with motion_area >= min_area.
        moving = [s.motion_area >= min_area for s in samples]
        run, longest_run = 0, 0
        for m in moving:
            run = run + 1 if m else 0
            longest_run = max(longest_run, run)
        has_progressive_motion = longest_run >= progressive_min_samples

        # Best candidate = sample with max score (only if any score > 0).
        best = max(samples, key=lambda s: s.score)
        best_candidate = None
        if best.score > 0:
            best_candidate = {
                "timestamp": round(best.timestamp, 3),
                "score": round(best.score, 1),
                "centeredness": round(best.centeredness or 0, 3),
                "motion_area": best.motion_area,
                "touches_edge": best.touches_edge,
            }

        # Sprite timestamps: N evenly-spaced points across the motion-active
        # span, so a downstream composer can render the whole arc as one image.
        sprite_timestamps = _sprite_pick(samples, min_area, DEFAULT_SPRITE_FRAMES)

        return {
            "video_path": str(video_path),
            "range": {"start": round(start, 3), "end": round(end, 3)},
            "fps": fps,
            "params": {
                "flow_threshold": flow_threshold,
                "min_area": min_area,
                "progressive_min_samples": progressive_min_samples,
            },
            "samples": [_sample_dict(s) for s in samples],
            "best_candidate": best_candidate,
            "sprite_timestamps": sprite_timestamps,
            "has_progressive_motion": has_progressive_motion,
            "longest_motion_run": longest_run,
        }
    finally:
        if use_temp:
            for p in out_dir.glob("motion_*.png"):
                p.unlink()
            out_dir.rmdir()


def _sprite_pick(samples: list[Sample], min_area: int, n_frames: int) -> list[float]:
    """Pick N evenly-spaced timestamps across the motion-active range.

    Definition of motion-active: from the first sample with motion_area >=
    min_area to the last such sample. If fewer than 2 active samples exist,
    return an empty list (the caller will skip sprite composition).
    """
    active = [s for s in samples if s.motion_area >= min_area]
    if len(active) < 2:
        return []
    start_t, end_t = active[0].timestamp, active[-1].timestamp
    if n_frames < 2 or end_t <= start_t:
        return [round(start_t, 3)]
    step = (end_t - start_t) / (n_frames - 1)
    return [round(start_t + i * step, 3) for i in range(n_frames)]


def compose_sprite_strip(frame_paths: list[Path], out_path: Path) -> None:
    """Composite an ordered list of full-res frames into a horizontal strip PNG.

    All frames are pasted at their original resolution; the output width is the
    sum of their widths and the height is the max of their heights (frames are
    top-aligned). Mismatched heights are padded with black.
    """
    if not frame_paths:
        raise ValueError("no frames to compose")
    images = [Image.open(p).convert("RGB") for p in frame_paths]
    total_w = sum(img.width for img in images)
    max_h = max(img.height for img in images)
    sprite = Image.new("RGB", (total_w, max_h), color=(0, 0, 0))
    x = 0
    for img in images:
        sprite.paste(img, (x, 0))
        x += img.width
    sprite.save(out_path, format="PNG", optimize=True)


def _sample_dict(s: Sample) -> dict:
    d = asdict(s)
    d["timestamp"] = round(d["timestamp"], 3)
    if d["centeredness"] is not None:
        d["centeredness"] = round(d["centeredness"], 3)
    d["score"] = round(d["score"], 1)
    return d


def main() -> int:
    p = argparse.ArgumentParser(
        description="Motion-bisection: score densely-sampled frames in a video range by subject-centeredness.",
    )
    p.add_argument("video", type=Path, help="path to a local video file")
    p.add_argument("--start", type=float, required=True, help="range start, seconds")
    p.add_argument("--end", type=float, required=True, help="range end, seconds")
    p.add_argument("-o", "--output-dir", type=Path, default=None, help="dir for sampled thumbnails (temp dir if omitted)")
    p.add_argument("--fps", type=float, default=DEFAULT_FPS, help=f"resample fps (default {DEFAULT_FPS})")
    p.add_argument("--flow-threshold", type=float, default=DEFAULT_FLOW_THRESHOLD, help=f"per-pixel flow magnitude threshold (default {DEFAULT_FLOW_THRESHOLD})")
    p.add_argument("--min-area", type=int, default=DEFAULT_MIN_AREA, help=f"min connected-component area in pixels (default {DEFAULT_MIN_AREA})")
    p.add_argument("--progressive-min-samples", type=int, default=DEFAULT_PROGRESSIVE_MIN_SAMPLES, help=f"min consecutive moving samples to call it progressive motion (default {DEFAULT_PROGRESSIVE_MIN_SAMPLES})")
    p.add_argument("--sprite-out", type=Path, default=None, help="if set, write a horizontal sprite-strip PNG of N evenly-spaced frames across the motion-active span")
    p.add_argument("--sprite-frames", type=int, default=DEFAULT_SPRITE_FRAMES, help=f"number of frames in the sprite strip (default {DEFAULT_SPRITE_FRAMES})")
    args = p.parse_args()

    if not args.video.is_file():
        print(f"error: {args.video} is not a file", file=sys.stderr)
        return 1

    try:
        manifest = analyse_range(
            args.video, args.start, args.end,
            fps=args.fps,
            flow_threshold=args.flow_threshold,
            min_area=args.min_area,
            progressive_min_samples=args.progressive_min_samples,
            out_dir=args.output_dir,
        )

        if args.sprite_out is not None:
            timestamps = manifest.get("sprite_timestamps") or []
            if not timestamps:
                print("warning: no motion-active samples; sprite not written", file=sys.stderr)
            else:
                # Re-extract the chosen timestamps at full source resolution and
                # composite into a horizontal strip. Cache the per-frame PNGs in
                # the same dir as the output sprite so a re-run reuses them.
                sprite_dir = args.sprite_out.parent / f".{args.sprite_out.stem}-frames"
                sprite_dir.mkdir(parents=True, exist_ok=True)
                if args.sprite_frames != DEFAULT_SPRITE_FRAMES:
                    # Recompute under the requested frame count.
                    timestamps = _resample_sprite_timestamps(timestamps, args.sprite_frames)
                full_res = _extract_full_res(args.video, timestamps, sprite_dir)
                compose_sprite_strip([f.path for f in full_res], args.sprite_out)
                manifest["sprite_path"] = str(args.sprite_out)
                manifest["sprite_timestamps"] = timestamps

    except (RuntimeError, OSError, ValueError, subprocess.CalledProcessError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1

    print(json.dumps(manifest, indent=2))
    return 0


def _resample_sprite_timestamps(existing: list[float], n_frames: int) -> list[float]:
    """Recompute N evenly-spaced timestamps spanning the same range as `existing`."""
    if not existing or n_frames < 1:
        return []
    if n_frames == 1 or len(existing) == 1:
        return [existing[0]]
    start, end = existing[0], existing[-1]
    step = (end - start) / (n_frames - 1)
    return [round(start + i * step, 3) for i in range(n_frames)]


if __name__ == "__main__":
    sys.exit(main())
