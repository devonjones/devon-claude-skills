#!/usr/bin/env python3
"""Write reviewers in the .reviewers/ layout.

  convert-reviewers.py repo [--repo-root DIR] [--write]
      Convert every AGENT-REVIEWERS.md in the repo. Without --write, print the
      plan and change nothing.
  convert-reviewers.py starters [--into DIR] [NAME ...]
      Copy shipped starter reviewers into DIR/.reviewers/. No NAME lists them.
  convert-reviewers.py template FILE --into DIR
      Convert one AGENT-REVIEWERS.md-style file (a language template) into
      DIR/.reviewers/.

Each reviewer becomes .reviewers/<name>.md: a header in its first 12 lines
(title, model:, verification:, Checks, Spawn when, Contents), then the spec
text unchanged. Names never change: dream markers, PR thread signatures and the
.pi config are keyed on them. Header lines the source cannot supply are written
as TODO for whoever runs the conversion to fill in.
"""

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path

HEADER_LINES = 12
PLUGIN = Path(__file__).resolve().parents[3]
STARTERS = PLUGIN / "agents"
NAME_RE = re.compile(r"^[a-z0-9][a-z0-9-]*$")
MODEL_RE = re.compile(r"^\s*model:\s*\"?([A-Za-z0-9._:-]+)\"?\s*$")
VERIFY_RE = re.compile(r"^\s*verification:")
CHECKS_RE = re.compile(r"^\*\*(?:What it checks|Checks):?\*\*:?\s*(.*)$")
SPAWN_RE = re.compile(r"^\*\*(?:When to spawn|Spawn when):?\*\*:?\s*(.*)$")
POINTER_RE = re.compile(r"\.reviewers/[\w-]+\.md")
SECTION_RE = re.compile(r"^(?:#{2,4}\s+(.+?)|\*\*([^*]+?):?\*\*:?)\s*$")


def sections(text):
    """Split markdown on H1/H2 outside code fences: [(h1, h2 or None, body)]."""
    out, h1, h2, buf, fence = [], None, None, [], False

    def flush():
        if h1 is not None or "".join(buf).strip():
            out.append((h1, h2, "\n".join(buf).strip("\n") + "\n"))

    for line in text.lstrip("﻿").splitlines():
        if line.startswith("```") or line.startswith("~~~"):
            fence = not fence
        if not fence and re.match(r"^# \S", line):
            flush()
            h1, h2, buf = line[2:].strip(), None, []
        elif not fence and h1 == "Agents" and re.match(r"^## \S", line):
            flush()
            h2, buf = line[3:].strip(), []
        else:
            buf.append(line)
    flush()
    return out


def take(lines, pattern, limit=5):
    """Remove and return the first line matching pattern in the first lines."""
    for i, line in enumerate(lines[:limit]):
        if pattern.match(line):
            return lines.pop(i).strip()
    return None


def contents(body):
    names, fence = [], False
    for line in body.splitlines():
        if line.startswith("```") or line.startswith("~~~"):
            fence = not fence
            continue
        m = None if fence else SECTION_RE.match(line)
        if m:
            name = (m.group(1) or m.group(2)).strip()
            if name not in names:
                names.append(name)
    return " · ".join(names) if len(names) >= 2 else None


def render(name, body, summary="", checks=None, spawn=None, model=None):
    """One reviewer file. summary is an index entry's text (hybrid layouts)."""
    lines = body.strip("\n").splitlines()
    while lines and not lines[0].strip():
        lines.pop(0)
    if lines and re.match(rf"^#\s+{re.escape(name)}\s*$", lines[0]):
        lines.pop(0)  # an existing title; ours replaces it
    model_line = take(lines, MODEL_RE)
    verify = take(lines, VERIFY_RE)
    inline_checks = take(lines, CHECKS_RE, limit=8)
    inline_spawn = take(lines, SPAWN_RE, limit=8)
    checks = checks or (inline_checks and CHECKS_RE.match(inline_checks).group(1))
    spawn = spawn or (inline_spawn and SPAWN_RE.match(inline_spawn).group(1))
    extra = []
    for line in summary.splitlines():
        if MODEL_RE.match(line):
            model_line = line.strip()
        elif CHECKS_RE.match(line):
            checks = CHECKS_RE.match(line).group(1)
        elif SPAWN_RE.match(line):
            spawn = SPAWN_RE.match(line).group(1)
        elif line.strip() and not POINTER_RE.search(line):
            extra.append(line)
    if model and not model_line:
        model_line = f"model: {model}"
    toc = contents("\n".join(lines))
    head = [f"# {name}"]
    head += [x for x in (model_line, verify) if x]
    head.append(f"**Checks:** {checks or 'TODO'}")
    head.append(f"**Spawn when:** {spawn or 'TODO'}")
    if toc:
        head.append(f"**Contents:** {toc}")
    body_text = "\n".join(extra + ([""] if extra else []) + lines).strip("\n")
    return "\n".join(head) + "\n\n" + body_text + "\n"


def frontmatter(text):
    m = re.match(r"^---\n(.*?)\n---\n", text, re.S)
    if not m:
        return {}, text
    meta = {}
    for line in m.group(1).splitlines():
        k, _, v = line.partition(":")
        meta[k.strip()] = v.strip()
    return meta, text[m.end():]


