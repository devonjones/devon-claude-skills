#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["PyYAML>=6"]
# ///
"""Check that an entry's body prose is the transcript, word for word.

Compares the words of the chapter prose (every `##` section except TL;DR,
Key takeaways, References and Commands & Code) against the transcript.
Case, punctuation, apostrophes and paragraph breaks are ignored. Each
logged `transcript_corrections` entry is applied to the transcript first, at
the occurrence of its `original` nearest its `timestamp`; any other
difference fails. Image embeds and fenced code blocks are skipped; anything
else in the prose, including a code block's lead-in, must be transcript.

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
import unicodedata
from pathlib import Path

import yaml

NON_PROSE_SECTIONS = {"tl;dr", "key takeaways", "references", "commands & code"}
TIMESTAMP_RE = re.compile(r"^\[(?:(\d+):)?(\d+):(\d+)\]\s*")
MAX_REPORTED = 20


def words(text: str) -> list[str]:
    """Split on punctuation and whitespace; letters, digits, marks and symbols are word."""
    text = unicodedata.normalize("NFC", text.lower()).replace("'", "").replace("’", "")
    return "".join(" " if unicodedata.category(ch)[0] in "PZC" else ch for ch in text).split()


def transcript_words(text: str) -> tuple[list[str], list[float | None]]:
    """Return the transcript's words and, per word, its line's timestamp in seconds."""
    out, stamps = [], []
    for line in text.splitlines():
        m = TIMESTAMP_RE.match(line)
        stamp = int(m.group(1) or 0) * 3600 + int(m.group(2)) * 60 + int(m.group(3)) if m else None
        line_words = words(line[m.end():] if m else line)
        out += line_words
        stamps += [stamp] * len(line_words)
    return out, stamps


def format_stamp(seconds: float | None) -> str:
    if seconds is None:
        return ""
    h, rem = divmod(int(seconds), 3600)
    return f"[{h:02d}:{rem // 60:02d}:{rem % 60:02d}]" if h else f"[{rem // 60:02d}:{rem % 60:02d}]"


def split_entry(text: str) -> tuple[dict, str]:
    if text.startswith("---\n"):
        end = text.find("\n---\n", 4)
        if end != -1:
            frontmatter = yaml.safe_load(text[4:end]) or {}
            if not isinstance(frontmatter, dict):
                raise ValueError("frontmatter is not a key: value mapping")
            return frontmatter, text[end + 5:]
    return {}, text


def body_prose(body: str) -> str:
    kept, in_prose, in_fence = [], False, False
    for line in body.splitlines():
        stripped = line.strip()
        if stripped.startswith("```"):
            in_fence = not in_fence
            continue
        if in_fence:
            continue
        if line.startswith("## "):
            in_prose = stripped[3:].strip().lower() not in NON_PROSE_SECTIONS
            continue
        if in_prose and not re.fullmatch(r"!\[\[[^\]]*\]\]", stripped):
            kept.append(line)
    if in_fence:
        raise ValueError("unclosed ``` code fence; the prose after it would go unchecked")
    return "\n".join(kept)


def apply_corrections(src: list[str], stamps: list, frontmatter: dict) -> None:
    """Rewrite src in place with each logged correction, at its nearest occurrence."""
    for n, c in enumerate(frontmatter.get("transcript_corrections") or [], 1):
        if not isinstance(c, dict):
            raise ValueError(f"transcript_corrections entry {n} is not an original/corrected mapping")
        orig, corr = words(str(c.get("original", ""))), words(str(c.get("corrected", "")))
        at = c.get("timestamp")
        hits = [i for i in range(len(src) - len(orig) + 1)
                if orig and src[i:i + len(orig)] == orig]
        if not corr:
            raise ValueError(f"transcript_corrections entry {n}: soft-corrects replace words, never delete them")
        if not hits:
            raise ValueError(f"transcript_corrections entry {n}: {c.get('original')!r} is not in the transcript")
        if isinstance(at, (int, float)):
            hits.sort(key=lambda i: abs(stamps[i] - at) if stamps[i] is not None else float("inf"))
        i, end = hits[0], hits[0] + len(orig)
        src[i:end], stamps[i:end] = corr, [stamps[i]] * len(corr)


def differences(transcript_text: str, entry_text: str) -> tuple[int, list[str]]:
    """Return the number of transcript words and a description of each unexplained difference."""
    src, stamps = transcript_words(transcript_text)
    frontmatter, body = split_entry(entry_text)
    total = len(src)
    apply_corrections(src, stamps, frontmatter)
    dst = words(body_prose(body))
    found = []
    for op, i1, i2, j1, j2 in difflib.SequenceMatcher(None, src, dst, autojunk=False).get_opcodes():
        if op == "equal":
            continue
        where = format_stamp(stamps[min(i1, len(stamps) - 1)]) if stamps else ""
        found.append(f"{where or 'word ' + str(i1)}: transcript {' '.join(src[i1:i2])!r} "
                     f"-> body {' '.join(dst[j1:j2])!r}")
    return total, found


def main() -> int:
    p = argparse.ArgumentParser(description="Check an entry's body prose against its transcript.")
    p.add_argument("transcript", type=Path, help="get_transcript.py output (with or without -t)")
    p.add_argument("entry", type=Path, help="the entry's .md file")
    args = p.parse_args()

    try:
        total, found = differences(args.transcript.read_text(encoding="utf-8"),
                                   args.entry.read_text(encoding="utf-8"))
    except (OSError, ValueError, yaml.YAMLError) as exc:
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
