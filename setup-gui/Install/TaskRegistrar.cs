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
        return "$ErrorActionPreference='Stop'; " +
            "Stop-ScheduledTask -TaskName 'BasaPOS-Appliance' -ErrorAction SilentlyContinue; " +
            "Stop-ScheduledTask -TaskName 'BasaPOS-Keeper' -ErrorAction SilentlyContinue; " +
            "Unregister-ScheduledTask -TaskName 'BasaPOS-Appliance' -Confirm:$false -ErrorAction SilentlyContinue; " +
            "Unregister-ScheduledTask -TaskName 'BasaPOS-Keeper' -Confirm:$false -ErrorAction SilentlyContinue; " +
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
        "Stop-ScheduledTask -TaskName 'BasaPOS-Appliance' -ErrorAction SilentlyContinue; " +
        "Stop-ScheduledTask -TaskName 'BasaPOS-Keeper' -ErrorAction SilentlyContinue; " +
        "Stop-ScheduledTask -TaskName 'BasaPOS-Setup-Resume' -ErrorAction SilentlyContinue; ";

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
    }
}
