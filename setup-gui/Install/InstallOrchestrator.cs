using System.Runtime.InteropServices;

namespace BasaPOS.Setup.Install;

public sealed class InstallOrchestrator(ISetupUi ui)
{
    public void RunAll() => RunAll(null);

    public void RunAll(string? payloadDirOverride)
    {
        var payload = payloadDirOverride
            ?? Path.Combine(AppContext.BaseDirectory, "payload");

        Prereqs.AssertAll(ui.Status, payload);                          // 1

        try { WslSetup.Ensure(ui.Status, payload); }                    // 2
        catch (RebootRequiredException e)
        {
            ui.ShowReboot(e.Message);
            return;
        }

        var tar = PartStitcher.StitchAndVerify(payload, ui.Progress);   // 3

        ui.Status("Importing distro…");                                 // 4
        Directory.CreateDirectory(Paths.DistroDir);
        WslRunner.Wsl($"--import {Paths.DistroName} \"{Paths.DistroDir}\" \"{tar}\" --version 2",
            1800, l => ui.Status("  " + l));
        File.Delete(tar);

        ui.Status("Writing credentials…");                              // 5
        var pw = Credentials.Generate(16, Random.Shared);
        Directory.CreateDirectory(Paths.ConfigDir);
        Directory.CreateDirectory(Paths.LogsDir);
        Directory.CreateDirectory(Paths.BackupsDir);
        Credentials.WriteInstallPassword(pw);
        File.WriteAllText(Path.Combine(Paths.ConfigDir, "settings.txt"), "LAN_MODE=false\n");

        ui.Status("Configuring WSL memory + hosts…");                   // 6
        var ramGiB = MemoryGB();
        WslConfig.Write(Math.Clamp(ramGiB / 2, 4, 8) * 1024L * 1024 * 1024);
        HostsFile.Ensure();

        ui.Status("Registering autostart…");                            // 7
        BootWrapper.Write();
        TaskRegistrar.Register();

        ui.Status("First boot: loading images + creating site (5-15 min)…"); // 8
        WslRunner.Wsl($"-d {Paths.DistroName} --exec /bin/true", 300);
        var ok = HealthPoller.WaitHealthy(s => ui.Status("  " + s)).GetAwaiter().GetResult();

        ui.Status("Trusting certificate…");                             // 9
        var cert = Path.Combine(Paths.ConfigDir, "basapos.crt");
        if (File.Exists(cert)) CertTrust.Trust(cert);

        File.WriteAllText(Path.Combine(Paths.ConfigDir, "version.txt"), VersionFor(payload) + "\n");

        if (ok)
        {
            ui.Healthy = true;
            ui.ShowDone(pw);
        }
        else
        {
            ui.Status("Site did not become healthy in 15 min. Re-run Setup to retry, " +
                      "or Uninstall + Install fresh.");
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    struct MEMORYSTATUSEX
    {
        public uint dwLength, dwMemoryLoad;
        public ulong ullTotalPhys, ullAvailPhys, ullTotalPageFile, ullAvailPageFile,
            ullTotalVirtual, ullAvailVirtual, ullAvailExtendedVirtual;
    }

    [DllImport("kernel32.dll")]
    static extern bool GlobalMemoryStatusEx(ref MEMORYSTATUSEX buffer);

    static long MemoryGB()
    {
        var m = new MEMORYSTATUSEX { dwLength = (uint)Marshal.SizeOf<MEMORYSTATUSEX>() };
        GlobalMemoryStatusEx(ref m);
        return (long)(m.ullTotalPhys / (1024L * 1024 * 1024));
    }

    static string VersionFor(string payload)
    {
        var sums = Path.Combine(payload, "SHA256SUMS");
        if (!File.Exists(sums)) return "dev";
        var hash = PartStitcher.ParseSums(sums).GetValueOrDefault("basapos-distro.tar.gz", "unknown");
        return DateTime.UtcNow.ToString("yyyy-MM-dd") + "+" + (hash.Length >= 8 ? hash[..8] : hash);
    }
}
