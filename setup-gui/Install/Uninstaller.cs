namespace BasaPOS.Setup.Install;

public sealed class Uninstaller(ISetupUi ui)
{
    public void Run() => Run(keepBackups: true, purge: false);

    public void Run(bool keepBackups) => Run(keepBackups, purge: false);

    /// <param name="keepBackups">preserve C:\BasaPOS\backups (and v2 backups)</param>
    /// <param name="purge">also unregister ALL WSL distros (not just BasaPOS)
    /// and delete the entire .wslconfig (backed up first). Opt-in blank slate
    /// for test machines — never the default.</param>
    public void Run(bool keepBackups, bool purge)
    {
        ui.Status("Unregistering distro...");
        UnregisterBasaPOS();
        if (purge)
            PurgeAllDistros();
        ui.Status("Removing autostart task...");
        TaskRegistrar.Delete();
        BootWrapper.Delete();
        ui.Status("Removing hosts entry...");
        HostsFile.Remove();
        if (purge)
        {
            ui.Status("Purge: removing entire .wslconfig (backed up)...");
            PurgeWslConfig(ui);
        }
        else
        {
            ui.Status("Removing .wslconfig keys...");
            var leftovers = WslConfig.RemoveManagedBlock();
            if (!string.IsNullOrEmpty(leftovers))
                ui.Status("NOTE: .wslconfig still contains non-BasaPOS keys left untouched:\n" + leftovers +
                          "\nIf WSL reports config errors, delete or fix %USERPROFILE%\\.wslconfig manually.");
        }
        ui.Status("Removing v2 install dir (if present)...");
        RemoveLegacyV2Dir(ui, keepBackups);
        ui.Status("Untrusting certificate...");
        CertTrust.UntrustAllBasaPOS();
        ui.Status(keepBackups ? "Keeping C:\\BasaPOS\\backups ..." : "Full removal...");
        foreach (var d in new[] { Paths.DistroDir, Paths.ConfigDir, Paths.LogsDir })
            if (Directory.Exists(d)) Directory.Delete(d, recursive: true);
        if (!keepBackups && Directory.Exists(Paths.InstallRoot))
            Directory.Delete(Paths.InstallRoot, recursive: true);
        else if (Directory.Exists(Paths.InstallRoot) &&
                 !Directory.EnumerateFileSystemEntries(Paths.InstallRoot).Any())
            Directory.Delete(Paths.InstallRoot);
        ui.Status("Uninstall complete.");
    }

    /// v2 (Inno Setup) installed to %LOCALAPPDATA%\Programs\BasaPOS — a different
    /// path from v3's C:\BasaPOS. If a v2 tree lingers (partial uninstall, manual
    /// delete), remove it so a fresh v3 install starts clean. Only touches the
    /// exact v2 dir (never user files elsewhere); preserves its backups subdir
    /// unless this is a full (!keepBackups) removal.
    static void RemoveLegacyV2Dir(ISetupUi ui, bool keepBackups)
    {
        var v2dir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "Programs", "BasaPOS");
        if (!Directory.Exists(v2dir)) return;
        // sanity: only treat it as ours if it has v2 markers
        bool looksLikeV2 = File.Exists(Path.Combine(v2dir, "BasaPOS.exe"))
            || Directory.Exists(Path.Combine(v2dir, "rootfs"))
            || Directory.Exists(Path.Combine(v2dir, "payload"));
        if (!looksLikeV2)
        {
            ui.Status($"NOTE: unexpected dir left untouched (not a v2 install): {v2dir}");
            return;
        }
        var v2backups = Path.Combine(v2dir, "backups");
        if (keepBackups && Directory.Exists(v2backups))
        {
            var dest = Path.Combine(Paths.BackupsDir, "v2-legacy");
            Directory.CreateDirectory(Paths.BackupsDir);
            if (Directory.Exists(dest)) Directory.Delete(dest, recursive: true);
            Directory.Move(v2backups, dest);
            ui.Status($"Preserved v2 backups at {dest}");
        }
        Directory.Delete(v2dir, recursive: true);
        ui.Status("Removed legacy v2 install dir.");
    }

    /// Unregisters BasaPOS plus any name-variant (e.g. partial states), with
    /// shutdown-retry. Strict: throws if BasaPOS itself survives.
    void UnregisterBasaPOS()
    {
        var targets = WslRunner.ListDistros()
            .Where(d => d.Equals(Paths.DistroName, StringComparison.OrdinalIgnoreCase)
                     || d.Contains("basapos", StringComparison.OrdinalIgnoreCase))
            .ToList();
        if (targets.Count == 0)
        {
            // fall back to direct unregister (covers vhdx-present-but-unlisted edge)
            WslRunner.Wsl($"--unregister {Paths.DistroName}", 300);
        }
        else foreach (var name in targets)
        {
            if (!name.Equals(Paths.DistroName, StringComparison.OrdinalIgnoreCase))
                ui.Status($"Removing variant distro: {name}");
            WslRunner.Wsl($"--unregister \"{name}\"", 300);
        }
        if (Detect.IsInstalled())
        {
            // real failure (not mere absence): WSL busy or AV lock on ext4.vhdx —
            // deleting C:\BasaPOS now would half-remove and leave a locked vhdx
            ui.Status("Unregister incomplete — retrying after wsl --shutdown...");
            WslRunner.Wsl("--shutdown", 120);
            WslRunner.Wsl($"--unregister \"{Paths.DistroName}\"", 300);
        }
        if (Detect.IsInstalled())
            throw new InvalidOperationException(
                "Could not unregister the BasaPOS distro (WSL busy or antivirus lock). " +
                "Reboot the machine and run Uninstall again.");
    }

    /// Purge mode: unregister EVERY distro (best-effort per distro, strict only
    /// for BasaPOS which UnregisterBasaPOS already handled). Collect failures
    /// and report — one stuck foreign distro must not abort the whole purge.
    void PurgeAllDistros()
    {
        WslRunner.Wsl("--shutdown", 120);
        var failures = new List<string>();
        foreach (var name in WslRunner.ListDistros())
        {
            try
            {
                WslRunner.Wsl($"--unregister \"{name}\"", 300);
                ui.Status($"Purged distro: {name}");
            }
            catch (Exception ex)
            {
                failures.Add($"{name} ({ex.Message})");
            }
        }
        // re-check BasaPOS specifically (strict); others are best-effort
        if (Detect.IsInstalled())
            throw new InvalidOperationException(
                "Purge could not remove the BasaPOS distro. Reboot and run Uninstall again.");
        if (failures.Count > 0)
            ui.Status("NOTE: these distros could not be purged (left in place):\n" +
                      string.Join("\n", failures));
    }

    /// Purge mode: back up .wslconfig then delete it entirely.
    static void PurgeWslConfig(ISetupUi ui)
    {
        var path = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".wslconfig");
        if (!File.Exists(path)) return;
        var bak = path + ".basapos-bak";
        try { File.Copy(path, bak, overwrite: true); }
        catch (Exception ex)
        {
            ui.Status($"WARNING: could not back up .wslconfig ({ex.Message}) — leaving it in place.");
            return;
        }
        File.Delete(path);
        ui.Status($"Deleted .wslconfig entirely (backup at {bak}).");
    }
}
