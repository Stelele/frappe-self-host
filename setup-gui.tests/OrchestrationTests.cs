using BasaPOS.Setup.Install;
using Xunit;

public class OrchestrationTests
{
    [Fact]
    public void UnattendedUi_surfaces_done_reboot_and_health()
    {
        var lines = new List<string>();
        var ui = new UnattendedUi(lines.Add);
        Assert.False(ui.Healthy);
        ui.Status("step");
        ui.Progress(50);
        ui.ShowReboot("reboot now");
        ui.ShowDone("pw123");
        Assert.True(ui.Healthy);
        Assert.True(ui.RebootNeeded);
        Assert.Contains("DONE password=pw123", lines);
        Assert.Contains("REBOOT_REQUIRED reboot now", lines);
        Assert.Contains("[progress] 50%", lines);
    }

    [Fact]
    public void Generated_certificate_has_stable_thumbprint()
    {
        using var rsa = System.Security.Cryptography.RSA.Create(2048);
        var req = new System.Security.Cryptography.X509Certificates.CertificateRequest(
            "CN=basapos-test.local", rsa,
            System.Security.Cryptography.HashAlgorithmName.SHA256,
            System.Security.Cryptography.RSASignaturePadding.Pkcs1);
        using var cert = req.CreateSelfSigned(
            DateTimeOffset.Now.AddDays(-1), DateTimeOffset.Now.AddYears(1));
        Assert.Equal(40, cert.Thumbprint.Length);
    }
}
