#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["Pillow>=10.1"]
# ///
"""Compose frames into grids; tile an extract.py manifest into labeled contact sheets.

A 3x3 sheet lets a reviewer triage nine candidate frames in one image read
instead of nine. Each cell is labeled `#<n> <MM:SS>` with the frame's index
in the manifest and its timestamp.

CLI:
    grid.py <extract-manifest.json> -o OUT_DIR [--cols 3] [--rows 3] [--max-width 1920]

Writes OUT_DIR/sheet-NN.jpg and prints JSON: one {sheet, cells} object per
sheet, each cell {label, timestamp, frame_path}.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

DEFAULT_COLS = 3
DEFAULT_ROWS = 3
DEFAULT_MAX_WIDTH = 1920  # cells are scaled so the grid fits this width


def compose_sprite_grid(
    frame_paths: list[Path],
    out_path: Path,
    *,
    cols: int = DEFAULT_COLS,
    max_width: int = DEFAULT_MAX_WIDTH,
    labels: list[str] | None = None,
) -> None:
    """Composite frames into a rows x cols grid in reading order.

    Cells keep the first frame's aspect ratio; a short last row is left black.
    `labels`, if given, are drawn in each cell's top-left corner. The output
    format follows `out_path`'s suffix, PNG when it has none.
    """
    if not frame_paths:
        raise ValueError("no frames to compose")
    images = [Image.open(p).convert("RGB") for p in frame_paths]
    rows = (len(images) + cols - 1) // cols
    src_w, src_h = images[0].size
    cell_w = max_width // cols
    cell_h = round(cell_w * src_h / src_w)
    sprite = Image.new("RGB", (cell_w * cols, cell_h * rows), color=(0, 0, 0))
    draw = ImageDraw.Draw(sprite)
    font = ImageFont.load_default(size=max(16, cell_h // 12))
    for i, img in enumerate(images):
        x, y = (i % cols) * cell_w, (i // cols) * cell_h
        sprite.paste(img.resize((cell_w, cell_h), Image.LANCZOS), (x, y))
        if labels:
            box = draw.textbbox((x + 6, y + 6), labels[i], font=font)
            draw.rectangle((box[0] - 4, box[1] - 4, box[2] + 4, box[3] + 4), fill=(0, 0, 0))
            draw.text((x + 6, y + 6), labels[i], fill=(255, 255, 0), font=font)
    sprite.save(out_path, format=None if out_path.suffix else "PNG", optimize=True)


def format_ts(seconds: float) -> str:
    h, rem = divmod(int(seconds), 3600)
    return f"{h}:{rem // 60:02d}:{rem % 60:02d}" if h else f"{rem // 60:02d}:{rem % 60:02d}"


def contact_sheets(entries: list[dict], out_dir: Path, *, cols: int, rows: int, max_width: int) -> list[dict]:
    out_dir.mkdir(parents=True, exist_ok=True)
    per_sheet = cols * rows
    sheets = []
    for start in range(0, len(entries), per_sheet):
        chunk = entries[start:start + per_sheet]
        cells = [{"label": f"#{start + i + 1} {format_ts(e['timestamp'])}",
                  "timestamp": e["timestamp"], "frame_path": e["frame_path"]}
                 for i, e in enumerate(chunk)]
        sheet = out_dir / f"sheet-{start // per_sheet + 1:02d}.jpg"
        compose_sprite_grid([Path(c["frame_path"]) for c in cells], sheet,
                            cols=cols, max_width=max_width, labels=[c["label"] for c in cells])
        sheets.append({"sheet": str(sheet.resolve()), "cells": cells})
    return sheets


def main() -> int:
    p = argparse.ArgumentParser(description="Tile an extract.py manifest into labeled contact sheets.")
    p.add_argument("manifest", type=Path, help="extract.py manifest JSON")
    p.add_argument("-o", "--output-dir", type=Path, required=True, help="where sheet-NN.jpg go")
    p.add_argument("--cols", type=int, default=DEFAULT_COLS)
    p.add_argument("--rows", type=int, default=DEFAULT_ROWS)
    p.add_argument("--max-width", type=int, default=DEFAULT_MAX_WIDTH)
    args = p.parse_args()
    if min(args.cols, args.rows) < 1 or args.max_width < args.cols:
        p.error("--cols and --rows must be >= 1 and --max-width >= --cols")

    try:
        data = json.loads(args.manifest.read_text(encoding="utf-8"))
        entries = data.get("entries") if isinstance(data, dict) else None
        if not entries or not isinstance(entries, list):
            raise ValueError(f"no entries in {args.manifest}")
        sheets = contact_sheets(entries, args.output_dir, cols=args.cols, rows=args.rows,
                                max_width=args.max_width)
    except (OSError, ValueError, KeyError, TypeError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    print(json.dumps(sheets, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
