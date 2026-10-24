# ClaudeUsageWidget.ps1
# Always-on-top desktop widget for Claude 5-hour + weekly limit usage.
# Data: GET https://api.anthropic.com/api/oauth/usage (undocumented route Claude Code's /usage uses)
# Costs zero model tokens. Token is read from Claude Code's own credentials file.
#
# Run:  double-click "Start Claude Usage Widget.vbs"
#
# Drag to move.  Double-click body = refresh now.  Right-click = menu.
# Tray icon: double-click to show/hide, right-click for menu.
#
# Troubleshooting: %LOCALAPPDATA%\ClaudeUsageWidget.log  (right-click -> Open log)
#
# THEMING NOTE (this cost three broken builds, do not undo it):
# Brushes are assigned DIRECTLY to element properties, never through
# $win.Resources['Key'] + {DynamicResource}. A PowerShell function's return value
# enters an untyped IDictionary still wrapped in a PSObject; property setters
# unwrap it, dictionaries do not. WPF then throws InvalidCastException
# (PSObject -> Brush) on every single resource lookup, forever.
#
# ASCII-only on purpose: Windows PowerShell 5.1 reads .ps1 as ANSI without a BOM.
#
# -SelfTest [-Since <ISO-8601>]: scan Claude Code transcripts once, print token
# totals as text, and exit without showing the widget.

param([switch]$SelfTest, [string]$Since)

$ErrorActionPreference = 'Stop'

$script:LogPath   = Join-Path $env:LOCALAPPDATA 'ClaudeUsageWidget.log'
$script:LogCounts = @{}
$script:LogMax    = 25     # per distinct message, per run - stops runaway logs

