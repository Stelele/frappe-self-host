using System.Text.Json;
using System.Text.Json.Nodes;

namespace BasaPOS.Setup.Install;

public static class ShortcutCreator
{
    public const string LinkName = "BasaPOS.lnk";
    public static string StartMenuLink => Environment.GetFolderPath(Environment.SpecialFolder.CommonStartMenu) + @"\Programs\" + LinkName;
    public static string DesktopLink => Environment.GetFolderPath(Environment.SpecialFolder.CommonDesktopDirectory) + "\\" + LinkName;
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

    static readonly JsonSerializerOptions Indented = new() { WriteIndented = true };

    internal static string HideProfileJson(string json)
    {
        var root = JsonNode.Parse(json) ?? new JsonObject();
        var list = root["profiles"]?["list"]?.AsArray();
        if (list is null) return json;
        if (!list.Any(n => n?["name"]?.GetValue<string>() == "BasaPOS"))
            list.Add(new JsonObject { ["name"] = "BasaPOS", ["hidden"] = true });
        return root.ToJsonString(Indented);
    }

    internal static string UnhideProfileJson(string json)
    {
        var root = JsonNode.Parse(json);
        var list = root?["profiles"]?["list"]?.AsArray();
        if (list is null) return json;
        for (int i = list.Count - 1; i >= 0; i--)
            if (list[i] is JsonObject o && o.Count == 2
                && o["name"]?.GetValue<string>() == "BasaPOS"
                && o["hidden"]?.GetValue<bool>() == true)
                list.RemoveAt(i);
        return root!.ToJsonString(Indented);
    }

    static void HideTerminalProfile()
    {
        try
        {
            var p = TerminalSettingsPath;
            if (!File.Exists(p)) return; // no Terminal — nothing to hide
            File.WriteAllText(p, HideProfileJson(File.ReadAllText(p)));
        }
        catch { /* best-effort cosmetic */ }
    }

    static void UnhideTerminalProfile()
    {
        try
        {
            var p = TerminalSettingsPath;
            if (!File.Exists(p)) return;
            File.WriteAllText(p, UnhideProfileJson(File.ReadAllText(p)));
        }
        catch { }
    }
}
