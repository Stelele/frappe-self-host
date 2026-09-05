using System.Text.Json;
using System.Text.Json.Nodes;

namespace BasaPOS.Setup.Install;

public static class ShortcutCreator
{
    public const string LinkName = "BasaPOS.lnk";
    internal static string JoinLink(params string[] parts) => string.Join("\\", parts);
    public static string StartMenuLink => JoinLink(
        Environment.GetFolderPath(Environment.SpecialFolder.CommonStartMenu), "Programs", LinkName);
    public static string DesktopLink => JoinLink(
        Environment.GetFolderPath(Environment.SpecialFolder.CommonDesktopDirectory), LinkName);
    public static string IconPath => Path.Combine(Paths.BinDir, "basapos.ico");

    /// payloadDir: installer payload folder containing BasaPOS.Keeper.exe + basapos.ico.
    /// (Shortcut creation itself is Windows-only at runtime; path/JSON logic above is tested on Linux.)
    public static void Create(string payloadDir)
    {
        Directory.CreateDirectory(Paths.BinDir);
        File.Copy(Path.Combine(payloadDir, "basapos.ico"), IconPath, overwrite: true);
        WriteLink(StartMenuLink);
        WriteLink(DesktopLink);
        HideTerminalProfile();
    }

    static void WriteLink(string lnk)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(lnk)!);
        var t = Type.GetTypeFromProgID("WScript.Shell")
            ?? throw new InvalidOperationException("WScript.Shell unavailable");
        dynamic shell = Activator.CreateInstance(t)!;
        dynamic sc = shell.CreateShortcut(lnk);
        sc.TargetPath = Paths.SiteUrl;          // URL target → browser, no console
        sc.IconLocation = IconPath;
        sc.Description = "BasaPOS point of sale";
        sc.Save();
    }

    public static void Remove()
    {
        foreach (var lnk in new[] { StartMenuLink, DesktopLink })
            try { if (File.Exists(lnk)) File.Delete(lnk); } catch { }
        UnhideTerminalProfile();
    }

    static string TerminalSettingsPath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "Packages", "Microsoft.WindowsTerminal_8wekyb3d8bbwe",
        "LocalState", "settings.json");

    // Terminal WSL-source toggle. Mechanism: disabledProfileSources array
    // (name-keyed hidden:true does NOT hide GUID-matched dynamic profiles).
    // JSONC-tolerant (stock settings.json has // comments + trailing
    // commas); returns the ORIGINAL string when nothing changes (never a
    // gratuitous rewrite); callers write atomically (temp + move).
    const string WslSource = "Windows.Terminal.Wsl";
    static readonly JsonSerializerOptions Indented = new() { WriteIndented = true };
    static readonly JsonDocumentOptions Jsonc = new() { CommentHandling = JsonCommentHandling.Skip, AllowTrailingCommas = true };

    static bool IsWslSource(JsonNode? n) =>
        n is JsonValue v && v.TryGetValue<string>(out var s) && s == WslSource;

    internal static string HideProfileJson(string json)
    {
        try
        {
            var root = JsonNode.Parse(json, null, Jsonc);
            if (root is null) return json;
            var arr = root["disabledProfileSources"]?.AsArray();
            if (arr is null)
            {
                root["disabledProfileSources"] = new JsonArray(WslSource);
                return root.ToJsonString(Indented);
            }
            if (arr.Any(IsWslSource)) return json; // already set — byte-identical no-op
            arr.Add(WslSource);
            return root.ToJsonString(Indented);
        }
        catch { return json; } // malformed — leave untouched
    }

    internal static string UnhideProfileJson(string json)
    {
        try
        {
            var root = JsonNode.Parse(json, null, Jsonc);
            var arr = root?["disabledProfileSources"]?.AsArray();
            if (arr is null) return json;
            bool removed = false;
            for (int i = arr.Count - 1; i >= 0; i--)
                if (IsWslSource(arr[i])) { arr.RemoveAt(i); removed = true; }
            if (!removed) return json; // byte-identical no-op
            return root!.ToJsonString(Indented);
        }
        catch { return json; }
    }

    // Atomic: temp file + move, so a crash/concurrent Terminal save
    // cannot truncate the user's settings.
    static void WriteAtomic(string path, string content)
    {
        var tmp = path + ".basapos.tmp";
        File.WriteAllText(tmp, content);
        File.Move(tmp, path, overwrite: true);
    }

    static void HideTerminalProfile()
    {
        try
        {
            var p = TerminalSettingsPath;
            if (!File.Exists(p)) return; // no Terminal — nothing to hide
            var current = File.ReadAllText(p);
            var updated = HideProfileJson(current);
            if (updated != current) WriteAtomic(p, updated);
        }
        catch { /* best-effort cosmetic */ }
    }

    static void UnhideTerminalProfile()
    {
        try
        {
            var p = TerminalSettingsPath;
            if (!File.Exists(p)) return;
            var current = File.ReadAllText(p);
            var updated = UnhideProfileJson(current);
            if (updated != current) WriteAtomic(p, updated);
        }
        catch { }
    }
}
