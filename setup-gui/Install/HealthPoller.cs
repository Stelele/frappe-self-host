using System.Net.Http;
using System.Security.Cryptography.X509Certificates;

namespace BasaPOS.Setup.Install;

public static class HealthPoller
{
    // Primary health check: hit the site from WINDOWS over the real browser
    // network path (hosts entry + WSL localhostForwarding), pinning the cert to
    // basapos.crt so we verify the SITE's own certificate. The cert isn't in the
    // trust store yet during this window (that's step 9), so we pin by thumbprint
    // here and do a proper trust-store check later via VerifyBrowserTrusted.
    public static async Task<bool> WaitHealthy(Action<string> status, int maxMinutes = 15)
    {
        string? pinnedThumbprint = null;
        var certFile = Path.Combine(Paths.ConfigDir, "basapos.crt");

        using var handler = new HttpClientHandler
        {
            ServerCertificateCustomValidationCallback =
                (_, cert, _, _) => cert is null ||
                    (pinnedThumbprint is not null && cert.Thumbprint == pinnedThumbprint)
        };
        using var http = new HttpClient(handler) { Timeout = TimeSpan.FromSeconds(10) };

        var deadline = DateTime.UtcNow.AddMinutes(maxMinutes);
        int attempt = 0;
        while (DateTime.UtcNow < deadline)
        {
            attempt++;
            if (pinnedThumbprint is null && File.Exists(certFile))
            {
                try { pinnedThumbprint = X509CertificateLoader.LoadCertificateFromFile(certFile).Thumbprint; }
                catch { /* cert mid-write — retry next poll */ }
            }
            try
            {
                var r = await http.GetAsync(Paths.SiteUrl + "/api/method/ping");
                if (r.IsSuccessStatusCode) { status($"Healthy after {attempt} polls."); return true; }
            }
            catch { /* not up yet */ }
            status($"Waiting for site... (poll {attempt})");
            await Task.Delay(TimeSpan.FromSeconds(10));
        }
        return false;
    }

    // Browser-equivalent check: default TLS validation against the Windows
    // trust store — exactly what Chrome/Edge do. Used AFTER the certificate is
    // imported, so "done" means a real browser will work, not just our pin.
    public static async Task<bool> VerifyBrowserTrusted(Action<string> status)
    {
        using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(15) };
        try
        {
            var r = await http.GetAsync(Paths.SiteUrl + "/api/method/ping");
            if (r.IsSuccessStatusCode) { status("Certificate trusted by Windows (browser path OK)."); return true; }
        }
        catch { /* cert not trusted or site unreachable */ }
        return false;
    }
}
