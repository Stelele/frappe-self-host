using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Net.Http;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace BasaPOS
{
    static class Program
    {
        [STAThread]
        static void Main()
        {
            using var mutex = new Mutex(true, "BasaPOS_8A2C9B4E5D3F", out bool createdNew);
            if (!createdNew) { NativeMethods.BringToFront(); return; }
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Application.Run(new MainForm());
        }
    }

    static class NativeMethods
    {
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        static extern IntPtr FindWindow(string lpClassName, string lpWindowName);
        [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr hWnd);
        [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

        public static void BringToFront()
        {
            var h = FindWindow(null, "BasaPOS");
            if (h != IntPtr.Zero) { ShowWindow(h, 9); SetForegroundWindow(h); }
        }
    }

    class MainForm : Form
    {
        readonly string _appDir;
        readonly string _installedMarker;
        readonly string _statusFile;
        readonly string _credsFile;
        readonly Func<string> _siteUrl;
        Label _statusLabel;
        Panel _statusDot;
        TextBox _log;
        Button _btnStart, _btnStop, _btnBackup, _btnOpen, _btnRepair, _btnCreds;
        bool _busy;

        public MainForm()
        {
            Text = "BasaPOS";
            ClientSize = new Size(860, 500);
            StartPosition = FormStartPosition.CenterScreen;
            FormBorderStyle = FormBorderStyle.FixedSingle;
            MaximizeBox = false;

            _appDir = AppContext.BaseDirectory;
            var installRoot = Path.GetFullPath(Path.Combine(_appDir, ".."));
            _installedMarker = Path.Combine(installRoot, "installed.txt");
            _statusFile = Path.Combine(installRoot, "appliance-status.txt");
            _credsFile = Path.Combine(installRoot, "config", "credentials.txt");
            var settingsFile = Path.Combine(installRoot, "app", "settings.txt");
            _siteUrl = () => ReadDomain(settingsFile);

            BuildUi();
            Load += async (s, e) => await RefreshStatusAsync();
            var statusTimer = new Timer { Interval = 15000 };
            statusTimer.Tick += async (s, e) => await RefreshStatusAsync();
            statusTimer.Start();
        }

        string ReadDomain(string settingsFile)
        {
            try
            {
                if (File.Exists(settingsFile))
                    foreach (var line in File.ReadAllLines(settingsFile))
                        if (line.StartsWith("DOMAIN="))
                            return "https://" + line.Substring(7).Trim();
            }
            catch { }
            return "https://basapos.local";
        }

        Button MakeButton(string text, int x)
        {
            var b = new Button
            {
                Text = text, Size = new Size(96, 32), Location = new Point(x, 10),
                FlatStyle = FlatStyle.FlatStyle.Flat,
                BackColor = Color.White, ForeColor = Color.FromArgb(32, 32, 32)
            };
            b.FlatAppearance.BorderColor = Color.FromArgb(200, 200, 200);
            return b;
        }

        void BuildUi()
        {
            var top = new Panel { Dock = DockStyle.Top, Height = 56, Padding = new Padding(10, 10, 10, 6) };
            _statusDot = new Panel { Size = new Size(14, 14), BackColor = Color.Gray, Location = new Point(12, 18) };
            _statusLabel = new Label
            {
                AutoSize = true, Font = new Font("Segoe UI", 10f, FontStyle.Bold),
                ForeColor = Color.FromArgb(64, 64, 64), Location = new Point(34, 18)
            };
            _btnStart = MakeButton("Start", 852);
            _btnStop = MakeButton("Stop", 752);
            _btnBackup = MakeButton("Backup", 652);
            _btnOpen = MakeButton("Open App", 532);
            _btnRepair = MakeButton("Repair", 432);
            _btnCreds = MakeButton("Password", 320);

            _btnStart.Click += async (s, e) => await OnStartAsync();
            _btnStop.Click += async (s, e) => await OnStopAsync();
            _btnBackup.Click += async (s, e) => await OnRunScriptAsync("backup.ps1");
            _btnOpen.Click += async (s, e) => await OnOpenAsync();
            _btnRepair.Click += async (s, e) => await OnRepairAsync();
            _btnCreds.Click += (s, e) => ShowCredentials();

            top.Controls.AddRange(new Control[] { _statusDot, _statusLabel,
                _btnStart, _btnStop, _btnBackup, _btnOpen, _btnRepair, _btnCreds });

            _log = new TextBox
            {
                Dock = DockStyle.Fill, Multiline = true, ReadOnly = true,
                ScrollBars = ScrollBars.Vertical, Font = new Font("Consolas", 9.5f),
                BackColor = Color.FromArgb(30, 30, 30), ForeColor = Color.FromArgb(220, 220, 220)
            };
            var panel = new Panel { Dock = DockStyle.Fill, Padding = new Padding(10, 8, 10, 10) };
            panel.Controls.Add(_log);
            Controls.Add(panel);
            Controls.Add(top);
        }

        void SetBusy(bool busy)
        {
            _busy = busy;
            foreach (var b in new[] { _btnStart, _btnStop, _btnBackup, _btnOpen, _btnRepair })
                b.Enabled = !busy;
        }

        void AppendLog(string line)
        {
            if (InvokeRequired) { BeginInvoke(new Action<string>(AppendLog), line); return; }
            _log.AppendText(line + Environment.NewLine);
            _log.ScrollToCaret();
        }

        void SetStatus(Color c, string text)
        {
            if (InvokeRequired) { BeginInvoke(new Action<Color, string>(SetStatus), c, text); return; }
            _statusDot.BackColor = c;
            _statusDot.Invalidate();
            _statusLabel.Text = text;
        }

        static readonly HttpClient _http = CreateHttpClient();
        static HttpClient CreateHttpClient()
        {
            var handler = new HttpClientHandler();
            handler.ServerCertificateCustomValidationCallback = (m, c, ch, e) => true;
            return new HttpClient(handler) { Timeout = TimeSpan.FromSeconds(8) };
        }

        async Task<bool> IsSiteUpAsync()
        {
            try { using var r = await _http.GetAsync(_siteUrl()); return r.IsSuccessStatusCode; }
            catch { return false; }
        }

        bool DistroVhdPresent() =>
            File.Exists(Path.GetFullPath(Path.Combine(_appDir, "..", "data", "distro", "ext4.vhdx")));

        async Task RefreshStatusAsync()
        {
            if (_busy) return;
            if (!File.Exists(_installedMarker)) { SetStatus(Color.Gray, "Not installed"); return; }
            if (!DistroVhdPresent()) { SetStatus(Color.Red, "Appliance missing - use Repair"); return; }
            var st = File.Exists(_statusFile) ? File.ReadAllText(_statusFile).Trim() : "";
            if (await IsSiteUpAsync()) SetStatus(Color.ForestGreen, "Running");
            else if (st == "ERROR_HEALTH" || st == "ERROR_WAKE") SetStatus(Color.Red, "Error (" + st + ") - see Repair / logs");
            else SetStatus(Color.Orange, "Starting...");
        }

        async Task RunProcessAsync(string fileName, string arguments, string workingDir)
        {
            var psi = new ProcessStartInfo
            {
                FileName = fileName, Arguments = arguments, WorkingDirectory = workingDir,
                UseShellExecute = false, CreateNoWindow = true,
                RedirectStandardOutput = true, RedirectStandardError = true
            };
            using var proc = new Process { StartInfo = psi };
            proc.OutputDataReceived += (s, e) => { if (!string.IsNullOrEmpty(e.Data)) AppendLog(e.Data); };
            proc.ErrorDataReceived += (s, e) => { if (!string.IsNullOrEmpty(e.Data)) AppendLog(e.Data); };
            try { proc.Start(); } catch (Exception ex) { AppendLog("Failed to launch: " + ex.Message); return; }
            proc.BeginOutputReadLine();
            proc.BeginErrorReadLine();
            await proc.WaitForExitAsync();
        }

        async Task OnStartAsync()
        {
            if (_busy || !File.Exists(_installedMarker)) return;
            SetBusy(true); AppendLog("== Starting ==");
            await WaitForSiteAsync(TimeSpan.FromMinutes(5));
            AppendLog("== Done =="); await RefreshStatusAsync(); SetBusy(false);
        }

        async Task<bool> WaitForSiteAsync(TimeSpan timeout)
        {
            AppendLog("Booting appliance (services start automatically)...");
            await RunProcessAsync("wsl.exe", $"-d BasaPOS -u root --exec /bin/true", _appDir);
            var deadline = DateTime.UtcNow + timeout;
            while (DateTime.UtcNow < deadline)
            {
                if (await IsSiteUpAsync()) { AppendLog("Site is ready."); return true; }
                await Task.Delay(3000);
            }
            AppendLog("WARN: site not responding yet.");
            return false;
        }

        async Task OnStopAsync()
        {
            if (_busy || !File.Exists(_installedMarker)) return;
            SetBusy(true); AppendLog("== Stopping (data preserved) ==");
            await RunProcessAsync("wsl.exe", "--terminate BasaPOS", _appDir);
            SetStatus(Color.Gray, "Stopped");
            AppendLog("== Done =="); SetBusy(false);
        }

        async Task OnRunScriptAsync(string script)
        {
            if (_busy || !File.Exists(_installedMarker)) return;
            SetBusy(true); AppendLog("== " + script + " ==");
            var p = Path.Combine(Path.GetDirectoryName(_appDir)!, "payload", "app", "scripts", script);
            if (!File.Exists(p)) p = Path.Combine(_appDir, "..", "payload", "install", script);
            await RunProcessAsync("powershell.exe",
                $"-NoProfile -ExecutionPolicy Bypass -File \"{p}\"",
                Path.GetDirectoryName(p)!);
            AppendLog("== Done =="); await RefreshStatusAsync(); SetBusy(false);
        }

        async Task OnOpenAsync()
        {
            if (_busy || !File.Exists(_installedMarker)) return;
            SetBusy(true);
            try
            {
                await WaitForSiteAsync(TimeSpan.FromMinutes(5));
                Process.Start(new ProcessStartInfo(_siteUrl()) { UseShellExecute = true });
            }
            catch (Exception ex) { AppendLog("Could not open app: " + ex.Message); }
            finally { await RefreshStatusAsync(); SetBusy(false); }
        }

        async Task OnRepairAsync()
        {
            if (_busy || !File.Exists(_installedMarker)) return;
            SetBusy(true); AppendLog("== Repair ==");
            var installRoot = Path.GetFullPath(Path.Combine(_appDir, ".."));
            var install = Path.Combine(installRoot, "payload", "install");
            if (!DistroVhdPresent())
                await RunProcessAsync("wsl.exe",
                    "--import BasaPOS \"" + Path.Combine(installRoot, "data", "distro") + "\" \"" + Path.Combine(installRoot, "rootfs", "basapos-rootfs.tar.gz") + "\"",
                    _appDir);
            await RunProcessAsync("powershell.exe",
                "-NoProfile -ExecutionPolicy Bypass -File \"" + Path.Combine(install, "register-autostart.ps1") + "\" -InstallRoot \"" + installRoot + "\"",
                install);
            await WaitForSiteAsync(TimeSpan.FromMinutes(5));
            AppendLog("== Done =="); await RefreshStatusAsync(); SetBusy(false);
        }

        void ShowCredentials()
        {
            try
            {
                if (!File.Exists(_credsFile)) { AppendLog("credentials.txt not found"); return; }
                MessageBox.Show(File.ReadAllText(_credsFile), "BasaPOS Credentials",
                    MessageBoxButtons.OK, MessageBoxIcon.Information);
            }
            catch (Exception ex) { AppendLog("Could not read credentials: " + ex.Message); }
        }
    }
}
