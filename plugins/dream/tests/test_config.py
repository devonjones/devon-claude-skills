"""config.py — repo-slug remote-URL parsing + DECISIONS.md corpus discovery."""

import os
import pathlib

from dreamlib import config


def test_repo_slug_parses_ssh(monkeypatch):
    monkeypatch.delenv("DREAM_REPO", raising=False)
    monkeypatch.setattr(
        config, "_run",
        lambda cmd, cwd=None: "git@github.com:owner/repo.git" if "remote" in cmd else "")
    assert config.repo_slug() == "owner/repo"


def test_repo_slug_parses_https(monkeypatch):
    monkeypatch.delenv("DREAM_REPO", raising=False)
    monkeypatch.setattr(
        config, "_run",
        lambda cmd, cwd=None: "https://github.com/owner/repo.git" if "remote" in cmd else "")
    assert config.repo_slug() == "owner/repo"


def test_repo_slug_env_override(monkeypatch):
    monkeypatch.setenv("DREAM_REPO", "x/y")
    assert config.repo_slug() == "x/y"


def test_repo_slug_prefers_gh_over_git(monkeypatch):
    monkeypatch.delenv("DREAM_REPO", raising=False)
    monkeypatch.setattr(
        config, "_run",
        lambda cmd, cwd=None: "owner/fromgh" if "view" in cmd
        else "git@github.com:owner/fromgit.git")
    assert config.repo_slug() == "owner/fromgh"


def test_known_corpus_discovers_decisions_md(tmp_path):
    (tmp_path / "CLAUDE.md").write_text("root rules", encoding="utf-8")
    sub = tmp_path / "pkg"
    sub.mkdir()
    (sub / "DECISIONS.md").write_text("D1. a decision", encoding="utf-8")
    venv = tmp_path / ".venv" / "x"
    venv.mkdir(parents=True)
    (venv / "DECISIONS.md").write_text("vendored, ignore", encoding="utf-8")

    files = config.known_corpus_files(str(tmp_path))
    assert str(sub / "DECISIONS.md") in files
    assert str(tmp_path / "CLAUDE.md") in files
    assert not any(".venv" in f for f in files)  # vendored dir pruned


def test_known_corpus_dedups_extra_corpus(tmp_path, monkeypatch):
    d = tmp_path / "DECISIONS.md"
    d.write_text("x", encoding="utf-8")
    monkeypatch.setenv("DREAM_EXTRA_CORPUS", str(d))
    files = config.known_corpus_files(str(tmp_path))
    assert files.count(str(d)) == 1  # walk hit + extra-corpus hit deduped


def test_project_slug_uses_main_checkout_from_worktree(monkeypatch):
    """A linked worktree must key the same slug as its main checkout, so its
    markers land in the repo's one stream."""
    def fake_run(cmd, cwd=None):
        if "--git-common-dir" in cmd:
            return "/home/dev/proj/.git"
        if "--show-toplevel" in cmd:
            return "/home/dev/proj-feature"
        return ""

    monkeypatch.setattr(config, "_run", fake_run)
    assert config.project_slug() == "proj"


def test_project_slug_falls_back_when_no_common_dir(monkeypatch):
    """Old git (no --path-format) or a bare layout: keep the previous behavior."""
    def fake_run(cmd, cwd=None):
        if "--git-common-dir" in cmd:
            return ""
        if "--show-toplevel" in cmd:
            return "/home/dev/proj"
        return ""

    monkeypatch.setattr(config, "_run", fake_run)
    assert config.project_slug() == "proj"


# --- slug is identical from every worktree, in every git layout --------------
# Real git, not mocks: the test depends on what git reports.

import subprocess as _sp


def _git(*a, cwd):
    _sp.run(["git", "-c", "user.email=t@t", "-c", "user.name=t", "-c",
             "protocol.file.allow=always", *a], cwd=cwd, check=True,
            capture_output=True)


def _slug(path, monkeypatch):
    monkeypatch.setenv("DREAM_PROJECT_DIR", str(path))
    return config.project_slug()


def test_slug_same_from_worktree_normal_clone(tmp_path, monkeypatch):
    _git("init", "-q", "repo", cwd=tmp_path)
    _git("commit", "-q", "--allow-empty", "-m", "i", cwd=tmp_path / "repo")
    _git("worktree", "add", "-q", "../repo-wt", "-b", "w", cwd=tmp_path / "repo")
    assert _slug(tmp_path / "repo-wt", monkeypatch) == _slug(tmp_path / "repo", monkeypatch) == "repo"


def test_slug_same_from_worktree_separate_git_dir(tmp_path, monkeypatch):
    _git("init", "-q", f"--separate-git-dir={tmp_path}/store.git", "repo", cwd=tmp_path)
    _git("commit", "-q", "--allow-empty", "-m", "i", cwd=tmp_path / "repo")
    _git("worktree", "add", "-q", "../repo-wt", "-b", "w", cwd=tmp_path / "repo")
    main, wt = _slug(tmp_path / "repo", monkeypatch), _slug(tmp_path / "repo-wt", monkeypatch)
    assert main == wt == "store"


def test_bash_writer_and_python_reader_agree_on_the_slug(tmp_path, monkeypatch):
    """emit-dream-marker.sh writes under the slug; dreamlib reads under it. Each
    is tested alone elsewhere - this checks they name the same directory."""
    emit = (pathlib.Path(__file__).resolve().parents[2]
            / "pr-review-loop/skills/pr-review-loop/scripts/emit-dream-marker.sh")
    _git("init", "-q", f"--separate-git-dir={tmp_path}/store.git", "repo", cwd=tmp_path)
    _git("commit", "-q", "--allow-empty", "-m", "i", cwd=tmp_path / "repo")
    _git("worktree", "add", "-q", "../repo-wt", "-b", "w", cwd=tmp_path / "repo")
    for tree in ("repo", "repo-wt", "normal"):
        if tree == "normal":
            _git("init", "-q", "normal", cwd=tmp_path)
        home = tmp_path / f"home-{tree}"
        env = {**os.environ, "HOME": str(home)}
        env.pop("DREAM_HOME", None)
        _sp.run(["bash", str(emit), "k", "a=1"], cwd=tmp_path / tree, env=env, check=True)
        written = [d.name for d in (home / ".dream").iterdir()]
        assert written == [_slug(tmp_path / tree, monkeypatch)], tree


def test_slug_submodule_is_not_the_superproject(tmp_path, monkeypatch):
    _git("init", "-q", "lib", cwd=tmp_path)
    _git("commit", "-q", "--allow-empty", "-m", "i", cwd=tmp_path / "lib")
    _git("init", "-q", "app", cwd=tmp_path)
    _git("commit", "-q", "--allow-empty", "-m", "i", cwd=tmp_path / "app")
    _git("submodule", "add", "-q", str(tmp_path / "lib"), "sub", cwd=tmp_path / "app")
    assert _slug(tmp_path / "app" / "sub", monkeypatch) not in ("app", "")
