"""cli.py gate — the contract with systemd ExecCondition / ExecStartPost.

  ExecCondition=dream gate --check X --peek   -> 0 run, SKIP (75) nothing new
  ExecStartPost=dream gate --check X          -> records what --peek saw;
                                                 1 only if state is unusable

ExecCondition reads every exit from 1 to 254 as "skip", so a deliberate skip
uses 75 and the `dream` wrapper turns any other --peek failure into a loud 0.
"""

import argparse
import json
import os
import subprocess

import pytest

from dreamlib import cli

DREAM = os.path.join(os.path.dirname(__file__), "..", "scripts", "dream")


def _args(check="sessions", peek=True):
    return argparse.Namespace(check=check, peek=peek)


def _user(uid, text):
    return {"type": "user", "uuid": uid, "message": {"role": "user", "content": text}}


@pytest.fixture
def home(tmp_path, monkeypatch):
    monkeypatch.setenv("DREAM_HOME", str(tmp_path / "h"))
    (tmp_path / "h").mkdir()
    return tmp_path / "h"


@pytest.fixture
def logs(tmp_path, monkeypatch):
    d = tmp_path / "logs"
    d.mkdir()
    monkeypatch.setattr(cli, "PROJECT_LOGS", str(d))
    return d


def _session(logs, name, *texts):
    events = [_user(f"u{i}", t) for i, t in enumerate(texts)]
    (logs / f"{name}.jsonl").write_text("\n".join(json.dumps(e) for e in events))


# --- the real sessions fingerprint ------------------------------------------

def test_missing_log_dir_is_unknown_not_nothing(tmp_path, monkeypatch):
    """A missing dir usually means the probe is looking in the wrong place."""
    monkeypatch.setattr(cli, "PROJECT_LOGS", str(tmp_path / "nope"))
    assert cli._sessions_fingerprint() is cli.UNKNOWN


def test_unreadable_log_dir_is_unknown(logs):
    if os.geteuid() == 0:
        pytest.skip("root can read anything")
    logs.chmod(0o000)
    try:
        assert cli._sessions_fingerprint() is cli.UNKNOWN
    finally:
        logs.chmod(0o755)


def test_empty_log_dir_is_nothing(logs):
    assert cli._sessions_fingerprint() == cli.NOTHING
    assert cli.NOTHING is not cli.UNKNOWN


def test_logs_with_no_events_are_unknown(logs):
    (logs / "bad.jsonl").write_text("{not json")
    assert cli._sessions_fingerprint() is cli.UNKNOWN


@pytest.mark.skipif(os.geteuid() == 0, reason="root reads mode-000 files")
def test_one_unreadable_log_makes_the_signal_unknown(logs):
    """Skipping the unreadable one would leave only the self-run, read as
    NOTHING, and skip the job with real input on disk."""
    _session(logs, "a", "/dream")
    _session(logs, "b", "real work")
    assert cli._sessions_fingerprint() not in (cli.NOTHING, cli.UNKNOWN)  # control
    (logs / "b.jsonl").chmod(0)
    try:
        assert cli._sessions_fingerprint() is cli.UNKNOWN
    finally:
        (logs / "b.jsonl").chmod(0o600)


def test_self_runs_are_not_minable(logs):
    _session(logs, "a", "/dream")
    _session(logs, "b", "run the dream-reviewers skill")
    assert cli._sessions_fingerprint() == cli.NOTHING


def test_a_work_session_among_self_runs_is_minable(logs):
    _session(logs, "a", "/dream")
    _session(logs, "b", "fix the failing test")
    assert cli._sessions_fingerprint() not in (cli.NOTHING, cli.UNKNOWN)


def test_newest_session_is_included(logs):
    """Excluding the newest (possibly live) session deadlocks the gate."""
    _session(logs, "only", "fix the failing test")
    assert cli._sessions_fingerprint() not in (cli.NOTHING, cli.UNKNOWN)


def test_new_content_changes_the_fingerprint(logs):
    _session(logs, "a", "fix the failing test")
    before = cli._sessions_fingerprint()
    _session(logs, "b", "add the export command")
    assert cli._sessions_fingerprint() != before


def test_a_growing_session_changes_the_fingerprint(logs):
    """Same file, more content - what a live session does. A fingerprint keyed
    on file names would miss it."""
    _session(logs, "a", "fix the failing test")
    before = cli._sessions_fingerprint()
    _session(logs, "a", "fix the failing test", "now add a regression test")
    assert cli._sessions_fingerprint() != before


# --- --peek (ExecCondition) ---------------------------------------------------

def test_nothing_to_mine_skips(home, monkeypatch):
    monkeypatch.setattr(cli, "_sessions_fingerprint", lambda: cli.NOTHING)
    assert cli.cmd_gate(_args()) == cli.SKIP


def test_probe_failure_fails_open(home, monkeypatch):
    monkeypatch.setattr(cli, "_sessions_fingerprint", lambda: cli.UNKNOWN)
    assert cli.cmd_gate(_args()) == 0


