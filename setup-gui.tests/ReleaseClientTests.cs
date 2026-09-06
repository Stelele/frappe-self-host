using BasaPOS.Downloader;
using Xunit;

public class ReleaseClientTests
{
    static string SampleJson => """
        {
          "tag_name": "v3.0.0-rc1",
          "assets": [
            { "name": "BasaPOS-Setup.exe", "size": 52428800, "browser_download_url": "https://example.com/BasaPOS-Setup.exe" },
            { "name": "basapos-distro.tar.part-00", "size": 1992294400, "browser_download_url": "https://example.com/part-00" },
            { "name": "basapos-distro.tar.part-01", "size": 1992294400, "browser_download_url": "https://example.com/part-01" },
            { "name": "SHA256SUMS", "size": 2048, "browser_download_url": "https://example.com/SHA256SUMS" },
            { "name": "wsl.msi", "size": 73400320, "browser_download_url": "https://example.com/wsl.msi" },
            { "name": "BasaPOS.Keeper.exe", "size": 5000, "browser_download_url": "https://example.com/BasaPOS.Keeper.exe" },
            { "name": "basapos.ico", "size": 1000, "browser_download_url": "https://example.com/basapos.ico" },
            { "name": "source.tar.gz", "size": 999, "browser_download_url": "https://example.com/source.tar.gz" },
            { "name": "README.md", "size": 300, "browser_download_url": "https://example.com/README.md" }
          ]
        }
        """;

    [Fact]
    public void Parse_extracts_tag_and_assets()
    {
        var r = ReleaseClient.Parse(SampleJson);
        Assert.Equal("v3.0.0-rc1", r.TagName);
        Assert.Equal(9, r.Assets.Count);
        Assert.Equal("BasaPOS-Setup.exe", r.Assets[0].Name);
        Assert.Equal(52428800, r.Assets[0].Size);
    }

    [Fact]
    public void SelectPayload_keeps_only_installer_assets_in_order()
    {
        var r = ReleaseClient.Parse(SampleJson);
        var payload = ReleaseClient.SelectPayload(r);
        var names = payload.Select(a => a.Name).ToList();
        Assert.DoesNotContain("source.tar.gz", names);
        Assert.DoesNotContain("README.md", names);
        Assert.Equal(7, names.Count);
        // parts sort ordinally before SHA256SUMS/wsl.msi, Setup.exe first
        Assert.Equal("BasaPOS-Setup.exe", names[0]);
        Assert.Contains("basapos-distro.tar.part-00", names);
        Assert.Contains("basapos-distro.tar.part-01", names);
        Assert.Contains("SHA256SUMS", names);
        Assert.Contains("wsl.msi", names);
        Assert.Contains("BasaPOS.Keeper.exe", names);
        Assert.Contains("basapos.ico", names);
    }

    [Fact]
    public void Parse_handles_missing_assets_field()
    {
        var r = ReleaseClient.Parse("""{ "tag_name": "v1.0.0" }""");
        Assert.Equal("v1.0.0", r.TagName);
        Assert.Empty(r.Assets);
    }
}
