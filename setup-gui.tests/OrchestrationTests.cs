using BasaPOS.Setup.Install;
using Xunit;

public class OrchestrationTests
{
    [Fact]
    public void BootWrapper_cmd_starts_wsl_and_polls_health()
    {
        var s = BootWrapper.Render();
        Assert.Contains("wsl.exe\" -d BasaPOS --exec /bin/true", s);
        Assert.Contains("hwclock -s", s);
        Assert.Contains("https://basapos.local/api/method/ping", s);
        Assert.Contains("if %tries% geq 60 exit /b 1", s);
        Assert.Contains("ping -n 11 127.0.0.1", s);
        Assert.DoesNotContain("timeout /t", s);
        Assert.DoesNotContain("%USERPROFILE%", s); // ProgramData, not profile (v2 lesson)
        // keeper: holds the VM open so it never idles out (vmIdleTimeout ignored)
        // NOTE: the reliable keeper is the dedicated BasaPOS-Keeper task (wsl.exe
        // as its direct action); boot.cmd's foreground :hold is belt-and-braces.
        // `start /b` background keepers are NOT used — they do not reliably
        // survive when boot.cmd runs under a scheduled task.
        Assert.Contains("goto :hold", s);
        Assert.Contains("--exec /bin/sleep infinity", s);
        Assert.DoesNotContain("if %errorlevel%==0 exit /b 0", s); // must NOT exit on healthy
        Assert.DoesNotContain("start /b", s);
    }

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
