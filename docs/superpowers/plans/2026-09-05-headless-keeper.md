# Headless Keeper (v3.1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the visible `boot.cmd` console keeper with an invisible supervised keeper exe, one 2-trigger scheduled task, browser shortcuts, and correct uninstall/upgrade ordering — per `docs/superpowers/specs/2026-09-05-headless-keeper-design.md` v1.1.

**Architecture:** New dependency-free `keeper/` project (`BasaPOS.Keeper.exe`, self-contained WinExe) loops a hidden `wsl.exe sleep infinity` client with health probing, backoff, and hang watchdog; `TaskRegistrar` v2 registers one at-logon + 5-min-repetition task; new `ShortcutCreator` + `PowerPolicy` + `KeeperProcess` units in `setup-gui/Install/`; orchestrator wires deploy; drills + CI assert the new behavior.

**Tech Stack:** C# / .NET 10 (net10.0-windows, win-x64 self-contained single-file), xunit (existing `setup-gui.tests`, new `keeper.tests`), PowerShell `Register-ScheduledTask` (Windows), WScript.Shell COM for `.lnk`, PIL (icon conversion, available), bash `validate.sh` grep guards.

---

## File map

```
CREATE:
  payload/basapos.ico                  (binary, from site favicon)
  keeper/BasaPOS.Keeper.csproj
  keeper/Program.cs                    (mutex + watchdog thread + run)
  keeper/KeeperLoop.cs                 (loop, backoff, stale check, fatal logic)
  keeper/Proc.cs                       (IProcessRunner/ProcessRunner/JobObject/IChildProcess)
  keeper/SiteProbe.cs                  (ISiteProbe/HttpClient ping)
  keeper/HeartbeatLog.cs               (60s line log + .1 roll)
  keeper.tests/BasaPOS.Keeper.Tests.csproj
  keeper.tests/KeeperTests.cs
  setup-gui/Install/ShortcutCreator.cs (links + ico copy + Terminal hide)
  setup-gui/Install/PowerPolicy.cs     (powercfg + WU registry)
  setup-gui/Install/KeeperProcess.cs   (find/kill keeper by exe path)

MODIFY:
  setup-gui/Install/Paths.cs                  (+ BinDir)
  setup-gui/Install/TaskRegistrar.cs          (v2: stop-first, 2 triggers, principal)
  setup-gui/Install/Uninstaller.cs            (order: task→kill→links→shutdown→unregister→files; BinDir delete)
  setup-gui/Install/InstallOrchestrator.cs    (step 7: deploy keeper+ico, policy, task, links; drop BootWrapper.Write)
  setup-gui/Install/BootWrapper.cs            (delete Render/Write; keep Delete for legacy boot.cmd)
  setup-gui/e2e/drill-install.ps1             (new assertions)
  setup-gui/e2e/drill-reinstall.ps1           (upgrade assertions)
  setup-gui/e2e/drill-uninstall.ps1           (new assertions)
  appliance/validate.sh                       (restart-policy guards)
  .github/workflows/ci.yml                    (keeper test+publish, payload copies)
```

`setup-gui.tests` auto-includes new `Install/*.cs` via its existing glob — no csproj change needed there.

---

### Task 1: Fetch favicon, commit `payload/basapos.ico`

**Files:**
- Create: `payload/basapos.ico` (binary)

- [ ] **Step 1: Download the 192px favicon and convert to multi-size .ico**

Run:
```bash
mkdir -p payload && curl -fsSL -o /tmp/site_logo.png https://bsmtechsolutions.co.zw/wp-content/uploads/2026/05/cropped-site_logo--192x192.png && python3 -c "from PIL import Image; im=Image.open('/tmp/site_logo.png'); im.save('payload/basapos.ico', sizes=[(16,16),(32,32),(48,48),(256,256)]))" && ls -la payload/basapos.ico
```
Expected: file exists, ~50–150 KB. (PIL verified present on this machine; CI does NOT regenerate — the .ico is committed.)

- [ ] **Step 2: Commit**

```bash
git add payload/basapos.ico && git commit -m "assets: basapos.ico from site favicon (multi-size)"
```

---

### Task 2: Keeper project skeleton + loop + process runner (TDD)

