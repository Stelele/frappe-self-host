using System.Diagnostics;
using System.Globalization;
using System.Text;

namespace BasaPOS.Setup.Install;

/// Runs a wsl.exe command as the NORMAL (non-elevated) logged-on user via a
/// one-shot scheduled task. Cure for the store-WSL quirk where --unregister
/// from an elevated process fails against distros whose lifecycle lives in the
/// unelevated user session — this replicates a plain terminal run (which is
/// proven to work on affected machines).
internal static class UnelevatedWsl
{
    public const string TaskName = "BasaPOS-Unelevated";

    public static string CmdPath => Path.Combine(Paths.ProgramData, "basapos-unelevated.cmd");

    /// true only when there is a real interactive user to re-run under
    /// (SYSTEM/CI service sessions have no user hive to help with).
    public static bool Available =>
        OperatingSystem.IsWindows()
        && !string.IsNullOrWhiteSpace(Environment.UserName)
        && !Environment.UserName.Equals("SYSTEM", StringComparison.OrdinalIgnoreCase);

    /// (bool Ok, string Error) — the shape RunEscalation feeds on.
    public static (bool Ok, string Error) TryUnregister(string name, int timeoutSeconds = 90)
    {
        try
        {
            var (ok, error) = Run($"--unregister \"{name}\"", timeoutSeconds);
            return (ok, error);
        }
        catch (Exception ex)
        {
            return (false, ex.Message);
        }
    }

    public static (bool Ok, string Error) Run(string wslArguments, int timeoutSeconds = 90)
    {
        if (!Available)
            return (false, "no interactive user session to re-run unelevated");
        var dir = Path.GetDirectoryName(CmdPath);
        if (dir is not null) Directory.CreateDirectory(dir);
        // Unique log per invocation: a crashed prior run must never poison this
        // one's EXITCODE polling (stale shared-log marker race).
        var log = Path.Combine(Paths.ProgramData, $"basapos-unelevated-{Guid.NewGuid():N}.log");
        try
        {
            File.WriteAllText(CmdPath,
                BuildCmd(log, Environment.SystemDirectory + @"\wsl.exe", wslArguments),
                new UTF8Encoding(encoderShouldEmitUTF8Identifier: false));
            var setup = WslRunner.RunAnsi("powershell.exe",
                "-NoProfile -ExecutionPolicy Bypass -Command \"" +
                BuildRunScript(Environment.UserName, CmdPath, TaskName) + "\"", 60);
            if (setup.ExitCode != 0)
                return (false, $"unelevated task could not start (exit {setup.ExitCode}): {setup.Error.Trim()}");

            var sw = Stopwatch.StartNew();
            while (sw.Elapsed.TotalSeconds < timeoutSeconds)
            {
                try
                {
                    if (File.Exists(log))
                    {
                        var text = File.ReadAllText(log);
                        var marker = text.LastIndexOf("EXITCODE=", StringComparison.Ordinal);
                        if (marker >= 0)
                        {
                            var raw = text[(marker + "EXITCODE=".Length)..].Trim();
                            // wsl.exe emits 32-bit exit codes, sometimes negative
                            // (e.g. 0x800703fa) — parse wide, compare to zero.
                            var ok = long.TryParse(raw, NumberStyles.Integer,
                                CultureInfo.InvariantCulture, out var code) && code == 0;
                            return (ok, BuildSummary(text, code));
                        }
                    }
                }
                catch { /* log briefly locked by the writer — keep polling */ }
                Thread.Sleep(1000);
            }
            return (false, $"unelevated unregister timed out after {timeoutSeconds}s");
        }
        finally
        {
            try { WslRunner.RunAnsi("schtasks.exe", $"/delete /tn {TaskName} /f", 60); } catch { }
            try { File.Delete(CmdPath); } catch { }
            try { File.Delete(log); } catch { }
        }
    }

    /// Pure cmd content — testable on any OS. Runs wsl with output redirected
    /// to the unique log, then stamps the exit code so pollers can detect
    /// completion. The `del` front ensures a stale log file from a prior
    /// invocation is never read.
    internal static string BuildCmd(string logPath, string wslExecutable, string wslArguments) =>
        "@echo off\r\n" +
        "del \"" + logPath + "\" 2>nul\r\n" +
        "\"" + wslExecutable + "\" " + wslArguments + " > \"" + logPath + "\" 2>&1\r\n" +
        "echo EXITCODE=%ERRORLEVEL% >> \"" + logPath + "\"\r\n";

    /// Pure PowerShell content — mirrors TaskRegistrar's proven pattern but as
    /// an immediate one-shot at LIMITED privilege + Interactive (no stored
    /// password required).
    internal static string BuildRunScript(string user, string cmdPath, string taskName)
    {
        var u = user.Replace("'", "''");
        var c = cmdPath.Replace("'", "''");
        var t = taskName.Replace("'", "''");
        return "$ErrorActionPreference='Stop'; " +
            "$a=New-ScheduledTaskAction -Execute '" + c + "'; " +
            "$p=New-ScheduledTaskPrincipal -UserId '" + u + "' -LogonType Interactive -RunLevel Limited; " +
            "$s=New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::FromMinutes(10)) -MultipleInstances IgnoreNew; " +
            "Register-ScheduledTask -TaskName '" + t + "' -Action $a -Principal $p -Settings $s -Force; " +
            "Start-ScheduledTask -TaskName '" + t + "'";
    }

    /// Pure log summarizer for error reporting.
    internal static string BuildSummary(string logText, long exitCode)
    {
        var idx = logText.LastIndexOf("EXITCODE=", StringComparison.Ordinal);
        var body = idx >= 0 ? logText[..idx] : logText;
        var trimmed = body.Trim();
        return $"wsl exited {exitCode}" + (trimmed.Length > 0 ? ": " + trimmed : string.Empty);
    }
}