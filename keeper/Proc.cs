namespace BasaPOS.Keeper;

public interface IChildProcess : IDisposable
{
    int Pid { get; }
    int ExitCode { get; }
    string StderrTail { get; }
    bool Exited();
    int WaitForExit(int msTimeout);
    void KillTree();
}

public interface IProcessRunner
{
    IChildProcess SpawnWslKeepalive();
    IReadOnlyList<string> ListDistros();
    string RunWslDiag(string arguments);
}

public interface ISiteProbe
{
    Task<bool> ProbeAsync(CancellationToken ct);
}

public sealed class FatalKeeperException(string message) : Exception(message);
