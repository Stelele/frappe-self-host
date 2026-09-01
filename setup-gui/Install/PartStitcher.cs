using System.Security.Cryptography;

namespace BasaPOS.Setup.Install;

public static class PartStitcher
{
    public static string[] OrderedParts(string payloadDir) =>
        Directory.GetFiles(payloadDir, "basapos-distro.tar.part-*")
            .OrderBy(p => p, StringComparer.Ordinal).ToArray();

    /// Stitch parts → single tar.gz in %TEMP%, verify against SHA256SUMS'
    /// recorded hash for basapos-distro.tar.gz. Throws with an actionable
    /// message on any mismatch. Returns the stitched file path.
    public static string StitchAndVerify(string payloadDir, Action<int> progress)
    {
        var parts = OrderedParts(payloadDir);
        if (parts.Length == 0)
            throw new InvalidOperationException("no payload parts found");

        var sums = ParseSums(Path.Combine(payloadDir, "SHA256SUMS"));
        if (!sums.ContainsKey("basapos-distro.tar.gz"))
            throw new InvalidOperationException("SHA256SUMS missing entry for basapos-distro.tar.gz");

        var target = Path.Combine(Path.GetTempPath(), "basapos-distro.tar.gz");
        using (var outStream = new FileStream(target, FileMode.Create, FileAccess.Write,
                   FileShare.None, 1 << 20))
        {
            for (int i = 0; i < parts.Length; i++)
            {
                using var part = File.OpenRead(parts[i]);
                part.CopyTo(outStream);
                progress((i + 1) * 90 / (parts.Length + 1));
            }
        }

        progress(91);
        using var sha = SHA256.Create();
        using var fs = File.OpenRead(target);
        var hash = Convert.ToHexString(sha.ComputeHash(fs)).ToLowerInvariant();
        if (hash != sums["basapos-distro.tar.gz"])
            throw new InvalidOperationException(
                $"Payload checksum mismatch.\nExpected {sums["basapos-distro.tar.gz"]}\nGot      {hash}\n" +
                "The USB copy is corrupt — re-copy the payload folder.");
        progress(95);
        return target;
    }

    internal static Dictionary<string, string> ParseSums(string path)
    {
        var d = new Dictionary<string, string>();
        foreach (var line in File.ReadAllLines(path))
        {
            var bits = line.Split(new[] { ' ', '\t' }, 2, StringSplitOptions.RemoveEmptyEntries);
            if (bits.Length == 2) d[bits[1].Trim().TrimStart('*')] = bits[0].Trim().ToLowerInvariant();
        }
        return d;
    }
}