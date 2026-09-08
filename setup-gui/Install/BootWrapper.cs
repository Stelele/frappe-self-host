namespace BasaPOS.Setup.Install;

public static class BootWrapper
{
    public static void Delete()
    {
        var f = Path.Combine(Paths.ProgramData, "boot.cmd");
        if (File.Exists(f)) File.Delete(f);
        if (Directory.Exists(Paths.ProgramData) &&
            Directory.GetFiles(Paths.ProgramData).Length == 0)
            Directory.Delete(Paths.ProgramData);
    }
}
