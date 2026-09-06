namespace BasaPOS.Keeper;

public sealed class KeeperLoop(
    IProcessRunner runner,
    ISiteProbe probe,
    Action<TimeSpan> sleep,
    Action<string> log,
    Func<DateTime> clock,
    Action<string>? onCrashLoop = null)
{
    public DateTime LastTick { get; private set; } = clock();

    internal static TimeSpan Backoff(int consecutiveFailures) =>
        TimeSpan.FromSeconds(Math.Min(60, 5 * (1 << Math.Min(consecutiveFailures, 4))));

    internal static bool IsStale(DateTime lastTick, DateTime now) =>
        now - lastTick > TimeSpan.FromSeconds(120);

    /// Runs until cancelled (returns) or the distro is proven missing (throws FatalKeeperException).
    public void Run(CancellationToken ct)
    {
        int failures = 0, missingStreak = 0, fastExits = 0, downStreak = 0;
        while (!ct.IsCancellationRequested)
        {
            LastTick = clock();
            var spawnedAt = clock();
            using var child = runner.SpawnWslKeepalive();
            log($"keeper: spawned wsl child pid={child.Pid}");
            child.WaitForExit(60_000);
            if (ct.IsCancellationRequested) return;
            var exitedAt = clock();
            bool up;
            try { up = probe.ProbeAsync(ct).GetAwaiter().GetResult(); }
            catch { up = false; }
            log(up ? "probe: SITE-UP" : "probe: SITE-DOWN (VM alive, site not responding)");
            LastTick = clock();
            if (up)
                downStreak = 0;
            else
            {
                downStreak++;
                if (downStreak == 3)
                {
                    var diag = runner.RunWslDiag("-d BasaPOS -u root --exec systemctl is-active docker docker.socket");
                    log($"diag: docker services: {diag}");
                }
            }
            if (child.Exited())
            {
                log($"keeper: child pid={child.Pid} exited {child.ExitCode} stderr={child.StderrTail}");
                var lifetime = exitedAt - spawnedAt;
                if (lifetime < TimeSpan.FromSeconds(10))
                    fastExits++;
                else
                    fastExits = 0;
                if (fastExits == 5)
                    onCrashLoop?.Invoke($"crash-loop: {fastExits} consecutive fast child exits; last exit {child.ExitCode} stderr={child.StderrTail}");
                if (!runner.ListDistros().Any(d => d.Equals("BasaPOS", StringComparison.OrdinalIgnoreCase)))
                {
                    missingStreak++;
                    log($"keeper: distro not listed ({missingStreak}/6)");
                    sleep(TimeSpan.FromSeconds(30));
                    if (missingStreak >= 6)
                        throw new FatalKeeperException("Distro 'BasaPOS' missing after 6x30s retries — not transient.");
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
