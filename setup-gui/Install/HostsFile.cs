namespace BasaPOS.Setup.Install;

public static class HostsFile
{
    const string HostsPath = @"C:\Windows\System32\drivers\etc\hosts";
    static readonly string Entry = $"127.0.0.1 {Paths.Domain}";

    public static bool HasEntry(string hostsContent) =>
        hostsContent.Split('\n', StringSplitOptions.RemoveEmptyEntries)
            .Select(l => l.Trim())
            .Any(l =>
            {
                var tokens = l.Split((char[])null, StringSplitOptions.RemoveEmptyEntries);
                return tokens.Length >= 2
                    && tokens[0].Equals("127.0.0.1", StringComparison.OrdinalIgnoreCase)
                    && tokens[1].Equals(Paths.Domain, StringComparison.OrdinalIgnoreCase);
            });

    public static void Ensure()
    {
        var content = File.ReadAllText(HostsPath);
        if (HasEntry(content)) return;
        File.AppendAllText(HostsPath, $"\n{Entry}\n");
    }

    public static void Remove()
    {
        var content = File.ReadAllText(HostsPath);
        var kept = content.Split('\n')
            .Where(l => !HasEntry(l))
            .ToList();
        File.WriteAllText(HostsPath, string.Join("\n", kept));
    }
}