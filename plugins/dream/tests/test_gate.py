"""cli.py — the gate's exit-code contract with systemd ExecCondition.

0 = run, 1 = nothing new, and anything unanticipated must still be 0. Each
test is written to fail if the behaviour it names is reverted.
"""

import argparse
import json

import pytest

from dreamlib import cli


def _args(check="sessions", advance=False):
    return argparse.Namespace(check=check, advance=advance)


@pytest.fixture
def home(tmp_path, monkeypatch):
    monkeypatch.setenv("DREAM_HOME", str(tmp_path / "h"))
    (tmp_path / "h").mkdir()
    return tmp_path / "h"


def test_nothing_to_mine_skips_rather_than_failing_open(home, monkeypatch):
    """A readable corpus with nothing minable is a determinate answer. Treating
    it as a probe failure would open the gate on every run for a corpus of only
    self-runs."""
    monkeypatch.setattr(cli, "_sessions_fingerprint", lambda: cli.NOTHING)
    assert cli.cmd_gate(_args()) == 1


def test_readable_but_empty_corpus_reports_NOTHING_not_UNKNOWN(tmp_path, monkeypatch):
    """Drives the REAL fingerprint, not a stub.

    The stubbed test above pins cmd_gate's handling of NOTHING; it cannot catch
    _sessions_fingerprint returning the wrong sentinel, because it replaces that
    function. Mutating `return NOTHING` to `return UNKNOWN` left the stubbed test
    green — a fixture that cannot fail, in the test written to prevent one.
    """
    logs = tmp_path / "logs"
    logs.mkdir()
    monkeypatch.setattr(cli, "PROJECT_LOGS", str(logs))
    assert cli._sessions_fingerprint() == cli.NOTHING
    assert cli.NOTHING is not cli.UNKNOWN


def test_probe_failure_fails_open(home, monkeypatch):
    monkeypatch.setattr(cli, "_sessions_fingerprint", lambda: cli.UNKNOWN)
    assert cli.cmd_gate(_args()) == 0


def test_unexpected_error_fails_open_not_skip(home, monkeypatch):
    """ExecCondition reads 1 as an ordinary skip, so a crashing gate that exits 1
    skips every night and looks identical to a quiet day in the journal."""
    def boom():
        raise RuntimeError("boom")
    monkeypatch.setattr(cli, "_sessions_fingerprint", boom)
    assert cli.cmd_gate(_args()) == 0


def test_new_input_runs_without_advancing_the_watermark(home, monkeypatch):
    """The run that consumes the input records it. Advancing at check time meant
    a crashed run's input was marked seen and silently never mined."""
    monkeypatch.setattr(cli, "_sessions_fingerprint", lambda: "deadbeef")
    assert cli.cmd_gate(_args()) == 0
    assert not (home / "gate.json").exists()


def test_advance_records_then_the_same_input_skips(home, monkeypatch):
    monkeypatch.setattr(cli, "_sessions_fingerprint", lambda: "deadbeef")
    assert cli.cmd_gate(_args(advance=True)) == 0
    assert cli.cmd_gate(_args()) == 1


def test_corrupt_state_is_not_overwritten(home, monkeypatch):
    """Valid JSON of the wrong shape must not crash the gate (exit 1 = skip) or
    be treated as empty, which would overwrite the other check's watermark."""
    (home / "gate.json").write_text("[1]", encoding="utf-8")
    monkeypatch.setattr(cli, "_sessions_fingerprint", lambda: "deadbeef")
    assert cli.cmd_gate(_args(advance=True)) == 0
    assert (home / "gate.json").read_text(encoding="utf-8") == "[1]"


def test_advancing_one_check_preserves_the_other(home, monkeypatch):
    (home / "gate.json").write_text(
        json.dumps({"prs": "p1", "prs_at": "t"}), encoding="utf-8")
    monkeypatch.setattr(cli, "_sessions_fingerprint", lambda: "s1")
    assert cli.cmd_gate(_args(advance=True)) == 0
    state = json.loads((home / "gate.json").read_text(encoding="utf-8"))
    assert state["prs"] == "p1"


def test_two_worktrees_get_separate_watermarks(home, monkeypatch):
    """The sessions signal is per-worktree while the state file is shared, so
    each worktree needs its own watermark or the gate never closes."""
    monkeypatch.setattr(cli, "PROJECT_LOGS", "/logs/-wt-a")
    monkeypatch.setattr(cli, "_sessions_fingerprint", lambda: "a1")
    assert cli.cmd_gate(_args(advance=True)) == 0

    monkeypatch.setattr(cli, "PROJECT_LOGS", "/logs/-wt-b")
    monkeypatch.setattr(cli, "_sessions_fingerprint", lambda: "b1")
    assert cli.cmd_gate(_args(advance=True)) == 0

    # Each worktree must now skip on its own unchanged input.
    monkeypatch.setattr(cli, "PROJECT_LOGS", "/logs/-wt-a")
    monkeypatch.setattr(cli, "_sessions_fingerprint", lambda: "a1")
    assert cli.cmd_gate(_args()) == 1


def test_state_path_follows_dream_home(tmp_path, monkeypatch):
    """GATE_STATE was computed at import, so DREAM_HOME could not be repointed
    and importing the module created a directory."""
    monkeypatch.setenv("DREAM_HOME", str(tmp_path / "x"))
    assert cli._gate_state_path().startswith(str(tmp_path / "x"))


def test_prs_probe_runs_gh_in_the_project_dir(tmp_path, monkeypatch):
    """gh locates the repo from its cwd. A systemd unit has its own
    WorkingDirectory, so a probe that inherits the process cwd never finds the
    repo, reports unknown, and the prs gate fails open on every run."""
    monkeypatch.setenv("DREAM_PROJECT_DIR", str(tmp_path))
    seen = {}

    class R:
        returncode, stdout, stderr = 0, '[{"number":1}]', ""

    def fake_run(cmd, **kw):
        seen["cwd"] = kw.get("cwd")
        return R()

    monkeypatch.setattr(cli.subprocess, "run", fake_run)
    assert cli._prs_fingerprint() == '[{"number":1}]'
    assert seen["cwd"] == str(tmp_path)
