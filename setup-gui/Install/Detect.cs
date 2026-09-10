namespace BasaPOS.Setup.Install;

public static class Detect
{
    /// Installed ⇔ the WSL vhdx exists under the distro dir. File-based on
    /// purpose: parsing `wsl --list` output used to be encoding-fragile. Since
    /// WslRunner forces WSL_UTF8=1 the parse is deterministic, but the file
    /// probe stays the cheapest "deployed" signal for install/reinstall UX.
    public static bool IsInstalled() =>
        File.Exists(Path.Combine(Paths.DistroDir, "ext4.vhdx"));

    /// True when this name refers to our distro (covers the shipped name plus
    /// any variant registrations left by botched/partial imports). Single
    /// source of truth for unregister targeting and post-unregister checks.
    public static bool IsBasaPOSName(string? name) =>
        !string.IsNullOrWhiteSpace(name)
        && name.Contains(Paths.DistroName, StringComparison.OrdinalIgnoreCase);

    /// Registered ⇔ `wsl --list --quiet` still names our distro. This is the
    /// truth used to decide whether unregister actually worked — the file
    /// probe alone is wrong when a registration survives a deleted vhdx.
    public static bool IsRegistered() => WslRunner.ListDistros().Any(IsBasaPOSName);
}
