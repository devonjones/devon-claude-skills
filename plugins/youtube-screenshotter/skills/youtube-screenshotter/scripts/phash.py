#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["imagehash>=4.3", "Pillow>=10"]
# ///
"""Perceptual-hash pre-filter for the screenshotter pipeline.

Three-band classifier on Hamming distance between 64-bit pHashes:
    same       - frames are visually identical (drop without LLM call)
    different  - frames are clearly different (keep without LLM call)
    ambiguous  - middle band, defer to vision-LLM judge

Importable: `from phash import compute, classify_pair`
CLI:
    phash.py compute <image>
    phash.py compare <image-a> <image-b> [--same-max N --different-min M]
"""

import argparse
import sys
from pathlib import Path
from typing import Literal

import imagehash
from PIL import Image

# Default thresholds for 64-bit pHash. Tuneable per-video-class via the
# kwargs on classify_pair() if some genres need different sensitivity.
SAME_MAX = 5
DIFFERENT_MIN = 20

Verdict = Literal["same", "different", "ambiguous"]


def compute(image_path: Path) -> imagehash.ImageHash:
    with Image.open(image_path) as img:
        return imagehash.phash(img)


def hamming(a: imagehash.ImageHash, b: imagehash.ImageHash) -> int:
    return a - b


def classify_pair(
    a: imagehash.ImageHash,
    b: imagehash.ImageHash,
    *,
    same_max: int = SAME_MAX,
    different_min: int = DIFFERENT_MIN,
) -> Verdict:
    distance = hamming(a, b)
    if distance <= same_max:
        return "same"
    if distance >= different_min:
        return "different"
    return "ambiguous"


def main() -> int:
    p = argparse.ArgumentParser(description="Compute / compare perceptual hashes.")
    sub = p.add_subparsers(dest="cmd", required=True)

    c_compute = sub.add_parser("compute", help="Print the pHash of one image")
    c_compute.add_argument("image", type=Path)

    c_compare = sub.add_parser("compare", help="Hamming distance + verdict for a pair")
    c_compare.add_argument("a", type=Path)
    c_compare.add_argument("b", type=Path)
    c_compare.add_argument("--same-max", type=int, default=SAME_MAX)
    c_compare.add_argument("--different-min", type=int, default=DIFFERENT_MIN)

    args = p.parse_args()

    if args.cmd == "compute":
        print(str(compute(args.image)))
        return 0

    ha = compute(args.a)
    hb = compute(args.b)
    d = hamming(ha, hb)
    v = classify_pair(ha, hb, same_max=args.same_max, different_min=args.different_min)
    print(f"hamming={d} verdict={v}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
