using System.Diagnostics;

namespace BasaPOS.Setup.Install;

/// Finds/kills the keeper by EXE PATH (never bare name — taskkill /IM
/// matches by name only and could hit an unrelated process).
internal static class KeeperProcess
{
    public static string ExePath => Path.Combine(Paths.BinDir, "BasaPOS.Keeper.exe")
        .Replace(Path.DirectorySeparatorChar, '\\');

    internal static bool PathMatches(string? actual, string expected) =>
        string.Equals(Normalize(actual), Normalize(expected), StringComparison.OrdinalIgnoreCase);

    static string? Normalize(string? p) => p?.Trim().TrimEnd('\\').Replace('\\', '/');

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