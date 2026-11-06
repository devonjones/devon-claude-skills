import os
import shutil
import subprocess
import time

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
    boxdir = home / ".dream" / "box"
    for d in (scripts, bin_, boxdir):
        d.mkdir(parents=True)
    (boxdir / "20000101-box.json").write_text("{}")
    shutil.copy(SRC, scripts / "dream-nightly")
    args, log = tmp_path / "dream-args", tmp_path / "prompts"
    _sh(scripts / "dream", f"""
echo "$@" > {args}
[ -n "${{DREAM_FAIL:-}}" ] && exit 3
[ -n "${{DREAM_NOWRITE:-}}" ] || touch "$HOME/.dream/box/$(date +%Y%m%d)-box.json"
""")
    _sh(bin_ / "hostname", "echo TestBox\n")
    _sh(bin_ / "herdr", f"""
if [ "$2" = list ]; then echo '{LIST}'; exit; fi
echo "$3|$4" >> {log}
ok='{{"result":{{}}}}'
echo "${{HERDR_REPLY:-$ok}}"
""")

    def run(**env):
        e = {"HOME": str(home), "PATH": f"{bin_}:/usr/bin:/bin", **env}
        r = subprocess.run([str(scripts / "dream-nightly")], env=e,
                           capture_output=True, text=True)
        read = lambda p: p.read_text() if p.exists() else ""
        return r, read(log), read(args)
    return run


def test_prompts_the_hostname_tab_with_todays_box(box):
    r, prompts, args = box()
    assert r.returncode == 0, r.stderr
    assert prompts.startswith("w9:p1|Nightly dream pass:")
    assert time.strftime("%Y%m%d") + "-box.json" in prompts
    assert args.strip() == "box --days 1"


def test_days_passes_through(box):
    _, _, args = box(DREAM_DAYS="3")
    assert args.strip() == "box --days 3"


def test_missing_tab_fails(box):
    r, prompts, _ = box(DREAM_TAB="dreams-other")
    assert r.returncode != 0 and "no herdr tab named dreams-other" in r.stderr
    assert prompts == ""


@pytest.mark.parametrize("env", [{"DREAM_FAIL": "1"}, {"DREAM_NOWRITE": "1"}])
def test_no_fresh_box_fails_without_prompting(box, env):
    r, prompts, _ = box(**env)
    assert r.returncode != 0
    assert prompts == ""


def test_herdr_error_fails(box):
    reply = '{"error":{"code":"agent_blocked"}}'
    r, _, _ = box(HERDR_REPLY=reply)
    assert r.returncode != 0
    assert reply in r.stdout
