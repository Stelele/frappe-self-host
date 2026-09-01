namespace BasaPOS.Setup.Install;

public sealed class Uninstaller(ISetupUi ui)
{
    public void Run() => Run(keepBackups: true);

    public void Run(bool keepBackups)
    {
        ui.Status("Unregistering distro…");
        WslRunner.Wsl($"--unregister {Paths.DistroName}", 300);
        if (Detect.IsInstalled())
        {
            // real failure (not mere absence): WSL busy or AV lock on ext4.vhdx —
            // deleting C:\BasaPOS now would half-remove and leave a locked vhdx
            ui.Status("Unregister incomplete — retrying after wsl --shutdown…");
            WslRunner.Wsl("--shutdown", 120);
            WslRunner.Wsl($"--unregister {Paths.DistroName}", 300);
        }
        if (Detect.IsInstalled())
            throw new InvalidOperationException(
                "Could not unregister the BasaPOS distro (WSL busy or antivirus lock). " +
                "Reboot the machine and run Uninstall again.");
        ui.Status("Removing autostart task…");
        TaskRegistrar.Delete();
        BootWrapper.Delete();
        ui.Status("Removing hosts entry…");
        HostsFile.Remove();
        ui.Status("Removing .wslconfig keys…");
        WslConfig.RemoveManagedBlock();
        ui.Status("Untrusting certificate…");
        CertTrust.UntrustAllBasaPOS();
        ui.Status(keepBackups ? "Keeping C:\\BasaPOS\\backups …" : "Full removal…");
        foreach (var d in new[] { Paths.DistroDir, Paths.ConfigDir, Paths.LogsDir })
            if (Directory.Exists(d)) Directory.Delete(d, recursive: true);
        if (!keepBackups && Directory.Exists(Paths.InstallRoot))
            Directory.Delete(Paths.InstallRoot, recursive: true);
        else if (Directory.Exists(Paths.InstallRoot) &&
                 !Directory.EnumerateFileSystemEntries(Paths.InstallRoot).Any())
            Directory.Delete(Paths.InstallRoot);
        ui.Status("Uninstall complete.");
    }
}
