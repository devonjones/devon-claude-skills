"""config.py — repo-slug remote-URL parsing + DECISIONS.md corpus discovery."""

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
