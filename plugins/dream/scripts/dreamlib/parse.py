"""Parse Claude Code session JSONL into a normalized turn sequence.

A session file is one JSON object per line. We care about the `user` and
`assistant` events (the conversation) plus a little session metadata; the rest
(file-history-snapshot, attachment, pr-link, mode, ...) is mostly noise for
behavioral mining, though we surface pr-link provenance.

Nothing here calls a model — this layer is deterministic and cheap.
"""

from __future__ import annotations

import hashlib
import json
import re
from dataclasses import dataclass, field

# Prefixes / wrappers that mark a string-content user event as harness noise
# (slash-command invocations, command stdout, injected reminders) rather than a
# real human turn.
_TAG_BLOCK = re.compile(
    r"<system-reminder>.*?</system-reminder>"
    r"|<command-[a-z-]+>.*?</command-[a-z-]+>"
    r"|<local-command-[a-z-]+>.*?</local-command-[a-z-]+>"
    r"|<bash-[a-z-]+>.*?</bash-[a-z-]+>",
    re.S,
)
_STRAY_TAG = re.compile(r"<[^>]{1,40}>")

_NOISE_PREFIXES = (
    "Caveat:",
    "[Request interrupted",
    "This session is being continued",
    "Your task is to create a detailed summary",
)

DENIAL_MARKERS = ("doesn't want to proceed", "tool use was rejected")


def clean_user_text(s: str) -> str:
    """Strip harness wrappers from a string-content user event.

    Returns the residual human prose (possibly empty if the event was pure
    harness noise).
    """
    s = _TAG_BLOCK.sub(" ", s)
    s = _STRAY_TAG.sub(" ", s)
    # collapse whitespace
    s = re.sub(r"[ \t]+", " ", s)
    s = re.sub(r"\n{3,}", "\n\n", s).strip()
    return s


@dataclass
class Event:
    idx: int
    type: str  # 'user' | 'assistant'
    role: str
    uuid: str
    parent: str | None
    ts: str | None
    # content, normalized:
    text: str = ""  # human/assistant prose (no thinking, no tool noise)
    blocks: list = field(default_factory=list)  # raw content blocks
    is_real_user: bool = False  # a genuine human turn (not harness noise)
    tool_uses: list = field(default_factory=list)  # [(id, name, input)]
    tool_results: list = field(default_factory=list)  # [(id, is_error, content)]


@dataclass
class Session:
    session_id: str
    path: str
    input_hash: str
    git_branch: str | None
    started_at: str | None
    ended_at: str | None
    version: str | None
    events: list = field(default_factory=list)
    tool_names: dict = field(default_factory=dict)  # tool_use_id -> name
    pr_links: list = field(default_factory=list)


def _stringify(content) -> str:
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts = []
        for b in content:
            if isinstance(b, dict) and b.get("type") == "text":
                parts.append(b.get("text", ""))
        return "\n".join(parts)
    return ""


def load_session(path: str) -> Session:
    with open(path, "rb") as fh:
        raw = fh.read()
    input_hash = hashlib.sha256(raw).hexdigest()[:16]

    session_id = None
    git_branch = None
    version = None
    started = ended = None
    events: list[Event] = []
    tool_names: dict = {}
    pr_links: list = []

    idx = 0
    for line in raw.splitlines():
        if not line.strip():
            continue
        try:
            d = json.loads(line)
        except Exception:
            continue

        t = d.get("type")
        session_id = session_id or d.get("sessionId")
        git_branch = git_branch or d.get("gitBranch")
        version = version or d.get("version")
        ts = d.get("timestamp")
        if ts:
            started = started or ts
            ended = ts

        if t == "pr-link":
            url = d.get("url") or d.get("prUrl") or d.get("pr")
            if url:
                pr_links.append(url)
            continue

        if t not in ("user", "assistant"):
            continue

        m = d.get("message", {})
        if not isinstance(m, dict):
            continue
        role = m.get("role", t)
        content = m.get("content")

        ev = Event(
            idx=idx,
            type=t,
            role=role,
            uuid=d.get("uuid", ""),
            parent=d.get("parentUuid"),
            ts=ts,
        )
        idx += 1

        if isinstance(content, list):
            ev.blocks = content
            for b in content:
                if not isinstance(b, dict):
                    continue
                bt = b.get("type")
                if bt == "tool_use":
                    tid = b.get("id", "")
                    name = b.get("name", "?")
                    tool_names[tid] = name
                    ev.tool_uses.append((tid, name, b.get("input", {})))
                elif bt == "tool_result":
                    rc = b.get("content")
                    rc_str = rc if isinstance(rc, str) else json.dumps(rc)[:2000]
                    ev.tool_results.append(
                        (b.get("tool_use_id", ""), bool(b.get("is_error")), rc_str)
                    )
            ev.text = _stringify(content)
        elif isinstance(content, str):
            if t == "user":
                cleaned = clean_user_text(content)
                ev.text = cleaned
                noise = (not cleaned) or any(
                    cleaned.startswith(p) for p in _NOISE_PREFIXES
                )
                ev.is_real_user = not noise
            else:
                ev.text = content

        events.append(ev)

    return Session(
        session_id=session_id or path,
        path=path,
        input_hash=input_hash,
        git_branch=git_branch,
        started_at=started,
        ended_at=ended,
        version=version,
        events=events,
        tool_names=tool_names,
        pr_links=pr_links,
    )
