namespace BasaPOS.Setup.Install;

public static class TaskRegistrar
{
    public const string TaskName = "BasaPOS-Appliance";

    public static void Register()
    {
        var cmd = Path.Combine(Paths.ProgramData, "boot.cmd");
        // plain at-logon task — all schtasks can express, no COM/xml needed
        var r = WslRunner.RunAnsi("schtasks.exe",
            $"/create /tn {TaskName} /tr \"\\\"{cmd}\\\"\" /sc onlogon /rl highest /f", 60);
        if (r.ExitCode != 0)
            throw new InvalidOperationException($"schtasks create failed ({r.ExitCode}): {r.Error}");
    }

    public static void Delete() =>
        WslRunner.RunAnsi("schtasks.exe", $"/delete /tn {TaskName} /f", 60);
}
