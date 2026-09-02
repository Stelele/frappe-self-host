using System.Security.Cryptography;

namespace BasaPOS.Downloader;

/// Orchestrates: fetch latest release → download payload assets → verify
/// SHA256SUMS → assemble the USB layout → (optionally) launch the installer.
/// WinForms-free; the UI drives it through callbacks.
public sealed class PayloadDownloader
{
    const string Repo = "Stelele/frappe-self-host";
    const string SetupExe = "BasaPOS-Setup.exe";

    public string Tag { get; init; } = "";
    public string Dest { get; init; } = "";
    public bool LaunchInstaller { get; init; } = true;

    public async Task<int> RunAsync(Action<string> status, Action<double> progress, CancellationToken ct)
    {
        var dest = string.IsNullOrEmpty(Dest)
            ? Path.GetDirectoryName(AppContext.BaseDirectory) ?? "."
            : Dest;
        var payloadDir = Path.Combine(dest, "payload");
        Directory.CreateDirectory(payloadDir);

        status("Looking up latest release…");
        var release = await ReleaseClient.GetAsync(Repo, string.IsNullOrEmpty(Tag) ? null : Tag);
        var assets = ReleaseClient.SelectPayload(release);
        if (assets.Count == 0)
            throw new InvalidOperationException(
                $"No BasaPOS assets found in release {release.TagName}. Wrong repo or tag?");

        status($"Downloading {release.TagName} ({assets.Count} files)…");
        var total = assets.Sum(a => a.Size);
        long done = 0;
        using var http = new HttpClient { Timeout = TimeSpan.FromMinutes(30) };
        http.DefaultRequestHeaders.UserAgent.ParseAdd("BasaPOS-Downloader/1.0");

        foreach (var asset in assets)
        {
            ct.ThrowIfCancellationRequested();
            status($"Downloading {asset.Name} ({asset.Size / 1_000_000.0:F0} MB)…");
            var target = asset.Name == SetupExe
                ? Path.Combine(dest, asset.Name)
                : Path.Combine(payloadDir, asset.Name);
            using (var src = await http.GetStreamAsync(asset.Url, ct))
            using (var dst = new FileStream(target, FileMode.Create, FileAccess.Write, FileShare.None, 1 << 20))
            {
                var buf = new byte[1 << 20];
                int n;
                while ((n = await src.ReadAsync(buf, ct)) > 0)
                {
                    await dst.WriteAsync(buf.AsMemory(0, n), ct);
                    done += n;
                    progress(total > 0 ? (double)done / total : 0);
                }
            }
        }

        status("Verifying checksums…");
        VerifyChecksums(dest, payloadDir);

        status("Done.");
        return 0;
    }

    static void VerifyChecksums(string dest, string payloadDir)
    {
        var sumsPath = Path.Combine(payloadDir, "SHA256SUMS");
        if (!File.Exists(sumsPath))
            throw new InvalidOperationException("SHA256SUMS missing from the release payload.");

        var expected = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var line in File.ReadAllLines(sumsPath))
        {
            var bits = line.Split(new[] { ' ', '\t' }, 2, StringSplitOptions.RemoveEmptyEntries);
            if (bits.Length == 2)
                expected[bits[1].Trim().TrimStart('*')] = bits[0].Trim().ToLowerInvariant();
        }

        // verify the parts (in payload/) and the installer exe (at root);
        // the full basapos-distro.tar.gz entry is skipped — only parts ship.
        var files = new List<string>();
        files.AddRange(Directory.GetFiles(payloadDir, "basapos-distro.tar.part-*"));
        var setup = Path.Combine(dest, SetupExe);
        if (File.Exists(setup)) files.Add(setup);

        foreach (var f in files)
        {
            var name = Path.GetFileName(f);
            if (!expected.TryGetValue(name, out var want))
                continue; // not in SHA256SUMS (e.g. no entry) — skip
            var got = Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(f))).ToLowerInvariant();
            if (got != want)
                throw new InvalidOperationException(
                    $"Checksum mismatch for {name}: expected {want}, got {got}. Re-run the downloader.");
        }
    }
}
