using System.Diagnostics;

namespace BasaPOS.Setup.Install;

/// Single unregister result: Ok + diagnostics text for the ladder report.
internal sealed record UnregisterAttempt(bool Ok, string Error);

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
        ui.Status("Stopping keeper task...");
        TaskRegistrar.Delete();                       // stops instances, then deletes all 3 names
        ui.Status("Killing keeper process...");
        KeeperProcess.KillAll();
        var staleLinks = ShortcutCreator.Remove();
        if (staleLinks.Length > 0)
            ui.Status("NOTE: could not remove shortcut(s), delete manually:\n" + string.Join("\n", staleLinks));
        ui.Status("Shutting down WSL...");
        ui.Status("NOTE: this briefly stops ALL WSL distros (including unrelated ones like docker-desktop).");
        try { WslRunner.Wsl("--shutdown", 120); } catch { }
        ui.Status("Unregistering distro...");
        UnregisterBasaPOS();
        if (purge)
            PurgeAllDistros();
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
        foreach (var d in new[] { Paths.DistroDir, Paths.ConfigDir, Paths.LogsDir, Paths.BinDir })
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

    /// Unregisters BasaPOS plus any name-variant (e.g. partial states).
    /// Ladder: elevated wsl --unregister → unelevated (LIMITED task) → raw
    /// Lxss registration-key removal. Strict: throws if BasaPOS survives.
    void UnregisterBasaPOS()
    {
        var targets = WslRunner.ListDistros()
            .Where(Detect.IsBasaPOSName)
            .ToList();
        if (targets.Count == 0)
            targets.Add(Paths.DistroName); // vhdx-present-but-unlisted edge; harmless if absent

        ui.Status("Shutting down WSL and waiting for the VM to release files...");
        try { WslRunner.Wsl("--shutdown", 60); } catch { /* VM already down */ }
        WaitForTeardown(ui);

        var errors = RunEscalation(
            targets,
            elevated: TryUnregister,
            unelevated: UnelevatedWsl.Available ? Unelevate : null,
            listLxss: DistroRegistration.FindLxssKeys,
            deleteLxss: DistroRegistration.DeleteKey,
            listRegistered: () => WslRunner.ListDistros().Where(Detect.IsBasaPOSName).ToList(),
            status: ui.Status);

        if (errors.Length > 0)
            ui.Status("Unregister notes:\n  " + errors);

        // Belt and braces: an Lxss key can outlive a nominal --unregister.
        foreach (var key in DistroRegistration.FindLxssKeys().ToList())
            if (DistroRegistration.DeleteKey(key))
                ui.Status($"Removed stray WSL registration: {key}");

        if (Detect.IsRegistered() || DistroRegistration.FindLxssKeys().Any())
            throw new InvalidOperationException(
                "Could not unregister the BasaPOS distro.\n" + errors +
                "\nManual fix: open a NORMAL (non-admin) terminal and run: " +
                "wsl --unregister BasaPOS, then run Uninstall again.");
    }

    /// The unregister escalation ladder — pure decision core with injected I/O
    /// so ordering is unit-testable without a real WSL:
    ///   1. elevated --unregister per candidate
    ///   2. if still registered: unelevated --unregister (when offered)
    ///   3. if still registered: delete remaining Lxss registration keys
    /// Returns accumulated diagnostics; the caller decides when to throw
    /// (a fully-removed distro may still carry intermediate error text).
    internal static string RunEscalation(
        IReadOnlyList<string> targets,
        Func<string, UnregisterAttempt> elevated,
        Func<string, UnregisterAttempt>? unelevated,
        Func<IReadOnlyList<string>> listLxss,
        Func<string, bool> deleteLxss,
        Func<IReadOnlyList<string>> listRegistered,
        Action<string>? status = null)
    {
        var errors = new List<string>();
        var tried = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        foreach (var name in targets)
        {
            if (!tried.Add(name)) continue;
            var r = elevated(name);
            if (r.Ok) { status?.Invoke($"Unregistered distro: {name}"); continue; }
            errors.Add($"{name}: {r.Error}");
        }
        var remaining = listRegistered();
        if (remaining.Count == 0) return string.Join("\n  ", errors);

        if (unelevated is not null)
        {
            status?.Invoke("Still registered — retrying as the normal (non-admin) user...");
            foreach (var name in remaining)
            {
                var r = unelevated(name);
                if (r.Ok) { status?.Invoke($"Unregistered distro: {name}"); continue; }
                errors.Add($"{name} (unelevated): {r.Error}");
            }
            remaining = listRegistered();
        }

        if (remaining.Count > 0)
        {
            status?.Invoke("Still registered — removing the WSL registration key(s) directly...");
            // snapshot: deleteLxss may mutate the underlying collection
            foreach (var key in listLxss().ToList())
                if (deleteLxss(key)) status?.Invoke($"Removed WSL registration: {key}");
                else errors.Add($"registry key: {key}: delete failed");
        }

        return string.Join("\n  ", errors);
    }

    /// One unregister attempt with the real wsl.exe outcome captured — no
    /// silent failures: exit codes and stderr feed the ladder and the report.
    static UnregisterAttempt TryUnregister(string name)
    {
        try
        {
            var r = WslRunner.Wsl($"--unregister \"{name}\"", 300);
            if (r.ExitCode == 0)
                return new UnregisterAttempt(Ok: true, Error: string.Empty);
            return new UnregisterAttempt(Ok: false,
                $"wsl --unregister \"{name}\" exited {r.ExitCode}: {r.Error.Trim()} {r.Output.Trim()}".Trim());
        }
        catch (Exception ex)
        {
            return new UnregisterAttempt(Ok: false, ex.Message);
        }
    }

    static UnregisterAttempt Unelevate(string name)
    {
        var (ok, error) = UnelevatedWsl.TryUnregister(name);
        return new UnregisterAttempt(ok, error);
    }

    /// wsl --shutdown returns while the VM is still dying; an immediate
    /// --unregister can then hit a locked ext4.vhdx. Wait until nobody holds
    /// the file (bounded) so unregister has the best odds. No vhdx = nothing
    /// to wait for.
    static void WaitForTeardown(ISetupUi ui, int maxSeconds = 30)
    {
        var vhdx = Path.Combine(Paths.DistroDir, "ext4.vhdx");
        if (!File.Exists(vhdx)) return;
        var sw = Stopwatch.StartNew();
        while (sw.Elapsed.TotalSeconds < maxSeconds)
        {
            try
            {
                using (new FileStream(vhdx, FileMode.Open, FileAccess.ReadWrite, FileShare.None)) { }
                return; // VM released the file
            }
            catch { Thread.Sleep(1000); } // still locked — VM tearing down / AV scanning
        }
        ui.Status("WSL VM still holding ext4.vhdx after 30s — proceeding anyway.");
    }

    /// Purge mode: unregister EVERY distro (best-effort per distro, strict only
    /// for BasaPOS which UnregisterBasaPOS already handled). Real wsl.exe
    /// errors are captured per distro and reported — one stuck foreign distro
    /// must not abort the whole purge.
    void PurgeAllDistros()
    {
        try { WslRunner.Wsl("--shutdown", 120); } catch { }
        WaitForTeardown(ui);
        var failures = new List<string>();
        foreach (var name in WslRunner.ListDistros())
        {
            var r = TryUnregister(name);
            if (r.Ok) ui.Status($"Purged distro: {name}");
            else failures.Add($"{name} ({r.Error})");
        }
        if (Detect.IsRegistered())
        {
            ui.Status("BasaPOS still registered after purge — removing its registration key directly...");
            foreach (var key in DistroRegistration.FindLxssKeys())
                if (DistroRegistration.DeleteKey(key)) ui.Status($"Removed WSL registration: {key}");
        }
        if (Detect.IsRegistered())
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
