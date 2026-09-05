namespace BasaPOS.Keeper;

public sealed class HeartbeatLog(string path)
{
    public void Write(string line)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            if (File.Exists(path) && new FileInfo(path).Length > (1 << 20))
            {
                var bak = path + ".1";
                try { if (File.Exists(bak)) File.Delete(bak); } catch { }
                try { File.Move(path, bak); } catch { }
            }
            File.AppendAllText(path, $"[{DateTime.UtcNow:yyyy-MM-dd HH:mm:ss}] {line}\n");
        }
        catch { /* logging never crashes the keeper */ }
    }
}
