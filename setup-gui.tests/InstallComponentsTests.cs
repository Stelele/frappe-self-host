using BasaPOS.Setup.Install;
using Xunit;

public class InstallComponentsTests
{
    [Fact]
    public void ParseSums_handles_double_space_and_binary_marker()
    {
        var f = Path.GetTempFileName();
        File.WriteAllText(f, "abc123  basapos-distro.tar.gz\ndef456  basapos-distro.tar.part-00\n1133aa *binary-mode-file\n");
        var d = PartStitcher.ParseSums(f);
        Assert.Equal("abc123", d["basapos-distro.tar.gz"]);
        Assert.Equal("def456", d["basapos-distro.tar.part-00"]);
        Assert.Equal("1133aa", d["binary-mode-file"]);
    }

    [Fact]
    public void StitchAndVerify_roundtrips_and_rejects_corruption()
    {
        var dir = Path.Combine(Path.GetTempPath(), "pp-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(dir);
        var data = System.Security.Cryptography.RandomNumberGenerator.GetBytes(3_000_000);
        var third = data.Length / 3;
        File.WriteAllBytes(Path.Combine(dir, "basapos-distro.tar.part-00"), data[..third]);
        File.WriteAllBytes(Path.Combine(dir, "basapos-distro.tar.part-01"), data[third..(2 * third)]);
        File.WriteAllBytes(Path.Combine(dir, "basapos-distro.tar.part-02"), data[(2 * third)..]);
        using (var sha = System.Security.Cryptography.SHA256.Create())
        {
            var real = Convert.ToHexString(sha.ComputeHash(data)).ToLowerInvariant();
            File.WriteAllText(Path.Combine(dir, "SHA256SUMS"), $"{real}  basapos-distro.tar.gz\n");
            var out1 = PartStitcher.StitchAndVerify(dir, _ => { });
            Assert.Equal(data, File.ReadAllBytes(out1));

            // corrupt one part → must throw with actionable message
            File.WriteAllBytes(Path.Combine(dir, "basapos-distro.tar.part-01"), data[third..(2 * third)][..^1]);
            var ex = Assert.Throws<InvalidOperationException>(() => PartStitcher.StitchAndVerify(dir, _ => { }));
            Assert.Contains("re-copy", ex.Message);
        }
        Directory.Delete(dir, recursive: true);
    }

    [Fact]
    public void OrderedParts_sorts_ordinally_beyond_10_parts()
    {
        var dir = Path.Combine(Path.GetTempPath(), "op-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(dir);
        for (int i = 0; i < 12; i++)
            File.WriteAllText(Path.Combine(dir, $"basapos-distro.tar.part-{i:D2}"), "x");
        var parts = PartStitcher.OrderedParts(dir);
        Assert.Equal("basapos-distro.tar.part-11", Path.GetFileName(parts[^1]));
        Directory.Delete(dir, recursive: true);
    }

    [Fact]
    public void HostsEntry_detection_is_idempotent()
    {
        Assert.True(HostsFile.HasEntry("127.0.0.1 basapos.local"));
        Assert.True(HostsFile.HasEntry("  127.0.0.1 BASAPOS.LOCAL  "));
        Assert.True(HostsFile.HasEntry("127.0.0.1  basapos.local  # double space + comment"));
        Assert.False(HostsFile.HasEntry("10.0.0.5 basapos.local"));
        Assert.False(HostsFile.HasEntry(""));
    }

    [Fact]
    public void WslConfig_renders_and_strips_managed_block()
    {
        var s = WslConfig.Render(6L * 1024 * 1024 * 1024);
        Assert.Contains("vmIdleTimeout=-1", s);
        Assert.Contains("memory=6GB", s);

        var withOther = "# other user config\n[experimental]\nautoMemoryReclaim=gradual\n" + s;
        var stripped = WslConfig.StripManagedBlock(withOther);
        Assert.DoesNotContain("BasaPOS (managed)", stripped);
        Assert.Contains("autoMemoryReclaim=gradual", stripped); // untouched foreign config

        var onlyOurs = WslConfig.StripManagedBlock(s);
        Assert.Equal("", onlyOurs.Trim()); // pure-managed file → empty → caller deletes
    }

    [Fact]
    public void WslConfig_strips_orphan_fragment_without_eating_foreign_config()
    {
        var orphan = "# other\n[experimental]\nkey=val\n# --- BasaPOS (managed) ---\n[wsl2]\nmemory=6G"; // no end marker
        var stripped = WslConfig.StripOrphanFragment(orphan);
        Assert.Contains("key=val", stripped);
        Assert.DoesNotContain("BasaPOS (managed)", stripped);
    }

    [Fact]
    public void StitchAndVerify_missing_sums_is_actionable()
    {
        var dir = Path.Combine(Path.GetTempPath(), "ns-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(dir);
        File.WriteAllText(Path.Combine(dir, "basapos-distro.tar.part-00"), "x");
        var ex = Assert.Throws<InvalidOperationException>(() => PartStitcher.StitchAndVerify(dir, _ => { }));
        Assert.Contains("re-copy", ex.Message);
        Directory.Delete(dir, recursive: true);
    }

    [Fact]
    public void PasswordGen_excludes_ambiguous_chars()
    {
        var rng = new Random(1);
        for (int i = 0; i < 200; i++)
        {
            var pw = Credentials.Generate(16, rng);
            Assert.Equal(16, pw.Length);
            foreach (var c in "0O1lI") Assert.DoesNotContain(c, pw.ToString());
        }
    }
}