**Files:**
- Create: `keeper/BasaPOS.Keeper.csproj`, `keeper/Program.cs`, `keeper/KeeperLoop.cs`, `keeper/Proc.cs`
- Test: `keeper.tests/KeeperTests.cs` (created in Task 4; for THIS task, write the tests first in the same step sequence — the test project is created in Task 4, so Task 2 steps write `keeper/*.cs` sources only, then Task 4 wires tests. To keep TDD honest, Task 2 Step 1 writes the test code that Task 4's project will compile.)

Actually — TDD order demands the test project first. So Task 2 creates BOTH projects (sources + failing tests), Task 3+ fills them. Restructured below.

**Files:**
- Create: `keeper/BasaPOS.Keeper.csproj`
- Create: `keeper.tests/BasaPOS.Keeper.Tests.csproj`

- [ ] **Step 1: Create the keeper csproj (self-contained WinExe, mirrors Setup's proven cross-build model)**

```xml
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <OutputType>WinExe</OutputType>
    <TargetFramework>net10.0-windows</TargetFramework>
    <Nullable>enable</Nullable>
    <ImplicitUsings>enable</ImplicitUsings>
    <RuntimeIdentifier>win-x64</RuntimeIdentifier>
    <SelfContained>true</SelfContained>
    <PublishSingleFile>true</PublishSingleFile>
    <EnableCompressionInSingleFile>true</EnableCompressionInSingleFile>
    <IncludeNativeLibrariesForSelfExtract>true</IncludeNativeLibrariesForSelfExtract>
    <EnableWindowsTargeting>true</EnableWindowsTargeting>
    <AssemblyName>BasaPOS.Keeper</AssemblyName>
  </PropertyGroup>
</Project>
```

- [ ] **Step 2: Create the test csproj**

```xml
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net10.0</TargetFramework>
    <Nullable>enable</Nullable>
    <ImplicitUsings>enable</ImplicitUsings>
    <EnableWindowsTargeting>true</EnableWindowsTargeting>
    <IsPackable>false</IsPackable>
  </PropertyGroup>
  <ItemGroup>
    <PackageReference Include="Microsoft.NET.Test.Sdk" Version="17.12.0" />
    <PackageReference Include="xunit" Version="2.9.2" />
    <PackageReference Include="xunit.runner.visualstudio" Version="2.8.2" />
  </ItemGroup>
  <ItemGroup>
    <ProjectReference Include="..\keeper\BasaPOS.Keeper.csproj" />
  </ItemGroup>
</Project>
```

- [ ] **Step 3: Commit**

```bash
git add keeper/BasaPOS.Keeper.csproj keeper.tests/BasaPOS.Keeper.Tests.csproj && git commit -m "scaffold: BasaPOS.Keeper exe + test projects"
```

---

### Task 3: `KeeperLoop` — spawn/respawn/fatal/distro-retry (TDD)

**Files:**
- Create: `keeper/KeeperLoop.cs`, `keeper/Proc.cs`
- Test: `keeper.tests/KeeperTests.cs` (append)

- [ ] **Step 1: Write the failing tests** — append to `keeper.tests/KeeperTests.cs`:

```csharp
using BasaPOS.Keeper;
using Xunit;

sealed class FakeChild(int exitCode, string stderr = "") : IChildProcess
{
    public int Pid => 4242;
    public int ExitCode => exitCode;
    public string StderrTail => stderr;
    public int WaitForExit(int msTimeout) => 0; // exits immediately
    public void KillTree() { }
    public void Dispose() { }
    public int SpawnCount;
}

sealed class FakeRunner : IProcessRunner
{
    public Queue<IChildProcess> Children = new();
    public List<string> DistroList = new() { "BasaPOS" };
    public int SpawnCount;
    public IChildProcess SpawnWslKeepalive()
    {
        SpawnCount++;
        var c = Children.Count > 0 ? Children.Dequeue() : new FakeChild(0);
        if (c is FakeChild f) f.SpawnCount = SpawnCount;
        return c;
    }
    public IReadOnlyList<string> ListDistros() => DistroList;
}

sealed class FakeProbe(bool up) : ISiteProbe
{
    public Task<bool> ProbeAsync(CancellationToken ct) => Task.FromResult(up);
}

public class KeeperLoopTests
{
    static (KeeperLoop, FakeRunner, List<TimeSpan>) Make(FakeRunner r, bool siteUp = true)
    {
        var sleeps = new List<TimeSpan>();
        var loop = new KeeperLoop(r, new FakeProbe(siteUp), ts => sleeps.Add(ts),
            _ => { }, () => DateTime.UtcNow);
        return (loop, r, sleeps);
    }

    [Fact]
    public void Backoff_sequence_is_5_10_20_40_then_60_cap()
    {
        Assert.Equal(TimeSpan.FromSeconds(5), KeeperLoop.Backoff(0));
        Assert.Equal(TimeSpan.FromSeconds(10), KeeperLoop.Backoff(1));
        Assert.Equal(TimeSpan.FromSeconds(20), KeeperLoop.Backoff(2));
        Assert.Equal(TimeSpan.FromSeconds(40), KeeperLoop.Backoff(3));
        Assert.Equal(TimeSpan.FromSeconds(60), KeeperLoop.Backoff(4));
        Assert.Equal(TimeSpan.FromSeconds(60), KeeperLoop.Backoff(99));
    }

    [Fact]
    public void Watchdog_stale_threshold_is_120s()
    {
        var now = DateTime.UtcNow;
        Assert.False(KeeperLoop.IsStale(now, now.AddSeconds(119)));
        Assert.True(KeeperLoop.IsStale(now, now.AddSeconds(121)));
    }

    [Fact]
    public void Missing_distro_retries_6x30s_then_throws_fatal()
    {
        var r = new FakeRunner { DistroList = new List<string>() };
        r.Children.Enqueue(new FakeChild(1, "No distribution"));
        var (loop, _, sleeps) = Make(r);
        var ex = Assert.Throws<FatalKeeperException>(() => loop.Run(new CancellationTokenSource(5000).Token));
        Assert.Contains("BasaPOS", ex.Message);
        Assert.Equal(6, sleeps.Count(s => s == TimeSpan.FromSeconds(30)));
    }

    [Fact]
    public void Transient_exit_respawns_with_backoff_not_fatal()
    {
        var r = new FakeRunner();
        r.Children.Enqueue(new FakeChild(1, "transient hcs error"));
        r.Children.Enqueue(new FakeChild(0));
        var (loop, _, sleeps) = Make(r);
        using var cts = new CancellationTokenSource(500);
        loop.Run(cts.Token); // cancelled, not fatal
        Assert.Contains(sleeps, s => s == TimeSpan.FromSeconds(5));
        Assert.Equal(2, r.SpawnCount);
    }

    [Fact]
    public void Loop_updates_last_tick()
    {
        var (loop, _, _) = Make(new FakeRunner());
        var before = DateTime.UtcNow;
        using var cts = new CancellationTokenSource(300);
        loop.Run(cts.Token);
        Assert.True(loop.LastTick >= before);
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `dotnet test keeper.tests/BasaPOS.Keeper.Tests.csproj -c Release`
Expected: FAIL — `KeeperLoop`, `IProcessRunner`, `ISiteProbe`, `FatalKeeperException` do not exist.

- [ ] **Step 3: Write minimal implementation** — create `keeper/Proc.cs`:

```csharp
namespace BasaPOS.Keeper;

public interface IChildProcess : IDisposable
{
    int Pid { get; }
    int ExitCode { get; }
    string StderrTail { get; }
    int WaitForExit(int msTimeout);
    void KillTree();
}

public interface IProcessRunner
{
    IChildProcess SpawnWslKeepalive();
    IReadOnlyList<string> ListDistros();
}

public interface ISiteProbe
{
    Task<bool> ProbeAsync(CancellationToken ct);
}

public sealed class FatalKeeperException(string message) : Exception(message);
```

Create `keeper/KeeperLoop.cs`:

```csharp
using System.Diagnostics;

namespace BasaPOS.Keeper;

public sealed class KeeperLoop(
    IProcessRunner runner,
    ISiteProbe probe,
    Action<TimeSpan> sleep,
    Action<string> log,
    Func<DateTime> clock)
{
    public DateTime LastTick { get; private set; } = clock();

    internal static TimeSpan Backoff(int consecutiveFailures) =>
        TimeSpan.FromSeconds(Math.Min(60, 5 * (1 << Math.Min(consecutiveFailures, 3))));

    internal static bool IsStale(DateTime lastTick, DateTime now) =>
        now - lastTick > TimeSpan.FromSeconds(120);

    /// Runs until cancelled (returns) or the distro is proven missing (throws FatalKeeperException).
    public void Run(CancellationToken ct)
    {
        int failures = 0, missingStreak = 0;
        while (!ct.IsCancellationRequested)
        {
            LastTick = clock();
            using var child = runner.SpawnWslKeepalive();
            log($"keeper: spawned wsl child pid={child.Pid}");
            child.WaitForExit(60_000);
            if (ct.IsCancellationRequested) return;
            // 60s probe tick (child alive path also probes site health)
            bool up;
            try { up = probe.ProbeAsync(ct).GetAwaiter().GetResult(); }
            catch { up = false; }
            log(up ? "probe: SITE-UP" : "probe: SITE-DOWN (VM alive, site not responding)");
            LastTick = clock();
            // child exited (or 60s tick elapsed) — respawn path
            if (child.Exited())
            {
                log($"keeper: child pid={child.Pid} exited {child.ExitCode} stderr={child.StderrTail}");
                if (!runner.ListDistros().Any(d => d.Equals("BasaPOS", StringComparison.OrdinalIgnoreCase)))
                {
                    missingStreak++;
                    log($"keeper: distro not listed ({missingStreak}/6)");
                    if (missingStreak >= 6)
                        throw new FatalKeeperException("Distro 'BasaPOS' missing after 6x30s retries — not transient.");
                    sleep(TimeSpan.FromSeconds(30));
                    continue;
                }
                missingStreak = 0;
                sleep(Backoff(failures++));
            }
            else
            {
                failures = 0; // healthy tick resets backoff
            }
        }
    }
}
```

NOTE to implementer: `IChildProcess` needs an `Exited()` helper — add `bool Exited();` to the interface in `Proc.cs` (FakeChild returns true). `WaitForExit(ms)` returns 0 on exit, nonzero on timeout; `Exited()` reports whether the process has exited. Adjust the test fake accordingly (add `public bool Exited() => true;`). Real implementation in Task 4's `ProcessRunner`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `dotnet test keeper.tests/BasaPOS.Keeper.Tests.csproj -c Release`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add keeper/Proc.cs keeper/KeeperLoop.cs keeper.tests/KeeperTests.cs && git commit -m "feat(keeper): loop with backoff, distro-retry-then-fatal, stale check"
```

---

### Task 4: `ProcessRunner` (Job Object, stderr) + `Program` entry (TDD where possible)

**Files:**
- Create: `keeper/ProcRunner.cs`, `keeper/Program.cs`
- Test: `keeper.tests/KeeperTests.cs` (append distro-parser test)

- [ ] **Step 1: Write the failing test** (distro-list parsing is unit-testable; Job Object + mutex are Windows-runtime, drill-verified):

```csharp
[Fact]
public void ParseDistroNames_trims_and_drops_blanks()
{
    var names = ProcessRunner.ParseDistroNames("BasaPOS\r\nUbuntu\r\n\r\n");
    Assert.Equal(new[] { "BasaPOS", "Ubuntu" }, names);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `dotnet test keeper.tests/BasaPOS.Keeper.Tests.csproj -c Release --filter "FullyQualifiedName~ParseDistroNames"`
Expected: FAIL — `ProcessRunner` does not exist.

- [ ] **Step 3: Write minimal implementation** — create `keeper/ProcRunner.cs` with:

  - `public static IReadOnlyList<string> ParseDistroNames(string output)` — trim lines, drop blanks (same semantics as `WslRunner.ParseDistroList`).
  - `public sealed class WslChild(Process p, StringBuilder stderr, IntPtr job) : IChildProcess` — `WaitForExit(ms)` → `p.WaitForExit(ms) ? 0 : 1`; `Exited()` → `p.HasExited`; `ExitCode` → `p.ExitCode`; `StderrTail` → last 2KB of captured stderr; `KillTree()` → `p.Kill(true)`; `Dispose()` → close job handle + dispose process.
  - `public sealed class ProcessRunner : IProcessRunner` — `SpawnWslKeepalive()`: start `wsl.exe -d BasaPOS --exec /bin/sleep infinity` with `UseShellExecute=false, CreateNoWindow=true, RedirectStandardError=true` (stdout NOT redirected — sleep writes nothing; avoids pipe stall), async stderr drain capped at 4KB, assign process to a kill-on-close Job Object; `ListDistros()`: run `wsl.exe --list --quiet` (30s timeout, UTF-16 read — wsl emits UTF-16) best-effort (empty on any failure, never throw).
  - Job Object P/Invoke: `CreateJobObject`, `SetInformationJobObject` (class 9 = `JobObjectExtendedLimitInformation`) with `JOBOBJECT_EXTENDED_LIMIT_INFORMATION` (`LimitFlags = 0x2000` = KILL_ON_JOB_CLOSE), `AssignProcessToJobObject`, `CloseHandle`. Structs: `JOBOBJECT_BASIC_LIMIT_INFORMATION` + 6-field `IO_COUNTERS` + 4 `UIntPtr` fields.
  - `FakeChild` in tests needs `public bool Exited() => true;` added (see Task 3 note) — make that edit in this task's Step 3 as well.

- [ ] **Step 4: Write `keeper/Program.cs`** (top-level statements):

```csharp
using BasaPOS.Keeper;

using var mutex = new Mutex(false, @"Global\BasaPOS.Keeper", out bool createdNew);
if (!createdNew) return 0; // watchdog fired while alive — exit clean

var logPath = Path.Combine(@"C:\BasaPOS\logs", "keeper.log");
var blog = new HeartbeatLog(logPath); // Task 5; stub Action<string> for now:
Action<string> log = m => blog.Write(m);
var loop = new KeeperLoop(new ProcessRunner(), new SiteProbe(), Thread.Sleep, log, () => DateTime.UtcNow);
var watchdog = new Thread(() =>
{
    while (true)
    {
        Thread.Sleep(10_000);
        if (KeeperLoop.IsStale(loop.LastTick, DateTime.UtcNow))
            Environment.FailFast("BasaPOS.Keeper main loop stalled");
    }
}) { IsBackground = true };
watchdog.Start();
try { loop.Run(CancellationToken.None); return 0; }
catch (FatalKeeperException ex) { log("FATAL: " + ex.Message); return 1; }
catch (Exception ex) { log("UNEXPECTED: " + ex); return 2; }
```

NOTE: `HeartbeatLog`/`SiteProbe` come in Task 5 — this step will NOT compile until then. If implementing strictly task-by-task, write Program.cs in Task 5 instead; Task 4 ends after `ProcRunner.cs` + test green. (Worker: do that — move Program.cs to Task 5.)

- [ ] **Step 5: Run tests**

Run: `dotnet test keeper.tests/BasaPOS.Keeper.Tests.csproj -c Release`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add keeper/ProcRunner.cs keeper.tests/KeeperTests.cs && git commit -m "feat(keeper): wsl runner with job object, stderr capture, distro parse"
```

---

### Task 5: `SiteProbe`, `HeartbeatLog`, `Program.cs` (TDD)

**Files:**
- Create: `keeper/SiteProbe.cs`, `keeper/HeartbeatLog.cs`, `keeper/Program.cs`
- Test: `keeper.tests/KeeperTests.cs` (append)

- [ ] **Step 1: Write the failing tests**

```csharp
[Fact]
public void HeartbeatLog_rolls_at_1MB_keeping_one_backup()
{
    var dir = Path.Combine(Path.GetTempPath(), "hb-" + Guid.NewGuid().ToString("N"));
    Directory.CreateDirectory(dir);
    var path = Path.Combine(dir, "keeper.log");
    File.WriteAllText(path, new string('x', (1 << 20) + 10));
    var log = new HeartbeatLog(path);
    log.Write("ts | TICK | site=up");
    Assert.True(new FileInfo(Path.Combine(dir, "keeper.log.1")).Length > (1 << 20));
    Assert.Contains("TICK", File.ReadAllText(path));
    Directory.Delete(dir, recursive: true);
}

[Fact]
public void HeartbeatLog_never_throws_on_locked_file()
{
    var path = Path.Combine(Path.GetTempPath(), "hb-locked.log");
    using var locked = File.Open(path, FileMode.Create, FileAccess.ReadWrite, FileShare.None);
    var log = new HeartbeatLog(path); // must not throw
    log.Write("x");                    // must not throw
    locked.Dispose();
    File.Delete(path);
}
```

(`SiteProbe` hits the real network — no unit test; drill-verified. Its shape is fixed below.)

- [ ] **Step 2: Run tests to verify they fail**

Run: `dotnet test keeper.tests/BasaPOS.Keeper.Tests.csproj -c Release --filter "FullyQualifiedName~HeartbeatLog"`
Expected: FAIL — `HeartbeatLog` does not exist.

- [ ] **Step 3: Write minimal implementation**

`keeper/HeartbeatLog.cs`:
```csharp
namespace BasaPOS.Keeper;

public sealed class HeartbeatLog(string path)
{
    public void Write(string line)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            if (File.Exists(path) && new FileInfo(path).Length > (1 << 20))
            {
                var bak = path + ".1";
                try { if (File.Exists(bak)) File.Delete(bak); } catch { }
                try { File.Move(path, bak); } catch { }
            }
            File.AppendAllText(path, $"[{DateTime.UtcNow:yyyy-MM-dd HH:mm:ss}] {line}\n");
        }
        catch { /* logging never crashes the keeper */ }
    }
}
```

`keeper/SiteProbe.cs`:
```csharp
namespace BasaPOS.Keeper;

public sealed class SiteProbe : ISiteProbe
{
    static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(10) };
    public async Task<bool> ProbeAsync(CancellationToken ct)
    {
        try
        {
            var r = await Http.GetAsync("https://basapos.local/api/method/ping", ct);
            return r.IsSuccessStatusCode;
        }
        catch { return false; }
    }
}
```

`keeper/Program.cs`: exactly the top-level code from Task 4 Step 4 (mutex `Global\BasaPOS.Keeper`, watchdog thread 10s/`IsStale`→`FailFast`, run loop, exit 0/1/2).

- [ ] **Step 4: Build the exe + run all keeper tests**

Run:
```bash
dotnet build keeper/BasaPOS.Keeper.csproj -c Release --nologo && dotnet test keeper.tests/BasaPOS.Keeper.Tests.csproj -c Release
```
Expected: build OK (WinExe cross-build from Linux via EnableWindowsTargeting), all tests PASS.

- [ ] **Step 5: Commit**

```bash
git add keeper/SiteProbe.cs keeper/HeartbeatLog.cs keeper/Program.cs keeper.tests/KeeperTests.cs && git commit -m "feat(keeper): site probe, rolling heartbeat log, program entry"
```

---

### Task 6: `TaskRegistrar` v2 — stop-first, 2 triggers, principal (TDD)

**Files:**
- Modify: `setup-gui/Install/TaskRegistrar.cs`
- Test: `setup-gui.tests/InstallComponentsTests.cs` (append; auto-compiled via glob)

- [ ] **Step 1: Write the failing tests**

```csharp
[Fact]
public void TaskRegistrar_script_stops_old_tasks_and_registers_two_triggers()
{
    var s = TaskRegistrar.BuildRegisterScript("tech", @"C:\BasaPOS\bin\BasaPOS.Keeper.exe");
    Assert.Contains("Stop-ScheduledTask -TaskName 'BasaPOS-Appliance'", s);
    Assert.Contains("Stop-ScheduledTask -TaskName 'BasaPOS-Keeper'", s);
    Assert.Contains("Unregister-ScheduledTask -TaskName 'BasaPOS-Appliance'", s);
    Assert.Contains("New-ScheduledTaskTrigger -AtLogOn", s);
    Assert.Contains("RepetitionInterval", s);
    Assert.Contains("PT5M", s); // 5-minute watchdog interval visible in script
    Assert.Contains("IgnoreNew", s);
    Assert.Contains(@"C:\BasaPOS\bin\BasaPOS.Keeper.exe", s);
    Assert.Contains("Start-ScheduledTask -TaskName 'BasaPOS-Keeper'", s);
}

[Fact]
public void TaskRegistrar_delete_stops_before_deleting()
{
    var s = TaskRegistrar.BuildDeleteScript();
    Assert.True(s.IndexOf("Stop-ScheduledTask") < s.IndexOf("/delete"),
        "stop must precede delete so no running instance survives");
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `dotnet test setup-gui.tests/ -c Release --filter "FullyQualifiedName~TaskRegistrar"`
Expected: FAIL — `BuildRegisterScript`/`BuildDeleteScript` do not exist.

- [ ] **Step 3: Write minimal implementation** — rewrite `TaskRegistrar.cs`:

```csharp
namespace BasaPOS.Setup.Install;

public static class TaskRegistrar
{
    public const string TaskName = "BasaPOS-Appliance";       // legacy, deleted
    public const string KeeperTaskName = "BasaPOS-Keeper";    // the ONE task
    const string LegacyResumeTask = "BasaPOS-Setup-Resume";   // v2, deleted

    public static void Register()
    {
        var r = WslRunner.RunAnsi("powershell.exe",
            "-NoProfile -ExecutionPolicy Bypass -Command \"" +
            BuildRegisterScript(Environment.UserName,
                Path.Combine(Paths.BinDir, "BasaPOS.Keeper.exe")) + "\"", 120);
        if (r.ExitCode != 0)
            throw new InvalidOperationException($"keeper task register failed ({r.ExitCode}): {r.Error}");
    }

    internal static string BuildRegisterScript(string user, string exe)
    {
        var u = user.Replace("'", "''");
        return "$ErrorActionPreference='Stop'; " +
            "Stop-ScheduledTask -TaskName 'BasaPOS-Appliance' -ErrorAction SilentlyContinue; " +
            "Stop-ScheduledTask -TaskName 'BasaPOS-Keeper' -ErrorAction SilentlyContinue; " +
            "Unregister-ScheduledTask -TaskName 'BasaPOS-Appliance' -Confirm:$false -ErrorAction SilentlyContinue; " +
            "Unregister-ScheduledTask -TaskName 'BasaPOS-Keeper' -Confirm:$false -ErrorAction SilentlyContinue; " +
            "$a=New-ScheduledTaskAction -Execute '" + exe + "'; " +
            "$t1=New-ScheduledTaskTrigger -AtLogOn -User '" + u + "'; " +
            "$t2=New-ScheduledTaskTrigger -Once -At (Get-Date) " +
            "-RepetitionInterval (New-TimeSpan -Minutes 5) " +
            "-RepetitionDuration ([TimeSpan]::MaxValue); " +
            "$p=New-ScheduledTaskPrincipal -UserId '" + u + "' -LogonType Interactive -RunLevel Highest; " +
            "$s=New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) " +
            "-RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew; " +
            "Register-ScheduledTask -TaskName 'BasaPOS-Keeper' " +
            "-Action $a -Trigger @($t1,$t2) -Principal $p -Settings $s -Force; " +
            "Start-ScheduledTask -TaskName 'BasaPOS-Keeper'";
    }

    internal static string BuildDeleteScript() =>
        "$ErrorActionPreference='Stop'; " +
        "Stop-ScheduledTask -TaskName 'BasaPOS-Appliance' -ErrorAction SilentlyContinue; " +
        "Stop-ScheduledTask -TaskName 'BasaPOS-Keeper' -ErrorAction SilentlyContinue; " +
        "Stop-ScheduledTask -TaskName 'BasaPOS-Setup-Resume' -ErrorAction SilentlyContinue; ";

    public static void Delete()
    {
        // Stop first: schtasks /delete leaves a RUNNING instance alive.
        WslRunner.RunAnsi("powershell.exe",
            "-NoProfile -ExecutionPolicy Bypass -Command \"" + BuildDeleteScript() + "\"", 60);
        WslRunner.RunAnsi("schtasks.exe", $"/delete /tn {TaskName} /f", 60);
        WslRunner.RunAnsi("schtasks.exe", $"/delete /tn {KeeperTaskName} /f", 60);
        WslRunner.RunAnsi("schtasks.exe", $"/delete /tn {LegacyResumeTask} /f", 60);
    }
}
```

NOTE: the `-RepetitionInterval` renders as `PT5M` in the *task XML*, not in the script text — the test's `Assert.Contains("PT5M", s)` above is WRONG. Fix the test in this step: assert `New-TimeSpan -Minutes 5` instead of `PT5M`. (XML-level PT5M is asserted in the drill, Task 12.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `dotnet test setup-gui.tests/ -c Release --filter "FullyQualifiedName~TaskRegistrar"`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add setup-gui/Install/TaskRegistrar.cs setup-gui.tests/InstallComponentsTests.cs && git commit -m "feat(tasks): single keeper task, stop-first, logon+5min triggers"
```

---

### Task 7: `KeeperProcess` + `Uninstaller` reorder (TDD)

**Files:**
- Create: `setup-gui/Install/KeeperProcess.cs`
- Modify: `setup-gui/Install/Paths.cs`, `setup-gui/Install/Uninstaller.cs`
- Test: `setup-gui.tests/InstallComponentsTests.cs` (append)

- [ ] **Step 1: Write the failing tests**

```csharp
[Fact]
public void KeeperProcess_path_match_is_exact_case_insensitive()
{
    Assert.True(KeeperProcess.PathMatches(@"C:\BasaPOS\bin\BasaPOS.Keeper.exe", KeeperProcess.ExePath));
    Assert.True(KeeperProcess.PathMatches(@"c:\basapos\BIN\basapos.keeper.exe", KeeperProcess.ExePath));
    Assert.False(KeeperProcess.PathMatches(@"C:\BasaPOS\bin\other.exe", KeeperProcess.ExePath));
    Assert.False(KeeperProcess.PathMatches(null, KeeperProcess.ExePath));
    Assert.Equal(@"C:\BasaPOS\bin\BasaPOS.Keeper.exe", KeeperProcess.ExePath);
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `dotnet test setup-gui.tests/ -c Release --filter "FullyQualifiedName~KeeperProcess"`
Expected: FAIL — `KeeperProcess` does not exist.

- [ ] **Step 3: Write minimal implementation** — create `setup-gui/Install/KeeperProcess.cs`:

```csharp
using System.Diagnostics;

namespace BasaPOS.Setup.Install;

/// Finds/kills the keeper by EXE PATH (never bare name — taskkill /IM
/// matches by name only and could hit an unrelated process).
internal static class KeeperProcess
{
    public static string ExePath => Path.Combine(Paths.BinDir, "BasaPOS.Keeper.exe");

    internal static bool PathMatches(string? actual, string expected) =>
        string.Equals(actual?.Trim().TrimEnd('\\'), expected.Trim().TrimEnd('\\'),
            StringComparison.OrdinalIgnoreCase);

    public static void KillAll()
    {
        foreach (var p in Process.GetProcessesByName("BasaPOS.Keeper"))
        {
            try
            {
                if (PathMatches(p.MainModule?.FileName, ExePath))
                    p.Kill(entireProcessTree: true);
            }
            catch { /* exited / access denied — desired end state anyway */ }
        }
    }
}
```

Add to `Paths.cs`: `public static readonly string BinDir = Path.Combine(InstallRoot, "bin");`

Reorder `Uninstaller.Run`: new sequence (exact replacement of lines 15–21):
```csharp
ui.Status("Stopping keeper task...");
TaskRegistrar.Delete();                       // stops instances, then deletes all 3 names
ui.Status("Killing keeper process...");
KeeperProcess.KillAll();
ShortcutCreator.Remove();                     // Task 8 — if implementing strictly in order,
                                              // call BootWrapper.Delete() here and add this line in Task 8
ui.Status("Shutting down WSL...");
try { WslRunner.Wsl("--shutdown", 120); } catch { }
ui.Status("Unregistering distro...");
UnregisterBasaPOS();
```
And extend the dirs loop (line 42) to include `Paths.BinDir`:
```csharp
foreach (var d in new[] { Paths.DistroDir, Paths.ConfigDir, Paths.LogsDir, Paths.BinDir })
```
(Worker: if Task 8 is not done yet, leave a `// TODO Task 8` marker? NO — placeholders forbidden. Instead: implement the reorder WITHOUT the ShortcutCreator line now, and Task 8 adds that single line + its own test. State that explicitly in the Task 8 description.)

- [ ] **Step 4: Run tests**

Run: `dotnet test setup-gui.tests/ -c Release`
Expected: PASS (full suite — reorder must not break existing uninstaller tests).

- [ ] **Step 5: Commit**

```bash
git add setup-gui/Install/KeeperProcess.cs setup-gui/Install/Paths.cs setup-gui/Install/Uninstaller.cs setup-gui.tests/InstallComponentsTests.cs && git commit -m "feat(uninstall): task-first kill order, keeper by path, bin dir"
```

---

### Task 8: `ShortcutCreator` — links, icon copy, Terminal hide (TDD)

**Files:**
- Create: `setup-gui/Install/ShortcutCreator.cs`
- Modify: `setup-gui/Install/Uninstaller.cs` (add `ShortcutCreator.Remove();` after `KeeperProcess.KillAll();`)
- Test: `setup-gui.tests/InstallComponentsTests.cs` (append)

- [ ] **Step 1: Write the failing tests**

```csharp
[Fact]
public void ShortcutCreator_paths_and_icon()
{
    Assert.Equal("BasaPOS.lnk", ShortcutCreator.LinkName);
    Assert.EndsWith(@"Programs\BasaPOS.lnk", ShortcutCreator.StartMenuLink);
    Assert.EndsWith(@"Desktop\BasaPOS.lnk", ShortcutCreator.DesktopLink);
    Assert.Equal(Path.Combine(Paths.BinDir, "basapos.ico"), ShortcutCreator.IconPath);
}

[Fact]
public void TerminalHide_adds_and_removes_only_our_entry()
{
    var empty = """{"profiles":{"list":[]}}""";
    var hidden = ShortcutCreator.HideProfileJson(empty);
    Assert.Contains("\"hidden\": true", hidden);
    Assert.Contains("BasaPOS", hidden);
    // idempotent: hiding twice adds one entry
    Assert.Equal(hidden, ShortcutCreator.HideProfileJson(hidden));
    // unhide removes exactly our shape, keeps user entries
    var withUser = """{"profiles":{"list":[{"name":"BasaPOS","hidden":true},{"name":"Ubuntu","fontSize":14}]}}""";
    var restored = ShortcutCreator.UnhideProfileJson(withUser);
    Assert.DoesNotContain("BasaPOS", restored);
    Assert.Contains("Ubuntu", restored);
    // unhide never touches a user-customized BasaPOS entry (extra keys)
    var custom = """{"profiles":{"list":[{"name":"BasaPOS","hidden":true,"fontSize":16}]}}""";
    Assert.Contains("fontSize", ShortcutCreator.UnhideProfileJson(custom));
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `dotnet test setup-gui.tests/ -c Release --filter "FullyQualifiedName~ShortcutCreator|FullyQualifiedName~TerminalHide"`
Expected: FAIL — `ShortcutCreator` does not exist.

- [ ] **Step 3: Write minimal implementation** — create `setup-gui/Install/ShortcutCreator.cs`:

```csharp
using System.Text.Json;
using System.Text.Json.Nodes;

namespace BasaPOS.Setup.Install;

public static class ShortcutCreator
{
    public const string LinkName = "BasaPOS.lnk";
    public static string StartMenuLink => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.CommonStartMenu), "Programs", LinkName);
    public static string DesktopLink => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.CommonDesktopDirectory), LinkName);
    public static string IconPath => Path.Combine(Paths.BinDir, "basapos.ico");

    /// payloadDir: installer payload folder containing BasaPOS.Keeper.exe + basapos.ico.
    /// (Shortcut creation itself is Windows-only at runtime; path/JSON logic above is tested on Linux.)
    public static void Create(string payloadDir)
    {
        Directory.CreateDirectory(Paths.BinDir);
        File.Copy(Path.Combine(payloadDir, "basapos.ico"), IconPath, overwrite: true);
        WriteLink(StartMenuLink);
        WriteLink(DesktopLink);
        HideTerminalProfile();
    }

    static void WriteLink(string lnk)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(lnk)!);
        var t = Type.GetTypeFromProgID("WScript.Shell")
            ?? throw new InvalidOperationException("WScript.Shell unavailable");
        dynamic shell = Activator.CreateInstance(t)!;
        dynamic sc = shell.CreateShortcut(lnk);
        sc.TargetPath = Paths.SiteUrl;          // URL target → browser, no console
        sc.IconLocation = IconPath;
        sc.Description = "BasaPOS point of sale";
        sc.Save();
    }

    public static void Remove()
    {
        foreach (var lnk in new[] { StartMenuLink, DesktopLink })
            try { if (File.Exists(lnk)) File.Delete(lnk); } catch { }
        UnhideTerminalProfile();
    }

    static string TerminalSettingsPath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "Packages", "Microsoft.WindowsTerminal_8wekyb3d8bbwe",
        "LocalState", "settings.json");

    internal static string HideProfileJson(string json)
    {
        var root = JsonNode.Parse(json) ?? new JsonObject();
        var list = root["profiles"]?["list"]?.AsArray();
        if (list is null) return json;
        if (!list.Any(n => n?["name"]?.GetValue<string>() == "BasaPOS"))
            list.Add(new JsonObject { ["name"] = "BasaPOS", ["hidden"] = true });
        return root.ToJsonString();
    }

    internal static string UnhideProfileJson(string json)
    {
        var root = JsonNode.Parse(json);
        var list = root?["profiles"]?["list"]?.AsArray();
        if (list is null) return json;
        for (int i = list.Count - 1; i >= 0; i--)
            if (list[i] is JsonObject o && o.Count == 2
                && o["name"]?.GetValue<string>() == "BasaPOS"
                && o["hidden"]?.GetValue<bool>() == true)
                list.RemoveAt(i);
        return root!.ToJsonString();
    }

    static void HideTerminalProfile()
    {
        try
        {
            var p = TerminalSettingsPath;
            if (!File.Exists(p)) return; // no Terminal — nothing to hide
            File.WriteAllText(p, HideProfileJson(File.ReadAllText(p)));
        }
        catch { /* best-effort cosmetic */ }
    }

    static void UnhideTerminalProfile()
    {
        try
        {
            var p = TerminalSettingsPath;
            if (!File.Exists(p)) return;
            File.WriteAllText(p, UnhideProfileJson(File.ReadAllText(p)));
        }
        catch { }
    }
}
```

Add `ShortcutCreator.Remove();` to `Uninstaller.Run` right after `KeeperProcess.KillAll();`.

- [ ] **Step 4: Run tests**

Run: `dotnet test setup-gui.tests/ -c Release`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add setup-gui/Install/ShortcutCreator.cs setup-gui/Install/Uninstaller.cs setup-gui.tests/InstallComponentsTests.cs && git commit -m "feat(shortcuts): browser links, icon copy, terminal hide"
```

