"""distill.py — friction routing + occurrence dedupe."""

from dreamlib import distill, parse


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
