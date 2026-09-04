namespace BasaPOS.Setup.Install;

public static class WslConfig
{
    static readonly string WslConfigPath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".wslconfig");
    const string Begin = "# --- BasaPOS (managed) ---";

    public static string Render(long memoryBytes) =>
        $"{Begin}\n[wsl2]\nvmIdleTimeout=-1\nmemory={memoryBytes / (1024L * 1024 * 1024)}GB\n# --- end BasaPOS ---\n";

    public static void Write(long memoryBytes)
    {
        var existing = File.Exists(WslConfigPath) ? File.ReadAllText(WslConfigPath) : "";
        var block = Render(memoryBytes);
        var final = StripManagedBlock(existing).TrimEnd() + "\n" + block;
        WriteAtomic(WslConfigPath, final);
    }

    /// Removes ALL BasaPOS-managed blocks (case-insensitive Begin/End markers,
    /// every occurrence, across all versions) plus orphan fragments. Deletes the
    /// file if nothing meaningful remains (only whitespace/comments/empty
    /// sections — an empty [wsl2] is harmless but pointless to keep). Returns a
    /// description of any non-BasaPOS content left behind ("" if clean) so
    /// callers can warn.
    public static string RemoveManagedBlock()
    {
        if (!File.Exists(WslConfigPath)) return "";
        var existing = File.ReadAllText(WslConfigPath);
        var cleaned = StripOrphanFragment(StripManagedBlock(existing));
        if (!HasKeys(cleaned)) { try { File.Delete(WslConfigPath); } catch { } return ""; }
        File.WriteAllText(WslConfigPath, cleaned);
        return SummarizeLeftovers(cleaned);
    }

    internal static string StripManagedBlock(string content) =>
        System.Text.RegularExpressions.Regex.Replace(
            content,
            @"#\s*---\s*basapos\s*\(managed\)\s*---.*?---\s*end\s+basapos\s*---\r?\n?",
            "",
            System.Text.RegularExpressions.RegexOptions.Singleline
            | System.Text.RegularExpressions.RegexOptions.IgnoreCase);

    internal static string StripOrphanFragment(string content) =>
        System.Text.RegularExpressions.Regex.Replace(
            content,
            @"#\s*---\s*basapos\s*\(managed\)\s*---(?s:.*)$",
            "",
            System.Text.RegularExpressions.RegexOptions.IgnoreCase);

    /// All non-blank, non-comment lines left in the file (including section
    /// headers like [wsl2]) — i.e. foreign keys we did NOT touch.
    internal static string SummarizeLeftovers(string content) =>
        string.Join("\n", content.Split('\n')
            .Select(l => l.Trim())
            .Where(l => l.Length > 0 && !l.StartsWith("#")));

    /// True if the content has any actual key=value lines (vs only
    /// whitespace, comments, or bare section headers).
    internal static bool HasKeys(string content) =>
        content.Split('\n').Any(l => {
            var t = l.Trim();
            return t.Length > 0 && !t.StartsWith("#") && !t.StartsWith(";")
                && !t.StartsWith("[") && t.Contains('=');
        });

    static void WriteAtomic(string path, string content)
    {
        var tmp = path + ".basapos.tmp";
        File.WriteAllText(tmp, content);
        if (File.Exists(path)) File.Replace(tmp, path, null);
        else File.Move(tmp, path);
    }

    static string Escape(string s) =>
        System.Text.RegularExpressions.Regex.Escape(s);
}