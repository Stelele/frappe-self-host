using BasaPOS.Keeper;

using var mutex = new Mutex(false, @"Global\BasaPOS.Keeper", out bool createdNew);
if (!createdNew) return 0; // watchdog fired while alive — exit clean

var logPath = Path.Combine(@"C:\BasaPOS\logs", "keeper.log");
var blog = new HeartbeatLog(logPath);
Action<string> log = m => blog.Write(m);
var loop = new KeeperLoop(new ProcessRunner(), new SiteProbe(), Thread.Sleep, log, () => DateTime.UtcNow);
var watchdog = new Thread(() =>
{
    while (true)
    {
        Thread.Sleep(10_000);
        if (KeeperLoop.IsStale(loop.LastTick, DateTime.UtcNow))
        {
            // on-disk breadcrumb: FailFast itself leaves no log line, and the
            // WER/EventViewer trail is hard to reach over a phone call
            try { blog.Write("WATCHDOG: main loop stalled — FailFast"); } catch { }
            Environment.FailFast("BasaPOS.Keeper main loop stalled");
        }
    }
}) { IsBackground = true };
watchdog.Start();
try { loop.Run(CancellationToken.None); return 0; }
catch (FatalKeeperException ex) { log("FATAL: " + ex.Message); return 1; }
catch (Exception ex) { log("UNEXPECTED: " + ex); return 2; }
