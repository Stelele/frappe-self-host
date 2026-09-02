using BasaPOS.Downloader;
using BasaPOS.DownloaderUI;

var tag = Arg("--tag");
var dest = Arg("--dest");
var noLaunch = args.Contains("--no-launch");
var unattended = args.Contains("--unattended");

if (unattended)
{
    Environment.Exit(await RunHeadless(tag, dest, !noLaunch));
    return;
}

ApplicationConfiguration.Initialize();
Application.Run(new MainForm(tag, dest, !noLaunch));

string Arg(string name)
{
    var i = Array.IndexOf(args, name);
    return i >= 0 && i + 1 < args.Length ? args[i + 1] : "";
}

async Task<int> RunHeadless(string tagValue, string destValue, bool launch)
{
    void Say(string s) => Console.WriteLine($"[{DateTime.Now:HH:mm:ss}] {s}");
    try
    {
        var dl = new PayloadDownloader { Tag = tagValue, Dest = destValue, LaunchInstaller = launch };
        await dl.RunAsync(Say,
            p => { if ((int)(p * 100) % 10 == 0) Console.WriteLine($"  {(int)(p * 100)}%"); },
            CancellationToken.None);
        return 0;
    }
    catch (Exception ex)
    {
        Say($"FATAL: {ex.Message}");
        return 1;
    }
}
