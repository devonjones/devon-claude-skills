"""hooks/session-start-proposals.sh must find pending proposals from a worktree.

The writers key ~/.dream/<slug> on the common git dir, so every worktree of a
repo shares one stream; the hook must read that same slug. Runs the real hook
against real git.
"""

import os
import subprocess

HOOK = os.path.join(os.path.dirname(__file__), "..", "hooks", "session-start-proposals.sh")


def _git(*a, cwd):
    subprocess.run(["git", "-c", "user.email=t@t", "-c", "user.name=t", *a],
                   cwd=cwd, check=True, capture_output=True)


def _hook(project_dir, home):
    env = {**os.environ, "HOME": str(home), "CLAUDE_PROJECT_DIR": str(project_dir)}
    env.pop("DREAM_HOME", None)
    return subprocess.run(["bash", HOOK], input="", env=env,
                          capture_output=True, text=True).stdout


def test_pending_proposals_surface_from_a_worktree(tmp_path):
    _git("init", "-q", "repo", cwd=tmp_path)
    _git("commit", "-q", "--allow-empty", "-m", "i", cwd=tmp_path / "repo")
    _git("worktree", "add", "-q", "../repo-wt", "-b", "w", cwd=tmp_path / "repo")
    home = tmp_path / "home"
    pending = home / ".dream" / "repo" / "review" / "pending"
    pending.mkdir(parents=True)
    (pending / "run-1.md").write_text("x")

    assert "1 UNREVIEWED" in _hook(tmp_path / "repo", home)
    assert "1 UNREVIEWED" in _hook(tmp_path / "repo-wt", home)


def test_nothing_pending_stays_silent(tmp_path):
    _git("init", "-q", "repo", cwd=tmp_path)
    assert _hook(tmp_path / "repo", tmp_path / "home") == ""
