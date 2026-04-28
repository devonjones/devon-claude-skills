#!/usr/bin/env python3
"""Render and serve a synthesizer-generated wiki entry over HTTP.

The synthesizer writes Obsidian-flavored markdown (wikilink image embeds
`![[image-NN.png]]`) which standard markdown viewers don't render. This
script generates an index.html beside index.md with wikilinks rewritten to
<img> tags, YAML frontmatter shown as a collapsible block, and basic
markdown rendering (headings, paragraphs, bold/italic, lists, links). It
then serves the entry directory over HTTP so the rendered page and its
sibling image-NN.png assets are reachable from a browser.

Usage:
    preview.py <entry-dir-or-md-file> [--port PORT] [--bind ADDR]

If given a directory, expects an index.md inside it. If given a .md file,
serves that file's parent directory.

Default port: 8765. Default bind: 0.0.0.0 (so a headless box is reachable
from another machine on the LAN).
"""

import argparse
import html
import http.server
import re
import socketserver
import sys
from pathlib import Path

# --- Rendering -----------------------------------------------------------


def render_inline(text: str) -> str:
    # Process most-specific to least-specific so `***x***` becomes <strong><em>x</em></strong>.
    text = re.sub(r"\*\*\*(.+?)\*\*\*", r"<strong><em>\1</em></strong>", text)
    text = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", text)
    text = re.sub(r"\*(.+?)\*", r"<em>\1</em>", text)
    text = re.sub(r"\[([^\]]+)\]\(([^)]+)\)", r'<a href="\2">\1</a>', text)
    return text


def render_body(md: str) -> str:
    out: list[str] = []
    in_list = False
    in_code = False
    para_lines: list[str] = []  # buffered consecutive plain lines forming one paragraph

    def flush_para() -> None:
        if para_lines:
            joined = " ".join(para_lines)
            out.append(f"<p>{render_inline(html.escape(joined))}</p>")
            para_lines.clear()

    def close_list() -> None:
        nonlocal in_list
        if in_list:
            out.append("</ul>")
            in_list = False

    for raw in md.split("\n"):
        line = raw.rstrip()

        # Fenced code block fence (```optional-lang or ```)
        fence_match = re.match(r"^```(\S*)\s*$", line)
        if fence_match:
            flush_para()
            close_list()
            if in_code:
                out.append("</code></pre>")
                in_code = False
            else:
                lang = fence_match.group(1)
                cls = f' class="language-{html.escape(lang)}"' if lang else ""
                out.append(f"<pre><code{cls}>")
                in_code = True
            continue

        # Inside a code block: emit raw escaped lines without further parsing.
        if in_code:
            out.append(html.escape(line))
            continue

        m = re.match(r"^!\[\[([^\]]+)\]\]\s*$", line)
        if m:
            flush_para()
            close_list()
            target = html.escape(m.group(1))
            out.append(f'<p><img src="{target}" alt="{target}" /></p>')
            continue

        m = re.match(r"^(#{1,4})\s+(.*)$", line)
        if m:
            flush_para()
            close_list()
            level = len(m.group(1))
            out.append(f"<h{level}>{render_inline(html.escape(m.group(2)))}</h{level}>")
            continue

        m = re.match(r"^[-*]\s+(.*)$", line)
        if m:
            flush_para()
            if not in_list:
                out.append("<ul>")
                in_list = True
            out.append(f"<li>{render_inline(html.escape(m.group(1)))}</li>")
            continue

        if not line.strip():
            flush_para()
            close_list()
            out.append("")
            continue

        # Plain text line: append to current paragraph buffer.
        # Consecutive non-empty plain lines join into one paragraph; blank lines flush.
        close_list()
        para_lines.append(line)

    flush_para()
    close_list()
    if in_code:
        out.append("</code></pre>")
    return "\n".join(out)


