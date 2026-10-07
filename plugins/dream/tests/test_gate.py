"""cli.py gate — the contract with systemd ExecCondition / ExecStartPost.

  ExecCondition=dream gate --check X --peek   -> 0 run, SKIP (75) nothing new
  ExecStartPost=dream gate --check X          -> records what --peek saw, or
                                                 STATE_FAILED; see the wrapper's
                                                 comment for how exits reach systemd
"""

import argparse
import json
import os
import subprocess

import pytest

from dreamlib import cli

DREAM = os.path.join(os.path.dirname(__file__), "..", "scripts", "dream")
# Subprocesses must not inherit the caller's DREAM_* settings or PYTHON*
# interpreter flags (the PYTHONSAFEPATH test sets its own).
_ENV = {k: v for k, v in os.environ.items()
        if not k.startswith(("DREAM_", "PYTHON"))}


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
    assert cli.cmd_gate(_args(peek=False)) == cli.STATE_FAILED
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


def test_a_blind_run_fails_the_record_step_once(home, monkeypatch):
    monkeypatch.setattr(cli, "_sessions_fingerprint", lambda: cli.UNKNOWN)
    assert cli.cmd_gate(_args()) == 0
    assert cli.cmd_gate(_args(peek=False)) == cli.STATE_FAILED
    monkeypatch.setattr(cli, "_sessions_fingerprint", lambda: "fp1")
    assert cli.cmd_gate(_args()) == 0
    assert cli.cmd_gate(_args(peek=False)) == 0


def test_a_later_peek_clears_a_blind_mark_left_by_a_failed_job(home, monkeypatch):
    monkeypatch.setattr(cli, "_sessions_fingerprint", lambda: cli.UNKNOWN)
    cli.cmd_gate(_args())                   # night 1: blind run, job fails, no record
    monkeypatch.setattr(cli, "_sessions_fingerprint", lambda: "fp1")
    assert cli.cmd_gate(_args()) == 0       # night 2: the signal is back
    assert cli.cmd_gate(_args(peek=False)) == 0


def test_a_record_step_with_no_peek_fails_and_records_nothing(home, monkeypatch):
    """No peek ran. The record step never probes either: what it saw after
    the job would include input that arrived during the run."""
    monkeypatch.setattr(cli, "_sessions_fingerprint", lambda: "fp1")
    assert cli.cmd_gate(_args(peek=False)) == cli.STATE_FAILED
    assert cli.cmd_gate(_args()) == 0  # fp1 was not marked consumed


def test_a_record_for_another_check_fails(home, monkeypatch):
    monkeypatch.setattr(cli, "_sessions_fingerprint", lambda: "s1")
    assert cli.cmd_gate(_args()) == 0
    assert cli.cmd_gate(_args("prs", peek=False)) == cli.STATE_FAILED
    assert cli.cmd_gate(_args(peek=False)) == 0  # control: the matching check


def test_a_blind_mark_belongs_to_one_check(home, monkeypatch):
    monkeypatch.setattr(cli, "_sessions_fingerprint", lambda: cli.UNKNOWN)
    monkeypatch.setattr(cli, "_prs_fingerprint", lambda: "p1")
    cli.cmd_gate(_args())              # sessions runs blind
    cli.cmd_gate(_args("prs"))         # prs peeks meanwhile
    cli.cmd_gate(_args("prs", peek=False))
    state = json.loads((home / "gate.json").read_text())
    assert f"{cli._sessions_scope()}_blind" in state  # prs did not consume it
    assert cli.cmd_gate(_args(peek=False)) == cli.STATE_FAILED


def test_a_probe_that_raises_runs_blind(home, logs, monkeypatch):
    """A log pruned between glob and stat, or a dangling symlink."""
    (logs / "gone.jsonl").symlink_to(logs / "nowhere")
    assert cli.cmd_gate(_args()) == 0
    state = json.loads((home / "gate.json").read_text())
    assert f"{cli._sessions_scope()}_blind" in state
    assert cli.cmd_gate(_args(peek=False)) == cli.STATE_FAILED


