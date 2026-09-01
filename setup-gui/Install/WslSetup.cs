namespace BasaPOS.Setup.Install;

public static class WslSetup
{
    public static void Ensure(Action<string> status, string payloadDir)
    {
        status("Checking WSL…");
        try
        {
            var probe = WslRunner.Wsl("--status", 30);
            if (probe.ExitCode == 0) { status("WSL: present"); return; }
            status($"WSL present but unhealthy (exit {probe.ExitCode}) — repairing");
        }
        catch (Exception)
        {
            // wsl.exe missing or hung → full install path below
        }

        status("Enabling VirtualMachinePlatform + WSL features…");
        var r = WslRunner.RunAnsi("dism.exe",
            "/online /enable-feature /featurename:VirtualMachinePlatform /all /norestart", 600);
        if (r.ExitCode != 0 && r.ExitCode != 3010)
            throw new InvalidOperationException($"dism VirtualMachinePlatform failed ({r.ExitCode}): {r.Error}");
        var r2 = WslRunner.RunAnsi("dism.exe",
            "/online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart", 600);
        if (r2.ExitCode != 0 && r2.ExitCode != 3010)
            throw new InvalidOperationException($"dism WSL feature failed ({r2.ExitCode}): {r2.Error}");

        var msi = Path.Combine(payloadDir, "wsl.msi");
        if (!File.Exists(msi))
            throw new InvalidOperationException($"wsl.msi missing in payload: {msi}");
        status("Installing pinned WSL 2.7.11…");
        var r3 = WslRunner.RunAnsi("msiexec.exe", $"/i \"{msi}\" /qn /norestart", 900);
        if (r3.ExitCode != 0 && r3.ExitCode != 3010)
            throw new InvalidOperationException($"WSL MSI install failed ({r3.ExitCode})");

        if (r.ExitCode == 3010 || r2.ExitCode == 3010 || r3.ExitCode == 3010)
            throw new RebootRequiredException();
    }
}

public sealed class RebootRequiredException : Exception
{
    public RebootRequiredException() : base(
        "Windows must REBOOT to finish WSL setup. After reboot, run BasaPOS-Setup.exe again — it will continue where it left off.") { }
}