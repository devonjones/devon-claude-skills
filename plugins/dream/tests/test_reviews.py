"""reviews.py — disposition parsing, reviewer attribution, thread/scorecard math,
and the marker-kind contract."""

import json

from dreamlib import reviews


def test_disposition_of_each_kind():
    assert reviews._disposition_of("Fixed - done in abc123") == "fixed"
    assert reviews._disposition_of("Won't fix - bad idea") == "wont_fix"
    assert reviews._disposition_of("Out of scope - tracked in BD-1") == "out_of_scope"
    assert reviews._disposition_of("Withdrawn — validator refuted") == "withdrawn"
    assert reviews._disposition_of("Acknowledged - noted") == "acknowledged"
    assert reviews._disposition_of("just some discussion") is None


def test_disposition_precedence_reject_beats_anchored_fixed():
    # 'wont_fix' matches anywhere and is checked before the anchored 'fixed'.
    assert reviews._disposition_of("Fixed the typo but won't fix the design") == "wont_fix"


def test_normalize_disposition_contract_values_passthrough():
    for v in ("fixed", "addressed", "acknowledged", "out_of_scope",
              "wont_fix", "withdrawn", "unresolved"):
        assert reviews._normalize_disposition(v) == v


def test_normalize_disposition_folds_off_contract_aliases():
    assert reviews._normalize_disposition("verified") == "acknowledged"
    assert reviews._normalize_disposition("approved") == "acknowledged"
    assert reviews._normalize_disposition("adopted") == "fixed"
    assert reviews._normalize_disposition("declined") == "wont_fix"
    assert reviews._normalize_disposition("deferred") == "out_of_scope"
    assert reviews._normalize_disposition("abandoned") == "unresolved"


def test_normalize_disposition_folds_separators_and_case():
    assert reviews._normalize_disposition("wont-fix") == "wont_fix"
    assert reviews._normalize_disposition("won't fix") == "wont_fix"
    assert reviews._normalize_disposition("Verified") == "acknowledged"
    assert reviews._normalize_disposition("out of scope") == "out_of_scope"
    assert reviews._normalize_disposition(None) == "unresolved"
    assert reviews._normalize_disposition("") == "unresolved"


def test_read_markers_normalizes_off_contract_disposition(markers_home):
    # A guardian marker written as the off-contract "verified" must reach the
    # acceptance math as "acknowledged" (a VALUE_ACCEPT bucket), not fall through.
    lines = [
        {"ts": "t", "skill": "prl", "kind": "reviewer-finding", "pr": 863,
         "reviewer": "morpheme-surface-identity-reviewer", "disposition": "verified"},
        {"ts": "t", "skill": "prl", "kind": "reviewer-finding", "pr": 850,
         "reviewer": "gemini", "disposition": "declined"},
    ]
    (markers_home / "prl.jsonl").write_text(
        "\n".join(json.dumps(x) for x in lines) + "\n", encoding="utf-8")
    out = {f["reviewer"]: f["disposition"] for f in reviews.read_markers()}
    assert out["morpheme-surface-identity-reviewer"] == "acknowledged"
    assert out["gemini"] == "wont_fix"


def test_canonical_reviewer_map_folds_suffix_variants_only_when_both_present():
    findings = [
        {"reviewer": "test-coverage"}, {"reviewer": "test-coverage-reviewer"},
        {"reviewer": "api-correctness"}, {"reviewer": "api-correctness-reviewer"},
        {"reviewer": "pr-test-analyzer"},      # lone plugin default, no -reviewer twin
        {"reviewer": "spa-parity-reviewer"},   # lone -reviewer, no bare twin
    ]
    m = reviews._canonical_reviewer_map(findings)
    assert m["test-coverage"] == "test-coverage-reviewer"
    assert m["test-coverage-reviewer"] == "test-coverage-reviewer"
    assert m["api-correctness"] == "api-correctness-reviewer"
    assert m["pr-test-analyzer"] == "pr-test-analyzer"        # untouched
    assert m["spa-parity-reviewer"] == "spa-parity-reviewer"  # untouched (no bare twin)


def test_synth_merges_suffix_variant_reviewers_into_one_row():
    findings = [
        {"reviewer": "test-coverage", "disposition": "fixed",
         "reopened": False, "severity": None, "pr": "1"},
        {"reviewer": "test-coverage-reviewer", "disposition": "fixed",
         "reopened": False, "severity": None, "pr": "2"},
    ]
    out = reviews.synth(findings)
    assert out["reviewer_count"] == 1  # not split into two rows
    card = out["scorecards"][0]
    assert card["reviewer"] == "test-coverage-reviewer"  # canonical form wins
    assert card["findings"] == 2
    assert card["prs"] == 2


