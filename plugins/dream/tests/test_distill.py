"""distill.py — friction routing + occurrence dedupe + self-run detection."""

from dreamlib import distill, parse


def _user(uid, text):
    return {"type": "user", "uuid": uid, "message": {"role": "user", "content": text}}


def test_is_self_run_detects_dream_invocation_as_opening_turn(session_jsonl):
    for opener in (
        "Run the dream skill on my logs",
        "run the dream-reviewers skill",
        "/dream",
        "/dream-reviewers please",
    ):
        path = session_jsonl([_user("u1", opener)])
        assert distill.is_self_run(parse.load_session(path)) is True, opener


def test_is_self_run_detects_dream_review_triage_opener(session_jsonl):
    # The dream-review triage cron opens with this — previously fell through the
    # guard and got distilled as if it were wyrd engineering work.
    triage = ("Triage the pending dream recommendation files in "
              "~/.dream/wyrd/review/pending/. Only consider files matching *-dream.md")
    path = session_jsonl([_user("u1", triage)])
    assert distill.is_self_run(parse.load_session(path)) is True


def test_is_self_run_dir_reference_catches_novel_dream_job(session_jsonl):
    # Belt-and-braces: an opener steering at the ~/.dream home is a self-run even
    # with a prompt shape not in the explicit alternation.
    path = session_jsonl([_user("u1", "Summarize everything under ~/.dream/wyrd/reviews and report")])
    assert distill.is_self_run(parse.load_session(path)) is True


def test_is_self_run_false_for_real_work_and_midsession_invocation(session_jsonl):
    # Opening turn is real work; a later "run the dream skill" turn must NOT flip it.
    path = session_jsonl([
        _user("u1", "read the kenning docs and summarize DECISIONS.md"),
        _user("u2", "run the dream skill"),
    ])
    assert distill.is_self_run(parse.load_session(path)) is False
    # An unrelated opener is also not a self-run.
    p2 = session_jsonl([_user("u1", "fix the failing test in reviews.py")])
    assert distill.is_self_run(parse.load_session(p2)) is False


def test_dedupe_friction_collapses_identical_with_occurrences():
    fr = [
        {"kind": "error", "detail": "boom", "user_said": ""},
        {"kind": "error", "detail": "boom", "user_said": ""},
        {"kind": "error", "detail": "different", "user_said": ""},
    ]
    out = distill._dedupe_friction(fr)
    assert [f["occurrences"] for f in out] == [2, 1]
    assert out[0]["detail"] == "boom"
    assert out[1]["detail"] == "different"


def test_dedupe_friction_preserves_first_appearance_order():
    fr = [
        {"kind": "correction", "user_said": "b", "detail": ""},
        {"kind": "correction", "user_said": "a", "detail": ""},
        {"kind": "correction", "user_said": "b", "detail": ""},
    ]
    out = distill._dedupe_friction(fr)
    assert [f["user_said"] for f in out] == ["b", "a"]


def test_extract_user_correction_pulls_embedded_instruction():
    blob = "The tool use was rejected. the user said: do it the other way"
    assert distill._extract_user_correction(blob) == "do it the other way"


def test_heuristic_digest_routes_error_and_correction(session_jsonl):
    path = session_jsonl(
        [
            {"type": "user", "uuid": "u0",
             "message": {"role": "user", "content": "please refactor X"}},
            {"type": "assistant", "uuid": "a1",
             "message": {"role": "assistant", "content": [
                 {"type": "text", "text": "I'll run a command"},
                 {"type": "tool_use", "id": "t1", "name": "Bash",
                  "input": {"command": "bad"}},
             ]}},
            {"type": "user", "uuid": "u1",
             "message": {"role": "user", "content": [
                 {"type": "tool_result", "tool_use_id": "t1",
                  "is_error": True, "content": "error: boom"},
             ]}},
            {"type": "user", "uuid": "u2",
             "message": {"role": "user",
                         "content": "no, that's wrong, do it differently"}},
        ]
    )
    h = distill.heuristic_digest(parse.load_session(path))
    assert h["stats"]["errors"] == 1
    assert h["stats"]["corrections"] == 1  # "no"/"wrong" match _CORRECTION
    assert h["tools_used"].get("Bash") == 1
    assert h["stats"]["denials"] == 0
