---
name: rodney
description: |
  Drive Chrome from the shell with the rodney CLI (installed at ~/bin/rodney):
  open pages, click, type, wait, read text or HTML, run JS, assert, and take
  screenshots you can then Read. Use for checking a web UI you just changed,
  screenshotting a page, scraping a JS-rendered page, or stepping through a
  login or form flow. Use the playwright-skill instead when you need request
  stubbing, init scripts or trusted mouse events (e.g. browser-extension tests).
---

# Rodney

[rodney](https://github.com/simonw/rodney) runs one long-lived Chrome and each
command talks to it, so a session spans many Bash calls. `rodney --help` lists
every command.

## Rules

1. **Use your own session.** The default session (`~/.rodney/`) is shared by
   every Claude on the machine. Pick one directory, e.g. `<scratchpad>/rodney`,
   and prefix **every** command with it. Shell variables don't survive between
   Bash calls, so write the path out each time:
   ```bash
   RODNEY_HOME=/tmp/…/rodney rodney start
   ```
2. **Always stop Chrome.** Its memory keeps growing. End with `rodney stop`.
   If that fails, or a command hung, kill the session's Chrome by profile:
   `pkill -f '<your RODNEY_HOME>/chrome-data'`.
3. **Wait before reading.** After `open` or `click`, run `waitstable` (DOM),
   `waitidle` (network) or `wait <selector>` before `text`, `html` or
   `screenshot`.
4. **Use `file://` for local HTML.** `data:` URLs crash rodney.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | Success |
| 1 | Check failed: `exists`, `visible`, `assert`, `ax-find` found nothing |
| 2 | Error: no browser, bad arguments, timeout. `text` on a missing element is 2 after a timeout, not 1 |

Check for an element with `exists` before calling `text` on it, so a missing
element doesn't cost a timeout.

`status` exits 0 even when it reports "Browser not responding", so read its
output, not its exit code.

## Example

```bash
R=/tmp/…/rodney   # same literal path in every call
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
