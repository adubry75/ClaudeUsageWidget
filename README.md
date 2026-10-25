# Claude Usage Widget

A small always-on-top desktop widget showing Claude 5-hour session and weekly
limit usage, with a live tray gauge, plus a token counter across every Claude
Code agent on this machine. Costs zero model tokens: it is a plain REST call
and local file reads, never a model call.

```
source/repos/ClaudeUsageWidget/
├── dist/                         <-- RUN FROM HERE
│   ├── Start Claude Usage Widget.vbs   <-- double-click this
│   └── ClaudeUsageWidget.ps1
├── src/                          <-- edit here
│   ├── Start Claude Usage Widget.vbs
│   └── ClaudeUsageWidget.ps1
├── build.ps1                     <-- copies src -> dist
└── README.md
```

## Running it

Double-click **`dist\Start Claude Usage Widget.vbs`**.

The `.vbs` is a 4-line launcher whose only job is to run the `.ps1` with the
console window hidden. Without it, double-clicking the `.ps1` either opens it in
Notepad or leaves a black console window sitting behind the widget forever. Both
files must stay in the same folder.

To autostart: right-click the widget → **Start with Windows**. That writes
`HKCU\Software\Microsoft\Windows\CurrentVersion\Run\ClaudeUsageWidget` pointing
at whichever copy of the `.vbs` you launched, so launch it from `dist\` before
turning that on.

## Editing it

Edit `src\`, then run `build.ps1` to copy into `dist\`. Restart the widget
(tray → Exit, then relaunch) to pick up changes.

## Controls

| Action | Result |
| --- | --- |
| Drag | Move (position is saved) |
| Double-click body | Refresh now |
| Click the Tokens header | Expand / collapse the per-session breakdown |
| Right-click body | Full menu |
| Double-click tray icon | Show / hide |
| Right-click tray icon | Show-hide, Bring to corner, Refresh, Exit |

Menu: Refresh now · Skin · Compact mode · Always on top · Poll every
(1/5/10/15/30/60 min) · Token window (Current session / Today / This week) ·
Sort sessions by (Most recent / Largest) · Opacity · Snap to corner · Start with Windows ·
Open log · Hide to tray · Exit.

Skins: Clay, Midnight, Synthwave, Nord, Terminal, Paper.

## Where its data lives

| What | Path |
| --- | --- |
| Settings (position, skin, interval, opacity, token window, session sort) | `%LOCALAPPDATA%\ClaudeUsageWidget.json` |
| Log | `%LOCALAPPDATA%\ClaudeUsageWidget.log` |
| OAuth token it reads (written by Claude Code) | `%USERPROFILE%\.claude\.credentials.json` |
| Transcripts it reads for token counts | `%USERPROFILE%\.claude\projects\**\*.jsonl` |

Deleting the settings file resets position and skin to defaults. Safe to do any
time the widget is closed.

## The API

```
GET https://api.anthropic.com/api/oauth/usage
Authorization: Bearer <claudeAiOauth.accessToken>
anthropic-beta: oauth-2025-04-20
User-Agent: claude-code/2.0.31
```

Returns `five_hour`, `seven_day`, `seven_day_opus`, `seven_day_sonnet`, each
`{ utilization: 0-100, resets_at }`, plus an optional `extra_usage` block. Any
bucket can be `null` depending on plan, so every one is nil-checked.

**This endpoint is undocumented.** It is the private route Claude Code's
`/usage` command uses. Anthropic can change or remove it without notice; if the
widget starts showing errors, suspect this first. It requires a subscription
login — API-key mode returns 401.

The widget does not refresh the OAuth token. The credentials file is shared with
Claude Code and a sloppy write corrupts its login, so on expiry the widget just
says "run `claude`" and lets the CLI rotate it properly.

### Polling

The endpoint is shared with Claude Code and rate-limits non-CLI callers fairly
hard. 10 minutes is the default and is polite. The 1-minute option exists but if
you start seeing "Rate limited" in the error line, back off to 5.

Countdowns tick every second locally off the cached `resets_at` — that costs
nothing. Only the poll hits the network.

## Token counter

The usage API only reports percentages, so token counts come from Claude Code's
own transcripts. Every assistant turn records `input_tokens`,
`cache_creation_input_tokens`, `cache_read_input_tokens` and `output_tokens`.
Subagents live in `<session>\subagents\agent-<id>.jsonl` with a
`.meta.json` holding their type and description.

- **Headline** = input + cache-write + output ("work" tokens).
- **Sub-line** shows `out | in | +cache`, where `in` is input + cache-write and
  cache reads are listed separately. Cache reads are roughly 100x everything
  else (context re-read every turn), so folding them into the headline would
  bury the signal.
- **Window**: Session and Week start at the matching bar's `resets_at` minus
  5h / 7d, so they line up with the bars. Today starts at local midnight.
- **Breakdown**: top 5 sessions, each with up to 3 rows for `main` and its
  subagents (children always sort largest first). A session without subagents
  gets no child rows. Sessions sharing a folder name get their start time
  appended (`Meowntain  Tue 8:55pm`). Hover any row for the full path, start
  time, last activity, in/out/cache split and session id; hover a `+N more`
  row to see what it folds away.
- **Sort**: right-click → **Sort sessions by**. *Most recent* (the default)
  puts the session with the newest activity on top, so the one you are
  working in is first. *Largest* sorts by work tokens, as older versions did.
- **Age / live**: each session row shows when it last did anything (`just now`,
  `4m ago`, `2h 11m ago`, then `Tue 3:05pm` past 24h), counting subagent
  activity too. A session active in the last 2 minutes is **live**: its age is
  drawn in the skin's accent color with a small dot in front. The age refreshes
  with each 30 s rescan.
- **Session names are the launch folder.** The label is the leaf of the
  session's `cwd`, the directory Claude Code was started in. It never changes,
  however many other folders the session edits files in, so a session launched
  from `ThumbsUp` that is working in `ClimbWithMe` still reads `ThumbsUp`. Use
  the live dot and the age to find the running session, not the name.
- **Coverage**: Claude Code on this PC only. claude.ai web/desktop chats and
  other machines are not visible.

The scanner is inline C# (`TokenScanner`) on a pool thread, rescanning every
30 s. It only reads bytes appended since the last pass, and only files touched
in the last 8 days. A cold scan of ~1.6 GB takes about 10 s and the UI shows
`scanning...` until then.

**Dedupe is load-bearing.** One API response is written as several lines (up
to 27 observed) sharing `message.id`, and earlier copies can carry partial
`output_tokens`. Records are keyed by `message.id` and the last line wins.
Summing lines overcounts several-fold.

To check the numbers without the UI:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File src\ClaudeUsageWidget.ps1 -SelfTest
powershell -NoProfile -ExecutionPolicy Bypass -File src\ClaudeUsageWidget.ps1 -SelfTest -Since 2026-10-23T00:00:00Z
```

