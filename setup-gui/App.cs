using BasaPOS.Setup.Install;

namespace BasaPOS.Setup;

public static class App
{
    /// Unattended entry: --install / --uninstall [--unattended] [--payload DIR]
    /// Exit codes: 0 ok · 1 fatal · 3 install finished but never healthy · 4 reboot required
    public static int RunUnattended(bool install, string[] args)
    {
        var logFile = Path.Combine(Path.GetTempPath(), "basapos-setup.log");
        using var log = new StreamWriter(logFile, append: false) { AutoFlush = true };
        void Say(string s)
        {
            log.WriteLine($"[{DateTime.Now:HH:mm:ss}] {s}");
            Console.WriteLine(s);
        }
        var ui = new UnattendedUi(Say);
        try
        {
            if (install)
            {
                new InstallOrchestrator(ui).RunAll(PayloadFrom(args));
                if (ui.RebootNeeded) return 4;
                return ui.Healthy ? 0 : 3;
            }
            new Uninstaller(ui).Run(keepBackups: true);
            return 0;
        }
        catch (Exception ex)
        {
            Say($"FATAL: {ex.Message}");
            log.WriteLine(ex.ToString());
            return 1;
        }
    }

    static string PayloadFrom(string[] args)
    {
        var i = Array.IndexOf(args, "--payload");
        return i >= 0 && i + 1 < args.Length ? args[i + 1]
            : Path.Combine(AppContext.BaseDirectory, "payload");
    }
}