def test_unknown_peek_drops_a_pending_left_by_a_failed_job(home, monkeypatch):
    monkeypatch.setattr(cli, "_sessions_fingerprint", lambda: "old")
    cli.cmd_gate(_args())               # night 1: job fails, no record step
    monkeypatch.setattr(cli, "_sessions_fingerprint", lambda: cli.UNKNOWN)
    assert cli.cmd_gate(_args()) == 0   # night 2: runs blind
    cli.cmd_gate(_args(peek=False))
    state = json.loads((home / "gate.json").read_text())
    assert cli._sessions_scope() not in state


@pytest.mark.skipif(os.geteuid() == 0, reason="root writes anywhere")
def test_an_unwritable_state_dir_fails_the_record_step(home, monkeypatch):
    """Steady state: the lock file already exists and the peek fails open."""
    monkeypatch.setattr(cli, "_sessions_fingerprint", lambda: "fp1")
    cli.cmd_gate(_args())
    cli.cmd_gate(_args(peek=False))
    monkeypatch.setattr(cli, "_sessions_fingerprint", lambda: "fp2")
    home.chmod(0o500)
    try:
        assert cli.cmd_gate(_args()) == 0
        assert cli.cmd_gate(_args(peek=False)) == cli.STATE_FAILED
    finally:
        home.chmod(0o700)
    assert cli.cmd_gate(_args()) == 0                 # control: writable again
    assert cli.cmd_gate(_args(peek=False)) == 0


def test_every_peek_drops_a_pending_left_by_a_failed_job(home, monkeypatch):
    for later in (cli.NOTHING, "watermark"):
        (home / "gate.json").unlink(missing_ok=True)
        monkeypatch.setattr(cli, "_sessions_fingerprint", lambda: "watermark")
        cli.cmd_gate(_args())
        cli.cmd_gate(_args(peek=False))
        monkeypatch.setattr(cli, "_sessions_fingerprint", lambda: "C")
        cli.cmd_gate(_args())                  # job fails, no record step
        monkeypatch.setattr(cli, "_sessions_fingerprint", lambda later=later: later)
        assert cli.cmd_gate(_args()) == cli.SKIP
        state = json.loads((home / "gate.json").read_text())
        assert f"{cli._sessions_scope()}_pending" not in state, later


