using BasaPOS.Setup.Install;
using System.Diagnostics;

namespace BasaPOS.Setup;

public sealed class MainForm : Form, ISetupUi
{
    readonly ListBox _status = new() { Dock = DockStyle.Fill, IntegralHeight = false };
    readonly ProgressBar _progress = new() { Dock = DockStyle.Bottom, Height = 24 };
    readonly FlowLayoutPanel _buttons = new()
        { Dock = DockStyle.Bottom, Height = 48, FlowDirection = FlowDirection.LeftToRight };
    readonly Button _btnInstall = new() { Text = "Install", AutoSize = true };
    readonly Button _btnUninstall = new() { Text = "Uninstall", AutoSize = true };
    readonly Button _btnOpen = new() { Text = "Open BasaPOS", AutoSize = true };
    bool _busy;

#pragma warning disable WFO1000
    public bool Healthy { get; set; }
#pragma warning restore WFO1000

    public MainForm()
    {
        Text = "BasaPOS Setup";
        Width = 640; Height = 480;
        Controls.Add(_status); Controls.Add(_progress); Controls.Add(_buttons);
        _buttons.Controls.Add(_btnInstall);
        _buttons.Controls.Add(_btnUninstall);
        _buttons.Controls.Add(_btnOpen);
        _btnInstall.Click += async (_, _) => await RunBusy(() =>
        {
            if (Detect.IsInstalled())
            {
                Status("Reinstall: uninstalling current installation…");
                new Uninstaller(this).Run(keepBackups: true);
            }
            new InstallOrchestrator(this).RunAll();
        });
        _btnUninstall.Click += async (_, _) => await RunBusy(() => new Uninstaller(this).Run());
        _btnOpen.Click += (_, _) =>
            Process.Start(new ProcessStartInfo(Paths.SiteUrl) { UseShellExecute = true });
        Shown += (_, _) => RefreshState();
    }

    void RefreshState()
    {
        bool installed = Detect.IsInstalled();
        _btnInstall.Text = installed ? "Reinstall" : "Install";
        _btnInstall.Enabled = _btnUninstall.Enabled = !_busy;
        _status.Items.Clear();
        _status.Items.Add(installed ? "BasaPOS is installed." : "BasaPOS is not installed.");
        if (installed) _status.Items.Add($"Distro: {Paths.DistroName}  |  Site: {Paths.SiteUrl}");
    }

    async Task RunBusy(Action work)
    {
        _busy = true; _btnInstall.Enabled = _btnUninstall.Enabled = false;
        try { await Task.Run(work); }
        catch (Exception ex)
        {
            Status($"ERROR: {ex.Message}");
            MessageBox.Show(ex.Message, "BasaPOS Setup");
        }
        _busy = false; RefreshState();
    }

    public void Status(string line)
    {
        if (InvokeRequired) BeginInvoke(() => _status.Items.Add(line));
        else _status.Items.Add(line);
    }

    public void Progress(int pct)
    {
        if (InvokeRequired) BeginInvoke(() => _progress.Value = Math.Clamp(pct, 0, 100));
        else _progress.Value = Math.Clamp(pct, 0, 100);
    }

    public void ShowDone(string password)
    {
        Healthy = true;
        if (InvokeRequired) BeginInvoke(() => ShowDoneCore(password));
        else ShowDoneCore(password);
    }

    void ShowDoneCore(string password)
    {
        Status($"DONE. Administrator password: {password}   (also in {Paths.ConfigDir}\\credentials.txt)");
        MessageBox.Show(
            $"Administrator password: {password}\n\nSaved to {Paths.ConfigDir}\\credentials.txt",
            "BasaPOS installed", MessageBoxButtons.OK, MessageBoxIcon.Information);
    }

    public void ShowReboot(string message)
    {
        Status(message);
        if (InvokeRequired) BeginInvoke(() => MessageBox.Show(message, "BasaPOS Setup — reboot needed"));
        else MessageBox.Show(message, "BasaPOS Setup — reboot needed");
    }
}