---

### Task 9: `PowerPolicy` — no-sleep on AC + WU mitigation (TDD)

**Files:**
- Create: `setup-gui/Install/PowerPolicy.cs`
- Test: `setup-gui.tests/InstallComponentsTests.cs` (append)

- [ ] **Step 1: Write the failing tests**

```csharp
[Fact]
public void PowerPolicy_builders_are_exact()
{
    var cmds = PowerPolicy.PowerCfgCommands();
    Assert.Contains("powercfg.exe -change -standby-timeout-ac 0", cmds);
    Assert.Contains("powercfg.exe -hibernate-timeout-ac 0", cmds);
    var vals = PowerPolicy.UpdatePolicyValues();
    Assert.Contains(vals, v => v.SubKey.EndsWith("WindowsUpdate\\AU")
        && v.Name == "NoAutoRebootWithLoggedOnUsers" && Equals(v.Value, 1));
    Assert.Contains(vals, v => v.SubKey.EndsWith("WindowsUpdate\\UX\\Settings")
        && v.Name == "ActiveHoursStart" && Equals(v.Value, 8));
    Assert.Contains(vals, v => v.Name == "ActiveHoursEnd" && Equals(v.Value, 23));
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `dotnet test setup-gui.tests/ -c Release --filter "FullyQualifiedName~PowerPolicy"`
Expected: FAIL — `PowerPolicy` does not exist.

- [ ] **Step 3: Write minimal implementation** — create `setup-gui/Install/PowerPolicy.cs`:

```csharp
using Microsoft.Win32;

