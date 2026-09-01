namespace BasaPOS.Setup.Install;

public sealed class InstallOrchestrator(ISetupUi ui)
{
    public void RunAll() => RunAll(null);

    public void RunAll(string? payloadDirOverride) =>
        throw new NotImplementedException("wired in a later task");
}
