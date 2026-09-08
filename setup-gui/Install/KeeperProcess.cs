using System.Diagnostics;

namespace BasaPOS.Setup.Install;

/// Finds/kills the keeper by EXE PATH (never bare name — taskkill /IM
/// matches by name only and could hit an unrelated process).
internal static class KeeperProcess
{
    public static string ExePath =>
        Path.Combine(Paths.BinDir, "BasaPOS.Keeper.exe").Replace(Path.DirectorySeparatorChar, '\\');

    // Normalizes separators so the Linux-CI build (forward slashes) tests
    // the same contract; identity transformation on Windows.
    internal static bool PathMatches(string? actual, string expected) =>
        string.Equals(Normalize(actual), Normalize(expected), StringComparison.OrdinalIgnoreCase);

    static string? Normalize(string? p) => p?.Trim().TrimEnd('\\').Replace('\\', '/');

    /// Kills all keeper instances and WAITS (bounded). Throws a clear,
    /// actionable error if one survives — callers must fail BEFORE
    /// irreversible uninstall steps, never delete bin/ under a live exe.
    public static void KillAll()
    {
        foreach (var p in Process.GetProcessesByName("BasaPOS.Keeper"))
        {
            using (p)
            {
                bool ours;
                try { ours = PathMatches(p.MainModule?.FileName, ExePath); }
                catch { ours = true; } // unreadable module of OUR unique name → assume ours
                if (!ours) continue;
                try { if (!p.HasExited) p.Kill(entireProcessTree: true); } catch { /* already gone */ }
                try
                {
                    if (!p.WaitForExit(5000) || !p.HasExited)
                        throw new InvalidOperationException(
                            "Could not stop the BasaPOS keeper process. Reboot the machine and run Uninstall again.");
                }
                catch (InvalidOperationException) { throw; }
                catch { /* exited during wait — desired end state */ }
            }
        }
    }
}