namespace BasaPOS.Setup.Install;

public sealed record RegValue(string SubKey, string Name, object Value);

public static class PowerPolicy
{
    internal static string[] PowerCfgCommands() => new[]
    {
        "powercfg.exe -change -standby-timeout-ac 0",
        "powercfg.exe -hibernate-timeout-ac 0",
    };

    internal static RegValue[] UpdatePolicyValues() => new[]
    {
        new RegValue(@"SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU",
            "NoAutoRebootWithLoggedOnUsers", 1),
        new RegValue(@"SOFTWARE\Microsoft\WindowsUpdate\UX\Settings",
            "ActiveHoursStart", 8),
        new RegValue(@"SOFTWARE\Microsoft\WindowsUpdate\UX\Settings",
            "ActiveHoursEnd", 23),
    };

    /// Appliance standard: never sleep on AC; don't auto-reboot under a
    /// logged-on technician. Best-effort — a failed tweak must not fail install.
    public static void Apply(Action<string>? status = null)
    {
        foreach (var cmd in PowerCfgCommands())
        {
            var parts = cmd.Split(' ', 2);
            try { WslRunner.RunAnsi(parts[0], parts[1], 60); }
            catch (Exception ex) { status?.Invoke($"NOTE: power tweak skipped ({ex.Message})"); }
        }
        foreach (var v in UpdatePolicyValues())
        {
            try
            {
                using var key = Registry.LocalMachine.CreateSubKey(v.SubKey);
                key?.SetValue(v.Name, v.Value, RegistryValueKind.DWord);
            }
            catch (Exception ex) { status?.Invoke($"NOTE: update-policy tweak skipped ({ex.Message})"); }
        }
    }
}
```

- [ ] **Step 4: Run tests**

Run: `dotnet test setup-gui.tests/ -c Release`
Expected: PASS. (Registry/powercfg paths are Windows-runtime only; builders are what's tested. `Microsoft.Win32.Registry` compiles on Linux via the existing `EnableWindowsTargeting`.)

- [ ] **Step 5: Commit**

```bash
git add setup-gui/Install/PowerPolicy.cs setup-gui.tests/InstallComponentsTests.cs && git commit -m "feat(power): no-sleep on AC, WU reboot mitigation"
```

---

### Task 10: Orchestrator wiring + retire `BootWrapper` writer (TDD-safe)

**Files:**
- Modify: `setup-gui/Install/InstallOrchestrator.cs`, `setup-gui/Install/BootWrapper.cs`
- Test: existing suite must stay green (no new unit test — wiring is drill-verified; the builders it calls are already tested)

- [ ] **Step 1: Replace install step 7** in `InstallOrchestrator.cs` (lines 54–56):

```csharp
ui.Status("Deploying keeper + registering autostart...");              // 7
Directory.CreateDirectory(Paths.BinDir);
File.Copy(Path.Combine(payload, "BasaPOS.Keeper.exe"),
    Path.Combine(Paths.BinDir, "BasaPOS.Keeper.exe"), overwrite: true);
