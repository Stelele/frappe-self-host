using BasaPOS.Setup.Install;

namespace BasaPOS.Setup;

public static class App
{
    /// Unattended entry: --install / --uninstall [--unattended] [--payload DIR] [--purge]
    /// --purge (uninstall only): also unregister ALL WSL distros and delete the
    /// entire .wslconfig (backed up). Opt-in blank slate for test machines.
    /// Exit codes: 0 ok · 1 fatal · 3 install finished but never healthy · 4 reboot required
    public static int RunUnattended(bool install, string[] args)
    {
        // Fixed, CI-capturable log location. Must NOT be under C:\BasaPOS:
        // the reinstall path uninstalls first, which deletes C:\BasaPOS\logs —
        // and an open log file inside it would abort the delete. ProgramData
        // survives uninstall and is reachable by both the elevated installer
        // and the non-elevated drill/CI.
        Directory.CreateDirectory(Paths.ProgramData);
        var logFile = Path.Combine(Paths.ProgramData, "install.log");
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
                // reinstall semantics: an existing distro makes `wsl --import`
                // collide — uninstall first (matches MainForm's reinstall path)
                if (Detect.IsInstalled())
                {
                    Say("Existing installation detected — uninstalling before reinstall…");
                    new Uninstaller(ui).Run(keepBackups: true);
                }
                new InstallOrchestrator(ui).RunAll(PayloadFrom(args));
                if (ui.RebootNeeded) return 4;
                return ui.Healthy ? 0 : 3;
            }
            new Uninstaller(ui).Run(keepBackups: true, purge: args.Contains("--purge"));
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
