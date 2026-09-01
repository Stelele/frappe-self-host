namespace BasaPOS.Setup.Install;

public static class Detect
{
    public static bool IsInstalled()
    {
        try
        {
            var r = WslRunner.Wsl("--list --quiet", 30);
            return r.Output.Contains(Paths.DistroName, StringComparison.OrdinalIgnoreCase);
        }
        catch
        {
            return false;
        }
    }
}