PowerPolicy.Apply(ui.Status);
TaskRegistrar.Register();
ShortcutCreator.Create(payload);
```

The payload folder gains `BasaPOS.Keeper.exe` + `basapos.ico` in Task 11 (CI). Until then a missing file throws here — correct fail-fast, asserted in Task 12's drill.

- [ ] **Step 2: Trim `BootWrapper.cs`** — delete `Render()` and `Write()`; keep `Delete()` (removes legacy `boot.cmd`; leaves `ProgramData` in place since `install.log` lives there by design — `Delete()` already only removes the dir when empty).

- [ ] **Step 3: Run full test suite**

Run: `dotnet test setup-gui.tests/ -c Release && dotnet test keeper.tests/BasaPOS.Keeper.Tests.csproj -c Release`
Expected: PASS. Also `dotnet build setup-gui/BasaPOS-Setup.csproj -c Release --nologo` must succeed (WinForms compile check).

- [ ] **Step 4: Commit**

```bash
git add setup-gui/Install/InstallOrchestrator.cs setup-gui/Install/BootWrapper.cs && git commit -m "feat(install): deploy keeper, policy, task, links; retire boot.cmd writer"
```

---

### Task 11: Compose-policy guards in `validate.sh` (no code change, per spec §1 correction)

**Files:**
- Modify: `appliance/validate.sh`
- Test: run `bash appliance/validate.sh` against the current distro tar (needs a built tar; if unavailable, test the grep logic against `compose.custom.yaml` directly — see Step 2)

- [ ] **Step 1: Append the guard block** before the `"== size report =="` section:

```bash
echo "== restart policy guard (keeper cold-boot contract) =="
grep -q 'restart: unless-stopped' "$TMPV/opt/basapos/compose/compose.final.yaml" \
  || { echo "VALIDATE FAIL: no unless-stopped policy in shipped compose"; exit 1; }