def test_skip_code_is_not_one(home):
    """Python exits 1 on any uncaught exception, so 1 cannot mean skip."""
    assert cli.SKIP not in (0, 1, 2)


def test_peek_runs_on_new_input_and_does_not_record_it(home, monkeypatch):
    monkeypatch.setattr(cli, "_sessions_fingerprint", lambda: "fp1")
    assert cli.cmd_gate(_args()) == 0
    state = json.loads((home / "gate.json").read_text())
    assert cli._sessions_scope() not in state


def test_truncated_state_runs_and_is_left_alone(home, monkeypatch):
    (home / "gate.json").write_text("{truncated")
    monkeypatch.setattr(cli, "_sessions_fingerprint", lambda: "fp1")
    assert cli.cmd_gate(_args()) == 0
    assert (home / "gate.json").read_text() == "{truncated"


def test_wrong_shape_state_runs_and_is_left_alone(home, monkeypatch):
    (home / "gate.json").write_text("[1]")
    monkeypatch.setattr(cli, "_sessions_fingerprint", lambda: "fp1")
    assert cli.cmd_gate(_args()) == 0
    assert cli.cmd_gate(_args(peek=False)) == 1  # ExecStartPost: unit failed
    assert (home / "gate.json").read_text() == "[1]"


# --- without --peek (ExecStartPost) ------------------------------------------

def test_record_then_unchanged_input_skips(home, monkeypatch):
    monkeypatch.setattr(cli, "_sessions_fingerprint", lambda: "fp1")
    assert cli.cmd_gate(_args()) == 0
    assert cli.cmd_gate(_args(peek=False)) == 0
    assert cli.cmd_gate(_args()) == cli.SKIP


def test_record_keeps_what_peek_saw_so_mid_run_input_stays_new(home, monkeypatch):
    monkeypatch.setattr(cli, "_sessions_fingerprint", lambda: "seen-before-run")
    assert cli.cmd_gate(_args()) == 0
    monkeypatch.setattr(cli, "_sessions_fingerprint", lambda: "arrived-during-run")
    assert cli.cmd_gate(_args(peek=False)) == 0
    assert cli.cmd_gate(_args()) == 0  # the mid-run input is still new


def test_record_with_nothing_pending_records_nothing(home, monkeypatch):
    """The record step never probes: anything it saw after the job would
    include input that arrived during the run."""
    monkeypatch.setattr(cli, "_sessions_fingerprint", lambda: "fp1")
    assert cli.cmd_gate(_args(peek=False)) == 0
    assert cli.cmd_gate(_args()) == 0  # fp1 was not marked consumed


def test_unknown_peek_drops_a_pending_left_by_a_failed_job(home, monkeypatch):
    monkeypatch.setattr(cli, "_sessions_fingerprint", lambda: "old")
    cli.cmd_gate(_args())               # night 1: job fails, no record step
    monkeypatch.setattr(cli, "_sessions_fingerprint", lambda: cli.UNKNOWN)
    assert cli.cmd_gate(_args()) == 0   # night 2: runs blind
    cli.cmd_gate(_args(peek=False))
    state = json.loads((home / "gate.json").read_text())
    assert cli._sessions_scope() not in state


def test_unwritable_state_fails_the_record_step(home, monkeypatch):
    monkeypatch.setattr(cli, "_sessions_fingerprint", lambda: "fp1")
    cli.cmd_gate(_args())
    monkeypatch.setattr(cli, "_write_gate_state", lambda s: (_ for _ in ()).throw(OSError("ro")))
    with pytest.raises(OSError):
        cli.cmd_gate(_args(peek=False))


def test_recording_one_check_preserves_the_other(home, monkeypatch):
    (home / "gate.json").write_text(json.dumps({"prs": "p1", "prs_at": "t"}))
    monkeypatch.setattr(cli, "_sessions_fingerprint", lambda: "s1")
    cli.cmd_gate(_args())
    cli.cmd_gate(_args(peek=False))
    assert json.loads((home / "gate.json").read_text())["prs"] == "p1"


def test_pending_belongs_to_one_check(home, monkeypatch):
    """Recording sessions must not consume what the prs peek saw."""
    monkeypatch.setattr(cli, "_prs_fingerprint", lambda: "p1")
    monkeypatch.setattr(cli, "_sessions_fingerprint", lambda: "s1")
    cli.cmd_gate(_args("prs"))
    cli.cmd_gate(_args())
    cli.cmd_gate(_args(peek=False))
    cli.cmd_gate(_args("prs", peek=False))
    assert cli.cmd_gate(_args("prs")) == cli.SKIP


