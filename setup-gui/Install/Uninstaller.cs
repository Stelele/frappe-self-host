namespace BasaPOS.Setup.Install;

public sealed class Uninstaller(ISetupUi ui)
{
    public void Run() => Run(keepBackups: true);

    public void Run(bool keepBackups) =>
        throw new NotImplementedException("wired in a later task");
}