function Write-Log([string]$msg) {
    try {
        $key = $msg -replace '[0-9]+', 'N'
        $n = [int]$script:LogCounts[$key]
        $script:LogCounts[$key] = $n + 1
        if ($n -ge $script:LogMax) {
            if ($n -eq $script:LogMax) {
                Add-Content -LiteralPath $script:LogPath -Encoding UTF8 `
                    -Value ('{0}  [further identical messages suppressed] {1}' -f
                            (Get-Date).ToString('HH:mm:ss.fff'), $key)
            }
            return
        }
        Add-Content -LiteralPath $script:LogPath -Encoding UTF8 `
            -Value ('{0}  {1}' -f (Get-Date).ToString('HH:mm:ss.fff'), $msg)
    } catch { }
}

function Die([string]$where, $err) {
    $detail = if ($err -is [System.Management.Automation.ErrorRecord]) {
        "$($err.Exception.GetType().Name): $($err.Exception.Message)`r`n" +
        "at line $($err.InvocationInfo.ScriptLineNumber): $($err.InvocationInfo.Line.Trim())"
    } else { "$err" }
    Write-Log "FATAL [$where] $detail"
    try {
        Add-Type -AssemblyName System.Windows.Forms -EA SilentlyContinue
        [System.Windows.Forms.MessageBox]::Show(
            "Claude Usage Widget failed in: $where`r`n`r`n$detail`r`n`r`nLog:`r`n$script:LogPath",
            'Claude Usage Widget', 'OK', 'Error') | Out-Null
    } catch { }
    exit 1
}

try {
    if ((Test-Path $script:LogPath) -and (Get-Item $script:LogPath).Length -gt 200kb) {
        Remove-Item $script:LogPath -Force -EA SilentlyContinue
    }
} catch { }
Write-Log '--- start ---'

try {
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase,
                           System.Windows.Forms, System.Drawing
    Add-Type @"
using System;
using System.Runtime.InteropServices;
public class W32 {
    [DllImport("user32.dll", SetLastError=true)]
    public static extern bool DestroyIcon(IntPtr handle);
}
"@
} catch { Die 'assembly load' $_ }

# ---------------------------------------------------------------- token scanner
# Reads Claude Code's local transcripts (~\.claude\projects\**\*.jsonl) for
# per-message token usage. Pure C# on a pool thread: the files total GBs and
# ConvertFrom-Json is far too slow for that under PS 5.1. Incremental - only
# bytes appended since the last pass are read.
#
# One API response is streamed as several lines sharing message.id, and earlier
# copies can carry partial output_tokens. Records are keyed by message.id and
# the LAST line wins. Summing lines instead inflates totals several-fold.

try {
    Add-Type -ReferencedAssemblies System.Web.Extensions -IgnoreWarnings @"
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;
using System.Threading.Tasks;
using System.Web.Script.Serialization;

public class TokRec {
    public DateTime Time; public string SessionId; public string Cwd; public string AgentId;
    public long In; public long CacheRead; public long Out;
}
public class TokChild { public bool IsMain; public string Kind; public string Desc; public long Work; }
public class TokSession {
    public string SessionId; public string Label; public long Work;
    public List<TokChild> Children = new List<TokChild>();
}
public class TokSummary {
    public long In; public long Out; public long CacheRead; public long Work;
    public List<TokSession> Sessions = new List<TokSession>();
}

public class TokenScanner {
    readonly string root;
    readonly object gate = new object();
    readonly Dictionary<string, long> offsets = new Dictionary<string, long>(StringComparer.OrdinalIgnoreCase);
    readonly Dictionary<string, TokRec> recs = new Dictionary<string, TokRec>();
    readonly Dictionary<string, string[]> meta = new Dictionary<string, string[]>();

    // written by the scan thread, read by the UI thread
    public volatile int Generation;
    public volatile bool IsBusy;
    public volatile bool Missing;
    public volatile string LastError;
    public volatile int LastFiles;
    public volatile int LastMs;
    public volatile int LastNewRecs;

    public TokenScanner(string root) { this.root = root; }

    public int RecordCount { get { lock (gate) { return recs.Count; } } }

    public void ScanAsync() {
        if (IsBusy) return;
        IsBusy = true;
        Task.Run(() => {
            try { Scan(); }
            catch (Exception ex) { LastError = ex.Message; }
            finally { IsBusy = false; }
        });
    }

    public void Scan() {
        var sw = System.Diagnostics.Stopwatch.StartNew();
        try {
            Missing = !Directory.Exists(root);
            if (Missing) return;

            DateTime horizon = DateTime.UtcNow.AddDays(-8);
            var ser = new JavaScriptSerializer();
            ser.MaxJsonLength = int.MaxValue;
            int files = 0, added = 0;
            string err = null;

            foreach (string path in Directory.EnumerateFiles(root, "*.jsonl", SearchOption.AllDirectories)) {
                try {
                    var fi = new FileInfo(path);
                    if (fi.LastWriteTimeUtc < horizon) continue;
                    long off;
                    lock (gate) { if (!offsets.TryGetValue(path, out off)) off = 0; }
                    if (fi.Length < off) off = 0;          // rewritten
                    if (fi.Length == off) continue;
                    files++;

                    LoadMeta(path, ser);
                    var parsed = new List<KeyValuePair<string, TokRec>>();
                    long consumed = ReadLines(path, off, delegate(string line) {
                        string id; TokRec r = Parse(line, ser, out id);
                        if (r != null) parsed.Add(new KeyValuePair<string, TokRec>(id, r));
                    });

                    lock (gate) {
                        foreach (var kv in parsed) recs[kv.Key] = kv.Value;
                        offsets[path] = consumed;
                    }
                    added += parsed.Count;
                } catch (Exception ex) {
                    err = Path.GetFileName(path) + ": " + ex.Message;
                }
            }

            lock (gate) {
                var old = new List<string>();
                foreach (var kv in recs) if (kv.Value.Time < horizon) old.Add(kv.Key);
                foreach (string k in old) recs.Remove(k);
            }

            LastFiles = files;
            LastNewRecs = added;
            LastError = err;
        } finally {
            LastMs = (int)sw.ElapsedMilliseconds;
            Generation++;
        }
    }

    // Reads complete lines from off to EOF. A trailing partial line (still being
    // written) is left for the next pass. Returns the offset just past the last \n.
    static long ReadLines(string path, long off, Action<string> onLine) {
        using (var fs = new FileStream(path, FileMode.Open, FileAccess.Read,
                                       FileShare.ReadWrite | FileShare.Delete)) {
            fs.Seek(off, SeekOrigin.Begin);
            var buf = new byte[1 << 20];
            var pending = new MemoryStream();
            long chunkPos = off, consumed = off;
            int n;
            while ((n = fs.Read(buf, 0, buf.Length)) > 0) {
                int start = 0;
                while (start < n) {
                    int nl = Array.IndexOf(buf, (byte)10, start, n - start);
                    if (nl < 0) break;
                    string line;
                    if (pending.Length > 0) {
                        pending.Write(buf, start, nl - start);
                        line = Encoding.UTF8.GetString(pending.GetBuffer(), 0, (int)pending.Length);
                        pending.SetLength(0);
                    } else {
                        line = Encoding.UTF8.GetString(buf, start, nl - start);
                    }
                    onLine(line);
                    consumed = chunkPos + nl + 1;
                    start = nl + 1;
                }
                if (start < n) pending.Write(buf, start, n - start);
                chunkPos += n;
            }
            return consumed;
        }
    }

    static object Get(Dictionary<string, object> d, string k) {
        object v; return (d != null && d.TryGetValue(k, out v)) ? v : null;
    }

    static long Num(Dictionary<string, object> d, string k) {
        object v = Get(d, k);
        if (v == null) return 0;
        try { return Convert.ToInt64(v, CultureInfo.InvariantCulture); } catch { return 0; }
    }

    static TokRec Parse(string line, JavaScriptSerializer ser, out string id) {
        id = null;
        if (line.IndexOf("\"usage\"", StringComparison.Ordinal) < 0 ||
            line.IndexOf("\"msg_", StringComparison.Ordinal) < 0) return null;
        Dictionary<string, object> j;
        try { j = ser.DeserializeObject(line) as Dictionary<string, object>; } catch { return null; }
        var m = Get(j, "message") as Dictionary<string, object>;
        var u = Get(m, "usage") as Dictionary<string, object>;
        id = Get(m, "id") as string;
        if (u == null || id == null || !id.StartsWith("msg_", StringComparison.Ordinal)) return null;

        string ts = Get(j, "timestamp") as string;
        DateTime t;
        if (ts == null || !DateTime.TryParse(ts, CultureInfo.InvariantCulture,
                DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal, out t)) return null;

        var r = new TokRec();
        r.Time = t;
        r.SessionId = (Get(j, "sessionId") as string) ?? "";
        r.Cwd = Get(j, "cwd") as string;
        if (Get(j, "isSidechain") is bool && (bool)Get(j, "isSidechain"))
            r.AgentId = (Get(j, "agentId") as string) ?? "sidechain";
        r.In = Num(u, "input_tokens") + Num(u, "cache_creation_input_tokens");
        r.CacheRead = Num(u, "cache_read_input_tokens");
        r.Out = Num(u, "output_tokens");
        return r;
    }

    // subagents\agent-<id>.jsonl sits next to agent-<id>.meta.json {agentType, description}
    void LoadMeta(string path, JavaScriptSerializer ser) {
        string name = Path.GetFileNameWithoutExtension(path);
        if (!name.StartsWith("agent-", StringComparison.Ordinal)) return;
        string agentId = name.Substring(6);
        lock (gate) { if (meta.ContainsKey(agentId)) return; }
        string kind = "agent", desc = "";
        try {
            string mp = Path.Combine(Path.GetDirectoryName(path), name + ".meta.json");
            if (File.Exists(mp)) {
                var d = ser.DeserializeObject(File.ReadAllText(mp)) as Dictionary<string, object>;
                string a = Get(d, "agentType") as string, b = Get(d, "description") as string;
                if (!string.IsNullOrEmpty(a)) kind = a;
                if (b != null) desc = b;
            }
        } catch { }
        lock (gate) { meta[agentId] = new string[] { kind, desc }; }
    }

    class Acc {
        public long Work;
        public Dictionary<string, long> Kids = new Dictionary<string, long>();
        public string MainCwd; public DateTime MainT = DateTime.MinValue;
        public string AnyCwd;  public DateTime AnyT  = DateTime.MinValue;
    }

    static string Leaf(string cwd) {
        try { return Path.GetFileName(cwd.TrimEnd('\\', '/')); } catch { return cwd; }
    }

    public TokSummary Summarize(DateTime fromUtc) {
        var s = new TokSummary();
        var by = new Dictionary<string, Acc>();
        lock (gate) {
            foreach (TokRec r in recs.Values) {
                if (r.Time < fromUtc) continue;
                long w = r.In + r.Out;
                s.In += r.In; s.Out += r.Out; s.CacheRead += r.CacheRead; s.Work += w;

                Acc a;
                if (!by.TryGetValue(r.SessionId, out a)) { a = new Acc(); by[r.SessionId] = a; }
                a.Work += w;
                string key = r.AgentId ?? "";
                long cur; a.Kids.TryGetValue(key, out cur); a.Kids[key] = cur + w;
                if (!string.IsNullOrEmpty(r.Cwd)) {
                    if (r.AgentId == null && r.Time >= a.MainT) { a.MainT = r.Time; a.MainCwd = r.Cwd; }
                    if (r.Time >= a.AnyT) { a.AnyT = r.Time; a.AnyCwd = r.Cwd; }
                }
            }

            foreach (var kv in by) {
                var ses = new TokSession();
                ses.SessionId = kv.Key;
                ses.Work = kv.Value.Work;
                string cwd = kv.Value.MainCwd ?? kv.Value.AnyCwd;
                ses.Label = !string.IsNullOrEmpty(cwd) ? Leaf(cwd)
                          : (kv.Key.Length > 8 ? kv.Key.Substring(0, 8) : kv.Key);
                foreach (var k in kv.Value.Kids) {
                    if (k.Value <= 0) continue;
                    var c = new TokChild();
                    c.Work = k.Value;
                    if (k.Key == "") { c.IsMain = true; c.Kind = "main"; c.Desc = ""; }
                    else {
                        string[] md;
                        if (!meta.TryGetValue(k.Key, out md)) md = new string[] { "agent", "" };
                        c.Kind = md[0]; c.Desc = md[1];
                    }
                    ses.Children.Add(c);
                }
                ses.Children.Sort(delegate(TokChild x, TokChild y) { return y.Work.CompareTo(x.Work); });
                s.Sessions.Add(ses);
            }
        }
        s.Sessions.Sort(delegate(TokSession x, TokSession y) { return y.Work.CompareTo(x.Work); });
        return s;
    }
}
"@
} catch { Die 'token scanner compile' $_ }

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$script:CredPath  = Join-Path $env:USERPROFILE '.claude\.credentials.json'
$script:CfgPath   = Join-Path $env:LOCALAPPDATA 'ClaudeUsageWidget.json'
$script:ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:RunKey    = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$script:RunName   = 'ClaudeUsageWidget'
$script:ProjDir   = Join-Path $env:USERPROFILE '.claude\projects'

$script:Cfg = [ordered]@{
    Left = $null; Top = $null
    Interval = 10; Opacity = 0.96; Compact = $false; Topmost = $true
    AlertAt = 85; Skin = 'Clay'
    TokenWindow = 'Session'; TokExpanded = $false
}
$script:Buckets   = @{}
$script:LastAlert = @{}
$script:TrayIcon  = $null
$script:Busy      = $false

$script:TokWindows  = @('Session', 'Today', 'Week')
$script:Scanner     = New-Object TokenScanner $script:ProjDir
$script:TokRendered = -1
$script:TokLastErr  = $null

# ---------------------------------------------------------------- token helpers

# 999 / 12.3K / 640K / 4.2M / 1.1B. Rounds first, then re-checks the unit so
# 999,950 reads 1.0M (not 1000K) and 99,960 reads 100K (not 100.0K).
function Format-Tok($n) {
    $n = [double]$n
    if ($n -lt 1000) { return ('{0:0}' -f $n) }
    $units = @(@(1e3, 'K'), @(1e6, 'M'), @(1e9, 'B'))
    $i = 0
    while ($i -lt 2 -and $n -ge $units[$i + 1][0]) { $i++ }
    while ($true) {
        $v = [Math]::Round($n / $units[$i][0], 1)
        if ($v -ge 100) { $v = [Math]::Round($n / $units[$i][0]) }
        if ($v -ge 1000 -and $i -lt 2) { $i++; continue }
        if ($v -ge 100) { return ('{0:0}{1}' -f $v, $units[$i][1]) }
        return ('{0:0.0}{1}' -f $v, $units[$i][1])
    }
}

# Session and Week line up with the bars via resets_at; until the first API
# response (or if the bucket / resets_at is null) fall back to now - span.
function Get-TokStart {
    switch ([string]$script:Cfg.TokenWindow) {
        'Today' { return [DateTime]::Today.ToUniversalTime() }
        'Week'  { $b = $script:Buckets['Weekly'];   $span = [TimeSpan]::FromDays(7) }
        default { $b = $script:Buckets['FiveHour']; $span = [TimeSpan]::FromHours(5) }
    }
    if ($b -and $b.resets_at) {
        try { return ([DateTimeOffset]$b.resets_at).UtcDateTime - $span } catch { }
    }
    [DateTime]::UtcNow - $span
}

if ($SelfTest) {
    $sc = $script:Scanner
    $sc.Scan()
    'files read {0}  recs {1}  ms {2}  missing {3}  error {4}' -f `
        $sc.LastFiles, $sc.RecordCount, $sc.LastMs, $sc.Missing, $sc.LastError
    $wins = New-Object System.Collections.ArrayList
    if ($Since) {
        [void]$wins.Add(@('since', [DateTimeOffset]::Parse($Since).UtcDateTime))
    } else {
        [void]$wins.Add(@('session (now-5h)', [DateTime]::UtcNow.AddHours(-5)))
        [void]$wins.Add(@('today', [DateTime]::Today.ToUniversalTime()))
        [void]$wins.Add(@('week (now-7d)', [DateTime]::UtcNow.AddDays(-7)))
    }
    foreach ($w in $wins) {
        $s = $sc.Summarize($w[1])
        ''
        '{0}  from {1:u}' -f $w[0], $w[1]
        '  work {0} ({1})  in {2}  out {3}  cacheRead {4}' -f `
            (Format-Tok $s.Work), $s.Work, $s.In, $s.Out, $s.CacheRead
        foreach ($ss in @($s.Sessions) | Select-Object -First 5) {
            '  {0,-28} {1,8}' -f $ss.Label, (Format-Tok $ss.Work)
            foreach ($k in @($ss.Children) | Select-Object -First 4) {
                '      {0,-24} {1,8}' -f (($k.Kind + '  ' + $k.Desc).Trim()), (Format-Tok $k.Work)
            }
        }
    }
    exit 0
}

# ---------------------------------------------------------------- skins

$script:Skins = [ordered]@{
    'Clay' = @{
        BgA='#FF2A2D36'; BgB='#FF121318'; Border='#FF3F4553'; Shadow=0.55; Gloss='#24FFFFFF'
        Accent='#FFE08A64'; Dot='#FFC96442'
        Label='#FF9BA3B1'; Sub='#FF6E7684'; Val='#FFF6F7F9'; Track='#FF2E3440'
        Ok=@('#FF6EE7B7','#FF34D399'); Warn=@('#FFFCD34D','#FFF59E0B'); Crit=@('#FFFCA5A5','#FFEF4444')
    }
    'Midnight' = @{
        BgA='#FF223054'; BgB='#FF080D1B'; Border='#FF32436F'; Shadow=0.60; Gloss='#26FFFFFF'
        Accent='#FF7DD3FC'; Dot='#FF38BDF8'
        Label='#FF97A9CC'; Sub='#FF61719A'; Val='#FFEDF4FF'; Track='#FF24334F'
        Ok=@('#FF67E8F9','#FF22D3EE'); Warn=@('#FFFDE68A','#FFFBBF24'); Crit=@('#FFFDA4AF','#FFF43F5E')
    }
    'Synthwave' = @{
        BgA='#FF3A1578'; BgB='#FF0F0226'; Border='#FF8B46F0'; Shadow=0.65; Gloss='#30FFFFFF'
        Accent='#FFFF7AD9'; Dot='#FFF472B6'
        Label='#FFC9B6FF'; Sub='#FF8E7AD0'; Val='#FFFFF0FC'; Track='#FF3E1F7A'
        Ok=@('#FF67E8F9','#FFA855F7'); Warn=@('#FFFDE047','#FFFB7185'); Crit=@('#FFFFA0A0','#FFFF2D95')
    }
    'Nord' = @{
        BgA='#FF4A5467'; BgB='#FF272B34'; Border='#FF5E6B86'; Shadow=0.50; Gloss='#1EFFFFFF'
        Accent='#FF88C0D0'; Dot='#FF81A1C1'
        Label='#FFD8DEE9'; Sub='#FF97A5B9'; Val='#FFECEFF4'; Track='#FF3B4252'
        Ok=@('#FFA3BE8C','#FF8FBCBB'); Warn=@('#FFEBCB8B','#FFD08770'); Crit=@('#FFD08C94','#FFBF616A')
    }
    'Terminal' = @{
        BgA='#FF141A15'; BgB='#FF020402'; Border='#FF2A552F'; Shadow=0.70; Gloss='#1E7CFF9B'
        Accent='#FF4ADE80'; Dot='#FF22C55E'
        Label='#FF84C795'; Sub='#FF4E7F5B'; Val='#FFDCFFE4'; Track='#FF16281B'
        Ok=@('#FF86EFAC','#FF22C55E'); Warn=@('#FFFDE047','#FFEAB308'); Crit=@('#FFFCA5A5','#FFDC2626')
    }
    'Paper' = @{
        BgA='#FFFFFFFF'; BgB='#FFE8EBEF'; Border='#FFCFD4DC'; Shadow=0.28; Gloss='#00FFFFFF'
        Accent='#FFB4542F'; Dot='#FFC96442'
        Label='#FF4B5563'; Sub='#FF8A919C'; Val='#FF0F1116'; Track='#FFDCE1E8'
        Ok=@('#FF34D399','#FF059669'); Warn=@('#FFFBBF24','#FFD97706'); Crit=@('#FFF87171','#FFDC2626')
    }
}

function New-Color([string]$hex) {
    [Windows.Media.ColorConverter]::ConvertFromString($hex)
}

function New-Brush([string]$hex) {
    $b = New-Object Windows.Media.SolidColorBrush
    $b.Color = [Windows.Media.Color](New-Color $hex)
    $b.Freeze()
    $b
}

# ---------------------------------------------------------------- UI
# Every themed element is x:Named and painted in code. No DynamicResource.

$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Claude Usage" Width="278" SizeToContent="Height"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ShowInTaskbar="False" ResizeMode="NoResize"
        WindowStartupLocation="Manual">
  <!-- Margin gives the drop shadow room to render. Do not remove. -->
  <Border x:Name="Root" CornerRadius="13" BorderThickness="1" Margin="15,14,15,16"
          Padding="14,12,14,13" Background="#FF2A2D36" BorderBrush="#FF3F4553">
    <Grid>
      <Border x:Name="Gloss" Height="1" VerticalAlignment="Top" Margin="-13,-11,-13,0"
              Background="#24FFFFFF" CornerRadius="13,13,0,0"/>

      <StackPanel>
        <Grid Margin="0,0,0,11">
          <StackPanel Orientation="Horizontal">
            <Ellipse x:Name="Dot" Width="7" Height="7" Margin="0,0,7,0"
                     VerticalAlignment="Center" Fill="#FFC96442"/>
            <TextBlock x:Name="Title" Text="CLAUDE USAGE" FontFamily="Segoe UI" FontSize="9.5"
                       FontWeight="Bold" VerticalAlignment="Center" Foreground="#FFE08A64"/>
          </StackPanel>
          <TextBlock x:Name="Stamp" HorizontalAlignment="Right" FontFamily="Segoe UI"
                     FontSize="9.5" VerticalAlignment="Center" Foreground="#FF6E7684" Text="--:--"/>
        </Grid>

        <Grid Margin="0,0,0,5">
          <TextBlock x:Name="LblFh" Text="Session" FontFamily="Segoe UI" FontSize="11"
                     VerticalAlignment="Bottom" Foreground="#FF9BA3B1"/>
          <TextBlock x:Name="FhPct" HorizontalAlignment="Right" FontFamily="Segoe UI"
                     FontSize="15" FontWeight="SemiBold" Foreground="#FFF6F7F9" Text="--"/>
        </Grid>
        <Border x:Name="FhTrack" Height="8" CornerRadius="4" Background="#FF2E3440">
          <Border x:Name="FhBar" HorizontalAlignment="Left" Width="0" CornerRadius="4"/>
        </Border>
        <TextBlock x:Name="FhReset" FontFamily="Segoe UI" FontSize="9.5"
                   Foreground="#FF6E7684" Margin="0,4,0,0" Text=""/>

        <Grid Margin="0,13,0,5">
          <TextBlock x:Name="LblWk" Text="Weekly" FontFamily="Segoe UI" FontSize="11"
                     VerticalAlignment="Bottom" Foreground="#FF9BA3B1"/>
          <TextBlock x:Name="WkPct" HorizontalAlignment="Right" FontFamily="Segoe UI"
                     FontSize="15" FontWeight="SemiBold" Foreground="#FFF6F7F9" Text="--"/>
        </Grid>
        <Border x:Name="WkTrack" Height="8" CornerRadius="4" Background="#FF2E3440">
          <Border x:Name="WkBar" HorizontalAlignment="Left" Width="0" CornerRadius="4"/>
        </Border>
        <TextBlock x:Name="WkReset" FontFamily="Segoe UI" FontSize="9.5"
                   Foreground="#FF6E7684" Margin="0,4,0,0" Text=""/>

        <!-- Tokens: header click toggles the breakdown. Rows are built in code. -->
        <StackPanel x:Name="TokBlock" Margin="0,13,0,0">
          <Grid x:Name="TokHdr" Background="Transparent" Cursor="Hand" Margin="0,0,0,3">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="Auto"/>
              <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <TextBlock x:Name="LblTok" Text="Tokens - session" FontFamily="Segoe UI" FontSize="11"
                       VerticalAlignment="Bottom" Foreground="#FF9BA3B1"/>
            <TextBlock x:Name="TokVal" Grid.Column="1" FontFamily="Segoe UI" FontSize="15"
                       FontWeight="SemiBold" Foreground="#FFF6F7F9" Text="--"/>
            <TextBlock x:Name="TokChev" Grid.Column="2" FontFamily="Consolas" FontSize="11"
                       Margin="7,0,0,3" VerticalAlignment="Bottom" Foreground="#FF6E7684" Text="&gt;"/>
          </Grid>
          <TextBlock x:Name="TokSub" FontFamily="Segoe UI" FontSize="9.5" Foreground="#FF6E7684"
                     TextTrimming="CharacterEllipsis" Text="scanning..."/>
          <ScrollViewer x:Name="TokScroll" MaxHeight="260" Margin="0,7,0,0" Visibility="Collapsed"
                        VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
            <StackPanel x:Name="TokList"/>
          </ScrollViewer>
        </StackPanel>

        <StackPanel x:Name="Detail">
          <StackPanel x:Name="OpusRow" Visibility="Collapsed" Margin="0,13,0,0">
            <Grid Margin="0,0,0,4">
              <TextBlock x:Name="LblOp" Text="Weekly - Opus" FontFamily="Segoe UI" FontSize="10"
                         Foreground="#FF9BA3B1"/>
              <TextBlock x:Name="OpPct" HorizontalAlignment="Right" FontFamily="Segoe UI"
                         FontSize="11.5" FontWeight="SemiBold" Foreground="#FFF6F7F9" Text="--"/>
            </Grid>
            <Border x:Name="OpTrack" Height="5" CornerRadius="3" Background="#FF2E3440">
              <Border x:Name="OpBar" HorizontalAlignment="Left" Width="0" CornerRadius="3"/>
            </Border>
          </StackPanel>

          <StackPanel x:Name="SonRow" Visibility="Collapsed" Margin="0,10,0,0">
            <Grid Margin="0,0,0,4">
              <TextBlock x:Name="LblSo" Text="Weekly - Sonnet" FontFamily="Segoe UI" FontSize="10"
                         Foreground="#FF9BA3B1"/>
              <TextBlock x:Name="SoPct" HorizontalAlignment="Right" FontFamily="Segoe UI"
                         FontSize="11.5" FontWeight="SemiBold" Foreground="#FFF6F7F9" Text="--"/>
            </Grid>
            <Border x:Name="SoTrack" Height="5" CornerRadius="3" Background="#FF2E3440">
              <Border x:Name="SoBar" HorizontalAlignment="Left" Width="0" CornerRadius="3"/>
            </Border>
          </StackPanel>

          <Grid x:Name="ExtraRow" Visibility="Collapsed" Margin="0,13,0,0">
            <TextBlock x:Name="LblEx" Text="Extra credits" FontFamily="Segoe UI" FontSize="10"
                       Foreground="#FF9BA3B1"/>
            <TextBlock x:Name="ExTxt" HorizontalAlignment="Right" FontFamily="Segoe UI"
                       FontSize="10" Foreground="#FF9BA3B1" Text=""/>
          </Grid>
        </StackPanel>

        <TextBlock x:Name="Err" Visibility="Collapsed" FontFamily="Segoe UI" FontSize="10"
                   TextWrapping="Wrap" Margin="0,11,0,0" Foreground="#FFEF4444" Text=""/>
      </StackPanel>
    </Grid>
  </Border>
</Window>
'@

try {
    $reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
    $win    = [Windows.Markup.XamlReader]::Load($reader)
    Write-Log 'xaml loaded'
} catch { Die 'XAML load' $_ }

$ui = @{}
try {
    'Root','Gloss','Dot','Title','Stamp',
    'LblFh','FhPct','FhTrack','FhBar','FhReset',
    'LblWk','WkPct','WkTrack','WkBar','WkReset',
    'TokBlock','TokHdr','LblTok','TokVal','TokChev','TokSub','TokScroll','TokList',
    'Detail','OpusRow','LblOp','OpPct','OpTrack','OpBar',
    'SonRow','LblSo','SoPct','SoTrack','SoBar',
    'ExtraRow','LblEx','ExTxt','Err' |
        ForEach-Object {
            $el = $win.FindName($_)
            if ($null -eq $el) { throw "named element '$_' not found in XAML" }
            $ui[$_] = $el
        }
    Write-Log 'elements bound'
} catch { Die 'element binding' $_ }

# ---------------------------------------------------------------- config

function Test-Num($v) {
    if ($null -eq $v) { return $false }
    try { $d = [double]$v } catch { return $false }
    -not ([double]::IsNaN($d) -or [double]::IsInfinity($d))
}

function Load-Cfg {
    if (-not (Test-Path $script:CfgPath)) { Write-Log 'no config yet'; return }
    try {
        $j = Get-Content -LiteralPath $script:CfgPath -Raw | ConvertFrom-Json
        foreach ($k in @($script:Cfg.Keys)) { if ($null -ne $j.$k) { $script:Cfg[$k] = $j.$k } }
        if (-not (Test-Num $script:Cfg.Left) -or -not (Test-Num $script:Cfg.Top)) {
            Write-Log 'config position not numeric; ignoring'
            $script:Cfg.Left = $null; $script:Cfg.Top = $null
        }
        if (-not $script:Skins.Contains([string]$script:Cfg.Skin)) {
            Write-Log "unknown skin '$($script:Cfg.Skin)'; using Clay"
            $script:Cfg.Skin = 'Clay'
        }
        if ($script:TokWindows -notcontains [string]$script:Cfg.TokenWindow) {
            Write-Log "unknown token window '$($script:Cfg.TokenWindow)'; using Session"
            $script:Cfg.TokenWindow = 'Session'
        }
        $script:Cfg.TokExpanded = [bool]$script:Cfg.TokExpanded
        Write-Log "config loaded (skin=$($script:Cfg.Skin))"
    } catch { Write-Log "config load failed: $($_.Exception.Message)" }
}

function Save-Cfg {
    try {
        if ((Test-Num $win.Left) -and (Test-Num $win.Top)) {
            $script:Cfg.Left = [double]$win.Left
            $script:Cfg.Top  = [double]$win.Top
        }
        [pscustomobject]$script:Cfg | ConvertTo-Json |
            Set-Content -LiteralPath $script:CfgPath -Encoding UTF8
    } catch { Write-Log "config save failed: $($_.Exception.Message)" }
}

# ---------------------------------------------------------------- theming

function Get-Skin {
    $s = $script:Skins[[string]$script:Cfg.Skin]
    if (-not $s) { $s = $script:Skins['Clay'] }
    $s
}

function Apply-Skin {
    try {
        $s = Get-Skin

        $g = New-Object Windows.Media.LinearGradientBrush
        $g.StartPoint = New-Object Windows.Point 0, 0
        $g.EndPoint   = New-Object Windows.Point 0.6, 1
        $g.GradientStops.Add((New-Object Windows.Media.GradientStop (
            [Windows.Media.Color](New-Color $s.BgA), [double]0)))
        $g.GradientStops.Add((New-Object Windows.Media.GradientStop (
            [Windows.Media.Color](New-Color $s.BgB), [double]1)))
        $g.Freeze()

        $shadow = New-Object Windows.Media.Effects.DropShadowEffect
        $shadow.Color = [Windows.Media.Color](New-Color '#FF000000')
        $shadow.BlurRadius = 22; $shadow.ShadowDepth = 5; $shadow.Direction = 270
        $shadow.Opacity = [double]$s.Shadow

        $ui.Root.Background  = $g
        $ui.Root.BorderBrush = New-Brush $s.Border
        $ui.Root.Effect      = $shadow
        $ui.Gloss.Background = New-Brush $s.Gloss
        $ui.Dot.Fill         = New-Brush $s.Dot
        $ui.Title.Foreground = New-Brush $s.Accent
        $ui.Err.Foreground   = New-Brush ($s.Crit[1])

        foreach ($n in 'Stamp','FhReset','WkReset','TokChev','TokSub') { $ui[$n].Foreground = New-Brush $s.Sub }
        foreach ($n in 'LblFh','LblWk','LblOp','LblSo','LblEx','ExTxt','LblTok') {
            $ui[$n].Foreground = New-Brush $s.Label
        }
        foreach ($n in 'FhPct','WkPct','OpPct','SoPct','TokVal') { $ui[$n].Foreground = New-Brush $s.Val }
        foreach ($n in 'FhTrack','WkTrack','OpTrack','SoTrack') {
            $ui[$n].Background = New-Brush $s.Track
        }

        Repaint-Bars
        Render-Tokens
        Write-Log "skin applied: $($script:Cfg.Skin)"
    } catch { Write-Log "APPLY-SKIN failed: $($_.Exception.Message)" }
}

# ---------------------------------------------------------------- data

function Get-Token {
    if (-not (Test-Path $script:CredPath)) {
        throw "No credentials file. Run 'claude' once and log in."
    }
    $c = Get-Content -LiteralPath $script:CredPath -Raw | ConvertFrom-Json
    if (-not $c.claudeAiOauth -or -not $c.claudeAiOauth.accessToken) {
        throw 'API-key mode - no subscription usage windows.'
    }
    $exp = [double]$c.claudeAiOauth.expiresAt
    if ($exp -gt 0) {
        $ms = if ($exp -ge 1e11) { $exp } else { $exp * 1000 }   # file may hold s or ms
        if ([DateTimeOffset]::FromUnixTimeMilliseconds([long]$ms) -lt
            [DateTimeOffset]::UtcNow.AddSeconds(30)) {
            throw "Token expired. Run 'claude' to refresh it."
        }
    }
    $c.claudeAiOauth.accessToken
}

function Get-Usage {
    Invoke-RestMethod -Uri 'https://api.anthropic.com/api/oauth/usage' -Method Get `
        -Headers @{ Authorization = "Bearer $(Get-Token)"; 'anthropic-beta' = 'oauth-2025-04-20' } `
        -UserAgent 'claude-code/2.0.31' -TimeoutSec 20
}

# ---------------------------------------------------------------- paint

function Get-Ramp([double]$p) {
    $s = Get-Skin
    if ($p -ge 85) { $s.Crit } elseif ($p -ge 60) { $s.Warn } else { $s.Ok }
}

function New-BarBrush($ramp) {
    $b = New-Object Windows.Media.LinearGradientBrush
    $b.StartPoint = New-Object Windows.Point 0, 0
    $b.EndPoint   = New-Object Windows.Point 1, 0
    $b.GradientStops.Add((New-Object Windows.Media.GradientStop (
        [Windows.Media.Color](New-Color $ramp[0]), [double]0)))
    $b.GradientStops.Add((New-Object Windows.Media.GradientStop (
        [Windows.Media.Color](New-Color $ramp[1]), [double]1)))
    $b.Freeze(); $b
}

# Track width is measured live; caching it at startup returned 0 and pinned
# every bar to the minimum sliver regardless of the real percentage.
function Paint-Bar($bar, $track, [double]$pct, [bool]$animate = $true) {
    try {
        $w = 0.0
        if ($track) { $w = [double]$track.ActualWidth }
        if (-not (Test-Num $w) -or $w -le 1) { $w = 278 - 30 - 28 }  # window - margin - padding

        $ramp = Get-Ramp $pct
        $bar.Background = New-BarBrush $ramp

        $glow = New-Object Windows.Media.Effects.DropShadowEffect
        $glow.Color = [Windows.Media.Color](New-Color ($ramp[1]))
        $glow.BlurRadius = 10; $glow.ShadowDepth = 0; $glow.Opacity = 0.75
        $bar.Effect = $glow

        $target = [Math]::Min(1.0, [Math]::Max(0.0, $pct / 100.0)) * $w
        if ($pct -gt 0 -and $target -lt 3) { $target = 3 }

        if ($animate) {
            $a = New-Object Windows.Media.Animation.DoubleAnimation
            $a.To = $target
            $a.Duration = New-Object Windows.Duration ([TimeSpan]::FromMilliseconds(700))
            $ease = New-Object Windows.Media.Animation.CubicEase
            $ease.EasingMode = 'EaseOut'
            $a.EasingFunction = $ease
            $bar.BeginAnimation([Windows.FrameworkElement]::WidthProperty, $a)
        } else {
            $bar.BeginAnimation([Windows.FrameworkElement]::WidthProperty, $null)
            $bar.Width = $target
        }
    } catch { Write-Log "PAINT-BAR failed: $($_.Exception.Message)" }
}

function Repaint-Bars {
    foreach ($p in @(
        @{ Bar=$ui.FhBar; Track=$ui.FhTrack; Key='FiveHour' },
        @{ Bar=$ui.WkBar; Track=$ui.WkTrack; Key='Weekly' },
        @{ Bar=$ui.OpBar; Track=$ui.OpTrack; Key='Opus' },
        @{ Bar=$ui.SoBar; Track=$ui.SoTrack; Key='Sonnet' })) {
        $b = $script:Buckets[$p.Key]
        if ($b) { Paint-Bar $p.Bar $p.Track ([double]$b.utilization) $false }
    }
}

function Format-Reset($iso) {
    if (-not $iso) { return '' }
    try {
        $d = ([DateTimeOffset]$iso).ToLocalTime() - [DateTimeOffset]::Now
        if ($d.TotalSeconds -le 0) { return 'resetting...' }
        if ($d.TotalHours -lt 1)  { return ('resets in {0}m {1}s' -f $d.Minutes, $d.Seconds) }
        if ($d.TotalHours -lt 24) { return ('resets in {0}h {1}m' -f $d.Hours, $d.Minutes) }
        'resets {0}' -f ([DateTimeOffset]$iso).ToLocalTime().ToString('ddd h:mm tt')
    } catch { '' }
}

function Set-Bucket($b, $pctBlock, $bar, $track) {
    if ($null -eq $b) { $pctBlock.Text = 'n/a'; Paint-Bar $bar $track 0; return }
    $p = [double]$b.utilization
    $pctBlock.Text = '{0:0}%' -f $p
    Paint-Bar $bar $track $p
}

# ---------------------------------------------------------------- tokens paint

$script:TokFont = New-Object Windows.Media.FontFamily 'Segoe UI'

# One breakdown row: label (trimmed with ...) on the left, value on the right.
# Brushes come straight from the skin, like everything else (no resources).
function New-TokRow([string]$label, [string]$value, [bool]$child, [bool]$indent) {
    $s = Get-Skin
    $g = New-Object Windows.Controls.Grid
    $g.Margin = New-Object Windows.Thickness 0, 1, 0, 1
    $g.ColumnDefinitions.Add((New-Object Windows.Controls.ColumnDefinition))
    $c2 = New-Object Windows.Controls.ColumnDefinition
    $c2.Width = [Windows.GridLength]::Auto
    $g.ColumnDefinitions.Add($c2)

    $size = if ($child) { 9.5 } else { 10.5 }
    $l = New-Object Windows.Controls.TextBlock
    $l.Text = $label; $l.FontFamily = $script:TokFont; $l.FontSize = $size
    $l.TextTrimming = [Windows.TextTrimming]::CharacterEllipsis
    $l.Margin = New-Object Windows.Thickness ($(if ($indent) { 11 } else { 0 })), 0, 8, 0
    $l.Foreground = New-Brush ($(if ($child) { $s.Sub } else { $s.Label }))

    $v = New-Object Windows.Controls.TextBlock
    $v.Text = $value; $v.FontFamily = $script:TokFont; $v.FontSize = $size
    $v.Foreground = New-Brush ($(if ($child) { $s.Sub } else { $s.Val }))
    if (-not $child) { $v.FontWeight = [Windows.FontWeights]::SemiBold }
    [Windows.Controls.Grid]::SetColumn($v, 1)

    $g.Children.Add($l) | Out-Null
    $g.Children.Add($v) | Out-Null
    $ui.TokList.Children.Add($g) | Out-Null
}

function Sum-Work($items) {
    $t = [long]0
    foreach ($i in $items) { $t += [long]$i.Work }
    $t
}

function Render-Tokens {
    try {
        $sc = $script:Scanner
        $open = [bool]$script:Cfg.TokExpanded
        $name = @{ Session = 'session'; Today = 'today'; Week = 'week' }[[string]$script:Cfg.TokenWindow]
        $ui.LblTok.Text = "Tokens - $name"
        $ui.TokChev.Text = if ($open) { 'v' } else { '>' }
        $ui.TokScroll.Visibility = if ($open) { 'Visible' } else { 'Collapsed' }
        $ui.TokList.Children.Clear()
        $script:TokRendered = $sc.Generation

        if ($sc.Generation -eq 0) { $ui.TokVal.Text = '--'; $ui.TokSub.Text = 'scanning...'; return }
        if ($sc.Missing) { $ui.TokVal.Text = '--'; $ui.TokSub.Text = 'no Claude Code logs found'; return }

        $sum = $sc.Summarize((Get-TokStart))
        $ui.TokVal.Text = Format-Tok $sum.Work
        $ui.TokSub.Text = if ($sum.Work -eq 0 -and $sum.CacheRead -eq 0) {
            'no Claude Code activity in window'
        } else {
            'out {0} | in {1} | +{2} cache' -f (Format-Tok $sum.Out), (Format-Tok $sum.In), (Format-Tok $sum.CacheRead)
        }
        if (-not $open) { return }

        $sessions = @($sum.Sessions)
        if ($sessions.Count -eq 0) { $ui.TokScroll.Visibility = 'Collapsed'; return }
        foreach ($ss in ($sessions | Select-Object -First 5)) {
            New-TokRow $ss.Label (Format-Tok $ss.Work) $false $false
            $kids = @($ss.Children)
            # a main-only session gets no children - its row already is "main"
            if (-not ($kids | Where-Object { -not $_.IsMain })) { continue }
            $show = if ($kids.Count -gt 3) { $kids[0..1] } else { $kids }
            foreach ($k in $show) {
                $lbl = if ($k.IsMain) { 'main' } else { ('{0}  {1}' -f $k.Kind, $k.Desc).Trim() }
                New-TokRow $lbl (Format-Tok $k.Work) $true $true
            }
            if ($kids.Count -gt 3) {
                $rest = $kids[2..($kids.Count - 1)]
                New-TokRow ('+{0} more agents' -f $rest.Count) (Format-Tok (Sum-Work $rest)) $true $true
            }
        }
        if ($sessions.Count -gt 5) {
            $rest = $sessions[5..($sessions.Count - 1)]
            New-TokRow ('+{0} more sessions' -f $rest.Count) (Format-Tok (Sum-Work $rest)) $true $false
        }
    } catch { Write-Log "tokens render failed: $($_.Exception.Message)" }
}

# Called every second by the countdown ticker; renders as soon as a scan lands.
function Check-Tokens {
    try {
        $sc = $script:Scanner
        if ($sc.Generation -eq $script:TokRendered) { return }
        if ($sc.LastNewRecs -gt 0) {
            Write-Log ('tokens: {0} files, {1} recs, {2} ms' -f $sc.LastFiles, $sc.RecordCount, $sc.LastMs)
        }
        $e = $sc.LastError
        if ($e -and $e -ne $script:TokLastErr) { Write-Log "tokens scan error: $e" }
        $script:TokLastErr = $e
        Render-Tokens
    } catch { Write-Log "tokens check failed: $($_.Exception.Message)" }
}

# ---------------------------------------------------------------- tray

function New-GaugeIcon([double]$pct) {
    $ramp = Get-Ramp $pct
    $bmp  = New-Object System.Drawing.Bitmap 32, 32
    $g    = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.Clear([System.Drawing.Color]::Transparent)

    $tp = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(230, 52, 58, 70)), 5
    $g.DrawEllipse($tp, 4, 4, 24, 24)

    $rgb = '#' + $ramp[1].Substring(3)     # skin colors are #AARRGGBB, GDI+ wants #RRGGBB
    $pen = New-Object System.Drawing.Pen ([System.Drawing.ColorTranslator]::FromHtml($rgb)), 5
    $pen.StartCap = 'Round'; $pen.EndCap = 'Round'
    $g.DrawArc($pen, 4, 4, 24, 24, -90, [Math]::Max(8, [Math]::Min(359, $pct * 3.6)))

    $tp.Dispose(); $pen.Dispose(); $g.Dispose()
    $h = $bmp.GetHicon()
    $ico = [System.Drawing.Icon]::FromHandle($h).Clone()
    [W32]::DestroyIcon($h) | Out-Null
    $bmp.Dispose()
    $ico
}

