"""Reviewer-validation pipeline: mine PR review threads to score the agent
reviewers that gate this project's quality.

The PR review loop (the `pr-review-loop` skill) is the operator's main quality
gate. Every reviewer finding is POSTED as a PR line comment stamped
`<!-- Agent: <name> -->`, with a threaded disposition reply (Fixed / Addressed /
Acknowledged / Won't fix / Withdrawn / Out of scope). So the durable, attributable
record lives on GitHub — this is a GitHub miner, not a session-log miner.

Stages:
  R1 distill  — paginate repo-wide review comments via `gh`, reconstruct threads,
                classify (reviewer, severity, disposition) per finding. Cached.
  R2 synth    — aggregate per-reviewer scorecards (volume, acceptance rate —
                both value-based and fix-strict — false-positive/reopen rates).
  (R3 taste cross-ref + R4 Opus roster proposals build on these.)
"""

from __future__ import annotations

import glob as _glob
import json
import os
import re
import subprocess
from collections import defaultdict

from . import config

REVIEW_OUT = config.subdir("reviews")
RAW_DIR = os.path.join(REVIEW_OUT, "raw")
HARVEST_FILE = os.path.join(REVIEW_OUT, "harvest.jsonl")

LOGS_DIR = config.project_log_dir()
# Full subagent transcripts under /tmp are cleared ON REBOOT (not a rolling
# window) — so capture is best-effort. The durable sources are the dream-marker
# stream (markers/) and the log <result> blocks; the cron just grabs /tmp
# transcripts opportunistically before the next reboot.
TMP_TASK_GLOB = os.path.join(
    "/tmp/claude-*", os.path.basename(LOGS_DIR), "*/tasks/*.output"
)

_PR_IN_DESC = re.compile(r"\bPR\s*#?(\d+)\b|#(\d+)\b", re.I)
_NOTIF_SUMMARY = re.compile(r'<summary>Agent "([^"]+)" completed</summary>')
_NOTIF_TASKID = re.compile(r"<task-id>([^<]+)</task-id>")
_NOTIF_RESULT = re.compile(r"<result>(.*?)</result>", re.S)

_AGENT_SIG = re.compile(r"<!--\s*Agent:\s*([^\s>]+)\s*-->")
_CLAUDE_PREFIX = re.compile(r"🤖\s*\*\*Claude Code\*\*\s*\(([^)]+)\)")
# Agent names are kebab-case tokens; reject prose that leaks through a loose
# regex match (e.g. a finding body captured inside parentheses).
_VALID_NAME = re.compile(r"^[a-z][a-z0-9]*(-[a-z0-9]+)*$")
_SEVERITY = re.compile(r"\bP([1-3])\b")
_GEMINI_BADGE = re.compile(r"!\[(critical|high|medium|low)\]")

# Disposition classification from a reply body (checked in priority order).
_DISPOSITIONS = [
    ("withdrawn", re.compile(r"\bwithdrawn\b|validator refuted|\binvalid\b", re.I)),
    ("wont_fix", re.compile(r"\bwon'?t[\s-]?fix\b|\bwontfix\b", re.I)),
    ("out_of_scope", re.compile(r"\bout[\s-]?of[\s-]?scope\b", re.I)),
    ("fixed", re.compile(r"^\W*fixed\b", re.I)),
    ("addressed", re.compile(r"^\W*addressed\b", re.I)),
    ("acknowledged", re.compile(r"^\W*(acknowledged|ack\b|good catch)", re.I)),
]

# Buckets for the two acceptance metrics (see synth()).
VALUE_ACCEPT = {"fixed", "addressed", "acknowledged", "out_of_scope"}
FIXSTRICT_ACCEPT = {"fixed", "addressed"}
REJECT = {"wont_fix", "withdrawn"}


def _gh(path: str) -> list:
    out = subprocess.run(
        ["gh", "api", path], capture_output=True, text=True, timeout=60
    )
    if out.returncode != 0:
        raise RuntimeError(f"gh api {path} failed: {out.stderr[:200]}")
    return json.loads(out.stdout)


def fetch_review_comments(echo=lambda *_: None) -> list[dict]:
    """Paginate every PR review (line) comment in the repo, caching to one file.
    Each call re-fetches all pages from scratch (no incremental cursor) — fine at
    this scale, and a re-run naturally picks up edits and new comments."""
    os.makedirs(RAW_DIR, exist_ok=True)
    repo = config.repo_slug()
    if not repo:
        raise RuntimeError("could not determine repo (set $DREAM_REPO)")
    cache = os.path.join(RAW_DIR, "review_comments.json")
    all_c: list[dict] = []
    page = 1
    while True:
        chunk = _gh(
            f"/repos/{repo}/pulls/comments?per_page=100&page={page}"
            f"&sort=created&direction=asc"
        )
        all_c.extend(chunk)
        if page % 5 == 0:
            echo(f"  [page {page}]  {len(all_c)} comments")
        if len(chunk) < 100:
            break
        page += 1
    with open(cache, "w") as fh:
        json.dump(all_c, fh)
    echo(f"fetched {len(all_c)} review comments across {page} pages")
    return all_c


