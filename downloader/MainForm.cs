using BasaPOS.Downloader;
using System.Diagnostics;

namespace BasaPOS.DownloaderUI;

public sealed class MainForm : Form
{
    readonly Label _status = new() { Dock = DockStyle.Fill, TextAlign = ContentAlignment.MiddleCenter };
    readonly ProgressBar _progress = new() { Dock = DockStyle.Bottom, Height = 28 };
    readonly Button _cancel = new() { Dock = DockStyle.Right, Text = "Cancel", Width = 90 };
    CancellationTokenSource _cts = new();

    public MainForm(string tag, string dest, bool launch)
    {
        Text = "BasaPOS Downloader";
        Width = 560; Height = 220;
        var panel = new Panel { Dock = DockStyle.Top, Height = 120, Padding = new Padding(16) };
        panel.Controls.Add(_status);
        var bar = new Panel { Dock = DockStyle.Bottom, Height = 40 };
        bar.Controls.Add(_cancel);
        bar.Controls.Add(_progress);
        Controls.Add(panel);
        Controls.Add(bar);

        _cancel.Click += (_, _) => _cts.Cancel();
        Shown += async (_, _) =>
        {
            _status.Text = "Starting…";
            try
            {
                var dl = new PayloadDownloader { Tag = tag, Dest = dest, LaunchInstaller = launch };
                await dl.RunAsync(
                    s => Safe(() => _status.Text = s),
                    p => Safe(() => _progress.Value = (int)(p * 100)),
                    _cts.Token);
                Safe(() => _status.Text = "Downloaded and verified.");
                if (launch && !_cts.IsCancellationRequested)
                {
                    var setup = Path.Combine(
                        string.IsNullOrEmpty(dest) ? Path.GetDirectoryName(AppContext.BaseDirectory)! : dest,
                        "BasaPOS-Setup.exe");
                    if (File.Exists(setup))
                        Process.Start(new ProcessStartInfo(setup) { UseShellExecute = true, Verb = "runas" });
                    else
                        Safe(() => _status.Text = "Done — BasaPOS-Setup.exe not found.");
                }
                else
                {
                    Safe(() => _status.Text = "Done. Close this window.");
                }
            }
            catch (OperationCanceledException)
            {
                Safe(() => _status.Text = "Cancelled.");
            }
            catch (Exception ex)
            {
                Safe(() => _status.Text = "Error: " + ex.Message);
                MessageBox.Show(ex.Message, "BasaPOS Downloader", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
            _cancel.Enabled = false;
        };
    }

    void Safe(Action a)
    {
        if (IsDisposed) return;
        if (InvokeRequired) { try { BeginInvoke(a); } catch { } }
        else a();
    }
}
