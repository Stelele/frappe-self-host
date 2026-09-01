using BasaPOS.Setup;

if (args.Contains("--install")) { Environment.Exit(App.RunUnattended(install: true, args)); return; }
if (args.Contains("--uninstall")) { Environment.Exit(App.RunUnattended(install: false, args)); return; }

ApplicationConfiguration.Initialize();
Application.Run(new MainForm());
