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

        ui.Status("Importing distro...");                                 // 4
        Directory.CreateDirectory(Paths.DistroDir);
        var imp = WslRunner.Wsl($"--import {Paths.DistroName} \"{Paths.DistroDir}\" \"{tar}\" --version 2",
            1800, l => ui.Status("  " + l));
        if (imp.ExitCode != 0)
            throw new InvalidOperationException(
                $"wsl --import failed (exit {imp.ExitCode}).\n{imp.Output}\n{imp.Error}");
        File.Delete(tar);

        ui.Status("Writing credentials...");                              // 5
        var pw = Credentials.Generate(16, Random.Shared);
        Directory.CreateDirectory(Paths.ConfigDir);
        Directory.CreateDirectory(Paths.LogsDir);
        Directory.CreateDirectory(Paths.BackupsDir);
        Credentials.WriteInstallPassword(pw);
        File.WriteAllText(Path.Combine(Paths.ConfigDir, "settings.txt"), "LAN_MODE=false\n");

        ui.Status("Configuring WSL memory + hosts...");                   // 6
        var ramGiB = MemoryGB();
        WslConfig.Write(Math.Clamp(ramGiB / 2, 4, 8) * 1024L * 1024 * 1024);
        HostsFile.Ensure();
        // .wslconfig is only read when the WSL2 VM next STARTS. If a VM is
        // already up (e.g. another distro), our vmIdleTimeout=-1 would not
        // apply and the VM idles out ~60s after the last wsl.exe client,
        // killing firstboot mid-docker-load. Force a full shutdown so the
        // first boot of BasaPOS reads the fresh config.
        try { WslRunner.Wsl("--shutdown", 60); } catch { /* no VM running yet */ }

        ui.Status("Registering autostart...");                            // 7
        BootWrapper.Write();
        TaskRegistrar.Register();

        ui.Status("First boot: loading images + creating site (5-15 min)..."); // 8
        var boot = WslRunner.Wsl($"-d {Paths.DistroName} --exec /bin/true", 300);
        if (boot.ExitCode != 0)
            throw new InvalidOperationException(
                $"Could not start the BasaPOS distro (exit {boot.ExitCode}).\n{boot.Output}\n{boot.Error}");

        // Hold the WSL VM open for the whole poll: one long-lived wsl.exe
        // session keeps the VM from idling out (idle = no connected client)
        // and killing firstboot mid-docker-load. vmIdleTimeout=-1 covers
        // steady-state runtime; this keeper bridges the install window.
        using var keeper = VmKeeper.Start();
        var ok = HealthPoller.WaitHealthy(s => ui.Status("  " + s), maxMinutes: 30).GetAwaiter().GetResult();

        ui.Status("Trusting certificate...");                             // 9
        var cert = Path.Combine(Paths.ConfigDir, "basapos.crt");
        // Reconcile first: prior installs/runs may have left STALE basapos certs
        // (each firstboot generates a unique CN), and a timed-out/crashed install
        // may never have imported the current one. Remove all, trust current —
        // so the store holds exactly what traefik serves.
        CertTrust.UntrustAllBasaPOS();
        if (File.Exists(cert)) CertTrust.Trust(cert);

        File.WriteAllText(Path.Combine(Paths.ConfigDir, "version.txt"), VersionFor(payload) + "\n");

        if (ok)
        {
            // Browser-path gate: the certificate must now validate against the
            // Windows trust store (what Chrome/Edge use), not just our pin —
            // otherwise a real browser warns/fails even though the appliance is
            // healthy on the inside.
            var browserOk = HealthPoller.VerifyBrowserTrusted(s => ui.Status("  " + s))
                .GetAwaiter().GetResult();
            if (browserOk)
            {
                ui.Healthy = true;
                ui.ShowDone(pw);
            }
            else
            {
                ui.Status("Site is up but the certificate is NOT trusted by Windows. " +
                          "A browser will show a warning. Re-run Setup, or import " +
                          cert + " into Trusted Root Certification Authorities.");
            }
        }
        else
        {
            ui.Status("Site did not become healthy in 30 min. Re-run Setup to retry, " +
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