awk '/^  configurator:/,/^  [a-z_]+:/' "$TMPV/opt/basapos/compose/compose.final.yaml" \
  | grep -q 'restart: on-failure' \
  || { echo "VALIDATE FAIL: configurator must stay on-failure (one-shot would loop)"; exit 1; }
```

- [ ] **Step 2: Verify the guard logic against the committed sample**

Run: `awk '/^  configurator:/,/^  [a-z_]+:/' compose.custom.yaml | grep -q 'restart: on-failure' && echo CONFIG-OK; grep -c 'restart: unless-stopped' compose.custom.yaml`
Expected: `CONFIG-OK` and count `12`.

- [ ] **Step 3: Commit**

```bash
git add appliance/validate.sh && git commit -m "guard: shipped compose keeps restart policies, configurator on-failure"
```

---

### Task 12: CI — keeper tests, keeper publish, payload copies

**Files:**
- Modify: `.github/workflows/ci.yml`

- [ ] **Step 1: Add keeper test + publish to the `gui` job** (after the existing `dotnet test setup-gui.tests` step):

```yaml
      - name: Test keeper components
        run: dotnet test keeper.tests/BasaPOS.Keeper.Tests.csproj -c Release
      - name: Publish keeper (WinExe, cross-build from Linux)
        run: |
          dotnet publish keeper/BasaPOS.Keeper.csproj -c Release \
            -r win-x64 --self-contained true \
            -p:PublishSingleFile=true -p:EnableCompressionInSingleFile=true \
            -o publish-keeper
