namespace BasaPOS.Keeper;

public sealed class SiteProbe : ISiteProbe
{
    static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(10) };
    public async Task<bool> ProbeAsync(CancellationToken ct)
    {
        try
        {
            var r = await Http.GetAsync("https://basapos.local/api/method/ping", ct);
            return r.IsSuccessStatusCode;
        }
        catch { return false; }
    }
}
