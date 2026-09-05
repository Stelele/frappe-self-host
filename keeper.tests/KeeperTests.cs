using BasaPOS.Keeper;
using Xunit;

sealed class FakeChild(int exitCode, string stderr = "") : IChildProcess
{
    public int Pid => 4242;
    public int ExitCode => exitCode;
    public string StderrTail => stderr;
    public bool Exited() => true;
    public int WaitForExit(int msTimeout) => 0; // exits immediately
    public void KillTree() { }
    public void Dispose() { }
}

sealed class FakeRunner : IProcessRunner
{
    public Queue<IChildProcess> Children = new();
    public List<string> DistroList = new() { "BasaPOS" };
    public int SpawnCount;
    public IChildProcess SpawnWslKeepalive()
    {
        SpawnCount++;
        return Children.Count > 0 ? Children.Dequeue() : new FakeChild(0);
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
        // DETERMINISTIC: the fake sleep cancels after 2 recorded sleeps.
        // (A record-only sleep never delays, so a wall-clock CTS lets the
        // loop spin unboundedly — SpawnCount would be nondeterministic.)
        using var cts = new CancellationTokenSource();
        var r = new FakeRunner();
        r.Children.Enqueue(new FakeChild(1, "transient hcs error"));
        r.Children.Enqueue(new FakeChild(0));
        var sleeps = new List<TimeSpan>();
        var loop = new KeeperLoop(r, new FakeProbe(true),
            ts => { sleeps.Add(ts); if (sleeps.Count >= 2) cts.Cancel(); },
            _ => { }, () => DateTime.UtcNow);
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

    [Fact]
    public void ParseDistroNames_trims_and_drops_blanks()
    {
        var names = ProcessRunner.ParseDistroNames("BasaPOS\r\nUbuntu\r\n\r\n");
        Assert.Equal(new[] { "BasaPOS", "Ubuntu" }, names);
    }

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
}
