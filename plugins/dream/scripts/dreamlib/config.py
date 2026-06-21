"""Runtime configuration — derive everything from the current project context so
the skill works on any repo, not just wyrd.

- project_log_dir : where Claude Code stores this project's session JSONL
- dream_home      : per-project derived-data root (`<git-root>/.dream`, gitignored)
- markers_dir     : the dream-marker stream producers append to (see
                    references/MARKER-CONTRACT.md)
- repo_slug       : owner/name for the GitHub-mining pipeline
"""

from __future__ import annotations

import os
import re
import subprocess


def _run(cmd: list[str], cwd: str | None = None) -> str:
    try:
        return subprocess.run(
            cmd, capture_output=True, text=True, cwd=cwd, timeout=10
        ).stdout.strip()
    except Exception:
        return ""


def project_dir() -> str:
    return os.environ.get("DREAM_PROJECT_DIR") or os.getcwd()


def git_root(cwd: str | None = None) -> str:
    return _run(["git", "rev-parse", "--show-toplevel"], cwd=cwd or project_dir())


def project_slug(cwd: str | None = None) -> str:
    """Stable per-project key: the git-root basename (so a sibling producer like
    pr-review-loop computes the SAME markers path with one `git rev-parse`)."""
    root = git_root(cwd)
    return os.path.basename(root or os.path.abspath(cwd or project_dir()))


def dream_home() -> str:
    """Per-project derived-data root, OUTSIDE the repo (never pollute the
    checkout): `~/.dream/<slug>`. Override with $DREAM_HOME."""
    d = os.environ.get("DREAM_HOME") or os.path.join(
        os.path.expanduser("~/.dream"), project_slug()
    )
    os.makedirs(d, exist_ok=True)
    return d


def subdir(name: str) -> str:
    d = os.path.join(dream_home(), name)
    os.makedirs(d, exist_ok=True)
    return d


def markers_dir() -> str:
    return subdir("markers")


def project_log_dir(cwd: str | None = None) -> str:
    """Claude Code stores logs at ~/.claude/projects/<cwd with '/' -> '-'>."""
    p = os.path.abspath(cwd or project_dir())
    munged = p.replace("/", "-")
    return os.path.expanduser(os.path.join("~/.claude/projects", munged))


def memory_dir(cwd: str | None = None) -> str:
    return os.path.join(project_log_dir(cwd), "memory")


def repo_slug(cwd: str | None = None) -> str:
    """owner/name for the current repo — $DREAM_REPO, else gh, else git remote."""
    if os.environ.get("DREAM_REPO"):
        return os.environ["DREAM_REPO"]
    cwd = cwd or project_dir()
    out = _run(
        ["gh", "repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner"], cwd
    )
    if out:
        return out
    url = _run(["git", "remote", "get-url", "origin"], cwd)
    m = re.search(r"[:/]([^/:]+/[^/]+?)(?:\.git)?$", url)
    return m.group(1) if m else ""


def known_corpus_files(cwd: str | None = None) -> list[str]:
    """CLAUDE.md / AGENTS.md the dedup pass treats as 'already known'. Walk up
    from the project dir to the git root, plus ~/.claude/CLAUDE.md, plus any
    paths in $DREAM_EXTRA_CORPUS (colon-separated — e.g. a project DECISIONS.md)."""
    cwd = os.path.abspath(cwd or project_dir())
    root = git_root(cwd) or cwd
    files: list[str] = []
    d = cwd
    while True:
        for name in ("CLAUDE.md", "AGENTS.md"):
            p = os.path.join(d, name)
            if os.path.exists(p):
                files.append(p)
        if d == root or os.path.dirname(d) == d:
            break
        d = os.path.dirname(d)
    for extra in (os.environ.get("DREAM_EXTRA_CORPUS", "").split(":")):
        if extra and os.path.exists(extra):
            files.append(extra)
    home_claude = os.path.expanduser("~/.claude/CLAUDE.md")
    if os.path.exists(home_claude):
        files.append(home_claude)
    return files
