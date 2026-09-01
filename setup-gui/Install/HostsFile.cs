namespace BasaPOS.Setup.Install;

public static class HostsFile
{
    const string HostsPath = @"C:\Windows\System32\drivers\etc\hosts";
    static readonly string Entry = $"127.0.0.1 {Paths.Domain}";

    public static bool HasEntry(string hostsContent) =>
        hostsContent.Split('\n', StringSplitOptions.RemoveEmptyEntries)
            .Select(l => l.Trim())
            .Any(l => l.Equals(Entry, StringComparison.OrdinalIgnoreCase));

    public static void Ensure()
    {
        var content = File.ReadAllText(HostsPath);
        if (HasEntry(content)) return;
        File.AppendAllText(HostsPath, $"\n{Entry}\n");
    }

    public static void Remove()
    {
        var lines = File.ReadAllLines(HostsPath)
            .Where(l => !l.Trim().Equals(Entry, StringComparison.OrdinalIgnoreCase));
        File.WriteAllLines(HostsPath, lines);
    }
}