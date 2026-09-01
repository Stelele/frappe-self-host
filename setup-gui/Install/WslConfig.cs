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

    public static void RemoveManagedBlock()
    {
        if (!File.Exists(WslConfigPath)) return;
        var existing = File.ReadAllText(WslConfigPath);
        var cleaned = StripOrphanFragment(StripManagedBlock(existing));
        if (cleaned.Trim().Length == 0) File.Delete(WslConfigPath);
        else File.WriteAllText(WslConfigPath, cleaned);
    }

    internal static string StripManagedBlock(string content) =>
        System.Text.RegularExpressions.Regex.Replace(
            content, Escape(Begin) + @".*?--- end BasaPOS ---\r?\n?", "",
            System.Text.RegularExpressions.RegexOptions.Singleline);

    internal static string StripOrphanFragment(string content) =>
        System.Text.RegularExpressions.Regex.Replace(
            content, Escape(Begin) + @"(?s:.*)$", "",
            System.Text.RegularExpressions.RegexOptions.None);

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