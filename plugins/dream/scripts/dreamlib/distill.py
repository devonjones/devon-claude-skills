"""Stage 1 heuristic distillation: a Session -> compact behavioral digest.

The deterministic half of stage 1. It extracts *friction* (the ore we actually
want) without a model:

  - denials   : user rejected a tool use (strong correction signal)
  - error     : a tool_result came back is_error
  - correction: a real human turn that pushes back ("no", "actually", ...)

It also collects the human turns and an assistant "decision skeleton", then
renders a bounded transcript suitable for handing to a local model (stage 1b).
"""

from __future__ import annotations

import re

from .parse import DENIAL_MARKERS, Event, Session

# Correction keywords near the start of a human turn. Deliberately conservative;
# the model pass catches softer redirects.
_CORRECTION = re.compile(
    r"\b(no|nope|don'?t|do not|stop|actually|instead|wrong|revert|undo|"
    r"that'?s not|not quite|incorrect|never|avoid|rather)\b",
    re.I,
)

# Caps to keep the model input bounded even for an 85MB session.
MAX_USER_TURNS = 50
MAX_FRICTION = 80
MAX_DECISIONS = 40
TRUNC = 280


def _truncate(s: str, n: int = TRUNC) -> str:
    s = " ".join(s.split())
    return s if len(s) <= n else s[: n - 1] + "…"


def _dedupe_friction(friction: list[dict]) -> list[dict]:
    """Collapse friction with identical (kind, payload) into one + occurrences.

    A standing instruction repeated across an autonomous loop should read as one
    recurring directive (occurrences=N) — frequency is signal, not 20 rows of
    noise. Order is preserved by first appearance.
    """
    seen: dict[tuple, dict] = {}
    out: list[dict] = []
    for f in friction:
        key = (f["kind"], f.get("user_said", ""), f.get("detail", ""))
        if key in seen:
            seen[key]["occurrences"] += 1
        else:
            f = {**f, "occurrences": 1}
            seen[key] = f
            out.append(f)
    return out


def _extract_user_correction(denial_text: str) -> str:
    """Pull the embedded 'the user said:' instruction out of a denial blob."""
    m = re.search(r"the user said:\s*(.+)", denial_text, re.I | re.S)
    if m:
        return _truncate(m.group(1), 400)
    return ""


def heuristic_digest(session: Session) -> dict:
    events: list[Event] = session.events

    user_turns: list[dict] = []
    decisions: list[str] = []
    friction: list[dict] = []
    tool_counts: dict[str, int] = {}

    def prev_assistant_action(i: int) -> str:
        """One-line summary of what the assistant was doing just before i."""
        for j in range(i - 1, max(-1, i - 6), -1):
            ev = events[j]
            if ev.type == "assistant":
                if ev.tool_uses:
                    tid, name, inp = ev.tool_uses[-1]
                    detail = ""
                    if isinstance(inp, dict):
                        detail = inp.get("command") or inp.get("file_path") or ""
                    return f"{name}({_truncate(str(detail), 80)})"
                if ev.text:
                    return _truncate(ev.text, 100)
        return ""

    for i, ev in enumerate(events):
        # tool usage tally
        for _tid, name, _inp in ev.tool_uses:
            tool_counts[name] = tool_counts.get(name, 0) + 1

        # assistant decision skeleton (stated plans / explanations)
        if ev.type == "assistant" and ev.text.strip():
            decisions.append(_truncate(ev.text))

        # friction: tool_result errors + denials live on user events
        for tid, is_error, content in ev.tool_results:
            if any(mk in content for mk in DENIAL_MARKERS):
                friction.append(
                    {
                        "kind": "denial",
                        "ts": ev.ts,
                        "after": prev_assistant_action(i),
                        "user_said": _extract_user_correction(content),
                    }
                )
            elif is_error:
                tool = session.tool_names.get(tid, "?")
                friction.append(
                    {
                        "kind": "error",
                        "ts": ev.ts,
                        "tool": tool,
                        "detail": _truncate(content, 200),
                    }
                )

        # friction: real human pushback
        if ev.is_real_user and ev.text:
            head = ev.text[:160]
            if _CORRECTION.search(head):
                friction.append(
                    {
                        "kind": "correction",
                        "ts": ev.ts,
                        "after": prev_assistant_action(i),
                        "user_said": _truncate(ev.text, 400),
                    }
                )
            user_turns.append({"ts": ev.ts, "text": _truncate(ev.text, 400)})

    friction = _dedupe_friction(friction)

    denials = sum(1 for f in friction if f["kind"] == "denial")
    errors = sum(1 for f in friction if f["kind"] == "error")
    corrections = sum(1 for f in friction if f["kind"] == "correction")

    return {
        "session_id": session.session_id,
        "source_file": session.path.split("/")[-1],
        "input_hash": session.input_hash,
        "git_branch": session.git_branch,
        "started_at": session.started_at,
        "ended_at": session.ended_at,
        "version": session.version,
        "pr_links": session.pr_links[:20],
        "stats": {
            "events": len(events),
            "user_turns": len(user_turns),
            "assistant_turns": len(decisions),
            "tool_calls": sum(tool_counts.values()),
            "denials": denials,
            "errors": errors,
            "corrections": corrections,
        },
        "tools_used": dict(
            sorted(tool_counts.items(), key=lambda kv: -kv[1])
        ),
        "user_turns": user_turns[:MAX_USER_TURNS],
        "friction": friction[:MAX_FRICTION],
        "decisions_sample": decisions[:MAX_DECISIONS],
    }


def build_model_input(h: dict) -> str:
    """Render a heuristic digest into a bounded transcript for the model pass."""
    lines: list[str] = []
    lines.append(
        f"SESSION branch={h.get('git_branch')} "
        f"started={h.get('started_at')} ended={h.get('ended_at')}"
    )
    s = h["stats"]
    lines.append(
        f"STATS user_turns={s['user_turns']} tool_calls={s['tool_calls']} "
        f"denials={s['denials']} errors={s['errors']} corrections={s['corrections']}"
    )
    top_tools = ", ".join(f"{k}={v}" for k, v in list(h["tools_used"].items())[:8])
    lines.append(f"TOOLS {top_tools}")

    lines.append("\nHUMAN TURNS (chronological):")
    for i, u in enumerate(h["user_turns"], 1):
        lines.append(f"{i}. {u['text']}")

    lines.append("\nFRICTION EVENTS (where things went wrong / got corrected):")
    for f in h["friction"]:
        rep = f" (x{f['occurrences']})" if f.get("occurrences", 1) > 1 else ""
        if f["kind"] == "denial":
            lines.append(
                f"- DENIAL{rep}: user rejected `{f.get('after','')}` "
                f"| said: {f.get('user_said','')}"
            )
        elif f["kind"] == "correction":
            lines.append(
                f"- CORRECTION{rep} after `{f.get('after','')}` "
                f"| user: {f.get('user_said','')}"
            )
        elif f["kind"] == "error":
            lines.append(f"- ERROR{rep} [{f.get('tool','?')}]: {f.get('detail','')}")

    lines.append("\nASSISTANT DECISION SKELETON (stated plans/explanations):")
    for d in h["decisions_sample"]:
        lines.append(f"- {d}")

    return "\n".join(lines)
