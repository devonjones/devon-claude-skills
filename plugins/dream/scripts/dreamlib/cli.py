"""Dream stage-1 CLI: distill Claude Code session logs into behavioral digests.

    python -m dream.cli distill            # distill the backlog (cached)
    python -m dream.cli distill --no-model # heuristic only (fast, no ollama)
    python -m dream.cli distill --session <uuid>
    python -m dream.cli stats              # summarize existing digests

Digests are cached in digests/{session_id}.json keyed by input_hash, so a
re-run only re-distills sessions whose source file changed. The live/most-recent
session is skipped by default (it may still be appended to).
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import sys
import time
from datetime import datetime, timezone

from .distill import build_model_input, heuristic_digest
from .parse import load_session
from .synth import REVIEW_DIR, synthesize
from . import reviews as rv
from . import config

PROJECT_LOGS = config.project_log_dir()
DIGEST_DIR = config.subdir("digests")


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _echo(msg: str) -> None:
    print(msg, file=sys.stderr, flush=True)


def _session_files(logs_dir: str, skip_live: bool) -> list[str]:
    files = sorted(
        glob.glob(os.path.join(logs_dir, "*.jsonl")),
        key=os.path.getmtime,
    )
    if skip_live and files:
        files = files[:-1]  # drop the most recently modified (likely active)
    return files


def _digest_path(session_id: str) -> str:
    return os.path.join(DIGEST_DIR, f"{session_id}.json")


def _cache_fresh(path: str, input_hash: str, want_model: bool) -> bool:
    """A digest is fresh if the source is unchanged AND it has the model
    enrichment when one was requested (a prior heuristic-only digest is stale
    for a model run)."""
    if not os.path.exists(path):
        return False
    try:
        with open(path) as fh:
            d = json.load(fh)
    except Exception:
        return False
    if d.get("input_hash") != input_hash:
        return False
    if want_model and "model" not in d and "model_error" not in d:
        return False
    return True


def cmd_distill(args: argparse.Namespace) -> int:
    os.makedirs(DIGEST_DIR, exist_ok=True)
    files = _session_files(args.logs, skip_live=not args.include_live)
    if args.session:
        files = [f for f in files if args.session in f]

    total = len(files)
    if not total:
        _echo("no session files found")
        return 1

    enrich = None
    if not args.no_model:
        from .model import enrich as _enrich

        enrich = _enrich

    done = skipped = failed = 0
    t0 = time.time()
    for i, f in enumerate(files, 1):
        # Fast hash precheck: skip unchanged before full parse when possible.
        try:
            session = load_session(f)
        except Exception as e:  # noqa: BLE001
            failed += 1
            _echo(f"  [{i}/{total}] PARSE-FAIL {os.path.basename(f)}: {e}")
            continue

        dpath = _digest_path(session.session_id)
        if not args.force and _cache_fresh(dpath, session.input_hash,
                                           want_model=enrich is not None):
            skipped += 1
        else:
            h = heuristic_digest(session)
            digest = {
                "schema": "dream.digest.v1",
                "distilled_at": _now(),
                **h,
            }
            if enrich is not None:
                try:
                    digest["model"] = enrich(
                        build_model_input(h),
                        model=args.model,
                        url=args.url,
                    )
                    digest["model_name"] = args.model
                except Exception as e:  # noqa: BLE001
                    digest["model_error"] = str(e)
                    _echo(f"  [{i}/{total}] model-fail {session.session_id[:8]}: {e}")
            with open(dpath, "w") as fh:
                json.dump(digest, fh, indent=2)
            done += 1

        if i % 5 == 0 or i == total:
            rate = (time.time() - t0) / i
            _echo(
                f"  [{i}/{total}]  done={done} skipped={skipped} "
                f"failed={failed} ({rate:.1f}s/entry)"
            )
    _echo(
        f"distill complete: {done} written, {skipped} cached, {failed} failed "
        f"in {time.time()-t0:.0f}s"
    )
    return 0


def cmd_stats(args: argparse.Namespace) -> int:
    paths = sorted(glob.glob(os.path.join(DIGEST_DIR, "*.json")))
    if not paths:
        _echo("no digests yet — run `distill` first")
        return 1
    tot = {"denials": 0, "errors": 0, "corrections": 0, "insights": 0}
    by_target: dict[str, int] = {}
    print(f"{'session':12} {'branch':28} {'den':>3} {'cor':>3} {'err':>4} {'ins':>3}")
    for p in paths:
        with open(p) as fh:
            d = json.load(fh)
        st = d.get("stats", {})
        ins = d.get("model", {}).get("candidate_insights", []) if d.get("model") else []
        for c in ins:
            by_target[c.get("target", "?")] = by_target.get(c.get("target", "?"), 0) + 1
        tot["denials"] += st.get("denials", 0)
        tot["errors"] += st.get("errors", 0)
        tot["corrections"] += st.get("corrections", 0)
        tot["insights"] += len(ins)
        print(
            f"{d['session_id'][:12]:12} {str(d.get('git_branch'))[:28]:28} "
            f"{st.get('denials',0):>3} {st.get('corrections',0):>3} "
            f"{st.get('errors',0):>4} {len(ins):>3}"
        )
    print(f"\nTOT:  denials={tot['denials']} corrections={tot['corrections']} "
          f"errors={tot['errors']} insights={tot['insights']}")
    if by_target:
        print("insight targets:", dict(sorted(by_target.items(), key=lambda kv: -kv[1])))
    return 0


_ROUTE_LABEL = {
    "memory": "MEMORY (auto-write candidate)",
    "claude_md": "CLAUDE.md (propose)",
    "doc": "DOC (propose)",
    "skill": "SKILL (propose)",
    "decisions_log": "DECISIONS.md (propose entry / drift)",
    "product_decision": "PRODUCT-DECISION → issue tracker",
}


def _render_queue(review: dict) -> str:
    lines = ["# Dream review queue", ""]
    lines.append(
        f"{review['candidate_count']} raw candidates → "
        f"{review['cluster_count']} clusters\n"
    )
    novel = [c for c in review["clusters"] if not c["likely_known"]]
    known = [c for c in review["clusters"] if c["likely_known"]]

    def block(c: dict) -> None:
        freq = c["frequency"]
        lines.append(
            f"### {c['id']} · {_ROUTE_LABEL.get(c['route_suggested'], c['route_suggested'])}"
            f" · freq={freq} · {c['confidence_max']}"
        )
        lines.append(f"**{c['representative']}**")
        if c["known_match"]:
            km = c["known_match"]
            lines.append(
                f"- _known-match_ `{km['artifact']}` (cov {km['coverage']}): {km['snippet']}"
            )
        lines.append(f"- sessions: {', '.join(c['sessions'])}")
        if len(c["members"]) > 1:
            for m in c["members"][:6]:
                lines.append(f"    - [{m['session']}/{m['target']}] {m['insight']}")
        lines.append("")

    lines.append(f"## Novel ({len(novel)})\n")
    for c in novel:
        block(c)
    lines.append(f"## Likely already captured ({len(known)})\n")
    for c in known:
        block(c)
    return "\n".join(lines)


def cmd_synth(args: argparse.Namespace) -> int:
    os.makedirs(REVIEW_DIR, exist_ok=True)
    review = synthesize()
    review["generated_at"] = _now()
    with open(os.path.join(REVIEW_DIR, "queue.json"), "w") as fh:
        json.dump(review, fh, indent=2)
    md = _render_queue(review)
    with open(os.path.join(REVIEW_DIR, "QUEUE.md"), "w") as fh:
        fh.write(md)
    novel = sum(1 for c in review["clusters"] if not c["likely_known"])
    by_route = {}
    for c in review["clusters"]:
        if not c["likely_known"]:
            by_route[c["route_suggested"]] = by_route.get(c["route_suggested"], 0) + 1
    _echo(
        f"synth: {review['candidate_count']} candidates → "
        f"{review['cluster_count']} clusters ({novel} novel). "
        f"novel routes: {by_route}"
    )
    _echo(f"wrote {REVIEW_DIR}/queue.json + QUEUE.md")
    return 0


def cmd_reviews_distill(args: argparse.Namespace) -> int:
    findings = rv.distill(_echo, refresh=args.refresh)
    by_rev = {}
    for f in findings:
        by_rev[f["reviewer"]] = by_rev.get(f["reviewer"], 0) + 1
    _echo(
        f"reviews-distill: {len(findings)} findings across {len(by_rev)} reviewers "
        f"→ {rv.REVIEW_OUT}/findings.json"
    )
    return 0


def _render_scorecards(s: dict) -> str:
    lines = ["# Reviewer scorecards", ""]
    lines.append(
        f"{s['total_findings']} findings · {s['reviewer_count']} reviewers\n"
    )
    lines.append(
        "| reviewer | findings | PRs | accept(value) | accept(fix) | "
        "FP rate | won't-fix | unresolved | reopened | taste(user) |"
    )
    lines.append("|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|")
    for c in s["scorecards"]:
        def pct(x):
            return "—" if x is None else f"{x*100:.0f}%"
        lines.append(
            f"| {c['reviewer']} | {c['findings']} | {c['prs']} | "
            f"{pct(c['acceptance_value'])} | {pct(c['acceptance_fixstrict'])} | "
            f"{pct(c['false_positive_rate'])} | {pct(c['wont_fix_rate'])} | "
            f"{pct(c['unresolved_rate'])} | {c['reopened']} | {c.get('taste_user', 0)} |"
        )
    return "\n".join(lines)


def cmd_reviews_synth(args: argparse.Namespace) -> int:
    findings = rv.load_findings(args.source)
    if not findings:
        _echo(
            f"no findings for source={args.source} — run `reviews-distill` "
            f"(github) or emit dream-markers (markers) first"
        )
        return 1
    s = rv.synth(findings)
    s["source"] = args.source
    s["generated_at"] = _now()
    with open(os.path.join(rv.REVIEW_OUT, "scorecards.json"), "w") as fh:
        json.dump(s, fh, indent=2)
    md = _render_scorecards(s)
    with open(os.path.join(rv.REVIEW_OUT, "SCORECARDS.md"), "w") as fh:
        fh.write(md)
    _echo(
        f"reviews-synth: {s['reviewer_count']} scorecards "
        f"→ {rv.REVIEW_OUT}/SCORECARDS.md"
    )
    return 0


def cmd_reviews_coverage(args: argparse.Namespace) -> int:
    cov = rv.coverage_from_logs()
    cov["generated_at"] = _now()
    os.makedirs(rv.REVIEW_OUT, exist_ok=True)
    with open(os.path.join(rv.REVIEW_OUT, "coverage.json"), "w") as fh:
        json.dump(cov, fh, indent=2)
    lines = ["# Reviewer firing coverage (from logs — complete, unbiased)", ""]
    lines.append(f"{cov['total_spawns']} reviewer spawns\n")
    lines.append("| reviewer | spawns | PRs | first seen | last seen |")
    lines.append("|---|--:|--:|---|---|")
    for r in cov["reviewers"]:
        lines.append(
            f"| {r['reviewer']} | {r['spawns']} | {r['prs']} | "
            f"{(r['first_seen'] or '')[:10]} | {(r['last_seen'] or '')[:10]} |"
        )
    with open(os.path.join(rv.REVIEW_OUT, "COVERAGE.md"), "w") as fh:
        fh.write("\n".join(lines))
    _echo(
        f"reviews-coverage: {len(cov['reviewers'])} reviewers, "
        f"{cov['total_spawns']} spawns → {rv.REVIEW_OUT}/COVERAGE.md"
    )
    return 0


def cmd_reviews_harvest(args: argparse.Namespace) -> int:
    rv.harvest(_echo)
    return 0


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(prog="dream")
    sub = p.add_subparsers(dest="cmd", required=True)

    d = sub.add_parser("distill", help="distill session logs into digests")
    d.add_argument("--logs", default=PROJECT_LOGS, help="session log dir")
    d.add_argument("--session", help="only this session id substring")
    d.add_argument("--no-model", action="store_true", help="heuristic only")
    d.add_argument("--force", action="store_true", help="ignore cache")
    d.add_argument("--include-live", action="store_true", help="don't skip newest")
    d.add_argument("--model", default=os.environ.get("DREAM_MODEL", "qwen2.5:7b"))
    d.add_argument("--url", default=os.environ.get("WYRD_OLLAMA_URL",
                                                   "http://10.5.2.31:11434"))
    d.set_defaults(func=cmd_distill)

    s = sub.add_parser("stats", help="summarize existing digests")
    s.set_defaults(func=cmd_stats)

    sy = sub.add_parser("synth", help="stage 2: cluster + dedup + route candidates")
    sy.set_defaults(func=cmd_synth)

    rd = sub.add_parser("reviews-distill", help="mine PR review threads → findings")
    rd.add_argument("--refresh", action="store_true", help="re-pull from GitHub")
    rd.set_defaults(func=cmd_reviews_distill)

    rs = sub.add_parser("reviews-synth", help="aggregate per-reviewer scorecards")
    rs.add_argument("--source", choices=["markers", "github", "all"], default="all",
                    help="finding source: markers (authoritative) | github | all")
    rs.set_defaults(func=cmd_reviews_synth)

    rc = sub.add_parser("reviews-coverage", help="reviewer firing coverage from logs")
    rc.set_defaults(func=cmd_reviews_coverage)

    rh = sub.add_parser("reviews-harvest", help="capture durable + /tmp reviewer findings")
    rh.set_defaults(func=cmd_reviews_harvest)

    args = p.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