## Gotchas burned in during development

Four real bugs. Do not reintroduce them.

**1. Never put brushes in `$win.Resources[...]` with `{DynamicResource}`.**
A PowerShell function's return value lands in an untyped `IDictionary` still
wrapped in a `PSObject`. Property setters unwrap it; dictionaries do not. WPF
then throws `InvalidCastException: PSObject -> Brush` on *every* resource
lookup, forever — 39,000 failures in 90 seconds, a 34 MB log, pegged CPU, and a
window that never finishes its first layout pass. Every themed element is
`x:Name`d and painted directly in `Apply-Skin`. Keep it that way.

**2. `[int]` rounds in PowerShell, it does not truncate.**
`[int]$d.TotalHours` turns 3h52m into "4h 52m". Use `$d.Hours`, which is the
TimeSpan's already-truncated hour component. Worst under an hour, where 58
minutes displayed as "1h 58m".

**3. Don't declare the `DropShadowEffect` in XAML.**
The XAML parser can hand it back frozen, and the per-skin shadow opacity then
can't be set on it. Effects are built in code and replaced wholesale.

**4. Measure bar track width live, not once at startup.**
Cached at startup it comes back 0, and every bar collapses to the 3px minimum
regardless of the real percentage.

Also: the file is deliberately **ASCII-only**. Windows PowerShell 5.1 reads
`.ps1` as ANSI unless there's a BOM, so a stray `·` or `—` becomes mojibake at
runtime.

## Troubleshooting

Right-click → **Open log**, or open `%LOCALAPPDATA%\ClaudeUsageWidget.log`.
A healthy start is about a dozen lines ending in `running`:

```
--- start ---
xaml loaded
elements bound
menu built
tray ready
config loaded (skin=Clay)
skin applied: Clay
monitors: {X=5760,Y=0,...} | {X=-2880,Y=881,...} | {X=0,Y=0,...}  (dip scale 0.667)
positioned at 2280,2
refresh ok: session 47% weekly 15%
running
tokens: 94 files, 10941 recs, 10636 ms
```

The logger is rate-limited to 25 per distinct message per run, so a repeating
fault can't spin out a huge file again. A fatal error during startup raises a
message box naming the step instead of closing silently.

**Widget doesn't appear but no error:** it is probably running off-screen or
behind something. Use the tray icon → **Bring to corner**. If the tray icon
isn't there either, the process isn't running — check the log.

**Launching it again:** only one copy runs. A second launch signals the running
widget to show itself (snapping back to a corner if it is off-screen) and exits;
the log shows `already running; asked it to show, exiting`. The guard is a
named mutex, so a crashed or killed copy never blocks the next launch.

If an old pre-guard build is somehow still running alongside, clear everything:

```powershell
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
  Where-Object { $_.CommandLine -like '*ClaudeUsageWidget*' } |
  Stop-Process -Id { $_.ProcessId } -Force
```

## Off-screen check and display scaling

`Test-OnScreen` compares the window's WPF position (DIPs) against each
monitor's `System.Windows.Forms.Screen` working area, which is in physical
pixels. At 150% scaling those differ by 1.5×, so each working area is converted
to DIPs first, using the window's own DPI transform from `PresentationSource`
(or the desktop DPI if the window has no HwndSource yet). The scale in use is
logged on the `monitors:` line at startup (`dip scale 0.667` at 150%). This
matters on layouts with dead gaps in the virtual desktop: a saved position in
the gap is detected and the window goes back to the corner.

## Requirements

- Windows, PowerShell 5.1 (ships with Windows — no install)
- Claude Code logged in at least once on this machine with a subscription account
- No modules, no build step, no dependencies
