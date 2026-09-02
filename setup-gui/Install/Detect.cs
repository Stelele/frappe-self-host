namespace BasaPOS.Setup.Install;

public static class Detect
{
    /// Installed ⇔ the WSL vhdx exists under the distro dir. File-based on
    /// purpose: parsing `wsl --list` output is encoding-fragile (wsl.exe emits
    /// UTF-16 unless WSL_UTF8=1, which the CI drill sets and the installer
    /// inherits via Start-Process — garbling WslRunner's UTF-16 decode).
    public static bool IsInstalled() =>
        File.Exists(Path.Combine(Paths.DistroDir, "ext4.vhdx"));
}
