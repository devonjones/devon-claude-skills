"""Dream stage-1 CLI: distill Claude Code session logs into behavioral digests.

    python -m dreamlib.cli distill            # distill the backlog (cached)
    python -m dreamlib.cli distill --no-model # heuristic only (fast, no ollama)
    python -m dreamlib.cli distill --session <uuid>
    python -m dreamlib.cli stats              # summarize existing digests

Digests are cached in digests/{session_id}.json keyed by input_hash, so a
re-run only re-distills sessions whose source file changed. The live/most-recent
session is skipped by default (it may still be appended to).
"""

from __future__ import annotations

import argparse
import fcntl
import glob
import hashlib
import json
import os
import subprocess
import time
from datetime import datetime, timezone

from .distill import build_model_input, heuristic_digest, is_self_run
from .parse import load_session
from .synth import REVIEW_DIR, synthesize
from . import reviews as rv
from . import config

PROJECT_LOGS = config.project_log_dir()
DIGEST_DIR = config.subdir("digests")


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _echo(msg: str) -> None:
    # Unbuffered and best-effort: a full or closed stderr must not change the
    # exit code, which is the gate's signal. A failed buffered write is
    # retried at exit and turns a deliberate skip into exit 120.
    try:
        os.write(2, (msg + "\n").encode())
    except OSError:
        pass


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
    """A digest is fresh if the source is unchanged AND it carries a SUCCESSFUL
    model enrichment when one was requested. A prior heuristic-only digest — or
    one that only recorded a ``model_error`` (a transient failure like the model
    host being offline) — is stale for a model run and must be retried; else a
    blip permanently poisons the digest and no later run ever re-enriches it."""
    if not os.path.exists(path):
        return False
    try:
        with open(path) as fh:
            d = json.load(fh)
    except Exception:
        return False
    if d.get("input_hash") != input_hash:
        return False
    if want_model and "model" not in d:
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
        # Name the model host up front: with $WYRD_OLLAMA_URL unset it defaults
        # to localhost, which may be much weaker than the intended host.
        if not os.environ.get("WYRD_OLLAMA_URL"):
            _echo(f"WARN: WYRD_OLLAMA_URL unset — distilling against {args.url}")
        else:
            _echo(f"distill model: {args.model} @ {args.url}")

    done = skipped = failed = selfrun = 0
    t0 = time.time()
    for i, f in enumerate(files, 1):
        # Fast hash precheck: skip unchanged before full parse when possible.
        try:
            session = load_session(f)
        except Exception as e:  # noqa: BLE001
            failed += 1
            _echo(f"  [{i}/{total}] PARSE-FAIL {os.path.basename(f)}: {e}")
            continue

        # Skip the tool's own self-runs (opening turn = dream/dream-reviewers
        # invocation) — their insights are the skill's echo, not project lessons.
        if is_self_run(session):
            selfrun += 1
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
                f"selfrun={selfrun} failed={failed} ({rate:.1f}s/entry)"
            )
    _echo(
        f"distill complete: {done} written, {skipped} cached, "
        f"{selfrun} self-runs skipped, {failed} failed in {time.time()-t0:.0f}s"
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
        ins = d["model"].get("candidate_insights", []) if d.get("model") else []
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
    # One file pair per source, so running several sources keeps each. The
    # markers scorecard is the only one carrying operator taste.
    with open(os.path.join(rv.REVIEW_OUT, f"scorecards-{args.source}.json"), "w") as fh:
        json.dump(s, fh, indent=2)
    with open(os.path.join(rv.REVIEW_OUT, f"SCORECARDS-{args.source}.md"), "w") as fh:
        fh.write(_render_scorecards(s))
    _echo(
        f"reviews-synth: {s['reviewer_count']} scorecards "
        f"→ {rv.REVIEW_OUT}/SCORECARDS-{args.source}.md"
    )
    return 0


def _merge_coverage(old: dict, new: dict) -> dict:
    """Merge coverage records, keeping each reviewer's highest counts and widest
    seen-window. Coverage comes from the session-log window, which is pruned,
    so a fresh computation undercounts; merging makes the count a high-water
    mark. A reviewer absent from the new window is kept, not dropped."""
    merged: dict[str, dict] = {r["reviewer"]: dict(r) for r in old.get("reviewers", [])}
    for r in new.get("reviewers", []):
        prev = merged.get(r["reviewer"])
        if prev is None:
            merged[r["reviewer"]] = dict(r)
            continue
        prev["spawns"] = max(prev.get("spawns") or 0, r.get("spawns") or 0)
        prev["prs"] = max(prev.get("prs") or 0, r.get("prs") or 0)
        seens = [s for s in (prev.get("first_seen"), r.get("first_seen")) if s]
        prev["first_seen"] = min(seens) if seens else None
        seens = [s for s in (prev.get("last_seen"), r.get("last_seen")) if s]
        prev["last_seen"] = max(seens) if seens else None
    out = dict(new)
    out["reviewers"] = sorted(
        merged.values(), key=lambda r: (-(r.get("spawns") or 0), r["reviewer"])
    )
    out["total_spawns"] = sum(r.get("spawns") or 0 for r in out["reviewers"])
    out["live_window_spawns"] = new.get("total_spawns", 0)
    return out


def cmd_reviews_coverage(args: argparse.Namespace) -> int:
    cov = rv.coverage_from_logs()
    os.makedirs(rv.REVIEW_OUT, exist_ok=True)
    path = os.path.join(rv.REVIEW_OUT, "coverage.json")
    merged = False
    if not args.no_merge and os.path.exists(path):
        try:
            with open(path) as fh:
                prior = json.load(fh)
        except Exception as e:  # noqa: BLE001
            # Never fall through to the write: this file is the only copy of
            # cumulative history, and the live window can be recomputed.
            _echo(f"reviews-coverage: prior coverage unreadable ({e})")
            _echo(f"reviews-coverage: REFUSING to write — {path} holds the only "
                  "cumulative history and overwriting it with the live window "
                  "would destroy it. Inspect or move that file, then re-run.")
            return 1
        cov = _merge_coverage(prior, cov)
        merged = True
    cov["generated_at"] = _now()
    tmp = f"{path}.tmp"
    with open(tmp, "w") as fh:
        json.dump(cov, fh, indent=2)
    os.replace(tmp, path)
    lines = [
        "# Reviewer firing coverage "
        + ("(cumulative high-water mark, merged forward across runs — the live "
           "log window is pruned)" if merged
           else "(THIS RUN'S LIVE WINDOW ONLY — not merged with prior history)"),
        "",
    ]
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
    spawns = (f"{cov['total_spawns']} spawns cumulative "
              f"({cov['live_window_spawns']} in the live window)" if merged
              else f"{cov['total_spawns']} spawns in the live window only")
    _echo(
        f"reviews-coverage: {len(cov['reviewers'])} reviewers, {spawns} "
        f"→ {rv.REVIEW_OUT}/COVERAGE.md"
    )
    return 0


def cmd_reviews_harvest(args: argparse.Namespace) -> int:
    rv.harvest(_echo)
    return 0


# Signal states. "Nothing to mine" is determinate and means skip; "could not
# look" is not, and means run.
UNKNOWN: None = None    # the probe failed; nobody can say
NOTHING = "nothing"     # the probe worked and there is nothing to mine

# A deliberate "nothing new" exits SKIP, not 1: Python exits 1 on any uncaught
# exception, and a crash must not read as a skip.
SKIP = 75


def _gate_state_path() -> str:
    """Resolved per call, not at import: $DREAM_HOME is repointable by tests and
    by callers, and importing a module should not create directories."""
    return os.path.join(config.dream_home(), "gate.json")


def _gate_state() -> tuple[dict, bool]:
    """Returns (state, readable). A corrupt file is not treated as empty:
    writing over it would destroy the other check's watermark. The caller runs
    the job instead and leaves the file for someone to look at."""
    path = _gate_state_path()
    if not os.path.exists(path):
        return {}, True
    try:
        with open(path) as fh:
            loaded = json.load(fh)
    except (OSError, ValueError) as exc:
        _echo(f"gate: state file unreadable ({exc}) — not overwriting it")
        return {}, False
    if not isinstance(loaded, dict):
        _echo(f"gate: state file is {type(loaded).__name__}, expected object — not overwriting it")
        return {}, False
    return loaded, True


def _write_gate_state(state: dict) -> None:
    path = _gate_state_path()
    tmp = f"{path}.tmp"
    with open(tmp, "w") as fh:
        json.dump(state, fh, indent=2)
    os.replace(tmp, path)


def _sessions_fingerprint() -> str | None:
    """Fingerprint of the minable corpus: the sorted input_hashes of every
    non-self-run session. Keyed on content, not mtime, because dream's own reads
    and the log pruner change mtimes without changing anything minable.

    Includes the newest, possibly still-live, session. Excluding it would
    deadlock the gate: with jobs gated off no new log appears, so that session
    stays newest and never becomes eligible. Including it costs at most an
    extra run.

    Returns NOTHING when the log dir is readable and holds nothing minable, and
    UNKNOWN when it cannot be read or none of its sessions load - a missing
    dir usually means the probe is looking in the wrong place, not that there
    is no work."""
    if not os.path.isdir(PROJECT_LOGS) or not os.access(PROJECT_LOGS, os.R_OK | os.X_OK):
        _echo(f"gate[sessions]: cannot read {PROJECT_LOGS}")
        return UNKNOWN
    files = _session_files(PROJECT_LOGS, skip_live=False)
    hashes, loaded = [], 0
    for f in files:
        try:
            session = load_session(f)
        except Exception as exc:  # noqa: BLE001
            # Usually an unreadable file. Skipping it could turn real input
            # into NOTHING and skip the job, so the whole signal is unknown.
            _echo(f"gate[sessions]: cannot load {f} ({exc})")
            return UNKNOWN
        if not session.events:  # nothing parsed out of it; not minable
            continue
        loaded += 1
        if not is_self_run(session):
            hashes.append(session.input_hash)
    if files and not loaded:
        _echo(f"gate[sessions]: none of {len(files)} session logs could be loaded")
        return UNKNOWN
    if not hashes:
        return NOTHING
    return hashlib.sha256("".join(sorted(hashes)).encode()).hexdigest()


def _prs_fingerprint() -> str | None:
    """Most recently touched PR (number + updatedAt). Catches a merge, a new PR,
    and new review comments on an existing one."""
    try:
        r = subprocess.run(
            ["gh", "pr", "list", "--state", "all", "--limit", "1",
             "--search", "sort:updated-desc", "--json", "number,updatedAt"],
            # gh finds the repo from its cwd. A systemd unit runs with its own
            # WorkingDirectory, so without this the probe never finds the repo.
            cwd=config.project_dir(),
            capture_output=True, text=True, timeout=60,
        )
    except Exception as exc:  # noqa: BLE001
        _echo(f"gate[prs]: gh failed to run ({exc})")
        return UNKNOWN
    if r.returncode != 0:
        _echo(f"gate[prs]: gh exited {r.returncode}: {r.stderr.strip()[:200]}")
        return UNKNOWN
    out = r.stdout.strip()
    if not out:
        _echo("gate[prs]: gh returned no output")
        return UNKNOWN
    return out


def _sessions_scope() -> str:
    """Which watermark the sessions signal belongs to.

    The signal is computed over PROJECT_LOGS, which Claude Code keys on the
    cwd, so it is per-worktree; the state file is shared by every worktree of
    the repo. Keying the entry by the log dir gives each worktree its own
    watermark. Comparing one worktree's signal with another's would never
    match, and the gate would never close."""
    return f"sessions@{os.path.basename(PROJECT_LOGS)}"


def cmd_gate(args: argparse.Namespace) -> int:
    """Gate a nightly job on new input. Wire it as

      ExecCondition=dream gate --check X --peek
      ExecStartPost=dream gate --check X

    --peek (the condition) exits 0 to run or SKIP when there is nothing new,
    and remembers the fingerprint it saw as pending. Without --peek (after the
    job) it records that pending fingerprint as consumed, so input that arrived
    during the run is still new tomorrow. With nothing pending - the condition
    could not tell what it saw - it records nothing, and the next run compares
    against the last good watermark. It exits 1 only when the state file
    cannot be read or written, which marks the unit failed.

    The condition runs when it cannot tell: an unreadable corpus, a failed gh
    call or an unreadable state file all exit 0."""
    # The state file is shared by every check and worktree; serialise the
    # read-modify-write so two units finishing together don't drop an entry.
    with open(_gate_state_path() + ".lock", "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        return _gate(args.check, args.peek)


def _gate(key: str, peek: bool) -> int:
    entry = _sessions_scope() if key == "sessions" else key
    pending = f"{entry}_pending"
    state, readable = _gate_state()

    if not peek:
        if not readable:
            _echo(f"gate[{key}]: state unreadable — watermark not recorded")
            return 1
        seen = state.pop(pending, None)
        if seen is None:
            _echo(f"gate[{key}]: nothing pending — watermark unchanged")
            return 0
        state[entry] = seen
        state[f"{entry}_at"] = _now()
        _write_gate_state(state)
        _echo(f"gate[{key}]: watermark recorded")
        return 0

    current = _sessions_fingerprint() if key == "sessions" else _prs_fingerprint()
    if current is UNKNOWN:
        # A pending value left by a job that failed is older than this run's
        # input; recording it afterwards would mark that input consumed.
        if readable and state.pop(pending, None) is not None:
            _write_gate_state(state)
        _echo(f"gate[{key}]: signal unavailable — failing open, run proceeds")
        return 0
    if current == NOTHING:
        _echo(f"gate[{key}]: nothing to mine — skipping")
        return SKIP
    if not readable:
        _echo(f"gate[{key}]: state unreadable — failing open, run proceeds")
        return 0
    if state.get(entry) == current:
        _echo(f"gate[{key}]: no new input since last run — skipping")
        return SKIP
    state[pending] = current
    _write_gate_state(state)
    _echo(f"gate[{key}]: new input since last run — run proceeds")
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
                                                   "http://localhost:11434"))
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
    rc.add_argument("--no-merge", action="store_true",
                    help="live log window only; do not merge the prior cumulative file")
    rc.set_defaults(func=cmd_reviews_coverage)

    rh = sub.add_parser("reviews-harvest", help="capture durable + /tmp reviewer findings")
    rh.set_defaults(func=cmd_reviews_harvest)

    g = sub.add_parser(
        "gate",
        help="--peek: exit 0 to run, 75 when nothing is new; without it: record the watermark",
    )
    g.add_argument("--check", choices=["sessions", "prs"], default="sessions",
                   help="sessions = new minable session content; prs = PR activity")
    g.add_argument("--peek", action="store_true",
                   help="check without recording (ExecCondition); omit it after "
                        "the job (ExecStartPost) to record what was seen")
    g.set_defaults(func=cmd_gate)

    args = p.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
