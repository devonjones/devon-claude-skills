"""parse.py — harness-noise stripping, session loading, tool extraction."""

from dreamlib import parse


def test_clean_user_text_strips_harness_wrappers():
    s = "<system-reminder>internal noise</system-reminder>real question?"
    assert parse.clean_user_text(s) == "real question?"


def test_clean_user_text_collapses_whitespace():
    assert parse.clean_user_text("a   b\n\n\n\nc") == "a b\n\nc"


def test_clean_user_text_strips_command_blocks():
    s = "<command-name>/foo</command-name> after"
    assert parse.clean_user_text(s) == "after"


def test_load_session_extracts_tool_uses_and_results(session_jsonl):
    path = session_jsonl(
        [
            {
                "type": "user", "sessionId": "s1", "gitBranch": "main",
                "timestamp": "2026-01-01T00:00:00Z", "uuid": "u1",
                "message": {"role": "user", "content": "do the thing please"},
            },
            {
                "type": "assistant", "uuid": "a1",
                "message": {"role": "assistant", "content": [
                    {"type": "text", "text": "running it"},
                    {"type": "tool_use", "id": "t1", "name": "Bash",
                     "input": {"command": "ls"}},
                ]},
            },
            {
                "type": "user", "uuid": "u2",
                "message": {"role": "user", "content": [
                    {"type": "tool_result", "tool_use_id": "t1",
                     "is_error": True, "content": "boom"},
                ]},
            },
        ]
    )
    sess = parse.load_session(path)
    assert sess.session_id == "s1"
    assert sess.git_branch == "main"
    assert ("t1", "Bash", {"command": "ls"}) in sess.events[1].tool_uses
    assert sess.tool_names["t1"] == "Bash"
    # (tool_use_id, is_error, content)
    assert sess.events[2].tool_results[0][0] == "t1"
    assert sess.events[2].tool_results[0][1] is True
    assert len(sess.input_hash) == 16  # sha256[:16]


def test_load_session_skips_malformed_lines(tmp_path):
    p = tmp_path / "s.jsonl"
    p.write_text(
        'not json at all\n'
        '{"type":"user","uuid":"u","message":{"role":"user","content":"hello there"}}\n',
        encoding="utf-8",
    )
    sess = parse.load_session(str(p))
    assert len(sess.events) == 1
    assert sess.events[0].text == "hello there"


def test_is_real_user_distinguishes_noise_from_human(session_jsonl):
    path = session_jsonl(
        [
            {"type": "user", "uuid": "u1",
             "message": {"role": "user", "content": "Caveat: harness noise"}},
            {"type": "user", "uuid": "u2",
             "message": {"role": "user", "content": "a genuine human question"}},
            {"type": "user", "uuid": "u3",
             "message": {"role": "user",
                         "content": "<system-reminder>x</system-reminder>"}},
        ]
    )
    sess = parse.load_session(path)
    assert sess.events[0].is_real_user is False  # Caveat: prefix
    assert sess.events[1].is_real_user is True
    assert sess.events[2].is_real_user is False  # cleans to empty