def test_two_worktrees_get_separate_watermarks(home, monkeypatch):
    """The sessions signal is per-worktree while the state file is shared, so
    each worktree needs its own watermark or the gate never closes."""
    for logs, fp in (("/logs/-wt-a", "a1"), ("/logs/-wt-b", "b1")):
        monkeypatch.setattr(cli, "PROJECT_LOGS", logs)
        monkeypatch.setattr(cli, "_sessions_fingerprint", lambda fp=fp: fp)
        cli.cmd_gate(_args())
        cli.cmd_gate(_args(peek=False))
    monkeypatch.setattr(cli, "PROJECT_LOGS", "/logs/-wt-a")
    monkeypatch.setattr(cli, "_sessions_fingerprint", lambda: "a1")
    assert cli.cmd_gate(_args()) == cli.SKIP


def test_state_path_follows_dream_home(tmp_path, monkeypatch):
    monkeypatch.setenv("DREAM_HOME", str(tmp_path / "x"))
    assert cli._gate_state_path().startswith(str(tmp_path / "x"))


# --- prs probe ---------------------------------------------------------------

class _R:
    def __init__(self, rc, out, err=""):
        self.returncode, self.stdout, self.stderr = rc, out, err


def test_prs_probe_runs_gh_in_the_project_dir(tmp_path, monkeypatch):
    monkeypatch.setenv("DREAM_PROJECT_DIR", str(tmp_path))
    seen = {}

    def fake_run(cmd, **kw):
        seen["cwd"] = kw.get("cwd")
        return _R(0, '[{"number":1}]')

    monkeypatch.setattr(cli.subprocess, "run", fake_run)
    assert cli._prs_fingerprint() == '[{"number":1}]'
    assert seen["cwd"] == str(tmp_path)


@pytest.mark.parametrize("result", [
    _R(1, "", "auth failed"),
    _R(1, '[{"number":1}]', "rate limited"),  # failed, but printed something
    _R(0, ""),
    _R(0, "  \n"),
])
def test_prs_probe_failures_are_unknown(monkeypatch, result):
    """An empty fingerprint recorded as the watermark would match every later
    empty result and skip forever."""
    monkeypatch.setattr(cli.subprocess, "run", lambda *a, **k: result)
    assert cli._prs_fingerprint() is cli.UNKNOWN


# --- the `dream` wrapper: a broken gate must run, never skip ----------------

def _wrapper(*args, home):
    return subprocess.run([DREAM, *args], env={**os.environ, "DREAM_HOME": str(home)},
                          capture_output=True, text=True)


def test_wrapper_turns_a_bad_argument_into_a_loud_run(home):
    r = _wrapper("gate", "--check", "nonsense", "--peek", home=home)
    assert r.returncode == 0
    assert "FAILED" in r.stderr


def test_wrapper_passes_a_deliberate_skip_through(tmp_path, home):
    proj, h = tmp_path / "proj", tmp_path / "fakehome"
    proj.mkdir()
    (h / ".claude" / "projects" / str(proj).replace("/", "-")).mkdir(parents=True)
    r = subprocess.run([DREAM, "gate", "--check", "sessions", "--peek"], cwd=proj,
                       env={**os.environ, "HOME": str(h), "DREAM_HOME": str(home)},
                       capture_output=True, text=True)
    assert r.returncode == cli.SKIP, r.stderr


def _fake_cli(tmp_path, rc):
    """A copy of the wrapper whose Python just exits rc."""
    d = tmp_path / "fake"
    (d / "dreamlib").mkdir(parents=True)
    (d / "dreamlib" / "__init__.py").write_text("")
    (d / "dreamlib" / "cli.py").write_text(f"raise SystemExit({rc})\n")
    w = d / "dream"
    w.write_text(open(DREAM).read())
    w.chmod(0o755)
    return str(w)


@pytest.mark.parametrize("rc,want", [(0, 0), (75, 75), (1, 0), (2, 0), (120, 0)])
def test_wrapper_peek_maps_every_failure_to_a_run(tmp_path, rc, want):
    r = subprocess.run([_fake_cli(tmp_path, rc), "gate", "--check", "sessions", "--peek"],
                       capture_output=True, text=True)
    assert r.returncode == want
    assert ("FAILED" in r.stderr) == (want != rc)


def test_wrapper_record_step_passes_a_failure_through(tmp_path):
    """ExecStartPost: non-zero marks the unit failed, which is the loud signal."""
    r = subprocess.run([_fake_cli(tmp_path, 1), "gate", "--check", "sessions"],
                       capture_output=True, text=True)
    assert r.returncode == 1


def test_a_full_stderr_does_not_turn_a_skip_into_a_run(tmp_path, home):
    proj, h = tmp_path / "proj", tmp_path / "fakehome"
    proj.mkdir()
    (h / ".claude" / "projects" / str(proj).replace("/", "-")).mkdir(parents=True)
    with open("/dev/full", "w") as full:
        r = subprocess.run([DREAM, "gate", "--check", "sessions", "--peek"], cwd=proj,
                           env={**os.environ, "HOME": str(h), "DREAM_HOME": str(home)},
                           stderr=full)
    assert r.returncode == cli.SKIP
