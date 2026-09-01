namespace BasaPOS.Setup.Install;

/// UI surface consumed by orchestrators. Implemented by MainForm (GUI) and
/// UnattendedUi (headless CI/log mode, added in a later task).
public interface ISetupUi
{
    void Status(string line);
    void Progress(int pct);
    bool Healthy { get; set; }
    void ShowDone(string password);
    void ShowReboot(string message);
}
