using System.Runtime.InteropServices;
using System.Security;
using System.Windows;

namespace PasswordProtect.App;

public partial class MainWindow : Window
{
    private readonly MainViewModel _vm;

    public MainWindow(AppServices services, IEnumerable<string>? initialFiles = null)
    {
        InitializeComponent();
        _vm = new MainViewModel(services);
        DataContext = _vm;
        if (initialFiles is not null) _vm.AddFiles(initialFiles);
    }

    private void OnDragOver(object sender, DragEventArgs e)
    {
        e.Effects = e.Data.GetDataPresent(DataFormats.FileDrop) ? DragDropEffects.Copy : DragDropEffects.None;
        e.Handled = true;
    }

    private void OnDrop(object sender, DragEventArgs e)
    {
        if (e.Data.GetDataPresent(DataFormats.FileDrop) &&
            e.Data.GetData(DataFormats.FileDrop) is string[] files)
        {
            _vm.AddFiles(files);
        }
    }

    private void AddFiles_Click(object sender, RoutedEventArgs e)
    {
        var dlg = new Microsoft.Win32.OpenFileDialog { Multiselect = true, Title = "Choose files to protect" };
        if (dlg.ShowDialog(this) == true) _vm.AddFiles(dlg.FileNames);
    }

    private void Clear_Click(object sender, RoutedEventArgs e) => _vm.Clear();

    private async void Protect_Click(object sender, RoutedEventArgs e)
    {
        if (PasswordBox.SecurePassword.Length == 0)
        {
            MessageBox.Show(this, "Enter a password first.", "PasswordProtect",
                MessageBoxButton.OK, MessageBoxImage.Warning);
            return;
        }
        if (ConfirmBox.SecurePassword.Length > 0 &&
            !SecureEquals(PasswordBox.SecurePassword, ConfirmBox.SecurePassword))
        {
            MessageBox.Show(this, "The two passwords do not match.", "PasswordProtect",
                MessageBoxButton.OK, MessageBoxImage.Warning);
            return;
        }

        SecureString pw = PasswordBox.SecurePassword.Copy();
        await _vm.RunAsync(pw); // RunAsync disposes pw
        PasswordBox.Clear();
        ConfirmBox.Clear();
    }

    private static bool SecureEquals(SecureString a, SecureString b)
    {
        IntPtr pa = IntPtr.Zero, pb = IntPtr.Zero;
        try
        {
            pa = Marshal.SecureStringToBSTR(a);
            pb = Marshal.SecureStringToBSTR(b);
            return Marshal.PtrToStringBSTR(pa) == Marshal.PtrToStringBSTR(pb);
        }
        finally
        {
            if (pa != IntPtr.Zero) Marshal.ZeroFreeBSTR(pa);
            if (pb != IntPtr.Zero) Marshal.ZeroFreeBSTR(pb);
        }
    }
}
