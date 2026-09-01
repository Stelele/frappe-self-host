namespace BasaPOS.Setup.Install;

/// Headless ISetupUi for CI drills and technician CLI runs.
public sealed class UnattendedUi(Action<string> log) : ISetupUi
{
    public bool Healthy { get; set; }
    public bool RebootNeeded { get; set; }
    public void Status(string line) => log(line);
    public void Progress(int pct) => log($"[progress] {pct}%");
    public void ShowDone(string password) { Healthy = true; log($"DONE password={password}"); }
    public void ShowReboot(string message) { RebootNeeded = true; log($"REBOOT_REQUIRED {message}"); }
}