def _reviewer_of(c: dict) -> str | None:
    """Identify the reviewer that authored a finding comment (None if this is a
    disposition reply / human prose, not an attributable finding)."""
    body = c.get("body", "")
    m = _AGENT_SIG.search(body) or _CLAUDE_PREFIX.search(body)
    if m:
        name = m.group(1).strip()
        return name if _VALID_NAME.match(name) else None
    login = (c.get("user") or {}).get("login", "")
    if "gemini" in login:
        return "gemini"
    if "cursor" in login:
        return "cursor"
    return None


def _severity_of(body: str) -> str | None:
    m = _SEVERITY.search(body)
    if m:
        return f"P{m.group(1)}"
    m = _GEMINI_BADGE.search(body)
    if m:
        return {"critical": "P1", "high": "P2", "medium": "P2", "low": "P3"}[m.group(1)]
    return None


def _disposition_of(body: str) -> str | None:
    for name, rx in _DISPOSITIONS:
        if rx.search(body):
            return name
    return None


def build_findings(comments: list[dict]) -> list[dict]:
    """Reconstruct threads → one record per finding with its disposition."""
    by_id = {c["id"]: c for c in comments}
    replies: dict[int, list[dict]] = defaultdict(list)
    for c in comments:
        rid = c.get("in_reply_to_id")
        if rid:
            replies[rid].append(c)

    findings: list[dict] = []
    for c in comments:
        if c.get("in_reply_to_id"):
            continue  # a reply, not a finding root
        reviewer = _reviewer_of(c)
        if not reviewer:
            continue  # human prose root or unattributable
        body = c.get("body", "")
        thread = sorted(replies.get(c["id"], []), key=lambda r: r.get("created_at", ""))
        disposition = "unresolved"
        reopened = False
        for r in thread:
            rb = r.get("body", "")
            if re.search(r"\breopening\b", rb, re.I):
                reopened = True
                continue
            d = _disposition_of(rb)
            if d:
                disposition = d  # last decisive reply wins
        pr = (c.get("pull_request_url") or "").rstrip("/").split("/")[-1]
        findings.append(
            {
                "pr": pr,
                "comment_id": c["id"],
                "reviewer": reviewer,
                "severity": _severity_of(body),
                "path": c.get("path"),
                "line": c.get("line"),
                "created_at": c.get("created_at"),
                "disposition": disposition,
                "reopened": reopened,
                "n_replies": len(thread),
                "body": " ".join(body.split())[:240],
            }
        )
    return findings


def distill(echo=lambda *_: None, *, refresh: bool = False) -> list[dict]:
    cache = os.path.join(RAW_DIR, "review_comments.json")
    if not refresh and os.path.exists(cache):
        with open(cache) as fh:
            comments = json.load(fh)
        echo(f"using cached {len(comments)} review comments (--refresh to re-pull)")
    else:
        comments = fetch_review_comments(echo)
    findings = build_findings(comments)
    os.makedirs(REVIEW_OUT, exist_ok=True)
    with open(os.path.join(REVIEW_OUT, "findings.json"), "w") as fh:
        json.dump(findings, fh, indent=2)
    return findings


def _rate(num: int, den: int) -> float | None:
    return round(num / den, 3) if den else None


def synth(findings: list[dict]) -> dict:
    per = defaultdict(lambda: defaultdict(int))
    prs = defaultdict(set)
    sev = defaultdict(lambda: defaultdict(int))
    for f in findings:
        r = f["reviewer"]
        per[r]["findings"] += 1
        per[r][f["disposition"]] += 1
        if f["reopened"]:
            per[r]["reopened"] += 1
        # Taste signal — only the marker stream records WHO dispositioned
        # (the operator vs the orchestrator). GitHub can't tell them apart.
        if f.get("disposition_by") == "user":
            per[r]["taste_user"] += 1
        if f["severity"]:
            sev[r][f["severity"]] += 1
        prs[r].add(f["pr"])

    cards = []
    for r, d in per.items():
        resolved = sum(d[k] for k in (VALUE_ACCEPT | REJECT))
        value_acc = sum(d[k] for k in VALUE_ACCEPT)
        fix_acc = sum(d[k] for k in FIXSTRICT_ACCEPT)
        cards.append(
            {
                "reviewer": r,
                "findings": d["findings"],
                "prs": len(prs[r]),
                "acceptance_value": _rate(value_acc, resolved),
                "acceptance_fixstrict": _rate(fix_acc, resolved),
                "false_positive_rate": _rate(d["withdrawn"], d["findings"]),
                "wont_fix_rate": _rate(d["wont_fix"], d["findings"]),
                "unresolved_rate": _rate(d["unresolved"], d["findings"]),
                "reopened": d["reopened"],
                "taste_user": d["taste_user"],
                "dispositions": {
                    k: d[k]
                    for k in (
                        "fixed", "addressed", "acknowledged", "out_of_scope",
                        "wont_fix", "withdrawn", "unresolved",
                    )
                    if d[k]
                },
                "severity": dict(sev[r]),
            }
        )
    cards.sort(key=lambda c: -c["findings"])
    return {
        "schema": "dream.reviewers.v1",
        "total_findings": len(findings),
        "reviewer_count": len(cards),
        "scorecards": cards,
    }


