---
name: rodney
description: |
  Drive Chrome from the shell with the rodney CLI: open pages, click, type,
  wait, read text or HTML, run JS, assert, and take screenshots you can then
  Read. Use for scraping or extracting data from JS-rendered pages, checking a
  web UI you just changed, screenshotting a page, or stepping through a login or
  form flow. Use the playwright-skill instead when you need request stubbing,
  init scripts, trusted mouse events (e.g. browser-extension tests) or a
  Cloudflare login, and plain curl when the page doesn't need JavaScript.
---

# Rodney

[rodney](https://github.com/simonw/rodney) runs one long-lived Chrome, and each
command talks to it, so a session spans many Bash calls. Read the whole of
`rodney --help` (don't pipe it through `head`); the commands are
self-explanatory. What goes wrong is the lifecycle, so follow the rules below.

If it isn't installed: `go install github.com/simonw/rodney@latest`.
`rodney --version` prints `dev`; `go version -m $(which rodney)` shows the
real version.

## Session lifecycle

1. **Use your own session.** The default session (`~/.rodney/`) is shared by
   every Claude on the machine. Pick one directory, e.g. `<scratchpad>/rodney`,
   and prefix **every** command with it. Shell variables don't survive between
   Bash calls, so write the path out each time:
   `RODNEY_HOME=/tmp/…/rodney rodney …`
2. **Put a `timeout` on every call.** A frozen Chrome makes `status` and
   `start` hang forever, and `ROD_TIMEOUT` doesn't cover `start`, `status` or
   `stop`. Use
   `timeout 60 rodney …`. Exit 124 means it hung, so kill Chrome (rule 6).
3. **Check before you start.** Run `timeout 15 rodney status` and read its
   output, not its exit code, which is 0 even for a dead browser. "Browser
   running" means healthy. "No active browser session" or "Browser not
   responding" means run `start`, which recovers from stale state.
4. **Warm up right after `start`.** Open a local page,
   `open file:///…/any.html`, and check that it succeeded. The first `open` in
   a session panics on any navigation failure (bad URL, refused connection,
   `data:` or `about:blank`) and leaves no page, while `status`
   still says "Browser running". Once a page exists, failures are clean
   exit-2 errors. `newpage <url>` always panics on failure, so avoid it for
   URLs that might fail.
5. **Chrome dies silently.** A long-lived or logged-in session can be gone
   between calls. If a command fails with a connection error, go back to
   rule 3. The profile in `$RODNEY_HOME/chrome-data` survives, so
   cookies and logins come back.
6. **Stop once, at the end.** Chrome's memory keeps growing, so always finish
   with `rodney stop`. If it fails or hangs, kill the session's Chrome by
   profile: `pkill -f '[/]tmp/…/rodney/chrome-data'`. The brackets stop the
   pattern matching your own shell, which `pkill -f` would otherwise kill. In
   a script, trap both (see the example). If the script holds a `flock`,
   start Chrome with that descriptor closed (`rodney start 9>&-`), or Chrome
   inherits the lock and outlives the script.

## Reading results

- After `open` or `click`, wait before reading: `waitstable` (DOM settled),
  `waitidle` (network quiet) or `wait <selector>`. Element queries time out
  after `ROD_TIMEOUT` seconds (default 30).
- After `open`, check `title`. An HTTP error page can load with exit 0, and
  bot walls show titles such as "Just a moment" or "Attention Required".
- `rodney js '<expression>'` is the quickest way to extract data. Strings print
  as-is, and objects and arrays print as JSON. A miss prints `null` and exits
  0, so test for `null` yourself.
- Don't pipe rodney into `head` or `tail` when you need its exit code; the
  pipe returns theirs.

| Exit | Meaning |
|---|---|
| 0 | Success |
| 1 | Check failed: `exists`, `visible`, `assert` or `ax-find` found nothing |
| 2 | The call failed: bad arguments, timeout, navigation error or dead browser. "element not found" can be a dead browser, so check `status` |

## Example

As one script. `set -e` stops at the first failed step, and the trap always
cleans up. Within a single script, `export` is fine.

```bash
set -e
export RODNEY_HOME=/tmp/…/rodney
trap "timeout 30 rodney stop || pkill -f '[/]tmp/…/rodney/chrome-data'" EXIT
timeout 60 rodney start
echo '<title>warm</title>' > $RODNEY_HOME/warm.html
timeout 60 rodney open file://$RODNEY_HOME/warm.html   # warm-up
timeout 60 rodney open http://localhost:3000/login
timeout 60 rodney waitstable
timeout 60 rodney input '#email' 'test@example.com'
timeout 60 rodney click 'button[type=submit]'
timeout 60 rodney wait '.dashboard'
timeout 60 rodney screenshot $RODNEY_HOME/dashboard.png   # then Read it
```

## Sites that block headless Chrome

For Cloudflare or Google sign-in walls, either:
- run `rodney start --show` for a visible window (needs a display), or
- have Devon pass the check in a Chrome started with
  `--remote-debugging-port=<port>`, then `rodney connect localhost:<port>` and
  drive it from there.

A Cloudflare clearance cookie is tied to the browser's user agent. For logins
that must survive across runs, use Playwright with a persistent profile.
