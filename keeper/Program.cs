using BasaPOS.Keeper;

using var mutex = new Mutex(false, @"Global\BasaPOS.Keeper", out bool createdNew);
if (!createdNew) return 0; // watchdog fired while alive — exit clean

var logPath = Path.Combine(@"C:\BasaPOS\logs", "keeper.log");
var blog = new HeartbeatLog(logPath);
Action<string> log = m => blog.Write(m);
var markerPath = Path.Combine(@"C:\BasaPOS\logs", "keeper-crashloop.marker");
Action<string> onCrash = m => { try { File.WriteAllText(markerPath, $"[{DateTime.UtcNow:yyyy-MM-dd HH:mm:ss}] {m}\n"); } catch { } log("MARKER: " + m); };
var loop = new KeeperLoop(new ProcessRunner(), new SiteProbe(), Thread.Sleep, log, () => DateTime.UtcNow, onCrash);
var watchdog = new Thread(() =>
{
    while (true)
    {
        Thread.Sleep(10_000);
        if (KeeperLoop.IsStale(loop.LastTick, DateTime.UtcNow))
        {
            // Bound the breadcrumb: a wedged filesystem must not wedge the
            // watchdog — FailFast below must ALWAYS run.
            try
            {
                var t = Task.Run(() => { try { blog.Write("WATCHDOG: main loop stalled — FailFast"); } catch { } });
                t.Wait(2000);
            }
            catch { }
            Environment.FailFast("BasaPOS.Keeper main loop stalled");
        }
    }
}) { IsBackground = true };
watchdog.Start();
try { loop.Run(CancellationToken.None); return 0; }
catch (FatalKeeperException ex) { log("FATAL: " + ex.Message); return 1; }
catch (Exception ex) { log("UNEXPECTED: " + ex); return 2; }