```

Extend the existing `basapos-setup-gui` artifact upload (or add a second upload) to include the keeper — add after the current upload step:

```yaml
      - uses: actions/upload-artifact@v4
        with:
          name: basapos-keeper
          retention-days: 14
          path: publish-keeper/BasaPOS.Keeper.exe
```

- [ ] **Step 2: Add keeper + icon to the `payload` job** — new download step plus extended assemble:

```yaml
      - uses: actions/download-artifact@v4
        with: { name: basapos-keeper, path: keeper }
```

and in `Assemble payload folder` add:
```bash
          cp keeper/BasaPOS.Keeper.exe out/payload/
          cp payload/basapos.ico out/payload/
```
(`payload/basapos.ico` is the repo-committed file from Task 1.)

- [ ] **Step 3: Validate YAML**

Run: `python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/ci.yml')); print('YAML OK')"`
Expected: `YAML OK`.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/ci.yml && git commit -m "ci: keeper tests+publish, payload gains keeper exe and icon"
```

---

### Task 13: Drill assertions — install / reinstall / uninstall

**Files:**
- Modify: `setup-gui/e2e/drill-install.ps1`, `setup-gui/e2e/drill-reinstall.ps1`, `setup-gui/e2e/drill-uninstall.ps1`
- Test: these run on `windows-latest` CI only — verify PowerShell syntax locally with the parser (no execution):

Run: `pwsh -NoProfile -Command "$null = [Parser]::ParseFile('setup-gui/e2e/drill-install.ps1', [ref]$null, [ref]$null); 'SYNTAX OK'"` (or `powershell` equivalent if pwsh absent — then syntax check is CI-gated; note it in the commit message)

- [ ] **Step 1: `drill-install.ps1`** — REPLACE the `boot.cmd` presence assertion with:

```powershell
if (-not (Test-Path C:\BasaPOS\bin\BasaPOS.Keeper.exe)) { throw 'keeper exe missing' }
if (Test-Path C:\ProgramData\BasaPOS\boot.cmd)           { throw 'legacy boot.cmd must not be created' }
$kt = Get-ScheduledTask -TaskName 'BasaPOS-Keeper'
if ($kt.Triggers.Count -ne 2)                            { throw "keeper task needs 2 triggers, has $($kt.Triggers.Count)" }
$xml = Export-ScheduledTask -TaskName 'BasaPOS-Keeper'
if ($xml -notmatch 'PT5M')                               { throw 'repetition interval PT5M missing from task XML' }
if ($xml -notmatch 'IgnoreNew')                          { throw 'MultipleInstances IgnoreNew missing from task XML' }
if (-not (Get-Process -Name 'BasaPOS.Keeper' -ErrorAction SilentlyContinue)) { throw 'keeper process not running' }
if (-not (Test-Path "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\BasaPOS.lnk")) { throw 'start menu link missing' }
if (-not (Test-Path C:\BasaPOS\bin\basapos.ico))         { throw 'shortcut icon missing' }
```

- [ ] **Step 2: `drill-reinstall.ps1`** — append upgrade-path assertions:

```powershell
$keepers = @(Get-Process -Name 'BasaPOS.Keeper' -ErrorAction SilentlyContinue)
if ($keepers.Count -ne 1) { throw "expected exactly 1 keeper after reinstall, found $($keepers.Count)" }
$kt = Get-ScheduledTask -TaskName 'BasaPOS-Keeper'
if ($kt.Triggers.Count -ne 2) { throw 'keeper task lost a trigger on reinstall' }
if ($kt.State -ne 'Running' -and $kt.State -ne 'Ready') { throw "unexpected keeper task state $($kt.State)" }
```

- [ ] **Step 3: `drill-uninstall.ps1`** — REPLACE the `boot.cmd` absence assertion with the fuller block:

```powershell
if (Test-Path C:\ProgramData\BasaPOS\boot.cmd) { throw 'boot.cmd left' }
if (Get-Process -Name 'BasaPOS.Keeper' -ErrorAction SilentlyContinue) { throw 'keeper process left' }
try { Get-ScheduledTask -TaskName 'BasaPOS-Keeper' -ErrorAction Stop; throw 'keeper task left' } catch { }
if (Test-Path "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\BasaPOS.lnk") { throw 'start menu link left' }
if (Test-Path C:\BasaPOS\bin) { throw 'bin dir left' }
if (-not (Test-Path C:\ProgramData\BasaPOS\install.log)) { throw 'install.log must survive in ProgramData by design' }
```

- [ ] **Step 4: Commit**

```bash
git add setup-gui/e2e/drill-install.ps1 setup-gui/e2e/drill-reinstall.ps1 setup-gui/e2e/drill-uninstall.ps1 && git commit -m "drills: keeper task/links/process assertions, ProgramData contract"
```

---

## Self-review

**1. Spec coverage (§v1.1 → tasks):**
- §3 keeper loop/backoff/mutex/watchdog/heartbeat/stderr/distro-retry → Tasks 3–5 ✓
- §3 exit codes 0/1/2 → Task 5 Program.cs ✓
- §3 Job Object → Task 4 ✓
- §4 TaskRegistrar v2 (stop-first, 2 triggers, principal, -Force, Start) → Task 6 ✓
- §4 ShortcutCreator (+ico copy, Terminal hide) → Task 8 ✓
- §4 compose verification-only → Task 11 ✓
- §4 uninstall order → Task 7 ✓
- §4 payload .ico committed → Task 1 ✓
- §4 BinDir → Task 7 (Paths.cs) ✓
- §5 matrix rows → asserted in Task 13 drills (respawn→reinstall drill kill? NOTE: no drill kills the keeper mid-run — the matrix's ≤5min watchdog path is asserted only via unit Backoff/repetition XML. Gap accepted: live kill-drill needs a stateful Windows box; CI drills are fresh-state. Documented here, not hidden.)
- §6 failure modes → unit (distro-retry, backoff, hang-stale) + drill (/end? NOT covered — add: Task 13 covers taskkill implicitly? No. ACCEPTED GAP: schtasks /end divergence and hang-simulation need a live box; unit + XML assertions are the CI-verifiable subset.)
- §7 tests → Tasks 3–9 unit + Task 13 drills + Task 11 guard ✓ (keeper test project named: `keeper.tests` ✓; seam named: `IProcessRunner` ✓)
- §8 retired → Task 10 (BootWrapper trim) + Task 7/8 (task/link removal) ✓
- §2 decisions → PowerPolicy (Task 9), single-account + Global mutex (Tasks 5–6), publish model (Task 2 csproj), ProgramData/install.log (Task 7 §7 assertion) ✓

**2. Placeholder scan:** no TBD/TODO/"appropriate handling" — every step has exact code/commands. One honest flag: Task 3's `Exited()` interface addition is called out inline with the exact edit (not "similar to…").

**3. Type consistency:** `KeeperLoop(runner, probe, sleep, log, clock)` signature identical in tests (Task 3) and Program (Task 5) ✓. `BuildRegisterScript(user, exe)` / `BuildDeleteScript()` signatures match tests ✓. `ShortcutCreator.Create(payloadDir)` matches orchestrator call ✓. `PowerPolicy.Apply(Action<string>?)` matches `ui.Status` (method group `Action<string>`) ✓. `KeeperProcess.ExePath`/`KillAll()`/`PathMatches` match tests + uninstaller ✓. `Paths.BinDir` used consistently ✓.
