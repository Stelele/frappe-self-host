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
        if (existing.Contains(Begin))
            existing = StripManagedBlock(existing);
        File.WriteAllText(WslConfigPath, existing.TrimEnd() + "\n" + block);
    }

    public static void RemoveManagedBlock()
    {
        if (!File.Exists(WslConfigPath)) return;
        var existing = File.ReadAllText(WslConfigPath);
        var cleaned = StripManagedBlock(existing);
        if (cleaned.Trim().Length == 0) File.Delete(WslConfigPath);
        else File.WriteAllText(WslConfigPath, cleaned);
    }

    internal static string StripManagedBlock(string content) =>
        System.Text.RegularExpressions.Regex.Replace(
            content, Escape(Begin) + @".*?--- end BasaPOS ---\r?\n?", "",
            System.Text.RegularExpressions.RegexOptions.Singleline);

    static string Escape(string s) =>
        System.Text.RegularExpressions.Regex.Escape(s);
}