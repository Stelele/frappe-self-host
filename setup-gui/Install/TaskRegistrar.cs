namespace BasaPOS.Setup.Install;

public static class TaskRegistrar
{
    public const string TaskName = "BasaPOS-Appliance";       // legacy, deleted
    public const string KeeperTaskName = "BasaPOS-Keeper";    // the ONE task
    const string LegacyResumeTask = "BasaPOS-Setup-Resume";   // v2, deleted

    public static void Register()
    {
        // Clear legacy tasks with schtasks (tolerates absence — fresh
        // install). Same reasoning as Delete(): PS stop/unregister cmdlets
        // fail on nonexistent tasks in ways try/catch does not suppress.
        foreach (var name in new[] { TaskName, KeeperTaskName })
            try
            {
                WslRunner.RunAnsi("schtasks.exe", $"/end /tn {name} /f", 60);
                WslRunner.RunAnsi("schtasks.exe", $"/delete /tn {name} /f", 60);
            }
            catch { }
        var r = WslRunner.RunAnsi("powershell.exe",
            "-NoProfile -ExecutionPolicy Bypass -Command \"" +
            BuildRegisterScript(Environment.UserName,
                Path.Combine(Paths.InstallRoot, "bin", "BasaPOS.Keeper.exe")) + "\"", 120);
        if (r.ExitCode != 0)
            throw new InvalidOperationException($"keeper task register failed ({r.ExitCode}): {r.Error}");
    }

    internal static string BuildRegisterScript(string user, string exe)
    {
        var u = user.Replace("'", "''");
        var x = exe.Replace("'", "''");
        // Creation only — old tasks are cleared with schtasks above, which
        // tolerates absence. Everything here SHOULD fail loudly.
        return "$ErrorActionPreference='Stop'; " +
            "$a=New-ScheduledTaskAction -Execute '" + x + "'; " +
            "$t1=New-ScheduledTaskTrigger -AtLogOn -User '" + u + "'; " +
            "$t2=New-ScheduledTaskTrigger -Once -At (Get-Date) " +
            "-RepetitionInterval (New-TimeSpan -Minutes 5) " +
            "-RepetitionDuration ([TimeSpan]::MaxValue); " +
            "$p=New-ScheduledTaskPrincipal -UserId '" + u + "' -LogonType Interactive -RunLevel Highest; " +
            "$s=New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) " +
            "-RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew; " +
            "Register-ScheduledTask -TaskName 'BasaPOS-Keeper' " +
            "-Action $a -Trigger @($t1,$t2) -Principal $p -Settings $s -Force; " +
            "Start-ScheduledTask -TaskName 'BasaPOS-Keeper'";
    }

    public static void Delete()
    {
        // Stop running instances first: schtasks /delete leaves them alive.
        // Deliberately schtasks.exe, NOT PowerShell Stop-ScheduledTask: on a
        // machine where the named tasks don't exist (fresh install path), the
        // PS cmdlet fails in ways -ErrorAction/try-catch do not reliably
        // suppress (proven by CI: exit 1, empty error). schtasks just returns
        // nonzero for absent tasks, which we ignore.
        foreach (var name in new[] { TaskName, KeeperTaskName, LegacyResumeTask })
            try { WslRunner.RunAnsi("schtasks.exe", $"/end /tn {name} /f", 60); } catch { }
        WslRunner.RunAnsi("schtasks.exe", $"/delete /tn {TaskName} /f", 60);
        WslRunner.RunAnsi("schtasks.exe", $"/delete /tn {KeeperTaskName} /f", 60);
        WslRunner.RunAnsi("schtasks.exe", $"/delete /tn {LegacyResumeTask} /f", 60);
        // Verify via schtasks /query (exit 0 = still exists). Same reasoning:
        // Get-ScheduledTask throws on absent tasks; /query just exits nonzero.
        var survivors = new List<string>();
        foreach (var name in new[] { TaskName, KeeperTaskName, LegacyResumeTask })
        {
            try
            {
                if (WslRunner.RunAnsi("schtasks.exe", $"/query /tn {name}", 60).ExitCode == 0)
                    survivors.Add(name);
            }
            catch { /* query itself failed — treat as unverified, not as clean */ }
        }
        // NOTE: a failed query is treated as "no evidence", not failure —
        // failing closed here would break uninstall on machines where the
        // task service is unreachable but nothing is actually registered.
        if (survivors.Count > 0)
            throw new InvalidOperationException(
                "Could not remove scheduled task(s): " + string.Join(", ", survivors) +
                ". Delete them in Task Scheduler and run Uninstall again.");
    }
}
