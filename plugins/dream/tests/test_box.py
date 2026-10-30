"""cli.py box — whole-box distill grouped by repo."""

import json
import os
import subprocess
import time

from dreamlib import cli


def _git(*args, cwd):
    subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True)


def _session(logroot, name, sid, cwd, text="no, not like that", age_days=0):
    d = logroot / name
    d.mkdir(parents=True, exist_ok=True)
    p = d / f"{sid}.jsonl"
    p.write_text(json.dumps({"type": "user", "sessionId": sid, "cwd": cwd,
                             "message": {"role": "user", "content": text}}))
    t = time.time() - age_days * 86400
    os.utime(p, (t, t))
    return p


def _box(tmp_path, monkeypatch, logroot, *extra):
    monkeypatch.setenv("HOME", str(tmp_path / "home"))
    assert cli.main(["box", "--projects", str(logroot), *extra]) == 0
    (manifest,) = (tmp_path / "home" / ".dream" / "box").glob("*-box.json")
    return {r["repo"]: r for r in json.loads(manifest.read_text())["repos"]}


def test_box_folds_worktrees_keeps_nested_repos_and_windows_by_age(tmp_path, monkeypatch):
    repo = tmp_path / "repo"
    repo.mkdir()
    _git("init", "-q", cwd=repo)
    _git("-c", "user.email=a@b", "-c", "user.name=a", "commit", "-q",
         "--allow-empty", "-m", "x", cwd=repo)
    wt = tmp_path / "wt"
    _git("worktree", "add", "-q", str(wt), cwd=repo)
    nested = repo / "nested"
    nested.mkdir()
    _git("init", "-q", cwd=nested)
    plain = tmp_path / "vault"
    plain.mkdir()

    logs = tmp_path / "logs"
    _session(logs, "a", "s1", str(repo))
    _session(logs, "b", "s2", str(wt))
    _session(logs, "c", "s3", str(nested))
    _session(logs, "d", "s4", str(plain))
    _session(logs, "e", "s5", str(repo), age_days=30)
    (logs / "a" / "memory").mkdir()

    repos = _box(tmp_path, monkeypatch, logs, "--include-tmp")
    assert sorted(s["session_id"] for s in repos[str(repo)]["sessions"]) == ["s1", "s2"]
    assert [s["session_id"] for s in repos[str(nested)]["sessions"]] == ["s3"]
    assert [s["session_id"] for s in repos[str(plain)]["sessions"]] == ["s4"]
    assert repos[str(repo)]["memory_dirs"] == [str(logs / "a" / "memory")]
    assert repos[str(repo)]["sessions"][0]["corrections"] == 1
    digest = json.loads(open(repos[str(repo)]["sessions"][0]["digest"]).read())
    assert digest["schema"] == cli.DIGEST_SCHEMA


def test_box_skips_tmp_sessions_by_default(tmp_path, monkeypatch):
    logs = tmp_path / "logs"
    _session(logs, "a", "s1", "/tmp/cryo-wt-abc/store")
    _session(logs, "b", "s2", "/home/someone/gone-repo")
    repos = _box(tmp_path, monkeypatch, logs)
    assert list(repos) == ["/home/someone/gone-repo"]