CSS = """\
body { max-width: 720px; margin: 2em auto; padding: 0 1em;
       font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, Arial, sans-serif;
       line-height: 1.55; color: #222; background: #fafaf7; }
h1 { border-bottom: 2px solid #888; padding-bottom: .25em; }
h2 { margin-top: 2em; border-bottom: 1px solid #ccc; padding-bottom: .15em; }
img { max-width: 100%; border: 1px solid #ddd; border-radius: 4px;
      display: block; margin: 1em auto; }
details { background: #f0efe8; padding: .5em 1em; border-radius: 4px; margin-bottom: 2em; }
details pre { white-space: pre-wrap; font-size: .85em; }
a { color: #1750a3; }
ul { padding-left: 1.5em; }
li { margin: .25em 0; }
.nav { background: #fff; padding: .5em 1em; border: 1px solid #ddd;
       border-radius: 4px; margin-bottom: 1em; font-size: .9em; }
"""


def render_html(md_path: Path) -> Path:
    """Read md_path, write a sibling .html file, return the html path."""
    src = md_path.read_text(encoding="utf-8")

    # Split YAML frontmatter
    parts = src.split("---\n", 2)
    if len(parts) == 3:
        frontmatter, body = parts[1], parts[2]
    else:
        frontmatter, body = "", src

    title_match = re.search(r"^# (.+)$", body, re.MULTILINE)
    page_title = title_match.group(1).strip() if title_match else md_path.stem

    body_html = render_body(body)
    fm_html = ""
    if frontmatter.strip():
        fm_html = (
            f"<details><summary>Frontmatter (YAML)</summary>"
            f"<pre>{html.escape(frontmatter)}</pre></details>"
        )

    raw_name = md_path.name
    doc = f"""<!doctype html>
<html><head>
<meta charset="utf-8">
<title>{html.escape(page_title)}</title>
<style>
{CSS}
</style>
</head>
<body>
<div class="nav">
  Rendered view of <code>{html.escape(raw_name)}</code> &middot;
  <a href="{html.escape(raw_name)}">raw markdown</a> &middot;
  <a href="./">file listing</a>
</div>
{fm_html}
{body_html}
</body></html>
"""

    out_path = md_path.with_suffix(".html")
    out_path.write_text(doc, encoding="utf-8")
    return out_path


# --- Serving -------------------------------------------------------------


class Handler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, fmt: str, *args) -> None:  # quieter logs
        sys.stderr.write(f"[preview] {self.address_string()} - {fmt % args}\n")


def serve(directory: Path, bind: str, port: int) -> None:
    handler = lambda *a, **kw: Handler(*a, directory=str(directory), **kw)
    # allow_reuse_address avoids "Address already in use" on quick restart
    # while the previous socket is still in TIME_WAIT.
    socketserver.TCPServer.allow_reuse_address = True
    with socketserver.TCPServer((bind, port), handler) as httpd:
        sys.stderr.write(f"[preview] serving {directory} at http://{bind or '0.0.0.0'}:{port}/\n")
        try:
            httpd.serve_forever()
        except KeyboardInterrupt:
            sys.stderr.write("\n[preview] shutting down\n")


# --- CLI -----------------------------------------------------------------


def main() -> int:
    p = argparse.ArgumentParser(
        description=__doc__.split("\n\n", 1)[0],
    )
    p.add_argument(
        "target",
        type=Path,
        help="Path to a wiki entry directory (containing index.md) or to a .md file directly.",
    )
    p.add_argument("--port", type=int, default=8765, help="Port to bind (default 8765).")
    p.add_argument(
        "--bind",
        default="0.0.0.0",
        help="Bind address (default 0.0.0.0; use 127.0.0.1 to restrict to localhost).",
    )
    p.add_argument(
        "--no-serve",
        action="store_true",
        help="Render the HTML and exit; don't start a server.",
    )
    args = p.parse_args()

    if not args.target.exists():
        print(f"error: {args.target} does not exist", file=sys.stderr)
        return 1

    if args.target.is_dir():
        md_path = args.target / "index.md"
        directory = args.target
    elif args.target.suffix == ".md":
        md_path = args.target
        directory = args.target.parent
    else:
        print(f"error: {args.target} is neither a directory nor a .md file", file=sys.stderr)
        return 1

    if not md_path.exists():
        print(f"error: no markdown file found at {md_path}", file=sys.stderr)
        return 1

    out = render_html(md_path)
    print(f"[preview] wrote {out}", file=sys.stderr)

    if args.no_serve:
        return 0

    serve(directory, args.bind, args.port)
    return 0


if __name__ == "__main__":
    sys.exit(main())