function Update-Tray([double]$pct, [string]$tip) {
    if (-not $script:TrayIcon) { return }
    try {
        $old = $script:TrayIcon.Icon
        $script:TrayIcon.Icon = New-GaugeIcon $pct
        if ($old) { $old.Dispose() }
        $script:TrayIcon.Text = $tip.Substring(0, [Math]::Min(62, $tip.Length))
    } catch { Write-Log "tray update failed: $($_.Exception.Message)" }
}

# ---------------------------------------------------------------- refresh

function Update-Widget {
    if ($script:Busy) { return }
    $script:Busy = $true
    $ui.Dot.Opacity = 0.3
    try {
        $u = Get-Usage
        $ui.Err.Visibility = 'Collapsed'

        $script:Buckets = @{
            FiveHour = $u.five_hour; Weekly = $u.seven_day
            Opus = $u.seven_day_opus; Sonnet = $u.seven_day_sonnet
        }

        Set-Bucket $u.five_hour $ui.FhPct $ui.FhBar $ui.FhTrack
        Set-Bucket $u.seven_day $ui.WkPct $ui.WkBar $ui.WkTrack

        if ($u.seven_day_opus) {
            Set-Bucket $u.seven_day_opus $ui.OpPct $ui.OpBar $ui.OpTrack
            $ui.OpusRow.Visibility = 'Visible'
        } else { $ui.OpusRow.Visibility = 'Collapsed' }

        if ($u.seven_day_sonnet) {
            Set-Bucket $u.seven_day_sonnet $ui.SoPct $ui.SoBar $ui.SoTrack
            $ui.SonRow.Visibility = 'Visible'
        } else { $ui.SonRow.Visibility = 'Collapsed' }

        if ($u.extra_usage -and $u.extra_usage.is_enabled) {
            $ui.ExTxt.Text = '${0:0.00} / ${1:0}' -f `
                [double]$u.extra_usage.used_credits, [double]$u.extra_usage.monthly_limit
            $ui.ExtraRow.Visibility = 'Visible'
        } else { $ui.ExtraRow.Visibility = 'Collapsed' }

        Tick-Countdown
        Render-Tokens      # session / week start may have moved with new resets_at

        $fh =if ($u.five_hour) { [double]$u.five_hour.utilization } else { 0 }
        $wk = if ($u.seven_day) { [double]$u.seven_day.utilization } else { 0 }
        Update-Tray $fh ('Session {0:0}%  |  Weekly {1:0}%' -f $fh, $wk)
        Check-Alert 'Session' $fh
        Check-Alert 'Weekly'  $wk

        $ui.Stamp.Text = (Get-Date).ToString('h:mm tt').ToLower()
        Write-Log ('refresh ok: session {0:0}% weekly {1:0}%' -f $fh, $wk)
    }
    catch {
        $msg = $_.Exception.Message
        if ($_.Exception.Response -and $_.Exception.Response.StatusCode.value__ -eq 429) {
            $msg = 'Rate limited - backing off until next poll.'
        }
        $ui.Err.Text = $msg
        $ui.Err.Visibility = 'Visible'
        $ui.Stamp.Text = (Get-Date).ToString('h:mm tt').ToLower()
        Write-Log "refresh failed: $msg"
    }
    finally {
        $ui.Dot.Opacity = 1
        $script:Busy = $false
    }
}

function Check-Alert([string]$name, [double]$pct) {
    $limit = [double]$script:Cfg.AlertAt
    $was   = [double]($script:LastAlert[$name])
    $script:LastAlert[$name] = $pct
    if ($pct -ge $limit -and $was -lt $limit -and $script:TrayIcon) {
        try {
            $script:TrayIcon.ShowBalloonTip(6000, 'Claude usage',
                ('{0} window at {1:0}%' -f $name, $pct),
                [System.Windows.Forms.ToolTipIcon]::Warning)
        } catch { }
    }
}

function Tick-Countdown {
    try {
        $f = $script:Buckets['FiveHour']; $w = $script:Buckets['Weekly']
        $ui.FhReset.Text = if ($f) { Format-Reset $f.resets_at } else { '' }
        $ui.WkReset.Text = if ($w) { Format-Reset $w.resets_at } else { '' }
        foreach ($b in @($f, $w)) {
            if ($b -and $b.resets_at -and ([DateTimeOffset]$b.resets_at) -lt [DateTimeOffset]::UtcNow) {
                Update-Widget; break
            }
        }
    } catch { Write-Log "ticker failed: $($_.Exception.Message)" }
}

# ---------------------------------------------------------------- layout

# Exact check against real monitor working areas. The virtual-screen bounding
# box is not enough: an L-shaped arrangement leaves dead rectangles inside it,
# and a window parked there is running, on no monitor, invisible.
function Test-OnScreen([double]$l, [double]$t) {
    try {
        foreach ($sc in [System.Windows.Forms.Screen]::AllScreens) {
            $wa = $sc.WorkingArea
            if ($l -ge ($wa.Left - 40) -and $l -le ($wa.Right - 80) -and
                $t -ge ($wa.Top - 10)  -and $t -le ($wa.Bottom - 40)) { return $true }
        }
    } catch { return $true }
    $false
}

function Snap-Corner([string]$corner) {
    $wa = [Windows.SystemParameters]::WorkArea
    $m = 2
    switch ($corner) {
        'TL' { $win.Left = $wa.Left + $m; $win.Top = $wa.Top + $m }
        'TR' { $win.Left = $wa.Right - $win.ActualWidth - $m; $win.Top = $wa.Top + $m }
        'BL' { $win.Left = $wa.Left + $m; $win.Top = $wa.Bottom - $win.ActualHeight - $m }
        'BR' { $win.Left = $wa.Right - $win.ActualWidth - $m
               $win.Top = $wa.Bottom - $win.ActualHeight - $m }
    }
}

function Apply-Cfg {
    $win.Topmost = [bool]$script:Cfg.Topmost
    $ui.Root.Opacity = [double]$script:Cfg.Opacity
    $v = if ($script:Cfg.Compact) { 'Collapsed' } else { 'Visible' }
    $ui.Detail.Visibility = $v
    $ui.TokBlock.Visibility = $v
    $ui.FhReset.Visibility = $v
    $ui.WkReset.Visibility = $v
}

# ---------------------------------------------------------------- menu

function New-MenuItem([string]$header, [scriptblock]$action, [bool]$checkable = $false, [bool]$checked = $false) {
    $mi = New-Object Windows.Controls.MenuItem
    $mi.Header = $header; $mi.IsCheckable = $checkable; $mi.IsChecked = $checked
    if ($action) { $mi.Add_Click($action) }
    $mi
}

try {
$menu = New-Object Windows.Controls.ContextMenu
$menu.Items.Add((New-MenuItem 'Refresh now' { Update-Widget })) | Out-Null

$mSkin = New-MenuItem 'Skin'
foreach ($name in $script:Skins.Keys) {
    $mi = New-MenuItem $name $null $true ($script:Cfg.Skin -eq $name)
    $mi.Tag = $name
    $mi.Add_Click({
        param($s, $e)
        $script:Cfg.Skin = [string]$s.Tag
        Apply-Skin
        foreach ($x in $mSkin.Items) { $x.IsChecked = ($x.Tag -eq $s.Tag) }
        Save-Cfg
    })
    $mSkin.Items.Add($mi) | Out-Null
}
$menu.Items.Add($mSkin) | Out-Null

$miCompact = New-MenuItem 'Compact mode' $null $true ([bool]$script:Cfg.Compact)
$miCompact.Add_Click({ $script:Cfg.Compact = $miCompact.IsChecked; Apply-Cfg; Save-Cfg })
$menu.Items.Add($miCompact) | Out-Null

$miTop = New-MenuItem 'Always on top' $null $true ([bool]$script:Cfg.Topmost)
$miTop.Add_Click({ $script:Cfg.Topmost = $miTop.IsChecked; Apply-Cfg; Save-Cfg })
$menu.Items.Add($miTop) | Out-Null

$menu.Items.Add((New-Object Windows.Controls.Separator)) | Out-Null

$mInt = New-MenuItem 'Poll every'
foreach ($n in 1, 5, 10, 15, 30, 60) {
    $mi = New-MenuItem "$n minutes" $null $true ($script:Cfg.Interval -eq $n)
    $mi.Tag = $n
    $mi.Add_Click({
        param($s, $e)
        $script:Cfg.Interval = [int]$s.Tag
        $script:Timer.Interval = [TimeSpan]::FromMinutes($script:Cfg.Interval)
        foreach ($x in $mInt.Items) { $x.IsChecked = ($x.Tag -eq $s.Tag) }
        Save-Cfg
    })
    $mInt.Items.Add($mi) | Out-Null
}
$menu.Items.Add($mInt) | Out-Null

$mTok = New-MenuItem 'Token window'
foreach ($pair in @(@('Current session (5h)','Session'), @('Today','Today'), @('This week','Week'))) {
    $mi = New-MenuItem $pair[0] $null $true
    $mi.Tag = $pair[1]
    $mi.Add_Click({
        param($s, $e)
        $script:Cfg.TokenWindow = [string]$s.Tag
        foreach ($x in $mTok.Items) { $x.IsChecked = ($x.Tag -eq $s.Tag) }
        Render-Tokens
        Save-Cfg
    })
    $mTok.Items.Add($mi) | Out-Null
}
$menu.Items.Add($mTok) | Out-Null

$mOp = New-MenuItem 'Opacity'
foreach ($o in 1.0, 0.9, 0.75, 0.6) {
    $mi = New-MenuItem ('{0:P0}' -f $o) $null $true ([Math]::Abs($script:Cfg.Opacity - $o) -lt 0.01)
    $mi.Tag = $o
    $mi.Add_Click({
        param($s, $e)
        $script:Cfg.Opacity = [double]$s.Tag; Apply-Cfg
        foreach ($x in $mOp.Items) { $x.IsChecked = ($x.Tag -eq $s.Tag) }
        Save-Cfg
    })
    $mOp.Items.Add($mi) | Out-Null
}
$menu.Items.Add($mOp) | Out-Null

$mSnap = New-MenuItem 'Snap to'
foreach ($pair in @(@('Top left','TL'), @('Top right','TR'), @('Bottom left','BL'), @('Bottom right','BR'))) {
    $mi = New-MenuItem $pair[0]
    $mi.Tag = $pair[1]
    $mi.Add_Click({ param($s, $e) Snap-Corner ([string]$s.Tag); Save-Cfg })
    $mSnap.Items.Add($mi) | Out-Null
}
$menu.Items.Add($mSnap) | Out-Null

$startupOn = $null -ne (Get-ItemProperty -Path $script:RunKey -Name $script:RunName -EA SilentlyContinue)
$miStart = New-MenuItem 'Start with Windows' $null $true $startupOn
$miStart.Add_Click({
    try {
        if ($miStart.IsChecked) {
            $vbs = Join-Path $script:ScriptDir 'Start Claude Usage Widget.vbs'
            Set-ItemProperty -Path $script:RunKey -Name $script:RunName -Value "wscript.exe `"$vbs`""
        } else {
            Remove-ItemProperty -Path $script:RunKey -Name $script:RunName -EA SilentlyContinue
        }
    } catch { Write-Log "startup toggle failed: $($_.Exception.Message)" }
})
$menu.Items.Add($miStart) | Out-Null

