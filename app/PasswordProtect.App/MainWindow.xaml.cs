using System.Runtime.InteropServices;
using System.Security;
using System.Windows;
using PasswordProtect.Core;

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

    private async void Preview_Click(object sender, RoutedEventArgs e) => await _vm.PreviewAsync();

    private async void Apply_Click(object sender, RoutedEventArgs e)
    {
        bool needsNew = _vm.NeedsNewPassword;
        bool needsCurrent = _vm.NeedsCurrentPassword;

        if (needsNew && PasswordBox.SecurePassword.Length == 0)
        {
            Warn("Enter a new password first.");
            return;
        }
        if (needsNew && ConfirmBox.SecurePassword.Length > 0 &&
            !SecureEquals(PasswordBox.SecurePassword, ConfirmBox.SecurePassword))
        {
            Warn("The two passwords do not match.");
            return;
        }
        if (needsCurrent && CurrentBox.SecurePassword.Length == 0)
        {
            Warn("Enter the current password.");
            return;
        }

        if (Overwrite_NeedsConfirm() &&
            MessageBox.Show(this,
                "Overwrite the original files in place? This replaces them with the result and cannot be undone.",
                "PasswordProtect", MessageBoxButton.OKCancel, MessageBoxImage.Warning) != MessageBoxResult.OK)
        {
            return;
        }

        switch (_vm.Operation)
        {
            case AppOperation.Protect:
                await _vm.RunAsync(PasswordBox.SecurePassword.Copy());
                break;
            case AppOperation.ChangePassword:
                await _vm.RunEditAsync(CurrentBox.SecurePassword.Copy(), PasswordBox.SecurePassword.Copy(), PasswordEditMode.Change);
                break;
            case AppOperation.RemovePassword:
                await _vm.RunEditAsync(CurrentBox.SecurePassword.Copy(), null, PasswordEditMode.Remove);
                break;
        }

        PasswordBox.Clear();
        ConfirmBox.Clear();
        CurrentBox.Clear();
    }

    private bool Overwrite_NeedsConfirm() => _vm.Overwrite;

    private void Warn(string message) =>
        MessageBox.Show(this, message, "PasswordProtect", MessageBoxButton.OK, MessageBoxImage.Warning);

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