# --------------------------------------------------------------------------
# Three finding sources, in order of fidelity:
#   1. MARKERS  — dream-marker stream producers (pr-review-loop) write to
#      .dream/markers/*.jsonl. Complete, durable, records disposition_by (taste).
#      The authoritative going-forward source (see read_markers).
#   2. GITHUB   — posted PR-comment findings (distill/synth). Biased: the loop
#      historically skipped posting, so this under-counts.
#   3. LOGS     — coverage (every Agent spawn — unbiased firing record) and
#      harvest (findings from <task-notification><result> blocks + /tmp
#      transcripts). Backfill for un-instrumented history. /tmp is cleared ON
#      REBOOT, so harvest opportunistically; markers are the durable answer.
# --------------------------------------------------------------------------


def _canonical_reviewers() -> set[str]:
    """Known reviewer names — from the GitHub scorecards if built, plus the 6
    plugin defaults. Used to normalize free-text Agent descriptions."""
    defaults = {
        "code-reviewer", "silent-failure-hunter", "pr-test-analyzer",
        "comment-analyzer", "type-design-analyzer", "code-simplifier",
    }
    names = set(defaults)
    sc = os.path.join(REVIEW_OUT, "scorecards.json")
    if os.path.exists(sc):
        with open(sc) as fh:
            names |= {c["reviewer"] for c in json.load(fh).get("scorecards", [])}
    # Keep only reviewer-shaped names — excludes stray tokens like "verify"
    # (the /verify skill) that leaked in via a single GitHub finding.
    return {n for n in names if n.endswith("-reviewer") or n in defaults}


def _match_reviewer(desc: str, canon: set[str]) -> str | None:
    """Longest canonical name (or its base) appearing in an Agent description."""
    d = desc.lower()
    best = None
    for name in canon:
        base = name[:-9] if name.endswith("-reviewer") else name
        for probe in (name, base):
            if re.search(rf"\b{re.escape(probe)}\b", d) and (
                best is None or len(probe) > len(best[1])
            ):
                best = (name, probe)
    return best[0] if best else None


def _pr_of(desc: str) -> str | None:
    m = _PR_IN_DESC.search(desc)
    if m:
        return m.group(1) or m.group(2)
    return None


def _iter_log_lines():
    for f in sorted(_glob.glob(os.path.join(LOGS_DIR, "*.jsonl"))):
        with open(f, encoding="utf-8") as fh:
            for line in fh:
                if line.strip():
                    yield f, line


def coverage_from_logs() -> dict:
    """Per-reviewer firing coverage: spawns, distinct PRs, time span."""
    canon = _canonical_reviewers()
    per = defaultdict(lambda: {"spawns": 0, "prs": set(), "first": None, "last": None})
    for _f, line in _iter_log_lines():
        if '"tool_use"' not in line:
            continue
        try:
            d = json.loads(line)
        except Exception:
            continue
        if d.get("type") != "assistant":
            continue
        ts = d.get("timestamp")
        msg = d.get("message")
        if not isinstance(msg, dict):
            continue
        content = msg.get("content")
        if not isinstance(content, list):
            continue
        for b in content:
            if not isinstance(b, dict) or b.get("type") != "tool_use":
                continue
            if b.get("name") not in ("Agent", "Task"):
                continue
            desc = (b.get("input", {}) or {}).get("description", "") or ""
            rev = _match_reviewer(desc, canon)
            if not rev:
                continue
            e = per[rev]
            e["spawns"] += 1
            pr = _pr_of(desc)
            if pr:
                e["prs"].add(pr)
            if ts:
                e["first"] = min(e["first"] or ts, ts)
                e["last"] = max(e["last"] or ts, ts)
    rows = [
        {
            "reviewer": r,
            "spawns": e["spawns"],
            "prs": len(e["prs"]),
            "first_seen": e["first"],
            "last_seen": e["last"],
        }
        for r, e in per.items()
    ]
    rows.sort(key=lambda x: -x["spawns"])
    return {"schema": "dream.coverage.v1", "reviewers": rows,
            "total_spawns": sum(r["spawns"] for r in rows)}


