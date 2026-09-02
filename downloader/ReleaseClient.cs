using System.Text.Json;

namespace BasaPOS.Downloader;

public sealed record Asset(string Name, string Url, long Size);

public sealed record ReleaseInfo(string TagName, IReadOnlyList<Asset> Assets);

/// Talks to the public GitHub releases API (unauthenticated) and selects the
/// payload assets the installer needs. Pure/JSON-only so it's unit-testable.
public static class ReleaseClient
{
    static readonly HttpClient Http = new() { Timeout = TimeSpan.FromMinutes(10) };

    static ReleaseClient() =>
        Http.DefaultRequestHeaders.UserAgent.ParseAdd("BasaPOS-Downloader/1.0");

    public static async Task<ReleaseInfo> GetAsync(string repo, string? tag)
    {
        var url = tag is null
            ? $"https://api.github.com/repos/{repo}/releases/latest"
            : $"https://api.github.com/repos/{repo}/releases/tags/{Uri.EscapeDataString(tag)}";
        var json = await Http.GetStringAsync(url);
        return Parse(json);
    }

    public static ReleaseInfo Parse(string json)
    {
        using var doc = JsonDocument.Parse(json);
        var root = doc.RootElement;
        var tag = root.GetProperty("tag_name").GetString() ?? "";
        var assets = new List<Asset>();
        if (root.TryGetProperty("assets", out var arr))
            foreach (var a in arr.EnumerateArray())
                assets.Add(new Asset(
                    a.GetProperty("name").GetString() ?? "",
                    a.GetProperty("browser_download_url").GetString() ?? "",
                    a.GetProperty("size").GetInt64()));
        return new ReleaseInfo(tag, assets);
    }

    /// The subset of release assets the installer consumes, in download order.
    public static IReadOnlyList<Asset> SelectPayload(ReleaseInfo release) =>
        release.Assets
            .Where(a => a.Name == "BasaPOS-Setup.exe"
                        || a.Name == "wsl.msi"
                        || a.Name == "SHA256SUMS"
                        || a.Name.StartsWith("basapos-distro.tar.part-", StringComparison.Ordinal))
            .OrderBy(a => a.Name, StringComparer.Ordinal)
            .ToList();
}
