"""Shared fixtures + import isolation for the dream plugin test suite.

Importing dreamlib.synth / dreamlib.reviews runs `config.subdir(...)` at module
load, which creates directories under the dream home. Point DREAM_HOME at a
throwaway dir BEFORE any dreamlib import so the tests never touch the real
~/.dream/<slug>/.
"""

import json
import os
import pathlib
import sys
import tempfile

_DREAM = pathlib.Path(__file__).resolve().parents[1]  # plugins/dream
sys.path.insert(0, str(_DREAM / "scripts"))  # enables `import dreamlib...`
os.environ["DREAM_HOME"] = tempfile.mkdtemp(prefix="dream-tests-")

import pytest  # noqa: E402


@pytest.fixture
def session_jsonl(tmp_path):
    """Write a list of event dicts as a session .jsonl; return its path."""

    def _write(events):
        p = tmp_path / "session.jsonl"
        p.write_text("\n".join(json.dumps(e) for e in events), encoding="utf-8")
        return str(p)

    return _write


@pytest.fixture
def markers_home(tmp_path, monkeypatch):
    """Point the dream home at tmp_path; return its (created) markers dir."""
    monkeypatch.setenv("DREAM_HOME", str(tmp_path))
    md = tmp_path / "markers"
    md.mkdir()
    return md
