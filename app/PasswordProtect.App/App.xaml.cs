using System.Diagnostics;
using System.Windows;

namespace PasswordProtect.App;

public partial class App : Application
{
    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);

        CliOptions cli = CliOptions.Parse(e.Args);
        string exe = Environment.ProcessPath
            ?? Process.GetCurrentProcess().MainModule?.FileName
            ?? "PasswordProtect.exe";

        switch (cli.Verb)
        {
            case CliVerb.Register:
                ContextMenuRegistrar.Register(exe);
                MessageBox.Show("“Protect with password” was added to the right-click menu.",
                    "PasswordProtect", MessageBoxButton.OK, MessageBoxImage.Information);
                Shutdown();
                return;

            case CliVerb.Unregister:
                ContextMenuRegistrar.Unregister();
                MessageBox.Show("“Protect with password” was removed from the right-click menu.",
                    "PasswordProtect", MessageBoxButton.OK, MessageBoxImage.Information);
                Shutdown();
                return;
        }

        var services = new AppServices();
        var window = new MainWindow(services, cli.Files);
        window.Show();
    }
}