def test_reviewer_of_agent_signature():
    c = {"body": "<!-- Agent: code-reviewer --> bug: foo", "user": {"login": "dev"}}
    assert reviews._reviewer_of(c) == "code-reviewer"


def test_reviewer_of_claude_prefix():
    c = {"body": "🤖 **Claude Code** (silent-failure-hunter): swallowed error",
         "user": {"login": "dev"}}
    assert reviews._reviewer_of(c) == "silent-failure-hunter"


def test_reviewer_of_gemini_login():
    c = {"body": "![medium] something", "user": {"login": "gemini-code-assist[bot]"}}
    assert reviews._reviewer_of(c) == "gemini"


def test_reviewer_of_human_reply_is_none():
    assert reviews._reviewer_of({"body": "thanks!", "user": {"login": "dev"}}) is None


def test_build_findings_reconstructs_thread_disposition():
    root = {"id": 1, "in_reply_to_id": None,
            "body": "<!-- Agent: code-reviewer --> bug: foo",
            "path": "x.py", "line": 10, "created_at": "t0",
            "pull_request_url": "https://api.github.com/repos/o/r/pulls/33"}
    reply = {"id": 2, "in_reply_to_id": 1, "body": "Fixed - done", "created_at": "t1"}
    findings = reviews.build_findings([root, reply])
    assert len(findings) == 1
    f = findings[0]
    assert f["reviewer"] == "code-reviewer"
    assert f["disposition"] == "fixed"
    assert f["pr"] == "33"
    assert f["reopened"] is False


def test_build_findings_reopen_and_last_reply_wins():
    root = {"id": 1, "in_reply_to_id": None,
            "body": "<!-- Agent: code-reviewer --> bug",
            "pull_request_url": "https://api.github.com/repos/o/r/pulls/9"}
    r1 = {"id": 2, "in_reply_to_id": 1, "body": "Won't fix - disagree", "created_at": "t1"}
    r2 = {"id": 3, "in_reply_to_id": 1, "body": "Reopening - still broken", "created_at": "t2"}
    r3 = {"id": 4, "in_reply_to_id": 1, "body": "Fixed - ok you were right", "created_at": "t3"}
    f = reviews.build_findings([root, r1, r2, r3])[0]
    assert f["reopened"] is True
    assert f["disposition"] == "fixed"  # last decisive reply wins


def test_build_findings_ignores_unattributable_root():
    root = {"id": 1, "in_reply_to_id": None, "body": "human comment, no agent",
            "user": {"login": "dev"},
            "pull_request_url": "https://api.github.com/repos/o/r/pulls/1"}
    assert reviews.build_findings([root]) == []


def test_synth_scorecard_math():
    findings = [
        {"reviewer": "r", "disposition": "fixed", "reopened": False,
         "severity": "P1", "pr": "1", "disposition_by": "user"},
        {"reviewer": "r", "disposition": "wont_fix", "reopened": False,
         "severity": "P2", "pr": "1"},
        {"reviewer": "r", "disposition": "withdrawn", "reopened": False,
         "severity": "P3", "pr": "2"},
        {"reviewer": "r", "disposition": "unresolved", "reopened": True,
         "severity": None, "pr": "2"},
    ]
    card = reviews.synth(findings)["scorecards"][0]
    assert card["findings"] == 4
    assert card["prs"] == 2
    assert card["acceptance_value"] == round(1 / 3, 3)  # fixed / (fixed+wont_fix+withdrawn)
    assert card["false_positive_rate"] == 0.25  # withdrawn / findings
    assert card["wont_fix_rate"] == 0.25
    assert card["unresolved_rate"] == 0.25
    assert card["reopened"] == 1
    assert card["taste_user"] == 1


def test_discover_reviewer_finds_custom_names():
    # explicit <name>-reviewer token, anywhere
    assert (reviews._discover_reviewer("morpheme-surface-identity-reviewer review for PR #5")
            == "morpheme-surface-identity-reviewer")
    assert reviews._discover_reviewer("clarity-reviewer review (rework)") == "clarity-reviewer"
    # legacy '<name> review ...' shape -> normalized to the -reviewer suffix
    assert reviews._discover_reviewer("test-coverage review PR 610") == "test-coverage-reviewer"
    # unattributable (bundled spawn / generic prose) -> None
    assert reviews._discover_reviewer("Spawn the diff-relevant reviewers (a, b)") is None
    assert reviews._discover_reviewer("just some discussion") is None