def plan_file(src, into):
    """Writes (path, text) for one AGENT-REVIEWERS.md-style file, plus notes."""
    text = src.read_text()
    rdir = into / ".reviewers"
    writes, notes, readme, config = [], [], [], None
    for h1, h2, body in sections(text):
        if h1 is None:  # prose above the first heading
            readme.append(body)
        elif h1 == "Configuration":
            m = re.search(r"```json\n(.*?)\n```", body, re.S)
            if m:
                config = json.loads(m.group(1))
        elif h1 == "Agents" and h2 is None:
            if body.strip():
                readme.append(f"# Agents\n\n{body}")
        elif h1 == "Agents":
            if not NAME_RE.match(h2):
                readme.append(f"## {h2}\n\n{body}")
                notes.append(f"moved '## {h2}' to README.md: it is not a reviewer name")
                continue
            spec = rdir / f"{h2}.md"
            if spec.exists():  # index entry + spec file: the H2 is the summary
                writes.append((spec, render(h2, spec.read_text(), summary=body)))
            else:
                writes.append((spec, render(h2, body)))
        else:
            readme.append(f"# {h1}\n\n{body}")
    written = {path.name for path, _ in writes}
    for spec in sorted(rdir.glob("*.md")) if rdir.is_dir() else []:
        if spec.name != "README.md" and spec.name not in written:
            notes.append(f"{spec.name} has no index entry, so it never ran; after conversion it runs."
                         " Give it a header, or delete it")
    if readme:
        old = (rdir / "README.md").read_text() + "\n" if (rdir / "README.md").exists() else ""
        writes.append((rdir / "README.md", old + "\n".join(readme)))
    return writes, notes, config


def git_files(root, pattern):
    out = subprocess.run(["git", "-C", str(root), "ls-files", pattern],
                         capture_output=True, text=True, check=True).stdout
    return [root / p for p in out.splitlines()]


def cmd_repo(args):
    root = Path(args.repo_root).resolve()
    indexes = git_files(root, "*AGENT-REVIEWERS.md")
    if not indexes:
        sys.exit("No AGENT-REVIEWERS.md tracked in this repo.")
    writes, notes, config = [], [], None
    for src in indexes:
        w, n, c = plan_file(src, src.parent)
        writes += w
        notes += [f"{src.relative_to(root)}: {x}" for x in n]
        if src.parent == root:
            config = c
    defaults = sorted(p.stem for p in STARTERS.glob("*.md"))
    if config is not None:
        disabled = set(config.get("disabled", []))
        if portable(config):
            writes.append((root / ".reviewers" / "config.json", json.dumps(portable(config), indent=2) + "\n"))
        active = [d for d in defaults if d not in disabled]
    else:
        active = defaults
    named = {p.stem for p, _ in writes}
    active = [d for d in active if d not in named]

    for path, text in writes:
        print(f"write  {path.relative_to(root)}"
              + ("  (TODO in header)" if "TODO" in "\n".join(text.splitlines()[:HEADER_LINES]) else ""))
    for src in indexes:
        print(f"remove {src.relative_to(root)}")
    for n in notes:
        print(f"note   {n}")
    if active:
        print("starters: these shipped defaults ran on this repo before conversion and will")
        print("          not run after it unless copied in:")
        print(f"          {' '.join(active)}")
        print(f"          convert-reviewers.py starters --into {root} <names...>")
    if not args.write:
        print("(dry run: nothing written; re-run with --write)")
        return
    for path, text in writes:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
    for src in indexes:
        src.unlink()


def cmd_starters(args):
    available = {p.stem: p for p in sorted(STARTERS.glob("*.md"))}
    if not args.names:
        for name, p in available.items():
            meta, _ = frontmatter(p.read_text())
            print(f"{name}: {meta.get('description', '')}")
        return
    rdir = Path(args.into).resolve() / ".reviewers"
    for name in args.names:
        if name not in available:
            sys.exit(f"No starter named {name}. Available: {', '.join(available)}")
        if (rdir / f"{name}.md").exists():
            sys.exit(f"{rdir / name}.md already exists; not overwriting")
    rdir.mkdir(parents=True, exist_ok=True)
    for name in args.names:
        meta, body = frontmatter(available[name].read_text())
        (rdir / f"{name}.md").write_text(render(
            name, body, checks=meta.get("description"), spawn=meta.get("spawn_when"),
            model=meta.get("model")))
        print(f"wrote {rdir / name}.md")


def portable(config):
    """The settings that still mean something once the roster is the files."""
    config = dict(config or {})
    config.pop("disabled", None)
    config.pop("defaults_version_checked", None)
    return config


def cmd_template(args):
    into = Path(args.into).resolve()
    writes, notes, config = plan_file(Path(args.file), into)
    cfg = into / ".reviewers" / "config.json"
    if portable(config) and not cfg.exists():
        writes.append((cfg, json.dumps(portable(config), indent=2) + "\n"))
    for path, _ in writes:
        if path.exists() and path.name != "README.md":
            sys.exit(f"{path} already exists; not overwriting")
    for path, text in writes:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        print(f"wrote {path}")
    for n in notes:
        print(f"note  {n}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("repo")
    r.add_argument("--repo-root", default=".")
    r.add_argument("--write", action="store_true")
    s = sub.add_parser("starters")
    s.add_argument("--into", default=".")
    s.add_argument("names", nargs="*")
    t = sub.add_parser("template")
    t.add_argument("file")
    t.add_argument("--into", required=True)
    args = ap.parse_args()
    {"repo": cmd_repo, "starters": cmd_starters, "template": cmd_template}[args.cmd](args)


if __name__ == "__main__":
    main()