def _looks_clean(result: str) -> bool:
    head = result[:500].lower()
    return bool(
        re.search(r"no issues|looks clean|all .*clean|no findings|^\s*\[\]\s*$", head)
    )


def harvest(echo=lambda *_: None) -> dict:
    """Append durable reviewer findings to harvest.jsonl (idempotent by task-id).

    Sources: (1) <task-notification><result> blocks in session logs (durable),
    (2) /tmp full subagent transcripts (ephemeral — captured while present)."""
    os.makedirs(REVIEW_OUT, exist_ok=True)
    seen: set[str] = set()
    if os.path.exists(HARVEST_FILE):
        with open(HARVEST_FILE) as fh:
            for line in fh:
                try:
                    seen.add(json.loads(line)["task_id"])
                except Exception:
                    pass

    canon = _canonical_reviewers()
    new = []
    for _f, line in _iter_log_lines():
        if "task-notification" not in line:
            continue
        try:
            d = json.loads(line)
        except Exception:
            continue
        m = d.get("message", {})
        c = m.get("content") if isinstance(m, dict) else None
        txt = c if isinstance(c, str) else (json.dumps(c) if c else "")
        sm = _NOTIF_SUMMARY.search(txt)
        if not sm:
            continue
        rev = _match_reviewer(sm.group(1), canon)
        if not rev:
            continue
        tid_m = _NOTIF_TASKID.search(txt)
        tid = tid_m.group(1) if tid_m else None
        if not tid or tid in seen:
            continue
        res_m = _NOTIF_RESULT.search(txt)
        result = (res_m.group(1).strip() if res_m else "")
        rec = {
            "task_id": tid,
            "reviewer": rev,
            "pr": _pr_of(sm.group(1)),
            "clean": _looks_clean(result),
            "result": result[:4000],
            "source": "log-notification",
        }
        seen.add(tid)
        new.append(rec)

    # /tmp full transcripts: enrich by task-id (richer than the result summary).
    tmp_by_id = {}
    for p in _glob.glob(TMP_TASK_GLOB):
        tmp_by_id[os.path.basename(p)[:-7]] = p  # strip ".output"
    tmp_captured = 0
    for rec in new:
        path = tmp_by_id.get(rec["task_id"])
        if path:
            try:
                rec["tmp_transcript_bytes"] = os.path.getsize(path)
                rec["source"] = "log-notification+tmp"
                tmp_captured += 1
            except Exception:
                pass

    with open(HARVEST_FILE, "a") as fh:
        for rec in new:
            fh.write(json.dumps(rec) + "\n")
    echo(
        f"harvest: +{len(new)} new findings ({tmp_captured} with /tmp transcript); "
        f"{len(seen)} total in {HARVEST_FILE}"
    )
    return {"new": len(new), "total": len(seen), "tmp_captured": tmp_captured}


# --------------------------------------------------------------------------
# MARKER consumer — the authoritative going-forward source.
# --------------------------------------------------------------------------


def read_markers() -> list[dict]:
    """Read the dream-marker stream (.dream/markers/*.jsonl) and normalize each
    reviewer-finding marker into the finding shape `synth` consumes. See
    references/MARKER-CONTRACT.md for the schema producers honor."""
    findings: list[dict] = []
    for path in sorted(_glob.glob(os.path.join(config.markers_dir(), "*.jsonl"))):
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    m = json.loads(line)
                except Exception:
                    continue
                if m.get("kind") != "reviewer-finding":
                    continue  # non-reviewer markers belong to the session miner
                if not m.get("reviewer"):
                    continue
                findings.append(
                    {
                        "pr": str(m.get("pr", "")),
                        "reviewer": m["reviewer"],
                        "severity": m.get("severity"),
                        "path": m.get("file"),
                        "line": m.get("line"),
                        "created_at": m.get("ts"),
                        "disposition": m.get("disposition", "unresolved"),
                        "disposition_by": m.get("disposition_by"),
                        "reopened": bool(m.get("reopened")),
                        "n_replies": 0,
                        "body": (m.get("finding") or "")[:240],
                        "source": "marker",
                    }
                )
    return findings


def load_findings(source: str = "all") -> list[dict]:
    """Unified finding loader. source: markers | github | all (markers+github)."""
    out: list[dict] = []
    if source in ("markers", "all"):
        out += read_markers()
    if source in ("github", "all"):
        fpath = os.path.join(REVIEW_OUT, "findings.json")
        if os.path.exists(fpath):
            with open(fpath) as fh:
                out += json.load(fh)
    return out
