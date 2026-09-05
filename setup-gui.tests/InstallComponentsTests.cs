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
        Assert.Contains("memory=6GB", s);
        // vmIdleTimeout deliberately NOT rendered: proven ignored on pinned
        // WSL (2.7.11) and the #1 source of duplicate-key errors when stacked;
        // the BasaPOS-Keeper scheduled task is the real keep-alive mechanism
        Assert.DoesNotContain("vmIdleTimeout", s, StringComparison.OrdinalIgnoreCase);

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
    public void WslConfig_strips_duplicate_blocks_case_insensitively()
    {
        // simulates an accumulated file: two managed blocks (one with edited
        // marker case) plus v2-style BARE timeout keys (no markers — v2 never
        // cleaned .wslconfig) — uninstall must remove all OUR content and
        // report only genuine foreign config
        var messy =
            "# --- BasaPOS (managed) ---\n[wsl2]\nmemory=4GB\n# --- end BasaPOS ---\n" +
            "[wsl2]\ninstanceIdleTimeout=60000\n" +
            "vmIdleTimeout=-1\n" +
            "vmidletimeout=-1\n" +
            "vmIdleTimeout=60000\n" +
            "# --- basapos (managed) ---\n[wsl2]\nmemory=4GB\n# --- END basapos ---\n";
        var cleaned = WslConfig.StripLegacyTimeoutKeys(
            WslConfig.StripOrphanFragment(WslConfig.StripManagedBlock(messy)));
        Assert.DoesNotContain("managed", cleaned, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("instanceIdleTimeout", cleaned, StringComparison.OrdinalIgnoreCase);
        // our signature -1 values gone (all cases); user's own 60000 preserved
        Assert.DoesNotContain("-1", cleaned);
        Assert.Contains("vmIdleTimeout=60000", cleaned);
        var leftovers = WslConfig.SummarizeLeftovers(cleaned);
        Assert.Contains("vmIdleTimeout=60000", leftovers); // user's: reported, not deleted
    }

    [Fact]
    public void WslConfig_strip_legacy_keys_preserves_user_tuning()
    {
        var content = "[wsl2]\nmemory=8GB\nvmIdleTimeout=120000\n";
        var cleaned = WslConfig.StripLegacyTimeoutKeys(content);
        Assert.Contains("vmIdleTimeout=120000", cleaned); // user's own value: untouched
        Assert.Contains("memory=8GB", cleaned);
    }

    [Fact]
    public void WslConfig_summarize_ignores_blanks_comments_and_sections_alone()
    {
        // headers alone are reported (transparent) but count as "no keys"
        // so RemoveManagedBlock deletes a file holding only them
        Assert.Equal("[wsl2]", WslConfig.SummarizeLeftovers("# comment\n\n[wsl2]\n   \n"));
        Assert.False(WslConfig.HasKeys("# comment\n\n[wsl2]\n"));
        Assert.True(WslConfig.HasKeys("[wsl2]\nmemory=8GB\n"));
        Assert.False(WslConfig.HasKeys("; semicolon comment\n[other]\n"));
        var s = WslConfig.SummarizeLeftovers("[wsl2]\nmemory=8GB\n# note\n");
        Assert.Contains("memory=8GB", s);
        Assert.DoesNotContain("# note", s);
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
    public void ParseDistroList_handles_utf16_artifacts_and_blanks()
    {
        var d = WslRunner.ParseDistroList("Ubuntu\r\nBasaPOS\r\n\r\ndocker-desktop\r\n");
        Assert.Equal(new[] { "Ubuntu", "BasaPOS", "docker-desktop" }, d);
        Assert.Empty(WslRunner.ParseDistroList(""));
        Assert.Empty(WslRunner.ParseDistroList("\r\n  \n"));
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

    [Fact]
    public void TaskRegistrar_script_stops_old_tasks_and_registers_two_triggers()
    {
        var s = TaskRegistrar.BuildRegisterScript("tech", @"C:\BasaPOS\bin\BasaPOS.Keeper.exe");
        Assert.Contains("Stop-ScheduledTask -TaskName 'BasaPOS-Appliance'", s);
        Assert.Contains("Stop-ScheduledTask -TaskName 'BasaPOS-Keeper'", s);
        Assert.Contains("Unregister-ScheduledTask -TaskName 'BasaPOS-Appliance'", s);
        Assert.Contains("New-ScheduledTaskTrigger -AtLogOn", s);
        Assert.Contains("RepetitionInterval", s);
        Assert.Contains("New-TimeSpan -Minutes 5", s);
        Assert.Contains("IgnoreNew", s);
        Assert.Contains(@"C:\BasaPOS\bin\BasaPOS.Keeper.exe", s);
        Assert.Contains("Start-ScheduledTask -TaskName 'BasaPOS-Keeper'", s);
    }

    [Fact]
    public void TaskRegistrar_delete_stops_all_tasks_before_deleting()
    {        var s = TaskRegistrar.BuildDeleteScript();
        Assert.Contains("Stop-ScheduledTask -TaskName 'BasaPOS-Appliance'", s);
        Assert.Contains("Stop-ScheduledTask -TaskName 'BasaPOS-Keeper'", s);
        Assert.Contains("Stop-ScheduledTask -TaskName 'BasaPOS-Setup-Resume'", s);
        Assert.True(s.StartsWith("$ErrorActionPreference='Stop';"),
            "delete must run as a single stop-then-delete unit");
    }

    [Fact]
    public void TaskRegistrar_script_escapes_apostrophes_in_user_and_exe()
    {
        var s = TaskRegistrar.BuildRegisterScript("o'brien", @"C:\BasaPOS'\bin\BasaPOS.Keeper.exe");
        Assert.Contains("o''brien", s);
        Assert.Contains(@"C:\BasaPOS''\bin\BasaPOS.Keeper.exe", s);
        Assert.DoesNotContain("o'brien", s.Replace("o''brien", ""));
    }

    [Fact]
    public void KeeperProcess_path_match_is_exact_case_insensitive()
    {
        Assert.True(KeeperProcess.PathMatches(@"C:\BasaPOS\bin\BasaPOS.Keeper.exe", KeeperProcess.ExePath));
        Assert.True(KeeperProcess.PathMatches(@"c:\basapos\BIN\basapos.keeper.exe", KeeperProcess.ExePath));
        Assert.True(KeeperProcess.PathMatches(@"C:/BasaPOS/bin/BasaPOS.Keeper.exe", KeeperProcess.ExePath)); // mixed separators
        Assert.True(KeeperProcess.PathMatches(@"C:\BasaPOS\bin\BasaPOS.Keeper.exe\", KeeperProcess.ExePath)); // trailing slash
        Assert.False(KeeperProcess.PathMatches(@"C:\BasaPOS\bin\other.exe", KeeperProcess.ExePath));
        Assert.False(KeeperProcess.PathMatches(null, KeeperProcess.ExePath));
        Assert.Equal(@"C:\BasaPOS\bin\BasaPOS.Keeper.exe", KeeperProcess.ExePath);
    }

    [Fact]
    public void ShortcutCreator_paths_and_icon()
    {
        Assert.Equal("BasaPOS.lnk", ShortcutCreator.LinkName);
        Assert.EndsWith(@"Programs\BasaPOS.lnk", ShortcutCreator.StartMenuLink);
        Assert.EndsWith(@"Desktop\BasaPOS.lnk", ShortcutCreator.DesktopLink);
        Assert.Equal(Path.Combine(Paths.BinDir, "basapos.ico"), ShortcutCreator.IconPath);
    }

    [Fact]
    public void TerminalHide_adds_and_removes_only_our_entry()
    {
        var empty = """{"profiles":{"list":[]}}""";
        var hidden = ShortcutCreator.HideProfileJson(empty);
        Assert.Contains("\"hidden\": true", hidden);
        Assert.Contains("BasaPOS", hidden);
        // idempotent: hiding twice adds one entry
        Assert.Equal(hidden, ShortcutCreator.HideProfileJson(hidden));
        // unhide removes exactly our shape, keeps user entries
        var withUser = """{"profiles":{"list":[{"name":"BasaPOS","hidden":true},{"name":"Ubuntu","fontSize":14}]}}""";
        var restored = ShortcutCreator.UnhideProfileJson(withUser);
        Assert.DoesNotContain("BasaPOS", restored);
        Assert.Contains("Ubuntu", restored);
        // unhide never touches a user-customized BasaPOS entry (extra keys)
        var custom = """{"profiles":{"list":[{"name":"BasaPOS","hidden":true,"fontSize":16}]}}""";
        Assert.Contains("fontSize", ShortcutCreator.UnhideProfileJson(custom));
    }
}
