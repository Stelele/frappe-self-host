using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;

namespace BasaPOS.Setup.Install;

public static class Credentials
{
    // unambiguous alphabet (no 0/O, 1/l/I)
    const string Alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz23456789";

    public static string Generate(int len, Random rng)
    {
        var sb = new StringBuilder(len);
        for (int i = 0; i < len; i++) sb.Append(Alphabet[rng.Next(Alphabet.Length)]);
        return sb.ToString();
    }

    public static void WriteInstallPassword(string adminPassword)
    {
        Directory.CreateDirectory(Paths.ConfigDir);
        var file = Path.Combine(Paths.ConfigDir, "install-password.txt");
        File.WriteAllText(file, adminPassword);
        RestrictToAdmins(file);
    }

    public static void RestrictToAdmins(string file)
    {
        // SIDs, not names: builtin group names are localized on non-English Windows
        var admins = new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null);
        var sec = new FileSecurity();
        sec.SetOwner(admins);
        sec.AddAccessRule(new FileSystemAccessRule(admins,
            FileSystemRights.FullControl, AccessControlType.Allow));
        sec.AddAccessRule(new FileSystemAccessRule(
            WindowsIdentity.GetCurrent().User!,
            FileSystemRights.ReadAndExecute, AccessControlType.Allow));
        new FileInfo(file).SetAccessControl(sec);
    }
}