$menu.Items.Add((New-MenuItem 'Open log' {
    try { Start-Process notepad.exe $script:LogPath } catch { }
})) | Out-Null

$menu.Items.Add((New-Object Windows.Controls.Separator)) | Out-Null
$menu.Items.Add((New-MenuItem 'Hide to tray' { $win.Hide() })) | Out-Null
$menu.Items.Add((New-MenuItem 'Exit' { $win.Close() })) | Out-Null
$win.ContextMenu = $menu
Write-Log 'menu built'
} catch { Die 'menu construction' $_ }

# The menu is built before Load-Cfg runs (SourceInitialized), so checks set at
# build time never reflected the saved config. Re-sync after loading.
function Sync-MenuChecks {
    foreach ($x in $mSkin.Items) { $x.IsChecked = ([string]$x.Tag -eq [string]$script:Cfg.Skin) }
    foreach ($x in $mInt.Items)  { $x.IsChecked = ([int]$x.Tag -eq [int]$script:Cfg.Interval) }
    foreach ($x in $mOp.Items)   {
        $x.IsChecked = ([Math]::Abs([double]$x.Tag - [double]$script:Cfg.Opacity) -lt 0.01)
    }
    foreach ($x in $mTok.Items)  { $x.IsChecked = ([string]$x.Tag -eq [string]$script:Cfg.TokenWindow) }
    $miCompact.IsChecked = [bool]$script:Cfg.Compact
    $miTop.IsChecked     = [bool]$script:Cfg.Topmost
}

