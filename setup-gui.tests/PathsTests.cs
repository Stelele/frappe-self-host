using BasaPOS.Setup.Install;
using Xunit;

public class PathsTests
{
    [Fact]
    public void Constants_are_stable()
    {
        Assert.Equal(@"C:\BasaPOS", Paths.InstallRoot);
        Assert.Equal("BasaPOS", Paths.DistroName);
        Assert.Equal("https://basapos.local", Paths.SiteUrl);
        Assert.Equal(@"C:\ProgramData\BasaPOS", Paths.ProgramData);
        Assert.EndsWith("distro", Paths.DistroDir);
        Assert.EndsWith("backups", Paths.BackupsDir);
    }
}
