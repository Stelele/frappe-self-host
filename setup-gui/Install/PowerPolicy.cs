using Microsoft.Win32;

namespace BasaPOS.Setup.Install;

public sealed record RegValue(string SubKey, string Name, object Value);

public static class PowerPolicy
{
    internal static string[] PowerCfgCommands() => new[]
    {
        "powercfg.exe -change -standby-timeout-ac 0",
        "powercfg.exe -hibernate-timeout-ac 0",
    };

    internal static RegValue[] UpdatePolicyValues() => new[]
    {
        new RegValue(@"SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU",
            "NoAutoRebootWithLoggedOnUsers", 1),
        new RegValue(@"SOFTWARE\Microsoft\WindowsUpdate\UX\Settings",
            "ActiveHoursStart", 8),
        new RegValue(@"SOFTWARE\Microsoft\WindowsUpdate\UX\Settings",
            "ActiveHoursEnd", 23),
    };

    /// Appliance standard: never sleep on AC; don't auto-reboot under a
    /// logged-on technician. Best-effort — a failed tweak must not fail install.
    public static void Apply(Action<string>? status = null)
    {
        foreach (var cmd in PowerCfgCommands())
        {
            var parts = cmd.Split(' ', 2);
            try
            {
                var r = WslRunner.RunAnsi(parts[0], parts[1], 60);
                if (r.ExitCode != 0)
                    status?.Invoke($"NOTE: power tweak skipped ({cmd} exited {r.ExitCode}: {r.Error.Trim()})");
            }
            catch (Exception ex) { status?.Invoke($"NOTE: power tweak skipped ({ex.Message})"); }
        }
        foreach (var v in UpdatePolicyValues())
        {
            try
            {
                using var key = Registry.LocalMachine.CreateSubKey(v.SubKey);
                key?.SetValue(v.Name, v.Value, RegistryValueKind.DWord);
            }
            catch (Exception ex) { status?.Invoke($"NOTE: update-policy tweak skipped ({ex.Message})"); }
        }
    }
}