# ---------------------------------------------------------------- tray icon

try {
    $script:TrayIcon = New-Object System.Windows.Forms.NotifyIcon
    $script:TrayIcon.Icon = New-GaugeIcon 0
    $script:TrayIcon.Text = 'Claude Usage'
    $script:TrayIcon.Visible = $true

    $cms = New-Object System.Windows.Forms.ContextMenuStrip
    $cms.Items.Add('Show / hide').Add_Click({
        if ($win.IsVisible) { $win.Hide() } else { $win.Show(); $win.Activate() }
    })
    $cms.Items.Add('Bring to corner').Add_Click({
        $win.Dispatcher.Invoke([action]{ $win.Show(); Snap-Corner 'TR'; $win.Activate(); Save-Cfg })
    })
    $cms.Items.Add('Refresh now').Add_Click({ $win.Dispatcher.Invoke([action]{ Update-Widget }) })
    $cms.Items.Add('-') | Out-Null
    $cms.Items.Add('Exit').Add_Click({ $win.Dispatcher.Invoke([action]{ $win.Close() }) })
    $script:TrayIcon.ContextMenuStrip = $cms

    $script:TrayIcon.Add_DoubleClick({
        if ($win.IsVisible) { $win.Hide() } else { $win.Show(); $win.Activate() }
    })
    Write-Log 'tray ready'
} catch {
    $script:TrayIcon = $null
    Write-Log "tray setup failed: $($_.Exception.Message)"
}

