using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

namespace BasaPOS.Keeper;

public sealed class ProcessRunner : IProcessRunner
{
    public static IReadOnlyList<string> ParseDistroNames(string output) =>
        output.Split('\n')
            .Select(l => l.Trim().TrimEnd('\r'))
            .Where(l => l.Length > 0)
            .ToList();

    public IChildProcess SpawnWslKeepalive()
    {
        var psi = new ProcessStartInfo
        {
            FileName = Environment.SystemDirectory + @"\wsl.exe",
            Arguments = "-d BasaPOS --exec /bin/sleep infinity",
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardError = true, // stdout NOT redirected: sleep writes nothing; avoids pipe stall
        };
        var p = Process.Start(psi) ?? throw new InvalidOperationException("failed to start wsl.exe");
        var job = JobObject.CreateKillOnClose();
        JobObject.Assign(job, p);
        return new WslChild(p, job);
    }

    public IReadOnlyList<string> ListDistros()
    {
        try
        {
            var psi = new ProcessStartInfo
            {
                FileName = Environment.SystemDirectory + @"\wsl.exe",
                Arguments = "--list --quiet",
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                StandardOutputEncoding = Encoding.Unicode, // wsl.exe emits UTF-16
            };
            using var p = Process.Start(psi) ?? throw new InvalidOperationException("failed to start wsl.exe");
            var output = p.StandardOutput.ReadToEnd();
            if (!p.WaitForExit(30_000)) { try { p.Kill(true); } catch { } return Array.Empty<string>(); }
            return ParseDistroNames(output);
        }
        catch { return Array.Empty<string>(); } // never throw: absence of data ≠ absence of distro is handled by retry logic
    }
}

sealed class WslChild(Process process, IntPtr job) : IChildProcess
{
    readonly StringBuilder _stderr = new();
    bool _drained;
    public int Pid { get { try { return process.Id; } catch { return -1; } } }

    public int ExitCode { get { try { return process.HasExited ? process.ExitCode : -1; } catch { return -1; } } }

    public string StderrTail { get { Drain(); lock (_stderr) return _stderr.Length <= 2048 ? _stderr.ToString() : _stderr.ToString()[^2048..]; } }
    public bool Exited() { try { return process.HasExited; } catch { return true; } }
    public int WaitForExit(int msTimeout) { try { return process.WaitForExit(msTimeout) ? 0 : 1; } catch { return 0; } }
    public void KillTree() { try { process.Kill(true); } catch { } }
    public void Dispose() { try { process.Dispose(); } catch { } try { JobObject.Close(job); } catch { } }

    void Drain()
    {
        if (_drained) return; _drained = true;
        try
        {
            // child is long-lived; read whatever stderr has arrived WITHOUT blocking:
            // poll in small slices only while data is available
            while (process.StandardError.Peek() > -1 && _stderr.Length < 4096)
                _stderr.Append((char)process.StandardError.Read());
        }
        catch { }
    }
}

static class JobObject
{
    const int JobObjectExtendedLimitInformation = 9;
    const int JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x2000;

    [StructLayout(LayoutKind.Sequential)]
    struct JOBOBJECT_BASIC_LIMIT_INFORMATION
    {
        public long PerProcessUserTimeLimit;
        public long JobMemoryLimit;
        public int LimitFlags;
        public UIntPtr MinimumWorkingSetSize;
        public UIntPtr MaximumWorkingSetSize;
        public int ActiveProcessLimit;
        public UIntPtr Affinity;
        public int PriorityClass;
        public int SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct IO_COUNTERS
    {
        public ulong ReadOperationCount, WriteOperationCount, OtherOperationCount;
        public ulong ReadTransferCount, WriteTransferCount, OtherTransferCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION
    {
        public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
        public IO_COUNTERS IoInfo;
        public UIntPtr ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    static extern IntPtr CreateJobObject(IntPtr attrs, string? name);
    [DllImport("kernel32.dll")]
    static extern bool SetInformationJobObject(IntPtr job, int infoClass, ref JOBOBJECT_EXTENDED_LIMIT_INFORMATION info, int size);
    [DllImport("kernel32.dll")]
    static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
    [DllImport("kernel32.dll")]
    static extern bool CloseHandle(IntPtr handle);

    public static IntPtr CreateKillOnClose()
    {
        var job = CreateJobObject(IntPtr.Zero, null);
        if (job == IntPtr.Zero) throw new InvalidOperationException("CreateJobObject failed");
        var info = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION
        {
            BasicLimitInformation = new JOBOBJECT_BASIC_LIMIT_INFORMATION { LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE }
        };
        if (!SetInformationJobObject(job, JobObjectExtendedLimitInformation, ref info, Marshal.SizeOf<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>()))
        { CloseHandle(job); throw new InvalidOperationException("SetInformationJobObject failed"); }
        return job;
    }

    public static void Assign(IntPtr job, Process p)
    {
        try
        {
            if (!AssignProcessToJobObject(job, p.Handle))
                throw new InvalidOperationException("AssignProcessToJobObject failed");
        }
        catch { CloseHandle(job); throw; }
    }

    public static void Close(IntPtr job) { try { if (job != IntPtr.Zero) CloseHandle(job); } catch { } }
}