def test_resolve_reviewer_breaks_the_canon_circularity():
    # A custom reviewer that never posted a finding is NOT in canon...
    canon = {"code-reviewer", "pr-test-analyzer"}
    desc = "generator-contract-reviewer review for PR #33"
    assert reviews._match_reviewer(desc, canon) is None
    # ...but _resolve_reviewer (used by coverage/harvest) still finds it.
    assert reviews._resolve_reviewer(desc, canon) == "generator-contract-reviewer"


def test_resolve_reviewer_prefers_canon_for_irregular_defaults():
    # pr-test-analyzer doesn't end in -reviewer; canon must win so discovery
    # doesn't mangle it into 'pr-test-analyzer-reviewer'.
    canon = {"pr-test-analyzer"}
    assert reviews._resolve_reviewer("pr-test-analyzer review for PR #1", canon) == "pr-test-analyzer"


def test_read_markers_enforces_kind_contract(markers_home):
    lines = [
        {"ts": "t", "skill": "prl", "kind": "reviewer-finding", "pr": 33,
         "reviewer": "code-reviewer", "severity": "P2", "file": "x.py", "line": 1,
         "disposition": "fixed", "disposition_by": "user", "finding": "real one"},
        {"ts": "t", "skill": "prl", "reviewer": "ghost", "finding": "no kind"},
        {"ts": "t", "skill": "miner", "kind": "insight", "text": "an insight"},
        {"ts": "t", "skill": "prl", "kind": "reviewer-finding", "finding": "anon"},
    ]
    (markers_home / "prl.jsonl").write_text(
        "\n".join(json.dumps(x) for x in lines) + "\n", encoding="utf-8")
    out = reviews.read_markers()
    assert len(out) == 1  # only the well-formed reviewer-finding survives
    assert out[0]["reviewer"] == "code-reviewer"
    assert out[0]["disposition_by"] == "user"
    assert out[0]["pr"] == "33"


# --- roster-seeded reviewer canonicalization -------------------------------
# Seeding the fold from the finding set alone made it source-dependent: under
# `--source markers`, `clarity` had no `clarity-reviewer` sibling to fold onto,
# so one reviewer scored as two rows there and one row under `--source all`.


def test_canonical_map_folds_bare_name_onto_roster_name(monkeypatch):
    monkeypatch.setattr(reviews, "roster_reviewers", lambda: {"clarity-reviewer"})
    findings = [{"reviewer": "clarity"}]  # suffixed form absent from THIS set
    assert reviews._canonical_reviewer_map(findings)["clarity"] == "clarity-reviewer"


def test_canonical_map_leaves_non_roster_names_alone(monkeypatch):
    monkeypatch.setattr(reviews, "roster_reviewers", lambda: {"clarity-reviewer"})
    findings = [{"reviewer": "gemini"}, {"reviewer": "both"}]
    m = reviews._canonical_reviewer_map(findings)
    assert m["gemini"] == "gemini" and m["both"] == "both"


def test_canonical_map_still_folds_within_finding_set(monkeypatch):
    """Original behavior survives when the roster is empty (non-roster repo)."""
    monkeypatch.setattr(reviews, "roster_reviewers", lambda: set())
    findings = [{"reviewer": "test-coverage"}, {"reviewer": "test-coverage-reviewer"}]
    m = reviews._canonical_reviewer_map(findings)
    assert m["test-coverage"] == "test-coverage-reviewer"


def test_roster_reviewers_reads_specs_and_headings(tmp_path, monkeypatch):
    (tmp_path / ".reviewers").mkdir()
    (tmp_path / ".reviewers" / "spec-reviewer.md").write_text("x", encoding="utf-8")
    (tmp_path / "AGENT-REVIEWERS.md").write_text(
        "# Agents\n\n## heading-reviewer\n\n## Not A Name\n", encoding="utf-8")
    monkeypatch.setattr(reviews.config, "git_root", lambda cwd=None: str(tmp_path))
    names = reviews.roster_reviewers()
    assert "spec-reviewer" in names and "heading-reviewer" in names
    assert "Not A Name" not in names  # prose heading, not a reviewer slug
