using System.Management;

namespace BasaPOS.Setup.Install;

public static class Prereqs
{
    public static void AssertAll(Action<string> status, string payloadDir)
    {
        status("Checking prerequisites…");
        var os = Environment.OSVersion;
        if (os.Version.Major < 10 || (os.Version.Major == 10 && os.Version.Build < 19044))
            throw new InvalidOperationException(
                $"Windows 10 19044+ required (you: {os.Version}).");

        var drive = Path.GetPathRoot(Paths.InstallRoot)!;
        var free = new DriveInfo(drive).AvailableFreeSpace;
        const long min = 25L * 1024 * 1024 * 1024;
        if (free < min)
            throw new InvalidOperationException(
                $"Need ≥25 GB free on {drive}, have {free / 1e9:F1} GB.");

        if (!Directory.Exists(payloadDir) ||
            !Directory.GetFiles(payloadDir, "basapos-distro.tar.part-*").Any())
            throw new InvalidOperationException(
                $"Payload not found.\nExpected: {payloadDir}\\basapos-distro.tar.part-*\n" +
                "Copy the full USB payload folder next to BasaPOS-Setup.exe and re-run.");

        using var searcher = new ManagementObjectSearcher(
            "SELECT HypervisorPresent FROM Win32_ComputerSystem");
        foreach (var o in searcher.Get())
            if ((bool)o["HypervisorPresent"]) { status("Virtualization: OK"); return; }
        throw new InvalidOperationException(
            "Hardware virtualization is disabled. Enable VT-x/AMD-V in BIOS, then re-run.");
    }
}