def test_the_gate_waits_for_the_state_lock(home, tmp_path):
    import fcntl
    proj, h = tmp_path / "proj", tmp_path / "fakehome"
    proj.mkdir()
    (h / ".claude" / "projects" / str(proj).replace("/", "-")).mkdir(parents=True)
    # Held shared, so the gate blocks only if it asks for an exclusive lock.
    with open(home / "gate.json.lock", "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_SH)
        with pytest.raises(subprocess.TimeoutExpired):
            subprocess.run([DREAM, "gate", "--check", "sessions", "--peek"], cwd=proj, timeout=2,
                           env={**_ENV, "HOME": str(h), "DREAM_HOME": str(home)},
                           capture_output=True)


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


# --- the `dream` wrapper ------------------------------------------------------

def _wrapper(*args, home):
    return subprocess.run([DREAM, *args], env={**_ENV, "DREAM_HOME": str(home)},
                          capture_output=True, text=True)


@pytest.mark.parametrize("bad", [
    ["gate", "--check", "nonsense", "--peek"],
    ["gate", "-peek"], ["gate", "--Peek"],          # peek typos without --p
    ["gate", "--check", "prs", "--prs"],             # record typo with --p
    ["gate", "--check", "nonsense"],
    ["gat", "--check", "sessions", "--peek"],        # misspelt subcommand
])
def test_wrapper_fails_the_unit_on_any_bad_argument(home, bad):
    r = _wrapper(*bad, home=home)
    assert r.returncode == 255
    assert "FAILED" in r.stderr


@pytest.mark.skipif(os.geteuid() == 0, reason="root writes anywhere")
def test_wrapper_record_step_fails_the_unit_on_unwritable_state(home):
    """Real wrapper, real CLI: STATE_FAILED reaches systemd as 255."""
    # A real pending value, so only the unwritable dir can fail the record step.
    (home / "gate.json").write_text(json.dumps({"prs_pending": "p1"}))
    (home / "gate.json.lock").write_text("")
    for sub in ("digests", "review", "reviews"):
        (home / sub).mkdir()
    home.chmod(0o500)
    try:
        r = _wrapper("gate", "--check", "prs", home=home)
    finally:
        home.chmod(0o700)
    assert r.returncode == 255
    assert f"exit {cli.STATE_FAILED}" in r.stderr


@pytest.mark.parametrize("args,real", [
    (["gate", "--check", "sessions", "--peek"], "gate[sessions]"),
    (["stats"], "no digests yet"),
])
def test_a_dreamlib_in_the_cwd_does_not_shadow_the_real_one(tmp_path, home, args, real):
    plant = tmp_path / "plant"
    (plant / "dreamlib").mkdir(parents=True)
    (plant / "dreamlib" / "__init__.py").write_text("")
    (plant / "dreamlib" / "cli.py").write_text("raise SystemExit(75)\n")
    r = subprocess.run([DREAM, *args], cwd=plant,
                       env={**_ENV, "HOME": str(tmp_path), "DREAM_HOME": str(home)},
                       capture_output=True, text=True)
    assert r.returncode != 75, r.stderr  # the plant exits 75
    assert real in r.stderr               # output only the real CLI prints


def test_wrapper_passes_a_deliberate_skip_through(tmp_path, home):
    proj, h = tmp_path / "proj", tmp_path / "fakehome"
    proj.mkdir()
    (h / ".claude" / "projects" / str(proj).replace("/", "-")).mkdir(parents=True)
    r = subprocess.run([DREAM, "gate", "--check", "sessions", "--peek"], cwd=proj,
                       env={**_ENV, "HOME": str(h), "DREAM_HOME": str(home)},
                       capture_output=True, text=True)
    assert r.returncode == cli.SKIP, r.stderr


def _fake_cli(tmp_path, rc):
    """A copy of the wrapper whose Python just exits rc."""
    d = tmp_path / "fake"
    (d / "dreamlib").mkdir(parents=True)
    (d / "dreamlib" / "__init__.py").write_text("")
    (d / "dreamlib" / "cli.py").write_text(f"raise SystemExit({rc})\n")
    (d / "dream_main.py").write_text(open(os.path.join(os.path.dirname(DREAM), "dream_main.py")).read())
    w = d / "dream"
    w.write_text(open(DREAM).read())
    w.chmod(0o755)
    return str(w)


@pytest.mark.parametrize("args", [["gate", "--check", "sessions", "--peek"],
                                  ["gate", "--check", "sessions"], ["stats"]])
@pytest.mark.parametrize("rc", [0, 75, 1, 2, 74, 120])
def test_wrapper_passes_0_and_75_and_fails_everything_else(tmp_path, args, rc):
    r = subprocess.run([_fake_cli(tmp_path, rc), *args],
                       cwd=tmp_path, capture_output=True, text=True)
    assert r.returncode == (rc if rc in (0, 75) else 255)
    assert ("FAILED" in r.stderr) == (rc not in (0, 75))


def test_a_full_stderr_does_not_turn_a_skip_into_a_run(tmp_path, home):
    proj, h = tmp_path / "proj", tmp_path / "fakehome"
    proj.mkdir()
    (h / ".claude" / "projects" / str(proj).replace("/", "-")).mkdir(parents=True)
    with open("/dev/full", "w") as full:
        r = subprocess.run([DREAM, "gate", "--check", "sessions", "--peek"], cwd=proj,
                           env={**_ENV, "HOME": str(h), "DREAM_HOME": str(home)},
                           stderr=full)
    assert r.returncode == cli.SKIP


def test_the_wrapper_works_with_pythonsafepath_set(home):
    r = subprocess.run([DREAM, "gate", "--check", "nonsense", "--peek"],
                       env={**_ENV, "DREAM_HOME": str(home), "PYTHONSAFEPATH": "1"},
                       capture_output=True, text=True)
    assert "ModuleNotFoundError" not in r.stderr
    assert "invalid choice" in r.stderr  # the real CLI parsed the arguments


def test_check_is_required(home):
    """A default would let two lines that both omit --check gate on the
    wrong signal and stay green."""
    r = _wrapper("gate", "--peek", home=home)
    assert r.returncode == 255
    assert "--check" in r.stderr
