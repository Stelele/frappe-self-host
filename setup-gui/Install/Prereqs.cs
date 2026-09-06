using System.Management;

namespace BasaPOS.Setup.Install;

public static class Prereqs
{
    public static void AssertAll(Action<string> status, string payloadDir)
    {
        status("Checking prerequisites...");
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

        var missing = MissingPayloadFiles(payloadDir);
        if (missing.Length > 0)
            throw new InvalidOperationException(
                $"Payload incomplete — missing in {payloadDir}:\n  " + string.Join("\n  ", missing) + "\n" +
                "Copy the full USB payload folder next to BasaPOS-Setup.exe and re-run.");

        // HypervisorPresent: a hypervisor is already running (Hyper-V/VBS).
        // VirtualizationFirmwareEnabled: VT-x/AMD-V on in BIOS (reads FALSE
        // under a running hypervisor) — hence the OR. Clean Win10 boxes with
        // VT enabled but no Hyper-V report only the latter.
        bool running = false, firmware = false;
        using (var searcher = new ManagementObjectSearcher(
            "SELECT HypervisorPresent FROM Win32_ComputerSystem"))
            foreach (var o in searcher.Get())
                running = (bool)o["HypervisorPresent"];
        using (var searcher = new ManagementObjectSearcher(
            "SELECT VirtualizationFirmwareEnabled FROM Win32_Processor"))
            foreach (var o in searcher.Get())
                if ((bool)o["VirtualizationFirmwareEnabled"]) firmware = true;
        if (running || firmware) { status("Virtualization: OK"); return; }
        throw new InvalidOperationException(
            "Hardware virtualization is disabled. Enable VT-x/AMD-V in BIOS, then re-run.");
    }

    internal static string[] MissingPayloadFiles(string payloadDir)
    {
        var missing = new List<string>();
        if (!Directory.Exists(payloadDir) ||
            !Directory.GetFiles(payloadDir, "basapos-distro.tar.part-*").Any())
            missing.Add("basapos-distro.tar.part-*");
        foreach (var f in new[] { "BasaPOS.Keeper.exe", "basapos.ico" })
            if (!File.Exists(Path.Combine(payloadDir, f))) missing.Add(f);
        return missing.ToArray();
    }
}