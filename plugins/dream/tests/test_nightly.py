import os
import shutil
import subprocess
import time

import pytest

SRC = os.path.join(os.path.dirname(__file__), "..", "scripts", "dream-nightly")


def _sh(path, body):
    with open(path, "w") as f:
        f.write("#!/usr/bin/env bash\n" + body)
    os.chmod(path, 0o755)


@pytest.fixture
def box(tmp_path):
    scripts = tmp_path / "repo" / "plugins" / "dream" / "scripts"
    bin_, home = tmp_path / "bin", tmp_path / "home"
    boxdir = home / ".dream" / "box"
    for d in (scripts, bin_, boxdir):
        d.mkdir(parents=True)
    (boxdir / "20000101-box.json").write_text("{}")
    shutil.copy(SRC, scripts / "dream-nightly")
    args, log = tmp_path / "dream-args", tmp_path / "prompts"
    _sh(scripts / "dream", f"""
echo "$@" > {args}
[ -n "${{DREAM_NOWRITE:-}}" ] || touch "$HOME/.dream/box/$(date +%Y%m%d)-box.json"
[ -z "${{DREAM_FAIL:-}}" ] || exit 3
""")
    _sh(bin_ / "claude", f"""
printf '%s\\n' "$PWD" "$@" > {log}
exit "${{CLAUDE_EXIT:-0}}"
""")

    def run(**env):
        e = {"HOME": str(home), "PATH": f"{bin_}:/usr/bin:/bin",
             "DREAM_REPO": str(tmp_path), **env}
        r = subprocess.run([str(scripts / "dream-nightly")], env=e,
                           capture_output=True, text=True)
        read = lambda p: p.read_text() if p.exists() else ""
        return r, read(log), read(args)
    return run


def test_runs_headless_claude_on_todays_box(box, tmp_path):
    r, prompts, args = box()
    assert r.returncode == 0, r.stderr
    cwd, flag, prompt, *rest = prompts.splitlines()
    assert cwd == str(tmp_path)
    assert flag == "-p" and rest == ["--permission-mode", "auto"]
    assert time.strftime("%Y%m%d") + "-box.json" in prompt
    assert "references/box-pass.md" in prompt
    assert args.strip() == "box --days 1"


def test_days_passes_through(box):
    _, _, args = box(DREAM_DAYS="3")
    assert args.strip() == "box --days 3"


@pytest.mark.parametrize("env", [{"DREAM_FAIL": "1"}, {"DREAM_NOWRITE": "1"}])
def test_no_fresh_box_fails_without_claude(box, env):
    r, prompts, _ = box(**env)
    assert r.returncode != 0
    assert prompts == ""


def test_claude_override(box, tmp_path):
    os.rename(tmp_path / "bin" / "claude", tmp_path / "my-claude")
    r, prompts, _ = box(CLAUDE=str(tmp_path / "my-claude"))
    assert r.returncode == 0, r.stderr
    assert prompts


def test_claude_failure_fails(box):
    r, _, _ = box(CLAUDE_EXIT="2")
    assert r.returncode == 2
