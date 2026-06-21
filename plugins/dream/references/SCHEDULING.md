# Scheduling dream runs (nightly, unattended)

Run `dream` (and `dream-reviewers`) on a schedule so the corpus stays mined
without you remembering to. Two pieces: a **headless command** that runs the
skill, and an **OS scheduler** that fires it. Pair it with the SessionStart
proposals hook (`hooks/session-start-proposals.sh`) so you're warned about
pending recommendations next time you open the project.

> This skill depends on **local files** (your Claude Code session logs, the
> `~/.dream/<slug>/` state, and — for the model pass — a reachable ollama). So it
> must run **on the machine where those live**, not in a cloud scheduler.

## The headless command

```bash
claude -p "Run the dream skill on this project: distill new sessions, synth, then \
consolidate. Auto-write only genuinely-new memories; collect every proposal into \
the skill's review/pending/ file; do NOT auto-edit CLAUDE.md, skills, or DECISIONS.md. \
Print a short summary with a per-bucket count. Do not manufacture insights." \
  --permission-mode auto
```

- **Run it from the target project directory** — the tool derives the log dir,
  repo, `~/.dream/<slug>/` home, and known-corpus from the working directory.
- **`--permission-mode auto`** is the key flag for unattended runs: the classifier
  auto-approves safe tool calls and blocks dangerous ones, failing **closed** when
  there's no human to ask. The pipeline shells out (the `dream` scripts, `python`,
  `git`, `gh`), so a stricter mode like `acceptEdits` would stall on those Bash
  calls. Avoid `--dangerously-skip-permissions` unless you accept full unattended
  tool access as yourself.
- **Auth** comes from your logged-in `~/.claude` credentials — the scheduled job
  runs as your user, so no API key is needed if you're signed in.
- Set `WYRD_OLLAMA_URL` / `DREAM_MODEL` if your ollama isn't at the default
  (`http://localhost:11434` / `qwen2.5:7b`).

For `dream-reviewers`, swap the prompt and ensure `gh` is authenticated.

---

## Linux — systemd user timer (recommended)

A user timer survives logout/reboot (with linger), catches missed runs, and logs
to the journal. Replace `<project>`, the project dir, and the `claude` path.

`~/.config/systemd/user/dream-<project>.service`:

```ini
[Unit]
Description=Dream session-miner for <project>

[Service]
Type=oneshot
WorkingDirectory=/home/<you>/path/to/<project>
# User units start with a MINIMAL PATH — this is the #1 cause of silent failure.
# Include the dir holding the `claude` binary (and node if your install needs it).
Environment=PATH=/home/<you>/.local/bin:/usr/local/bin:/usr/bin:/bin
# Optional: point at a non-default ollama for the model pass.
Environment=WYRD_OLLAMA_URL=http://localhost:11434
ExecStart=/home/<you>/.local/bin/claude -p "Run the dream skill on this project: distill new sessions, synth, consolidate. Auto-write only genuinely-new memories; collect proposals into the skill's review/pending/ file; do NOT auto-edit CLAUDE.md, skills, or DECISIONS.md. Print a per-bucket count. Do not manufacture insights." --permission-mode auto
TimeoutStartSec=2400
```

`~/.config/systemd/user/dream-<project>.timer`:

```ini
[Unit]
Description=Run dream-<project> daily

[Timer]
OnCalendar=*-*-* 03:17:00
Persistent=true          # run on next wake if the machine was off at fire time
RandomizedDelaySec=120

[Install]
WantedBy=timers.target
```

Enable it:

```bash
systemctl --user daemon-reload
systemctl --user enable --now dream-<project>.timer
loginctl enable-linger "$USER"     # fire even when you're not logged in
```

Operate it:

```bash
systemctl --user list-timers 'dream*'              # next fire times
systemctl --user start dream-<project>.service     # run once now (test)
journalctl --user -u dream-<project>.service -f    # watch a run
```

Note: `claude -p` buffers and prints its summary at exit, so the journal stays
quiet until the run finishes.

---

## macOS — launchd LaunchAgent

`~/Library/LaunchAgents/com.<you>.dream-<project>.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>            <string>com.<you>.dream-<project></string>
  <key>WorkingDirectory</key> <string>/Users/<you>/path/to/<project></string>
  <key>EnvironmentVariables</key>
  <dict>
    <!-- launchd also has a minimal env; set a full PATH. -->
    <key>PATH</key>            <string>/Users/<you>/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
    <key>WYRD_OLLAMA_URL</key> <string>http://localhost:11434</string>
  </dict>
  <key>ProgramArguments</key>
  <array>
    <string>/Users/<you>/.local/bin/claude</string>
    <string>-p</string>
    <string>Run the dream skill on this project: distill new sessions, synth, consolidate. Auto-write only genuinely-new memories; collect proposals into the skill's review/pending/ file; do NOT auto-edit CLAUDE.md, skills, or DECISIONS.md. Print a per-bucket count. Do not manufacture insights.</string>
    <string>--permission-mode</string>
    <string>auto</string>
  </array>
  <key>StartCalendarInterval</key>
  <dict>
    <key>Hour</key>    <integer>3</integer>
    <key>Minute</key>  <integer>17</integer>
  </dict>
  <key>RunAtLoad</key>          <false/>
  <key>StandardOutPath</key>    <string>/Users/<you>/.dream/<project>/launchd.out.log</string>
  <key>StandardErrorPath</key>  <string>/Users/<you>/.dream/<project>/launchd.err.log</string>
</dict>
</plist>
```

Load / unload it:

```bash
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.<you>.dream-<project>.plist
launchctl bootout  gui/$(id -u) ~/Library/LaunchAgents/com.<you>.dream-<project>.plist   # to remove
launchctl kickstart -k gui/$(id -u)/com.<you>.dream-<project>                            # run once now (test)
```

(Older macOS: `launchctl load -w <plist>` / `launchctl unload -w <plist>`.)

Notes:
- LaunchAgents run only while you're **logged in** — there's no `linger`
  equivalent. If the Mac was asleep at the fire time, launchd runs the missed
  `StartCalendarInterval` job **once** on wake.
- Set the full `PATH` in `EnvironmentVariables` (note `/opt/homebrew/bin` on Apple
  Silicon) — launchd does not source your shell profile.
- Logs go to the `StandardOutPath` / `StandardErrorPath` files.

---

## cron (portable fallback, Linux or macOS)

```bash
crontab -e
```

```cron
# m h dom mon dow  — runs at 03:17 daily
PATH=/home/<you>/.local/bin:/usr/local/bin:/usr/bin:/bin
17 3 * * * cd /home/<you>/path/to/<project> && claude -p "Run the dream skill on this project: distill, synth, consolidate; auto-write only new memories; collect proposals into review/pending/; do not auto-edit shared files. Print a per-bucket count." --permission-mode auto >> "$HOME/.dream/<slug>/cron.log" 2>&1
```

Caveats: cron's env is the most minimal of all — set `PATH` at the top and use
absolute paths. cron does **not** catch missed runs (a machine off at 03:17 skips
that day), and on macOS `cron` needs Full Disk Access granted to `/usr/sbin/cron`
in System Settings → Privacy. Prefer the systemd/launchd options above when
available.

---

## Staggering dream + dream-reviewers

Give each its own unit/job a few minutes apart (e.g. `03:17` and `03:47`) so they
don't contend for ollama or the GitHub API. Both write per-run files into
`~/.dream/<slug>/review/pending/`, which the SessionStart hook surfaces together.