# ---------------------------------------------------------------- wiring

# A throw inside a WPF handler would otherwise take the dispatcher down.
# Write-Log is rate-limited per message, so a repeating fault cannot spin
# the CPU writing a multi-megabyte log the way the resource-cast bug did.
$win.Dispatcher.Add_UnhandledException({
    param($s, $e)
    Write-Log "DISPATCHER: $($e.Exception.GetType().Name): $($e.Exception.Message)"
    $e.Handled = $true
})

$win.Add_MouseLeftButtonDown({
    param($s, $e)
    if ($e.ClickCount -eq 2) { Update-Widget } else { $win.DragMove() }
})
# Handled, so the header click neither starts DragMove nor feeds the
# window's double-click refresh.
$ui.TokHdr.Add_MouseLeftButtonDown({
    param($s, $e)
    $e.Handled = $true
    $script:Cfg.TokExpanded = -not [bool]$script:Cfg.TokExpanded
    Render-Tokens
    Save-Cfg
})
$win.Add_MouseEnter({ $ui.Root.Opacity = 1.0 })
$win.Add_MouseLeave({ $ui.Root.Opacity = [double]$script:Cfg.Opacity })

$script:Timer = New-Object Windows.Threading.DispatcherTimer
$script:Timer.Add_Tick({ Update-Widget })

