"""Stage 2 synthesis: cross-session consolidation of stage-1 candidates.

The DETERMINISTIC mechanical core. It does the cheap, repeatable heavy lifting
so the expensive Opus judgment pass can be small and focused:

  1. Pool every candidate_insight across all digests.
  2. Cluster near-duplicate insights (lexical) so the same lesson across N
     sessions becomes one cluster with frequency=N. Frequency is the promotion
     signal (a 1-session lesson is a memory at most; a recurring one is a
     CLAUDE.md candidate).
  3. Pre-flag "likely already captured" by lexical match against the KNOWN
     corpus — existing memories, both CLAUDE.md files, and kenning DECISIONS.md.
  4. Suggest a route per cluster (with frequency-gated downgrade of over-eager
     claude_md tags), and emit a review queue.

What this layer deliberately does NOT do (left to the Opus pass): semantic
dedup, behavior-vs-product-decision routing, final promotion. See README.
"""

from __future__ import annotations

import glob
import json
import os
import re
from collections import Counter

from . import config

DIGEST_DIR = config.subdir("digests")
REVIEW_DIR = config.subdir("review")

# The "already known" corpus: dedup candidates against these. Derived from the
# project (CLAUDE.md/AGENTS.md up to git root + ~/.claude, plus $DREAM_EXTRA_CORPUS
# for a project decision log like kenning DECISIONS.md) and the project's memory.
MEMORY_DIR = config.memory_dir()
KNOWN_CORPUS_FILES = config.known_corpus_files()

_STOP = set(
    "the a an and or of to in on for with is are be that this it as at by from "
    "should must always never when not no do does done use used using via not "
    "than then into over under but if can could would will shall may might also "
    "you your they them their our we i he she his her its it's project agent".split()
)
_WORD = re.compile(r"[a-zA-Z][a-zA-Z0-9_]+")

CLUSTER_THRESHOLD = 0.40  # token Jaccard to merge
KNOWN_THRESHOLD = 0.50  # content-word coverage to flag likely-known


def _tokens(s: str) -> set[str]:
    return {w.lower() for w in _WORD.findall(s) if w.lower() not in _STOP and len(w) > 2}


def _jaccard(a: set, b: set) -> float:
    if not a or not b:
        return 0.0
    return len(a & b) / len(a | b)


def _load_candidates() -> list[dict]:
    cands = []
    for p in sorted(glob.glob(os.path.join(DIGEST_DIR, "*.json"))):
        with open(p) as fh:
            d = json.load(fh)
        sid = d.get("session_id", os.path.basename(p))
        for c in d.get("model", {}).get("candidate_insights", []) or []:
            ins = (c.get("insight") or "").strip()
            if not ins:
                continue
            cands.append(
                {
                    "session": sid,
                    "branch": d.get("git_branch"),
                    "target": c.get("target", "memory"),
                    "insight": ins,
                    "evidence": c.get("evidence", ""),
                    "confidence": c.get("confidence", "low"),
                    "tokens": _tokens(ins),
                }
            )
    return cands


_CONF_RANK = {"high": 3, "medium": 2, "low": 1}


def _cluster(cands: list[dict]) -> list[dict]:
    # Seed clusters with the most confident, longest insights first so they
    # become the representatives.
    order = sorted(
        cands,
        key=lambda c: (-_CONF_RANK.get(c["confidence"], 0), -len(c["tokens"])),
    )
    clusters: list[dict] = []
    for c in order:
        best, best_score = None, 0.0
        for cl in clusters:
            s = _jaccard(c["tokens"], cl["rep_tokens"])
            if s > best_score:
                best, best_score = cl, s
        if best is not None and best_score >= CLUSTER_THRESHOLD:
            best["members"].append(c)
            best["rep_tokens"] |= c["tokens"]
        else:
            clusters.append(
                {
                    "representative": c["insight"],
                    "rep_tokens": set(c["tokens"]),
                    "members": [c],
                }
            )
    return clusters


def _load_known_paragraphs() -> list[tuple[str, set, str]]:
    """(artifact_label, content_tokens, snippet) for each corpus paragraph."""
    paras: list[tuple[str, set, str]] = []
    sources = []
    for f in KNOWN_CORPUS_FILES:
        if os.path.exists(f):
            sources.append((os.path.basename(f), f))
    for f in sorted(glob.glob(os.path.join(MEMORY_DIR, "*.md"))):
        sources.append((f"memory/{os.path.basename(f)}", f))
    for label, path in sources:
        try:
            with open(path) as fh:
                text = fh.read()
        except Exception:
            continue
        for chunk in re.split(r"\n\s*\n", text):
            chunk = chunk.strip()
            if len(chunk) < 20:
                continue
            paras.append((label, _tokens(chunk), " ".join(chunk.split())[:200]))
    return paras


def _known_match(rep_tokens: set, paras: list) -> dict | None:
    """Best corpus paragraph by content-word coverage of the cluster rep."""
    if not rep_tokens:
        return None
    best = None
    best_cov = 0.0
    for label, ptoks, snippet in paras:
        cov = len(rep_tokens & ptoks) / len(rep_tokens)
        if cov > best_cov:
            best_cov, best = cov, (label, snippet)
    if best is None or best_cov < 0.30:
        return None
    return {"artifact": best[0], "coverage": round(best_cov, 2), "snippet": best[1]}


def _suggest_route(members: list[dict], frequency: int, known: dict | None) -> str:
    targets = Counter(m["target"] for m in members)
    route = targets.most_common(1)[0][0]
    # Frequency gate: a single-session claude_md is over-eager → downgrade.
    if route == "claude_md" and frequency < 2:
        route = "memory"
    # A strong match against the kenning decision log means it's a product
    # decision that's almost certainly already recorded.
    if known and "DECISIONS.md" in known.get("artifact", "") and known["coverage"] >= KNOWN_THRESHOLD:
        route = "product_decision"
    return route


def synthesize() -> dict:
    cands = _load_candidates()
    clusters = _cluster(cands)
    paras = _load_known_paragraphs()

    out_clusters = []
    for i, cl in enumerate(sorted(clusters, key=lambda c: -len(c["members"])), 1):
        members = cl["members"]
        sessions = sorted({m["session"] for m in members})
        frequency = len(sessions)
        known = _known_match(cl["rep_tokens"], paras)
        likely_known = bool(known and known["coverage"] >= KNOWN_THRESHOLD)
        conf_max = max((m["confidence"] for m in members), key=lambda c: _CONF_RANK.get(c, 0))
        route = _suggest_route(members, frequency, known)
        out_clusters.append(
            {
                "id": f"c{i:03d}",
                "route_suggested": route,
                "frequency": frequency,
                "occurrences": len(members),
                "sessions": [s[:8] for s in sessions],
                "confidence_max": conf_max,
                "likely_known": likely_known,
                "known_match": known,
                "representative": cl["representative"],
                "members": [
                    {
                        "session": m["session"][:8],
                        "target": m["target"],
                        "insight": m["insight"],
                        "evidence": m["evidence"],
                        "confidence": m["confidence"],
                    }
                    for m in members
                ],
            }
        )

    # Rank: novel first, then by frequency, then confidence.
    out_clusters.sort(
        key=lambda c: (
            c["likely_known"],
            -c["frequency"],
            -_CONF_RANK.get(c["confidence_max"], 0),
        )
    )
    return {
        "schema": "dream.review.v1",
        "candidate_count": len(cands),
        "cluster_count": len(out_clusters),
        "clusters": out_clusters,
    }
