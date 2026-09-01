using System.Diagnostics;
using System.Text;

namespace BasaPOS.Setup.Install;

public sealed record ProcResult(int ExitCode, string Output, string Error);

/// Hardened external-process wrapper. v2 lessons baked in:
/// - per-call timeouts (wsl.exe can hang forever without one)
/// - CreateNoWindow (no console flashes)
/// - wsl.exe emits UTF-16; other tools emit console codepage → two entry points
/// - stdout/stderr drained via ReadToEndAsync BEFORE WaitForExit (deadlock-safe)
public static class WslRunner
{
    public static ProcResult Run(string fileName, string arguments, int timeoutSeconds = 600,
        Action<string>? onLine = null)
        => RunCore(fileName, arguments, timeoutSeconds, Encoding.Unicode, onLine);

    public static ProcResult RunAnsi(string fileName, string arguments, int timeoutSeconds = 600,
        Action<string>? onLine = null)
        => RunCore(fileName, arguments, timeoutSeconds, Console.OutputEncoding, onLine);

    public static ProcResult Wsl(string arguments, int timeoutSeconds = 600,
        Action<string>? onLine = null)
        => Run(Environment.SystemDirectory + @"\wsl.exe", arguments, timeoutSeconds, onLine);

    static ProcResult RunCore(string fileName, string arguments, int timeoutSeconds,
        Encoding outputEncoding, Action<string>? onLine)
    {
        var psi = new ProcessStartInfo
        {
            FileName = fileName,
            Arguments = arguments,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            StandardOutputEncoding = outputEncoding,
            StandardErrorEncoding = outputEncoding,
        };
        using var p = Process.Start(psi)
            ?? throw new InvalidOperationException($"failed to start {fileName}");
        var outTask = p.StandardOutput.ReadToEndAsync();
        var errTask = p.StandardError.ReadToEndAsync();
        if (!p.WaitForExit(timeoutSeconds * 1000))
        {
            p.Kill(entireProcessTree: true);
            throw new TimeoutException($"{fileName} timed out after {timeoutSeconds}s");
        }
        p.WaitForExit(); // flush async reads
        var output = outTask.Result;
        var error = errTask.Result;
        if (onLine != null)
            foreach (var line in output.Split('\n', StringSplitOptions.RemoveEmptyEntries))
                onLine(line.TrimEnd('\r'));
        return new ProcResult(p.ExitCode, output, error);
    }
}
