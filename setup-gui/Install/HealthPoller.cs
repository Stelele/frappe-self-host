using System.Net.Http;
using System.Security.Cryptography.X509Certificates;

namespace BasaPOS.Setup.Install;

public static class HealthPoller
{
    public static async Task<bool> WaitHealthy(Action<string> status, int maxMinutes = 15)
    {
        string? pinnedThumbprint = null;
        var certFile = Path.Combine(Paths.ConfigDir, "basapos.crt");
        if (File.Exists(certFile))
            pinnedThumbprint = new X509Certificate2(certFile).Thumbprint;

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
            try
            {
                var r = await http.GetAsync(Paths.SiteUrl + "/api/method/ping");
                if (r.IsSuccessStatusCode) { status($"Healthy after {attempt} polls."); return true; }
            }
            catch { /* not up yet */ }

            if (attempt % 6 == 0)
            {
                // inside-WSL fallback (v2 lesson: Windows-side polling can lie)
                try
                {
                    var inWsl = WslRunner.Wsl(
                        $"-d {Paths.DistroName} -- curl -sk -o /dev/null -w %{{http_code}} https://localhost/api/method/ping",
                        30);
                    if (inWsl.Output.Trim().EndsWith("200"))
                    { status("Healthy (in-WSL check)."); return true; }
                }
                catch { /* distro busy — keep polling */ }
            }
            status($"Waiting for site… (poll {attempt})");
            await Task.Delay(TimeSpan.FromSeconds(10));
        }
        return false;
    }
}
