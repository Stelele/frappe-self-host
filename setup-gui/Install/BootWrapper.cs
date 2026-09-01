namespace BasaPOS.Setup.Install;

public static class BootWrapper
{
    public static string Render() =>
"""
@echo off
rem BasaPOS boot wrapper - starts appliance at logon and waits for health
"%SystemRoot%\System32\wsl.exe" -d BasaPOS --exec /bin/true
"%SystemRoot%\System32\wsl.exe" -d BasaPOS -u root --exec /sbin/hwclock -s 2>nul
set /a tries=0
:wait
"%SystemRoot%\System32\curl.exe" -sk -o nul https://basapos.local/api/method/ping
if %errorlevel%==0 exit /b 0
set /a tries+=1
if %tries% geq 60 exit /b 1
ping -n 11 127.0.0.1 >nul
goto wait
""";

    public static void Write()
    {
        Directory.CreateDirectory(Paths.ProgramData);
        File.WriteAllText(Path.Combine(Paths.ProgramData, "boot.cmd"), Render());
    }

    public static void Delete()
    {
        var f = Path.Combine(Paths.ProgramData, "boot.cmd");
        if (File.Exists(f)) File.Delete(f);
        if (Directory.Exists(Paths.ProgramData) &&
            Directory.GetFiles(Paths.ProgramData).Length == 0)
            Directory.Delete(Paths.ProgramData);
    }
}
