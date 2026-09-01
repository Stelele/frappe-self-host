namespace BasaPOS.Setup.Install;

public static class Paths
{
    public const string InstallRoot = @"C:\BasaPOS";
    public static readonly string DistroDir = Path.Combine(InstallRoot, "distro");
    public static readonly string ConfigDir = Path.Combine(InstallRoot, "config");
    public static readonly string LogsDir = Path.Combine(InstallRoot, "logs");
    public static readonly string BackupsDir = Path.Combine(InstallRoot, "backups");
    public static readonly string ProgramData = @"C:\ProgramData\BasaPOS";
    public const string DistroName = "BasaPOS";
    public const string Domain = "basapos.local";
    public const string SiteUrl = "https://basapos.local";
}
