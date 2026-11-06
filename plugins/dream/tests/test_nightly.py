"""scripts/dream-nightly: finds the dreams tab by title, prompts it, and fails
the unit when the tab is missing or herdr answers with an error."""

import os
import shutil
import subprocess

import pytest

SRC = os.path.join(os.path.dirname(__file__), "..", "scripts", "dream-nightly")
LIST = ('{"result":{"agents":[{"terminal_title_stripped":"dreams-testbox",'
        '"pane_id":"w9:p1"}]}}')


def _sh(path, body):
    with open(path, "w") as f:
        f.write("#!/usr/bin/env bash\n" + body)
    os.chmod(path, 0o755)


@pytest.fixture
def box(tmp_path):
    scripts, bin_, home = tmp_path / "scripts", tmp_path / "bin", tmp_path / "home"
    for d in (scripts, bin_, home / ".dream" / "box"):
        d.mkdir(parents=True)
    shutil.copy(SRC, scripts / "dream-nightly")
    _sh(scripts / "dream", 'touch "$HOME/.dream/box/20261106-box.json"\n')
    log = tmp_path / "prompts"
    _sh(bin_ / "herdr", f"""
if [ "$2" = list ]; then echo '{LIST}'; exit; fi
echo "$3|$4" >> {log}
echo "${{HERDR_REPLY:-{{\\"result\\":{{}}}}}}"
""")

    def run(**env):
        e = {"HOME": str(home), "PATH": f"{bin_}:/usr/bin:/bin", **env}
        r = subprocess.run([str(scripts / "dream-nightly")], env=e,
                           capture_output=True, text=True)
        return r, (log.read_text() if log.exists() else "")
    return run


def test_prompts_the_named_tab(box):
    r, prompts = box(DREAM_TAB="dreams-testbox")
    assert r.returncode == 0, r.stderr
    assert prompts.startswith("w9:p1|Nightly dream pass:")
    assert "20261106-box.json" in prompts


def test_missing_tab_fails(box):
    r, prompts = box(DREAM_TAB="dreams-other")
    assert r.returncode != 0 and "no herdr tab named dreams-other" in r.stderr
    assert prompts == ""


def test_herdr_error_fails(box):
    r, _ = box(DREAM_TAB="dreams-testbox",
               HERDR_REPLY='{"error":{"code":"agent_blocked"}}')
    assert r.returncode != 0
