#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["PyYAML>=6"]
# ///
"""Check that an entry's body prose is the transcript, word for word.

Compares the words of the chapter prose (every `##` section except TL;DR,
Key takeaways, References and Commands & Code) against the transcript.
Case, punctuation, apostrophes and paragraph breaks are ignored; any other
difference must match a logged `transcript_corrections` entry in the
entry's frontmatter. Image embeds, fenced code blocks and a code block's
one-line lead-in (the line ending in `:` just above the fence) are skipped.

Usage:
    check_fidelity.py <transcript.txt> <entry.md>

The transcript is get_transcript.py output, with or without `-t`
timestamps; with them, each difference is reported at its timestamp.
Exit 0 when the body matches, 1 with the differences listed when it doesn't.
"""

import argparse
import difflib
import re
import sys
from pathlib import Path

import yaml

NON_PROSE_SECTIONS = {"tl;dr", "key takeaways", "references", "commands & code"}
TIMESTAMP_RE = re.compile(r"^\[(?:(\d+):)?(\d+):(\d+)\]\s*")
WORD_RE = re.compile(r"[a-z0-9]+(?:'[a-z0-9]+)*")
MAX_REPORTED = 20


def words(text: str) -> list[str]:
    return [w.replace("'", "") for w in WORD_RE.findall(text.lower().replace("’", "'"))]


def transcript_words(text: str) -> tuple[list[str], list[str]]:
    """Return the transcript's words and, per word, its line's timestamp ("" if none)."""
    out, stamps = [], []
    for line in text.splitlines():
        m = TIMESTAMP_RE.match(line)
        stamp = m.group(0).strip() if m else ""
        line_words = words(line[m.end():] if m else line)
        out += line_words
        stamps += [stamp] * len(line_words)
    return out, stamps


def split_entry(text: str) -> tuple[dict, str]:
    if text.startswith("---\n"):
        end = text.find("\n---\n", 4)
        if end != -1:
            return yaml.safe_load(text[4:end]) or {}, text[end + 5:]
    return {}, text


def body_prose(body: str) -> str:
    kept, in_prose, in_fence = [], False, False
    for line in body.splitlines():
        stripped = line.strip()
        if stripped.startswith("```"):
            while not in_fence and kept and not kept[-1].strip():
                kept.pop()
            if not in_fence and in_prose and kept and kept[-1].rstrip().endswith(":"):
                kept.pop()  # the code block's lead-in
            in_fence = not in_fence
            continue
        if in_fence:
            continue
        if line.startswith("## "):
            in_prose = stripped[3:].strip().lower() not in NON_PROSE_SECTIONS
            continue
        if in_prose and not re.fullmatch(r"!\[\[[^\]]*\]\]", stripped):
            kept.append(line)
    return "\n".join(kept)


def allowed_changes(frontmatter: dict) -> set[tuple[tuple[str, ...], tuple[str, ...]]]:
    return {
        (tuple(words(str(c.get("original", "")))), tuple(words(str(c.get("corrected", "")))))
        for c in frontmatter.get("transcript_corrections") or []
    }


def differences(transcript_text: str, entry_text: str) -> tuple[int, list[str]]:
    """Return the number of transcript words and a description of each unexplained difference."""
    src, stamps = transcript_words(transcript_text)
    frontmatter, body = split_entry(entry_text)
    dst = words(body_prose(body))
    allowed = allowed_changes(frontmatter)
    found = []
    for op, i1, i2, j1, j2 in difflib.SequenceMatcher(None, src, dst, autojunk=False).get_opcodes():
        if op == "equal" or (tuple(src[i1:i2]), tuple(dst[j1:j2])) in allowed:
            continue
        where = stamps[min(i1, len(stamps) - 1)] if stamps else ""
        found.append(f"{where or 'word ' + str(i1)}: transcript {' '.join(src[i1:i2])!r} "
                     f"-> body {' '.join(dst[j1:j2])!r}")
    return len(src), found


def main() -> int:
    p = argparse.ArgumentParser(description="Check an entry's body prose against its transcript.")
    p.add_argument("transcript", type=Path, help="get_transcript.py output (with or without -t)")
    p.add_argument("entry", type=Path, help="the entry's .md file")
    args = p.parse_args()

    try:
        total, found = differences(args.transcript.read_text(encoding="utf-8"),
                                   args.entry.read_text(encoding="utf-8"))
    except (OSError, yaml.YAMLError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1

    if total == 0:
        print(f"error: no words in transcript {args.transcript}", file=sys.stderr)
        return 1
    if not found:
        print(f"ok: body matches the transcript ({total} words)")
        return 0
    print(f"{len(found)} difference(s) not covered by transcript_corrections:", file=sys.stderr)
    for line in found[:MAX_REPORTED]:
        print(f"  {line}", file=sys.stderr)
    if len(found) > MAX_REPORTED:
        print(f"  ... and {len(found) - MAX_REPORTED} more", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
