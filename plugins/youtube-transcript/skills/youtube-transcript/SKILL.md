---
name: youtube-transcript
description: Extract transcripts from YouTube videos. Use when the user asks for a transcript, subtitles, or captions of a YouTube video and provides a YouTube URL (youtube.com/watch?v=, youtu.be/, youtube.com/shorts/, youtube.com/embed/) or an 11-character video ID. Supports plain text, timestamped output, language selection, and writing directly to a file.
---

# YouTube Transcript

Fetch auto-generated or manually-uploaded captions from a YouTube video via the `youtube-transcript-api` library (run via `uv run --script`, isolated per-invocation — no persistent install).

## Usage

```bash
# Plain transcript to stdout
scripts/get_transcript.py "<URL_OR_VIDEO_ID>"

# With timestamps
scripts/get_transcript.py "<URL_OR_VIDEO_ID>" --timestamps

# Specific language (falls back to default if unavailable)
scripts/get_transcript.py "<URL_OR_VIDEO_ID>" --lang en

# Write directly to a file
scripts/get_transcript.py "<URL_OR_VIDEO_ID>" -o transcript.txt
```

If the user doesn't specify a filename, either print to stdout or save as `<VIDEO_ID>-transcript.txt` using `-o`.

## Supported URL Formats

- `https://www.youtube.com/watch?v=VIDEO_ID`
- `https://youtu.be/VIDEO_ID`
- `https://youtube.com/embed/VIDEO_ID`
- `https://youtube.com/shorts/VIDEO_ID`
- Raw 11-character video ID

## Output Format

- **Plain** (default): one line per caption segment.
- **Timestamped** (`--timestamps`): `[MM:SS] text` (or `[HH:MM:SS]` for long videos).

## Handling the Transcript

- **Never modify the returned transcript content.** Do not paraphrase, summarize, or correct. The raw transcript is the source of truth.
- **For plain output**, you MAY reflow lines into paragraphs so sentences aren't cut mid-clause. This is cosmetic only — do not change words.
- **For timestamped output**, preserve the one-segment-per-line structure; do not reflow.

## When Captions Aren't Available

The script errors out when a video has no captions at all. Pass that error back to the user — do not fabricate a transcript.

## Prerequisites

- `uv` — installs the Python dependencies in an ephemeral venv at invocation time. Install with `curl -LsSf https://astral.sh/uv/install.sh | sh` or `pip install uv`.
- Network access to `youtube.com` (the script calls the public timedtext endpoint directly).
