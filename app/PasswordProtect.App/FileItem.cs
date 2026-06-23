namespace PasswordProtect.App;

/// <summary>One row in the bulk list, bound to the UI with live status updates.</summary>
public sealed class FileItem : ObservableObject
{
    public string InputPath { get; }

    public FileItem(string path)
    {
        InputPath = path;
        _status = "Pending";
    }

    public string FileName => Path.GetFileName(InputPath);

    private string _status;
    public string Status { get => _status; set => Set(ref _status, value); }

    private string _message = "";
    public string Message { get => _message; set => Set(ref _message, value); }

    private string? _outputPath;
    public string? OutputPath { get => _outputPath; set => Set(ref _outputPath, value); }
}
