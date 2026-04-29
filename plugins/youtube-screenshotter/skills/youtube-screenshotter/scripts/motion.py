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
DEFAULT_SPRITE_FRAMES = 9    # Brady-Bunch 3x3 by default
DEFAULT_SPRITE_COLS = 3
DEFAULT_SPRITE_MAX_WIDTH = 1920  # final composite cap; cells scaled to fit


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


SPIKE_RATIO = 3.0  # leading sample is a static-reveal spike if its area > SPIKE_RATIO × the next sample's
CUT_RATIO = 1.5    # trailing sample is a scene-cut spike if its area > CUT_RATIO × the predecessor's
CLUSTER_GAP_SAMPLES = 4  # consecutive quiet samples that split one cluster from the next


def _is_static_reveal_spike(active: list[Sample]) -> bool:
    """A leading sample is a one-frame fade-in spike (e.g., a diagram appearing
    in place) when its motion_area dwarfs the immediately following samples.
    Picking this frame as the first sprite cell wastes a slot on near-empty
    canvas — the diagram has finished rendering by the very next sample.
    """
    if len(active) < 2:
        return False
    a0 = active[0].motion_area
    next_areas = [s.motion_area for s in active[1:4]]
    if not next_areas:
        return False
    median_next = sorted(next_areas)[len(next_areas) // 2]
    return median_next > 0 and a0 > SPIKE_RATIO * median_next


def _is_trailing_cut_spike(active: list[Sample]) -> bool:
    """A trailing sample is a scene-cut spike when its motion_area noticeably
    exceeds the rolling median of the recent samples. A natural animation
    end decays smoothly; a hard cut to a new scene shows up as one big-flow
    frame because every pixel between the last surplus-lord sample and the
    first presenter sample is different. Picking that frame as the last
    sprite cell renders the start of the next scene, not the animation we
    wanted.

    Compare against a rolling median (last 5 samples excluding the trailing
    one) rather than the immediate predecessor — single-frame jitter in
    busy animations can momentarily double the per-frame area without being
    a cut, so the median smooths that out.
    """
    if len(active) < 6:
        return False
    window = sorted(s.motion_area for s in active[-6:-1])
    median = window[len(window) // 2]
    return median > 0 and active[-1].motion_area > CUT_RATIO * median


def _split_clusters(samples: list[Sample], min_area: int, gap: int) -> list[list[Sample]]:
    """Group motion-active samples into clusters separated by `gap` or more
    consecutive quiet samples (motion_area < min_area). A cluster is the
    natural unit of one animation; a downstream scene break (e.g. cut to a
    new chapter title card) shows up as a quiet gap and gets split off.
    """
    clusters: list[list[Sample]] = []
    current: list[Sample] = []
    quiet_run = 0
    for s in samples:
        if s.motion_area >= min_area:
            if current and quiet_run >= gap:
                clusters.append(current)
                current = []
            current.append(s)
            quiet_run = 0
        else:
            quiet_run += 1
    if current:
        clusters.append(current)
    return clusters


def _sprite_pick(samples: list[Sample], min_area: int, n_frames: int) -> list[float]:
    """Pick N evenly-spaced timestamps across the largest motion cluster.

    A cluster is one continuous animation; quiet gaps split clusters so a
    scene break in the supplied range doesn't bleed into the sprite grid.
    Within the chosen cluster, a leading static-reveal spike (one big sample
    followed by sustained smaller ones — e.g., a diagram fading in) is
    dropped so the first sprite cell isn't near-empty canvas.

    If no cluster has ≥ 2 samples after spike trim, return an empty list
    (the caller skips sprite composition).
    """
    clusters = _split_clusters(samples, min_area, CLUSTER_GAP_SAMPLES)
    if not clusters:
        return []
    # Pick the largest cluster — multi-cluster spans (rare but possible) get
    # only their dominant animation; the caller can re-invoke per cluster if
    # they want grids for the others.
    cluster = max(clusters, key=len)
    if _is_static_reveal_spike(cluster):
        cluster = cluster[1:]
    if _is_trailing_cut_spike(cluster):
        cluster = cluster[:-1]
    if len(cluster) < 2:
        return []
    start_t, end_t = cluster[0].timestamp, cluster[-1].timestamp
    if n_frames < 2 or end_t <= start_t:
        return [round(start_t, 3)]
    step = (end_t - start_t) / (n_frames - 1)
    return [round(start_t + i * step, 3) for i in range(n_frames)]


def pick_grid_shape(n_frames: int, preferred_cols: int = DEFAULT_SPRITE_COLS) -> tuple[int, int]:
    """Choose (cols, rows) for an n-frame grid. Square-ish so a 4-step
    build-up reads as 2x2 rather than a lopsided 3x2-with-one-empty-cell.
    Falls back to `preferred_cols` once n exceeds `preferred_cols^2`.
    """
    if n_frames <= 1:
        return (1, 1)
    if n_frames <= 4:
        return (2, 2)
    if n_frames <= 6:
        return (3, 2)
    if n_frames <= preferred_cols * preferred_cols:
        return (preferred_cols, preferred_cols)
    cols = preferred_cols
    rows = (n_frames + cols - 1) // cols
    return (cols, rows)


def compose_sprite_grid(
    frame_paths: list[Path],
    out_path: Path,
    *,
    cols: int = DEFAULT_SPRITE_COLS,
    max_width: int = DEFAULT_SPRITE_MAX_WIDTH,
) -> None:
    """Composite frames into a Brady-Bunch grid (rows × cols), reading order.

    Each cell is scaled so the total grid width is ≤ `max_width`; the cell
    height is derived from the source frame's aspect ratio. Frames are
    pasted in time order, left-to-right then top-to-bottom. If the frame
    count isn't a perfect multiple of `cols`, the trailing cells in the last
    row are left black.
    """
    if not frame_paths:
        raise ValueError("no frames to compose")
    images = [Image.open(p).convert("RGB") for p in frame_paths]
    rows = (len(images) + cols - 1) // cols
    src_w, src_h = images[0].size
    cell_w = max_width // cols
    # Preserve source aspect ratio in cells.
    cell_h = round(cell_w * src_h / src_w)
    total_w = cell_w * cols
    total_h = cell_h * rows
    sprite = Image.new("RGB", (total_w, total_h), color=(0, 0, 0))
    for i, img in enumerate(images):
        scaled = img.resize((cell_w, cell_h), Image.LANCZOS)
        col = i % cols
        row = i // cols
        sprite.paste(scaled, (col * cell_w, row * cell_h))
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
    p.add_argument("--sprite-out", type=Path, default=None, help="if set, write a Brady-Bunch grid PNG of N evenly-spaced frames across the motion-active span")
    p.add_argument("--sprite-frames", type=int, default=DEFAULT_SPRITE_FRAMES, help=f"number of frames in the sprite grid (default {DEFAULT_SPRITE_FRAMES} for a 3x3 layout)")
    p.add_argument("--sprite-cols", type=int, default=DEFAULT_SPRITE_COLS, help=f"grid columns; rows derived from N/cols (default {DEFAULT_SPRITE_COLS})")
    p.add_argument("--sprite-max-width", type=int, default=DEFAULT_SPRITE_MAX_WIDTH, help=f"max output width in pixels; cells scaled to fit (default {DEFAULT_SPRITE_MAX_WIDTH})")
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
                compose_sprite_grid(
                    [f.path for f in full_res],
                    args.sprite_out,
                    cols=args.sprite_cols,
                    max_width=args.sprite_max_width,
                )
                manifest["sprite_path"] = str(args.sprite_out)
                manifest["sprite_timestamps"] = timestamps
                manifest["sprite_layout"] = {
                    "cols": args.sprite_cols,
                    "rows": (len(timestamps) + args.sprite_cols - 1) // args.sprite_cols,
                    "frames": len(timestamps),
                }

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
