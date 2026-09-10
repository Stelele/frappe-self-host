using Microsoft.Win32;

namespace BasaPOS.Setup.Install;

/// Last-resort cure for distros wsl.exe won't unregister: delete the Lxss
/// registration key directly. WSL registrations are HKCU
/// Software\Microsoft\Windows\CurrentVersion\Lxss\{GUID} keys whose
/// DistributionName value names the distro. Registry-only — never touches
/// DefaultDistribution or foreign distros.
public static class DistroRegistration
{
    const string LxssRoot = @"Software\Microsoft\Windows\CurrentVersion\Lxss";
    const string ValueName = "DistributionName";

    /// HKCU\...\Lxss\{GUID} paths for every key naming a BasaPOS variant.
    /// Empty on non-Windows and when WSL has no Lxss hive.
    public static IReadOnlyList<string> FindLxssKeys()
    {
        var result = new List<string>();
        if (!OperatingSystem.IsWindows()) return result;
        try
        {
            using var lxss = Registry.CurrentUser.OpenSubKey(LxssRoot);
            if (lxss is null) return result;
            foreach (var sub in lxss.GetSubKeyNames())
            {
                try
                {
                    using var key = lxss.OpenSubKey(sub);
                    if (Matches(key?.GetValue(ValueName) as string))
                        result.Add($@"HKCU\{LxssRoot}\{sub}");
                }
                catch { /* unreadable key — leave it */ }
            }
        }
        catch { /* Lxss hive absent */ }
        return result;
    }

    /// Deletes one Lxss {GUID} subkey (path as produced by FindLxssKeys).
    /// True when the key is gone afterwards. Registry ops never involve WSL,
    /// so they work even when wsl.exe itself (elevated or not) cannot.
    public static bool DeleteKey(string keyPath)
    {
        if (!OperatingSystem.IsWindows()) return false;
        var leaf = keyPath.Split('\\').LastOrDefault();
        if (string.IsNullOrWhiteSpace(leaf)) return false;
        try
        {
            using var lxss = Registry.CurrentUser.OpenSubKey(LxssRoot, writable: true);
            if (lxss is null) return false;
            using (lxss.OpenSubKey(leaf)) { } // presence probe — avoid deleting a guess
            if (lxss.OpenSubKey(leaf) is null) return true; // already gone
            lxss.DeleteSubKeyTree(leaf, throwOnMissingSubKey: false);
            return lxss.OpenSubKey(leaf) is null;
        }
        catch
        {
            return false;
        }
    }

    /// Pure name matcher — the only piece tests feed without a real hive.
    internal static bool Matches(string? distributionName) =>
        string.IsNullOrWhiteSpace(distributionName) is false
        && distributionName.Contains(Paths.DistroName, StringComparison.OrdinalIgnoreCase);
}