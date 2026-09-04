namespace BasaPOS.Setup.Install;

public static class TaskRegistrar
{
    public const string TaskName = "BasaPOS-Appliance";
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
    }

    public static void Delete()
    {
        WslRunner.RunAnsi("schtasks.exe", $"/delete /tn {TaskName} /f", 60);
        // best-effort: v2 resume task (fails silently if absent — schtasks
        // returns non-zero, no throw, since a missing task is the desired end state)
        WslRunner.RunAnsi("schtasks.exe", $"/delete /tn {LegacyResumeTask} /f", 60);
    }
}
