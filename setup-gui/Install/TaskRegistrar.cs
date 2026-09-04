namespace BasaPOS.Setup.Install;

public static class TaskRegistrar
{
    public const string TaskName = "BasaPOS-Appliance";
    // Dedicated keeper task: runs wsl.exe DIRECTLY (not via start /b in boot.cmd,
    // whose background child does not reliably survive). The task's own wsl.exe
    // process IS the keeper — as long as the task runs, the VM has an active
    // client and never idles out. No time limit; restart on failure.
    public const string KeeperTaskName = "BasaPOS-Keeper";
    // v2 (Inno/PS) resume task — v3 never creates it, but a machine upgraded
    // from v2 may still have it. Uninstall removes both so no stale task lingers.
    const string LegacyResumeTask = "BasaPOS-Setup-Resume";

    public static void Register()
    {
        var cmd = Path.Combine(Paths.ProgramData, "boot.cmd");
        // plain at-logon task — all schtasks can express, no COM/xml needed
        var r = WslRunner.RunAnsi("schtasks.exe",
            $"/create /tn {TaskName} /tr \"\\\"{cmd}\\\"\" /sc onlogon /rl highest /f", 60);
        if (r.ExitCode != 0)
            throw new InvalidOperationException($"schtasks create failed ({r.ExitCode}): {r.Error}");

        // boot.cmd now holds a persistent keeper session (never exits), so the
        // default 72h ExecutionTimeLimit would kill it after 3 days — remove it.
        // PowerShell (not schtasks /change, which demands the run-as password).
        var script = "$t = Get-ScheduledTask -TaskName '" + TaskName + "'; " +
                     "$s = $t.Settings; $s.ExecutionTimeLimit = 'PT0S'; " +
                     "Set-ScheduledTask -TaskName '" + TaskName + "' -Settings $s";
        var r2 = WslRunner.RunAnsi("powershell.exe", "-NoProfile -Command \"" + script + "\"", 60);
        if (r2.ExitCode != 0)
            throw new InvalidOperationException($"removing task time limit failed ({r2.ExitCode}): {r2.Error}");

        // Dedicated keeper: a second at-logon task whose action IS wsl.exe
        // holding a sleep session. Unlike `start /b` inside boot.cmd (whose
        // background child does not reliably survive), the task's own process
        // persists as long as the task runs. No time limit; restart on failure
        // so a killed keeper is resurrected.
        var keeperCmd = Environment.SystemDirectory + @"\wsl.exe";
        var r3 = WslRunner.RunAnsi("schtasks.exe",
            $"/create /tn {KeeperTaskName} /tr \"\\\"{keeperCmd}\\\" -d {Paths.DistroName} --exec /bin/sleep infinity\" /sc onlogon /rl highest /f", 60);
        if (r3.ExitCode != 0)
            throw new InvalidOperationException($"keeper task create failed ({r3.ExitCode}): {r3.Error}");
        var kscript = "$t = Get-ScheduledTask -TaskName '" + KeeperTaskName + "'; " +
                      "$s = $t.Settings; $s.ExecutionTimeLimit = 'PT0S'; " +
                      "$s.RestartCount = 3; $s.RestartInterval = 'PT1M'; " +
                      "Set-ScheduledTask -TaskName '" + KeeperTaskName + "' -Settings $s";
        var r4 = WslRunner.RunAnsi("powershell.exe", "-NoProfile -Command \"" + kscript + "\"", 60);
        if (r4.ExitCode != 0)
            throw new InvalidOperationException($"keeper task settings failed ({r4.ExitCode}): {r4.Error}");
    }

    public static void Delete()
    {
        WslRunner.RunAnsi("schtasks.exe", $"/delete /tn {TaskName} /f", 60);
        WslRunner.RunAnsi("schtasks.exe", $"/delete /tn {KeeperTaskName} /f", 60);
        // best-effort: v2 resume task (fails silently if absent — schtasks
        // returns non-zero, no throw, since a missing task is the desired end state)
        WslRunner.RunAnsi("schtasks.exe", $"/delete /tn {LegacyResumeTask} /f", 60);
    }
}
