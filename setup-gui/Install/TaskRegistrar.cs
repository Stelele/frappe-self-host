namespace BasaPOS.Setup.Install;

public static class TaskRegistrar
{
    public const string TaskName = "BasaPOS-Appliance";       // legacy, deleted
    public const string KeeperTaskName = "BasaPOS-Keeper";    // the ONE task
    const string LegacyResumeTask = "BasaPOS-Setup-Resume";   // v2, deleted

    public static void Register()
    {
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
        // Stop/unregister preamble MUST tolerate missing tasks (fresh install):
        // Stop-ScheduledTask on a nonexistent task can throw terminating
        // regardless of -ErrorAction, which under $ErrorActionPreference='Stop'
        // would abort with exit 1. Per-task try/catch swallows every severity;
        // the REAL work below keeps fail-loud Stop semantics.
        return "$ErrorActionPreference='Stop'; " +
            "foreach ($n in 'BasaPOS-Appliance','BasaPOS-Keeper') " +
            "{ try { Stop-ScheduledTask -TaskName $n -ErrorAction Stop } catch { }; " +
            "try { Unregister-ScheduledTask -TaskName $n -Confirm:$false -ErrorAction Stop } catch { } }; " +
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

    internal static string BuildDeleteScript() =>
        "$ErrorActionPreference='Stop'; " +
        "foreach ($n in 'BasaPOS-Appliance','BasaPOS-Keeper','BasaPOS-Setup-Resume') " +
        "{ try { Stop-ScheduledTask -TaskName $n -ErrorAction Stop } catch { } }; ";

    public static void Delete()
    {
        // Stop first: schtasks /delete leaves a RUNNING instance alive.
        var stop = WslRunner.RunAnsi("powershell.exe",
            "-NoProfile -ExecutionPolicy Bypass -Command \"" + BuildDeleteScript() + "\"", 60);
        if (stop.ExitCode != 0)
            throw new InvalidOperationException($"stopping keeper tasks failed ({stop.ExitCode}): {stop.Error}");
        WslRunner.RunAnsi("schtasks.exe", $"/delete /tn {TaskName} /f", 60);
        WslRunner.RunAnsi("schtasks.exe", $"/delete /tn {KeeperTaskName} /f", 60);
        WslRunner.RunAnsi("schtasks.exe", $"/delete /tn {LegacyResumeTask} /f", 60);
        // Verify: a failed delete (exit code swallowed above — absence is the
        // normal case) must not proceed to BinDir removal under a live task.
        // Check BOTH exit code (nonzero + empty stdout = unverified) and output.
        var survivors = WslRunner.RunAnsi("powershell.exe",
            "-NoProfile -ExecutionPolicy Bypass -Command \"" + BuildSurvivorScript() + "\"", 60);
        if (survivors.ExitCode != 0)
            throw new InvalidOperationException(
                $"verifying task removal failed ({survivors.ExitCode}): {survivors.Error.Trim()}");
        if (!string.IsNullOrWhiteSpace(survivors.Output))
            throw new InvalidOperationException(
                "Could not remove scheduled task(s): " + survivors.Output.Trim() +
                ". Delete them in Task Scheduler and run Uninstall again.");
    }

    internal static string BuildSurvivorScript() =>
        "try { Get-ScheduledTask -TaskName 'BasaPOS-Appliance','BasaPOS-Keeper','BasaPOS-Setup-Resume' " +
        "-ErrorAction Stop | Select-Object -ExpandProperty TaskName } catch { }";
}