$script:Ticker = New-Object Windows.Threading.DispatcherTimer
$script:Ticker.Interval = [TimeSpan]::FromSeconds(1)
$script:Ticker.Add_Tick({ Tick-Countdown; Check-Tokens })

# Local file reads only - no network, so it can run far more often than the poll.
$script:TokTimer = New-Object Windows.Threading.DispatcherTimer
$script:TokTimer.Interval = [TimeSpan]::FromSeconds(30)
$script:TokTimer.Add_Tick({ $script:Scanner.ScanAsync() })

$win.Add_SourceInitialized({
    Load-Cfg
    Apply-Skin
    Apply-Cfg

    try {
        $mons = ([System.Windows.Forms.Screen]::AllScreens | ForEach-Object {
            $_.WorkingArea.ToString() }) -join ' | '
        Write-Log "monitors: $mons"
    } catch { }

    $placed = $false
    if ((Test-Num $script:Cfg.Left) -and (Test-Num $script:Cfg.Top)) {
        $l = [double]$script:Cfg.Left; $t = [double]$script:Cfg.Top
        if (Test-OnScreen $l $t) { $win.Left = $l; $win.Top = $t; $placed = $true }
        else { Write-Log "saved position $l,$t is on no monitor; using default corner" }
    }
    if (-not $placed) {
        $wa = [Windows.SystemParameters]::WorkArea
        $win.Left = $wa.Right - 278 - 2; $win.Top = $wa.Top + 2
    }
    Write-Log ("positioned at {0},{1}" -f $win.Left, $win.Top)

    Sync-MenuChecks
})

$win.Add_ContentRendered({
    $script:Timer.Interval = [TimeSpan]::FromMinutes([int]$script:Cfg.Interval)
    $script:Scanner.ScanAsync()
    Update-Widget
    $script:Timer.Start()
    $script:Ticker.Start()
    $script:TokTimer.Start()
    Write-Log 'running'
})

$win.Add_Closed({
    $script:Timer.Stop(); $script:Ticker.Stop(); $script:TokTimer.Stop()
    Save-Cfg
    if ($script:TrayIcon) { $script:TrayIcon.Visible = $false; $script:TrayIcon.Dispose() }
    Write-Log '--- closed ---'
    [Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown()
})

try {
    $win.Show() | Out-Null
    $win.Activate() | Out-Null
    [Windows.Threading.Dispatcher]::Run()
} catch { Die 'main loop' $_ }
