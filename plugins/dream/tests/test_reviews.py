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
