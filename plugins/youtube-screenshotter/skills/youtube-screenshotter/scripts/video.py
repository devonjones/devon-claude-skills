#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["yt-dlp"]
# ///
"""Download a YouTube video at 720p and emit metadata.

Foundation for the youtube-screenshotter sampling pipeline. Importable as
`from video import download` or runnable as a CLI for manual testing:

    video.py <url-or-id> [-o DIR] [--no-download]
"""

import argparse
import json
import sys
from dataclasses import asdict, dataclass, field
from pathlib import Path

import yt_dlp


@dataclass
class Chapter:
    title: str
    start_time: float
    end_time: float


@dataclass
class VideoMetadata:
    video_id: str
    source_url: str
    source_title: str
    source_author: str           # channel display name
    source_published_date: str   # YYYY-MM-DD or "" if unknown
    channel: str                 # mirror of source_author for in-context clarity
    channel_id: str              # stable handle, survives channel renames
    duration_seconds: int
    description: str = ""        # author-written video description verbatim
    chapter_markers: list[Chapter] = field(default_factory=list)
    playlist_id: str | None = None
    playlist_title: str | None = None


@dataclass
class DownloadResult:
    video_path: Path | None  # None when --no-download
    metadata: VideoMetadata


def _to_iso_date(yyyymmdd: str) -> str:
    return f"{yyyymmdd[:4]}-{yyyymmdd[4:6]}-{yyyymmdd[6:8]}" if len(yyyymmdd) == 8 else ""


def _parse_metadata(info: dict) -> VideoMetadata:
    chapters_raw = info.get("chapters") or []
    chapters = [
        Chapter(
            title=c.get("title", ""),
            start_time=float(c.get("start_time", 0)),
            end_time=float(c.get("end_time", 0)),
        )
        for c in chapters_raw
    ]
    return VideoMetadata(
        video_id=info["id"],
        source_url=info.get("webpage_url", ""),
        source_title=info.get("title", ""),
        source_author=info.get("uploader", "") or info.get("channel", ""),
        source_published_date=_to_iso_date(info.get("upload_date", "")),
        channel=info.get("channel", "") or info.get("uploader", ""),
        channel_id=info.get("channel_id", ""),
        duration_seconds=int(info.get("duration") or 0),
        description=info.get("description", "") or "",
        chapter_markers=chapters,
        playlist_id=info.get("playlist_id"),
        playlist_title=info.get("playlist_title"),
    )


def download(url: str, output_dir: Path, *, skip_download: bool = False) -> DownloadResult:
    """Download a video at 720p (or best available below) and return path + metadata.

    With skip_download=True, only metadata is fetched — useful for testing or
    for the synthesizer to populate frontmatter before deciding to do frame work.
    """
    output_dir.mkdir(parents=True, exist_ok=True)
    output_template = str(output_dir / "%(id)s.%(ext)s")

    ydl_opts = {
        "format": "bestvideo[height<=720]+bestaudio/best[height<=720]/best",
        "outtmpl": output_template,
        "merge_output_format": "mp4",
        "quiet": True,
        "no_warnings": True,
        "noplaylist": True,
        "nooverwrites": True,
        "skip_download": skip_download,
    }

    with yt_dlp.YoutubeDL(ydl_opts) as ydl:
        info = ydl.extract_info(url, download=not skip_download)
        prepared_path = Path(ydl.prepare_filename(info))

    metadata = _parse_metadata(info)

    if skip_download:
        return DownloadResult(video_path=None, metadata=metadata)

    if prepared_path.exists():
        return DownloadResult(video_path=prepared_path, metadata=metadata)

    # Fallback: post-merge extension can differ from prepare_filename's prediction.
    candidates = sorted(output_dir.glob(f"{metadata.video_id}.*"))
    media = [p for p in candidates if p.suffix.lower() in {".mp4", ".mkv", ".webm"}]
    if not media:
        raise RuntimeError(f"download finished but no media file matches {metadata.video_id}.*")
    return DownloadResult(video_path=media[0], metadata=metadata)


def main() -> int:
    p = argparse.ArgumentParser(description="Download a YouTube video and emit metadata.")
    p.add_argument("url", help="YouTube video URL or 11-char video ID")
    p.add_argument(
        "-o", "--output-dir",
        type=Path,
        default=Path("./downloads"),
        help="Directory to write the video file into (default: ./downloads)",
    )
    p.add_argument(
        "--no-download",
        action="store_true",
        help="Fetch metadata only, skip the video download (for testing/debugging)",
    )
    args = p.parse_args()

    try:
        result = download(args.url, args.output_dir, skip_download=args.no_download)
    except (yt_dlp.utils.DownloadError, RuntimeError, OSError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1

    print(json.dumps(
        {
            "video_path": str(result.video_path) if result.video_path else None,
            "metadata": asdict(result.metadata),
        },
        indent=2,
    ))
    return 0


if __name__ == "__main__":
    sys.exit(main())
