using System.Security.Cryptography.X509Certificates;

namespace BasaPOS.Setup.Install;

public static class CertTrust
{
    public static void Trust(string certFile)
    {
        using var cert = X509CertificateLoader.LoadCertificateFromFile(certFile);
        using var store = new X509Store(StoreName.Root, StoreLocation.LocalMachine);
        store.Open(OpenFlags.ReadWrite);
        store.Remove(cert);   // idempotent replace (unique per-install CN)
        store.Add(cert);
    }

    public static void UntrustAllBasaPOS()
    {
        using var store = new X509Store(StoreName.Root, StoreLocation.LocalMachine);
        store.Open(OpenFlags.ReadWrite);
        foreach (var c in store.Certificates.Find(X509FindType.FindBySubjectName,
                     "basapos", false))
            if (c.Subject.Contains("basapos", StringComparison.OrdinalIgnoreCase))
                store.Remove(c);
    }
}
