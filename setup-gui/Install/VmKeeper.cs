using System.Diagnostics;

namespace BasaPOS.Setup.Install;

/// Holds a long-lived wsl.exe client session open so the WSL2 VM does not
/// idle-shutdown during firstboot. The VM's vmIdleTimeout (configurable in
/// .wslconfig) is measured by connected client sessions, not CPU activity —
/// without a keeper, a VM with no active wsl.exe command shuts down ~60s in,
/// killing a multi-minute `docker load` mid-stream (v2 field lesson).
public sealed class VmKeeper : IDisposable
{
    readonly Process _p;

    VmKeeper(Process p) => _p = p;

    public static VmKeeper Start()
    {
        var p = new Process
        {
            StartInfo = new ProcessStartInfo
            {
                FileName = Environment.SystemDirectory + @"\wsl.exe",
                Arguments = $"-d {Paths.DistroName} --exec /bin/sleep 7200",
                UseShellExecute = false,
                CreateNoWindow = true,
            },
        };
        p.Start();
        return new VmKeeper(p);
    }

    public void Dispose()
    {
        try { if (!_p.HasExited) _p.Kill(entireProcessTree: true); }
        catch { /* already gone */ }
        _p.Dispose();
    }
}
