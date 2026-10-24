# Token usage section - design

Date: 2026-10-23
Status: approved in brainstorming; spec review rounds 1-2 issues addressed

## Goal

Add a token counter to the widget: total tokens used by all Claude Code agents
on this machine in a selectable time window, with an expandable per-session /
per-subagent breakdown.

## Non-goals

- claude.ai web / desktop chat usage, or other machines. Only Claude Code
  transcripts on this PC are visible.
- Cost in dollars.
- Any network call. This feature is local file reads only.

## Data source

`%USERPROFILE%\.claude\projects\<project-dir>\`

| File | Contents |
| --- | --- |
| `<sessionId>.jsonl` | Main conversation. `isSidechain:false`. |
| `<sessionId>\subagents\agent-<agentId>.jsonl` | One subagent. Lines carry `isSidechain:true`, `agentId`. |
| `<sessionId>\subagents\agent-<agentId>.meta.json` | `{ agentType, description, ... }` |

Relevant fields on an assistant line:

```
message.id                                  msg_...
message.usage.input_tokens
message.usage.cache_creation_input_tokens
message.usage.cache_read_input_tokens
message.usage.output_tokens
timestamp                                   ISO-8601 UTC
sessionId
cwd
agentId                                     subagent lines only
```

**Duplicate lines:** one API response is streamed as several lines, all with
the same `message.id`. Observed up to 27 copies. Copies are not identical:
earlier ones can carry partial `output_tokens` (e.g. 8, then 548) and
different `timestamp`s. Rule: **last line wins** - a later line for the same
id replaces the whole record, including its timestamp. Ids never span files.

**Volume:** ~1.6 GB / 93 files modified in the last 8 days. Largest file 74 MB.
Some non-usage lines exceed 2 MB. Full re-reads are not acceptable.

## Token math

Per record:
- `In`  = `input_tokens + cache_creation_input_tokens` (displayed as "in")
- `Out` = `output_tokens`
- `CacheRead` = `cache_read_input_tokens`
- **Work** = `In + Out`. This is the headline and the sort key everywhere.

Cache reads are shown separately on the sub-line only. Observed 24h mix:
out 1.18M, cache-write 4.99M, input ~0, cache-read 502M.

## Scanner (inline C#, `Add-Type`)

Class `TokenScanner`, compiled in its own `Add-Type` call with
`-ReferencedAssemblies System.Web.Extensions` (separate from the existing
`W32` helper). Must compile under the C# 5 / .NET Framework compiler PS 5.1
uses: no string interpolation, no `?.`, no tuples, no `nameof`.

State:
- `Dictionary<string,long> offsets` - bytes consumed per file path.
- `Dictionary<string,Rec> recs` - keyed by `message.id`.
- `Dictionary<string,string[]> meta` - agentId -> {agentType, description},
  read lazily from `.meta.json`; missing file -> {"agent", ""}.
- `volatile int Generation` - incremented at the end of **every** completed
  scan (including the early return when the dir is missing), so the UI always
  leaves the `scanning...` state and picks up `Missing` / `LastError` changes.
- `volatile bool IsBusy`, `volatile bool Missing`, `volatile string LastError`,
  `volatile int LastFiles`, `volatile int LastMs`, `volatile int LastNewRecs`
  - written by the pool thread, read by the UI thread.

`Rec`: `Time (DateTime UTC), SessionId, Cwd, AgentId (null for main),
In, CacheRead, Out` (longs).

`Scan()`:
1. Set `Missing` = whether the projects dir is absent (so it clears again if
   the dir appears later). If missing: bump `Generation`, return.
2. Enumerate `*.jsonl` recursively. Skip files whose `LastWriteTimeUtc` is
   older than now - 8 days (one-week window + 1 day slack).
3. Open with `FileShare.ReadWrite | FileShare.Delete`. If length < stored
   offset, the file was rewritten: reset offset to 0.
4. Seek to the stored offset and read in 1 MB chunks to EOF, splitting on the
   byte `0x0A` (safe in UTF-8). Only consume through the last `\n`; a trailing
   partial line is left for the next pass. Decode each complete line as UTF-8.
5. For each line: skip unless it contains `"usage"` and `"msg_`. Parse with
   `JavaScriptSerializer` (`MaxJsonLength = int.MaxValue`). Read numbers via
   `Convert.ToInt64` (serializer returns int/long/decimal). Missing numeric
   fields count as 0. Malformed lines are skipped.
6. **Parsing happens outside the lock** into a per-file local list. Only the
   merge into `recs` / `offsets` takes the lock.
7. After all files: prune records older than now - 8 days; set `LastFiles`,
   `LastMs`, `LastNewRecs`; bump `Generation`.
8. Locked/unreadable files: skip this pass, keep offset, record message in
   `LastError`.

`ScanAsync()`: if not `IsBusy`, set it and run `Scan()` via
`Task.Run` inside C# (no PowerShell scriptblocks on pool threads); clear
`IsBusy` in `finally`. Never throws.

`Summarize(DateTime fromUtc)` (takes the lock, returns copies):
- Totals: `In, Out, CacheRead, Work` over records with `Time >= fromUtc`.
- Sessions: `{ SessionId, Label, Work, Children[] }`, sorted by Work desc.
  - `Label` = last path segment of the most recent `Cwd` among **main**
    (AgentId null) records of that session; fallback the most recent subagent
    Cwd; fallback first 8 chars of sessionId.
  - `Children` = one entry for the main conversation (`Kind="main"`,
    `Desc=""`) plus one per subagent (`Kind=agentType`, `Desc=description`),
    each with its own Work, sorted by Work desc, zero-Work entries dropped.

## Windows

Config key `TokenWindow`: `Session` (default) | `Today` | `Week`.

