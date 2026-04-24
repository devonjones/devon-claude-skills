#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["youtube-transcript-api>=1.0.0"]
# ///
"""Extract a transcript from a YouTube video.

Usage:
    get_transcript.py <video_id_or_url> [--timestamps] [--lang LANG] [-o PATH]
"""

import argparse
import re
import sys
from pathlib import Path

from youtube_transcript_api import YouTubeTranscriptApi

VIDEO_ID_RE = re.compile(
    r"(?:youtube\.com/watch\?v=|youtu\.be/|youtube\.com/embed/|youtube\.com/v/|youtube\.com/shorts/)([a-zA-Z0-9_-]{11})"
    r"|^([a-zA-Z0-9_-]{11})$"
)


def extract_video_id(url_or_id: str) -> str:
    m = VIDEO_ID_RE.search(url_or_id)
    if not m:
        raise ValueError(f"Could not extract a YouTube video ID from: {url_or_id}")
    return m.group(1) or m.group(2)


def format_timestamp(seconds: float) -> str:
    h, rem = divmod(int(seconds), 3600)
    m, s = divmod(rem, 60)
    return f"{h:02d}:{m:02d}:{s:02d}" if h else f"{m:02d}:{s:02d}"


def fetch(video_id: str, lang: str | None) -> list:
    api = YouTubeTranscriptApi()
    if lang:
        return api.fetch(video_id, languages=[lang]).snippets
    return api.fetch(video_id).snippets


def render(snippets: list, with_timestamps: bool) -> str:
    if with_timestamps:
        return "\n".join(f"[{format_timestamp(s.start)}] {s.text}" for s in snippets)
    return "\n".join(s.text for s in snippets)


def main() -> int:
    p = argparse.ArgumentParser(description="Get YouTube video transcript")
    p.add_argument("video", help="YouTube video URL or 11-char video ID")
    p.add_argument("-t", "--timestamps", action="store_true", help="Include [MM:SS]/[HH:MM:SS] timestamps")
    p.add_argument("--lang", help="Preferred transcript language code (e.g. 'en')")
    p.add_argument(
        "-o",
        "--output",
        help="Write to PATH instead of stdout. Use '-' for stdout. "
        "If omitted, prints to stdout.",
    )
    args = p.parse_args()

    try:
        video_id = extract_video_id(args.video)
        text = render(fetch(video_id, args.lang), args.timestamps)
    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
        return 1

    if args.output and args.output != "-":
        Path(args.output).write_text(text + "\n", encoding="utf-8")
        print(f"Wrote transcript to {args.output} ({len(text)} chars)", file=sys.stderr)
    else:
        print(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
