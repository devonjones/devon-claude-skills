---
name: rodney
description: |
  Drive Chrome from the shell with the rodney CLI: open pages, click, type,
  wait, read text or HTML, run JS, assert, and take screenshots you can then
  Read. Use for scraping or extracting data from JS-rendered pages, checking a
  web UI you just changed, screenshotting a page, or stepping through a login or
  form flow. Use the playwright-skill instead when you need request stubbing,
  init scripts or trusted mouse events (e.g. browser-extension tests), and
  plain curl when the page doesn't need JavaScript.
---

# Rodney

[rodney](https://github.com/simonw/rodney) runs one long-lived Chrome, and each
command talks to it, so a session spans many Bash calls. The commands are
self-explanatory from `rodney --help`. What goes wrong is the lifecycle, so
follow the rules below.

## Session lifecycle

1. **Use your own session.** The default session (`~/.rodney/`) is shared by
   every Claude on the machine. Pick one directory, e.g. `<scratchpad>/rodney`,
   and prefix **every** command with it. Shell variables don't survive between
   Bash calls, so write the path out each time:
   `RODNEY_HOME=/tmp/…/rodney rodney …`
2. **Check before you start.** Run `status` and read its output. Its exit code
   is 0 even for a dead browser. "Browser running" means healthy. "No active
   browser session" or "Browser not responding" means run `start`, which
   recovers from stale state.
3. **Chrome dies silently.** A long-lived or logged-in session can be gone
   between calls. If a command fails with a websocket or connection error,
   run `status`, then `start` again. The profile in `$RODNEY_HOME/chrome-data`
   survives, so cookies and logins come back.
4. **Stop once, at the end.** Chrome's memory keeps growing, so always finish
   with `rodney stop`. You don't need to stop defensively before each `start`.
   If `stop` fails or hangs, kill the session's Chrome by its profile:
   `pkill -f '<your RODNEY_HOME>/chrome-data'`.
5. **In scripts, own the cleanup.** In a script or service, put `stop` in a
   `finally` or `trap`, and fall back to the `pkill` above. A crash before
   `stop` leaks Chrome.

## Waits and timeouts

- After `open` or `click`, wait before reading: `waitstable` (DOM settled),
  `waitidle` (network quiet) or `wait <selector>`.
- Element queries time out after 30 s. Set `ROD_TIMEOUT=<seconds>` per command
  to change that.
- Most failures are timeouts and dead browsers, not bad selectors. Check
  liveness (rule 2) before debugging a selector.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Success |
| 1 | Check failed: `exists`, `visible`, `assert` or `ax-find` found nothing |
| 2 | Error: no browser, bad arguments, timeout. `text` on a missing element is 2 after the timeout, not 1 |

Check for an element with `exists` before calling `text` on it, so a missing
element doesn't cost a timeout.

## Gotchas

- `open` fails on an HTTP error status, with
  `net::ERR_HTTP_RESPONSE_CODE_FAILURE`. Check the URL with `curl -sI` if you
  need the status code.
- `data:` URLs crash rodney; use `file://` for local HTML.
- For extraction, `rodney js '<expression>'` is usually faster than chaining
  selector commands: one call, and you shape the output yourself. Strings
  print as-is, and objects and arrays print as JSON, ready for `jq`.

## Example

```bash
R=/tmp/…/rodney   # same literal path in every Bash call
RODNEY_HOME=$R rodney status        # read the output
RODNEY_HOME=$R rodney start
RODNEY_HOME=$R rodney open http://localhost:3000/login
RODNEY_HOME=$R rodney waitstable
RODNEY_HOME=$R rodney input '#email' 'test@example.com'
RODNEY_HOME=$R rodney click 'button[type=submit]'
RODNEY_HOME=$R rodney wait '.dashboard'
RODNEY_HOME=$R rodney screenshot $R/dashboard.png   # then Read the PNG
RODNEY_HOME=$R rodney exists '.error' && RODNEY_HOME=$R rodney text '.error'
RODNEY_HOME=$R rodney stop
```

## Sites that block headless Chrome

For Cloudflare or Google sign-in walls, either:
- run `rodney start --show` for a visible window (needs a display), or
- have Devon pass the check in a Chrome started with
  `--remote-debugging-port=<port>`, then `rodney connect localhost:<port>` and
  drive it from there.