| Window | Start |
| --- | --- |
| Session | `five_hour.resets_at - 5h`; fallback `now - 5h` if no API data yet, bucket null, or `resets_at` null |
| Today | local midnight, converted to UTC |
| Week | `seven_day.resets_at - 7d`; same fallbacks with `now - 7d` |

Changing the window re-runs `Summarize` only; no rescan.

## UI

Content width is ~218 px (278 window - 30 margin - 28 padding - 2 border).

New block after `WkReset`, before `Detail`. Hidden in Compact mode (same
treatment as `Detail`).

```
Tokens - session                   6.2M >
out 1.2M | in 5.0M | +502M cache
```

Expanded (chevron becomes `v`):

```
Purrpendicular                     2.6M
   main                            1.4M
   general-purpose  Build Cit...   820K
   +4 more agents                  380K
ClaudeUsageWidget                  640K
+3 more sessions
```

- **Session row** shows the session's total Work (main + all subagents).
- **Child rows** are shown only when the session has at least one subagent
  (a main-only session has no children - its row already is "main").
  At most 3 child rows: if there are more than 3 children, show the top 2
  then `+N more agents` with the remaining Work summed.
- At most 5 sessions; remainder collapsed into `+N more sessions`.
- The list is wrapped in a ScrollViewer with `MaxHeight=260`
  (vertical scrollbar Auto) as a safety net.
- Each row is a 2-column Grid (label `*`, value `Auto`). Labels use
  `TextTrimming="CharacterEllipsis"`; no manual truncation. Subagent label is
  `<agentType>  <description>`.
- Header row (`TokHdr`) is clickable: toggles the list. Its MouseLeftButtonDown
  sets `e.Handled = $true` so it neither starts `DragMove` nor counts toward
  the window's double-click refresh.
- No records in window: headline `0`, sub-line
  `no Claude Code activity in window`.
- Projects dir missing: headline `--`, sub-line `no Claude Code logs found`.
- Before the first scan finishes: headline `--`, sub-line `scanning...`.
- Expanded state persisted as config key `TokExpanded` (bool, default false).
- Rows are rebuilt in code on every render; every TextBlock gets its brush
  directly from the current skin (Label for labels, Sub for child rows and
  the sub-line, Val for values). Never via resources. `Apply-Skin` triggers a
  re-render.
- All new strings and source text ASCII-only.

### Number format

`Format-Tok([long]$n)`:
- `n < 1000` -> integer as-is.
- Otherwise pick unit K (1e3), M (1e6), B (1e9) as the largest unit <= n.
  Value `v = n / unit`. Round to one decimal; if the rounded value is
  >= 100, round to an integer instead. If that yields >= 1000 and a larger
  unit exists, move up a unit and re-format (999,950 -> `1.0M`, not `1000K`;
  99,960 -> `100K`, not `100.0K`).
- Examples: `999`, `1.0K`, `12.3K`, `640K`, `4.2M`, `502M`, `1.1B`.

## Menu

New submenu after `Poll every`: `Token window` -> `Current session (5h)`,
`Today`, `This week`. Radio-style checks. Saves config and re-renders.

Existing bug, fixed in passing because the new submenu would copy it: Skin,
Poll every and Opacity set their checks at menu-build time, which runs before
`Load-Cfg`, so saved choices never appear checked. A `Sync-MenuChecks`
function sets all four submenus' checks from `$script:Cfg` (Opacity compared
with a 0.01 tolerance, as now; the 0.96 default matching no item is
expected) and is called in
`SourceInitialized` after `Load-Cfg` (where `miCompact`/`miTop` are already
synced).

## Config

Add to the `$script:Cfg` defaults (`Load-Cfg` only copies known keys):
`TokenWindow = 'Session'`, `TokExpanded = $false`. Validate `TokenWindow`
against the three values like `Skin`; fall back to `Session`.

## Timing

- First scan: `ScanAsync()` in `ContentRendered`.
- `TokTimer`: DispatcherTimer, 30 s, Tick calls `ScanAsync()`.
- The existing 1 s `Ticker` also checks `$scanner.Generation` against
  `$script:TokRendered`; if different, render and store the new generation.
  This shows results as soon as any scan finishes.
- `Update-Widget` success re-renders (the session/week start may have moved).
- Window change, toggle, and skin change re-render directly.

## Errors and logging

- Scanner never throws into PowerShell; failures land in `LastError`.
- `Render-Tokens` is wrapped in try/catch and logs via `Write-Log`; failures
  never affect the usage bars, tray icon, or alerts.
- When a scan finishes with `LastNewRecs > 0`: `tokens: N files, M recs, K ms`. When
  `LastError` changes: `tokens scan error: ...`. (Write-Log's per-message
  rate limit will silence the per-scan line after 25 writes; accepted.)

## Testing

`-SelfTest` script switch (with optional `-Since <ISO-8601>`): compile
`TokenScanner`, run `Scan()` synchronously, print totals for `-Since` (or
Session-fallback now-5h, Today, Week) and the top sessions with children as
text, plus files/recs/ms, then exit before any window is created.

Verification: run `-SelfTest -Since X` and an independent Python script over
the same files that dedupes by `message.id` with **last-line-wins** (record
and timestamp from the last line), filters `timestamp >= X`, and sums In/Out/
CacheRead. Totals must match exactly. Also time the cold scan.

Manual checks: widget starts; section renders; toggle works and persists;
window menu switches values and persists; every skin paints the new rows;
Compact hides the block; header click doesn't drag or refresh; `build.ps1`
reports `ascii ok`.

## Docs

README: add the token section to Controls/Menu, add the projects dir to
"Where its data lives", note the local-only coverage and the cache-read split.
